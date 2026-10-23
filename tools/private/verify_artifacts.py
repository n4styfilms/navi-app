"""Validate private mobile packages. Structural checks do not prove device behavior."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import subprocess
import sys
import zipfile


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _archive(path):
    try:
        archive = zipfile.ZipFile(path)
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError('Duplicate archive entries')
        if any(PurePosixPath(n).is_absolute() or '..' in PurePosixPath(n).parts for n in names):
            raise ValueError('Unsafe archive entry')
        bad = archive.testzip()
        if bad:
            raise ValueError(f'Archive checksum failed: {bad}')
        return archive
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise ValueError(f'Invalid package: {error}') from error


def _commit(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value):
        raise ValueError('Missing or invalid source provenance')
    return value


def _external(command):
    try:
        result = subprocess.run([str(c) for c in command], check=True,
                                capture_output=True, text=True, timeout=120)
        return result.stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f'Package tool failed: {error}') from error


def verify_apk(apk_path: Path, aapt2_path: Path, apksigner_path: Path, *, require_maplibre=False) -> dict:
    with _archive(apk_path) as archive:
        names = archive.namelist()
        if 'AndroidManifest.xml' not in names:
            raise ValueError('Missing Android manifest')
        libraries = [n for n in names if n.startswith('lib/arm64-v8a/') and n.endswith('.so')]
        if not libraries:
            raise ValueError('Missing ARM64 library')
        abis = sorted({n.split('/')[1] for n in names if n.startswith('lib/') and n.endswith('.so')})
        if require_maplibre:
            if not {'lib/arm64-v8a/liborganicmaps.so', 'lib/arm64-v8a/libmaplibre.so'}.issubset(libraries):
                raise ValueError('MapLibre device renderer and native router must both be present')
            if abis != ['arm64-v8a']:
                raise ValueError('Unexpected ABI in ARM64 private map package')
        for library in libraries:
            data = archive.read(library)[:64]
            if len(data) < 20 or data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
                raise ValueError(f'Invalid ARM64 ELF library: {library}')
        try:
            provenance = json.loads(archive.read('assets/private-build.json'))
            commit = _commit(provenance.get('source_commit'))
        except (KeyError, json.JSONDecodeError, AttributeError) as error:
            raise ValueError('Missing or invalid source provenance') from error
    badging = _external([aapt2_path, 'dump', 'badging', apk_path])
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'", badging, re.M)
    if not package:
        raise ValueError('Invalid aapt2 package metadata')
    _external([apksigner_path, 'verify', '--verbose', apk_path])
    return {'kind': 'apk', 'application_id': package[1], 'version_code': package[2],
            'version_name': package[3], 'abis': abis, 'signature_verified': True,
            'maplibre_device_verified': bool(require_maplibre),
            'artifact_sha256': sha256(apk_path), 'source_commit': commit}


def _entitlements(signature):
    try:
        magic, length, count = struct.unpack_from('>III', signature)
        if magic != 0xfade0cc0 or length > len(signature) or count > 100:
            raise ValueError('Invalid code signature')
        result = {}
        for i in range(count):
            slot, offset = struct.unpack_from('>II', signature, 12 + 8*i)
            if slot == 7:
                raise ValueError('DER entitlements unsupported in unsigned private package')
            if slot == 5:
                blob_magic, size = struct.unpack_from('>II', signature, offset)
                if blob_magic != 0xfade7171 or offset + size > length:
                    raise ValueError('Invalid entitlement blob')
                parsed = plistlib.loads(signature[offset+8:offset+size])
                if not isinstance(parsed, dict):
                    raise ValueError('Invalid entitlement dictionary')
                result.update(parsed)
        return result
    except (struct.error, plistlib.InvalidFileException) as error:
        raise ValueError('Invalid embedded entitlements') from error


def _macho(data):
    if len(data) < 8:
        raise ValueError('Truncated executable')
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        fat64 = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        if count < 1 or count > 32:
            raise ValueError('Invalid universal executable')
        result = []
        for i in range(count):
            position = 8 + i*(32 if fat64 else 20)
            if fat64:
                _, _, offset, size, _, _ = struct.unpack_from('>IIQQII', data, position)
            else:
                _, _, offset, size, _ = struct.unpack_from('>IIIII', data, position)
            if offset + size > len(data):
                raise ValueError('Truncated universal executable')
            result.extend(_macho(data[offset:offset+size]))
        return result
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Unsupported iOS device executable')
    _, cpu, _, _, count, command_bytes, _, _ = struct.unpack_from('<IIIIIIII', data)
    if count > 10000 or command_bytes > len(data)-32:
        raise ValueError('Invalid Mach-O load commands')
    platform = None
    entitlements = {}
    position = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position+size > 32+command_bytes:
            raise ValueError('Invalid Mach-O command length')
        if command == 0x32 and size >= 24:
            platform = struct.unpack_from('<I', data, position+8)[0]
        elif command == 0x25 and size >= 16:
            platform = 2  # LC_VERSION_MIN_IPHONEOS, legacy physical devices.
        elif command == 0x1d and size >= 16:
            offset, length = struct.unpack_from('<II', data, position+8)
            if offset+length > len(data):
                raise ValueError('Truncated code signature')
            entitlements.update(_entitlements(data[offset:offset+length]))
        position += size
    if platform != 2 or cpu not in (0x100000c, 12):
        raise ValueError('Executable is not an iOS device binary')
    return [('arm64' if cpu == 0x100000c else 'arm', entitlements)]


def _restricted(entitlements):
    return sorted(k for k, value in entitlements.items() if value and (
        k.startswith(('com.apple.developer.', 'com.apple.security.application-groups',
                      'com.apple.developer.ubiquity', 'com.apple.developer.icloud'))
        or k == 'aps-environment'))


def verify_ipa(ipa_path: Path, *, require_maplibre=False) -> dict:
    with _archive(ipa_path) as archive:
        names = archive.namelist()
        main_plists = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if len(main_plists) != 1:
            raise ValueError('Expected exactly one main app')
        app_prefix = main_plists[0].rsplit('/', 1)[0] + '/'
        try:
            info = plistlib.loads(archive.read(main_plists[0]))
        except (plistlib.InvalidFileException, ValueError) as error:
            raise ValueError('Invalid main app Info.plist') from error
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or '/' in executable or app_prefix+executable not in names:
            raise ValueError('Missing or invalid executable')
        commit = _commit(info.get('NaviSourceCommit'))
        bundle = info.get('CFBundleIdentifier')
        if not isinstance(bundle, str) or not bundle:
            raise ValueError('Missing bundle identifier')
        results = _macho(archive.read(app_prefix+executable))
        maplibre = app_prefix + 'Frameworks/MapLibre.framework/MapLibre'
        if require_maplibre:
            if maplibre not in names:
                raise ValueError('Missing embedded MapLibre device framework')
            results.extend(_macho(archive.read(maplibre)))
        for name in names:
            if name == app_prefix+executable or not name.startswith(app_prefix) or name.endswith('/'):
                continue
            if name.endswith('embedded.mobileprovision'):
                raise ValueError('Unsigned private package must not contain provisioning profiles')
            if name.endswith(('.entitlements', '.xcent')):
                try:
                    if _restricted(plistlib.loads(archive.read(name))):
                        raise ValueError('Restricted entitlement in packaged configuration')
                except plistlib.InvalidFileException as error:
                    raise ValueError('Unreadable packaged entitlements') from error
            if '/Frameworks/' in name or '/PlugIns/' in name:
                if require_maplibre and name == maplibre:
                    continue
                content = archive.read(name)
                if content[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                    results.extend(_macho(content))
        restricted = sorted({key for _, ent in results for key in _restricted(ent)})
        if restricted:
            raise ValueError(f'Restricted entitlement: {", ".join(restricted)}')
        architectures = sorted({architecture for architecture, _ in results})
        if 'arm64' not in architectures:
            raise ValueError('Missing ARM64 iOS device binary')
        return {'kind': 'ipa', 'bundle_id': bundle, 'version': str(info.get('CFBundleVersion', '')),
                'executable': executable, 'architectures': architectures, 'platform': 'iOS',
                'restricted_entitlements': [], 'artifact_sha256': sha256(ipa_path),
                'maplibre_device_verified': bool(require_maplibre),
                'source_commit': commit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='kind', required=True)
    apk = sub.add_parser('apk')
    apk.add_argument('artifact', type=Path)
    apk.add_argument('--aapt2', required=True, type=Path)
    apk.add_argument('--apksigner', required=True, type=Path)
    apk.add_argument('--require-maplibre', action='store_true')
    ipa = sub.add_parser('ipa')
    ipa.add_argument('artifact', type=Path)
    ipa.add_argument('--require-maplibre', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        report = (verify_apk(args.artifact, args.aapt2, args.apksigner, require_maplibre=args.require_maplibre)
                  if args.kind == 'apk' else verify_ipa(args.artifact, require_maplibre=args.require_maplibre))
    except (ValueError, OSError, struct.error) as error:
        print(f'Verification failed: {error}', file=sys.stderr)
        return 1
    output = json.dumps(report, indent=2, ensure_ascii=False)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output+'\n', encoding='utf-8')
    print(output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
