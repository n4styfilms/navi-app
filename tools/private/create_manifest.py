"""Bundle verified APK/IPA pairs without implying that a device was tested."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys


def _hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def create_manifest(artifacts: list[Path], reports: list[dict], source_commit: str,
                    run_id: str, output_directory: Path, *,
                    platform_commits: dict[str, str] | None = None) -> Path:
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit) or not run_id.strip():
        raise ValueError('Valid source commit and run ID required')
    expected_commits = dict(platform_commits) if platform_commits is not None else {
        'apk': source_commit, 'ipa': source_commit}
    if set(expected_commits) != {'apk', 'ipa'} or any(
            not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value)
            for value in expected_commits.values()):
        raise ValueError('An explicit valid source commit for each platform is required')
    if len(artifacts) != 2 or {p.suffix for p in artifacts} != {'.apk', '.ipa'}:
        raise ValueError('One APK and one IPA are required')
    if len(reports) != 2 or {r.get('kind') for r in reports} != {'apk', 'ipa'}:
        raise ValueError('One verified report per platform required')
    destination = output_directory / 'build-manifest.json'
    if destination.exists():
        raise ValueError('Refusing to replace an existing delivery manifest')
    entries = []
    for artifact in artifacts:
        if not artifact.is_file():
            raise ValueError(f'Missing artifact: {artifact.name}')
        report = next(r for r in reports if r['kind'] == artifact.suffix[1:])
        if report.get('source_commit') != expected_commits[report['kind']]:
            raise ValueError('Report source commit does not match this delivery')
        actual_hash = _hash(artifact)
        if report.get('artifact_sha256') != actual_hash:
            raise ValueError('Report hash does not match the actual artifact')
        entries.append({'filename': artifact.name, 'kind': report['kind'], 'sha256': actual_hash,
                        'source_commit': report['source_commit'],
                        'package_verified': True, 'installed_on_device': False,
                        'navigation_tested': False})
    output_directory.mkdir(parents=True, exist_ok=True)
    for artifact in artifacts:
        target = output_directory / artifact.name
        if target.resolve() != artifact.resolve():
            if target.exists():
                raise ValueError(f'Refusing to overwrite artifact: {target.name}')
            shutil.copyfile(artifact, target)
    unique_commits = set(expected_commits.values())
    data = {'source_commit': next(iter(unique_commits)) if len(unique_commits) == 1 else None,
            'source_commits': expected_commits, 'run_id': run_id,
            'created_utc': datetime.now(timezone.utc).isoformat(), 'artifacts': entries}
    (output_directory / 'SHA256SUMS.txt').write_text(
        ''.join(f"{a['sha256']}  {a['filename']}\n" for a in entries), encoding='utf-8')
    destination.write_text(json.dumps(data, indent=2)+'\n', encoding='utf-8')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--apk-commit', help='Explicit Android source; defaults to --commit')
    parser.add_argument('--ipa-commit', help='Explicit iOS source; defaults to --commit')
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        reports = [json.loads((args.reports / f'{kind}-report.json').read_text(encoding='utf-8'))
                   for kind in ('apk', 'ipa')]
        sources = {'apk': args.apk_commit or args.commit, 'ipa': args.ipa_commit or args.commit}
        result = create_manifest([args.apk, args.ipa], reports, args.commit, args.run_id,
                                 args.output, platform_commits=sources)
    except (ValueError, OSError) as error:
        print(f'Delivery verification failed: {error}', file=sys.stderr)
        return 1
    print(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
