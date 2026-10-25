"""Compile the real session fixture as an ad-hoc Simulator app with normal app Keychain context."""
import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
from select_ios_simulator import select

out = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[2]
subprocess.run(['gem', 'install', '--user-install', 'xcodeproj', '--no-document'], check=True, timeout=180)
(out / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.navi.friendstest', 'CFBundleExecutable': 'FriendsNativeProbe',
    'CFBundleName': 'Friends Native Test', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.6', 'UILaunchScreen': {},
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True,
        'NSExceptionDomains': {'127.0.0.1': {'NSExceptionAllowsInsecureHTTPLoads': True}}}
}))
script = out / 'generate-project.rb'
script.write_text('''require 'xcodeproj'
out = ARGV.fetch(0)
project = Xcodeproj::Project.new(File.join(out, 'FriendsNativeProbe.xcodeproj'))
target = project.new_target(:application, 'FriendsNativeProbe', :ios, '15.6')
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.navi.friendstest'
  config.build_settings['INFOPLIST_FILE'] = 'Info.plist'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'YES'
  config.build_settings['CODE_SIGN_IDENTITY'] = '-'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
Dir.glob(File.join(out, 'Sources/FriendsNativeProbe/*.swift')).each do |path|
  target.source_build_phase.add_file_reference(project.main_group.new_file(path))
end
package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/firebase/firebase-ios-sdk.git'
package.requirement = {'kind' => 'exactVersion', 'version' => '13.1.1'}
project.root_object.package_references << package
['FirebaseCore', 'FirebaseAuth', 'FirebaseDatabase'].each do |name|
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = name
  target.package_product_dependencies << dependency
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = dependency
  target.frameworks_build_phase.files << build
end
project.save
''', encoding='utf-8')
subprocess.run(['ruby', str(script), str(out)], check=True, timeout=30)
# First boot includes Apple data migration. Start it while the SDK is compiling,
# rather than consuming the native test's execution deadline before its app starts.
inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
device = select(inventory)
(out / 'simulator.json').write_text(json.dumps(device, indent=2), encoding='utf-8')
if device['state'] != 'Booted':
    subprocess.run(['xcrun', 'simctl', 'boot', device['udid']], check=True, timeout=60)
boot_log = (out.parent / 'friends-evidence/simulator-boot.log').open('w', encoding='utf-8')
boot = subprocess.Popen(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], stdout=boot_log, stderr=subprocess.STDOUT)
subprocess.run(['xcodebuild', '-project', str(out / 'FriendsNativeProbe.xcodeproj'), '-scheme', 'FriendsNativeProbe',
    '-sdk', 'iphonesimulator', '-destination', 'platform=iOS Simulator,id=' + device['udid'], '-configuration', 'Debug',
    '-derivedDataPath', str(out / 'DerivedData'), 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'build'], check=True, timeout=900)
try:
    if boot.wait(timeout=600) != 0:
        raise RuntimeError('Simulator boot failed before native friends tests; see simulator-boot.log')
finally:
    boot_log.close()
resolved = out / 'FriendsNativeProbe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
(out / 'Package.resolved').write_bytes(resolved.read_bytes())
# Keep the host protocol unchanged: this executable now launches the real Simulator app.
launcher = out / '.build/debug/FriendsNativeProbe'
launcher.parent.mkdir(parents=True, exist_ok=True)
launcher.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(root / 'tools/private/run-friends-apple.py'))
                    + ' ' + shlex.quote(str(out)) + '\n', encoding='utf-8')
launcher.chmod(0o755)
