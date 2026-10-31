"""Isolate pinned MapLibre startup on an actual Apple simulator; no app credentials or network map."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import textwrap
import urllib.request
import zipfile
from select_ios_simulator import select

out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
work = out/'work'
work.mkdir(exist_ok=True)
repo = Path(__file__).resolve().parents[2]

def run(args, timeout=120):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stdout}\n{result.stderr}')
    return result.stdout.strip()

url = 'https://github.com/maplibre/maplibre-native/releases/download/ios-v6.31.0/MapLibre.dynamic.xcframework.zip'
archive = work/'MapLibre.zip'
urllib.request.urlretrieve(url, archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == 'de3aaa435dd86768b06d90245e630d068dd7eef1491afae7217d1654c52c462a'
with zipfile.ZipFile(archive) as zipped:
    zipped.extractall(work)
framework = work/'MapLibre.xcframework/ios-arm64_x86_64-simulator/MapLibre.framework'
assert framework.is_dir()
source = work/'Probe.swift'
source.write_text('''import UIKit
import MapLibre
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
    config.delegateClass = SceneDelegate.self
    return config
  }
}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  var owner: NaviMapController?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    self.window = window
    if ProcessInfo.processInfo.arguments.contains("--friends-map") {
      window.makeKeyAndVisible()
      Task { @MainActor in
        do { try await FriendsMapScenario.run(in: root); fflush(stdout); exit(0) }
        catch { print("NAVI_FRIENDS_MAP_ERROR \\(error)"); fflush(stdout); exit(1) }
      }
      return
    }
    NSLog("NAVI_MAP_PROBE_BEFORE_INIT")
    let owner = NaviMapController(frame: .zero, configuration: NaviEsriConfiguration(key: "", language: "de"))
    self.owner = owner
    let map = owner.view
    NSLog("NAVI_MAP_PROBE_AFTER_INIT")
    root.view.addSubview(map)
    map.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([map.topAnchor.constraint(equalTo: root.view.topAnchor),
      map.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
      map.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
      map.trailingAnchor.constraint(equalTo: root.view.trailingAnchor)])
    window.makeKeyAndVisible()
    owner.onState = { state in NSLog("NAVI_MAP_PROBE_STATE_%@", String(describing: state.status)) }
    owner.setFollowing(true)
    owner.setBasemap(.street)
    runLegacyHostContract(ProcessInfo.processInfo.arguments.last ?? "--legacy-logging")
    NSLog("NAVI_MAP_PROBE_READY")
    probeReadyCheckpoint()
  }
  @objc dynamic func probeReadyCheckpoint() {}
}
''')
# Only the unused route-input type is doubled. No fake renderer, HTTP transport or controller.
route_types = work/'UnusedRouteInput.swift'
route_types.write_text('''import Foundation
enum NaviRouteProbeState { case preview, navigating, none }
struct NaviRouteProbePoint { var latitude: Double; var longitude: Double }
struct NaviRouteSnapshot {
  var state = NaviRouteProbeState.none
  var geometryIncluded = false
  var geometry: [NaviRouteProbePoint] = []
  var revision: UInt64 = 0
}
''')
# Execute the actual legacy-host access expressions against a loaded external-map
# boundary. Its legacy-renderer getter is forbidden, just as the Navi root owns
# no EAGL view. Also exercise a legacy root to retain that provider's behavior.
carplay = (repo/'iphone/Maps/Classes/CarPlay/CarPlayService.swift').read_text()
logging = carplay[carplay.index('    var hosting ='):carplay.index('    let scenes =', carplay.index('    var hosting ='))]
reconcile = carplay.split('  private func reconcileMapHostIfOrphaned() {',1)[1].split('    let wasHostingMapOnCarScreen',1)[0]
contract = work/'LegacyHostContract.swift'
contract.write_text('''import UIKit
enum ProbeMapHost { case none, phone }
final class MapViewController: UIViewController {
  static let fixture = MapViewController()
  var usesExternalMap = true
  var rendererReads = 0
  let legacy = UIView()
  var mapView: UIView {
    rendererReads += 1
    if usesExternalMap { fatalError("NAVI_LEGACY_RENDERER_ACCESSED") }
    return legacy
  }
  static func shared() -> MapViewController? {
    fixture.loadViewIfNeeded()
    return fixture
  }
}
enum CarPlayLogging {
  static func diagnosticIdentity(_ value: AnyObject?) -> String { "fixture" }
}
func probeLegacyLogging() {
  let mapHost = ProbeMapHost.phone
__LOGGING_BODY__
  NSLog("NAVI_LEGACY_LOGGING_RETURNED_%@", hosting)
}
func probeLegacyReconcile() {
  let mapHost = ProbeMapHost.phone
__RECONCILE_BODY__
}
func runLegacyHostContract(_ kind: String) {
  let fixture = MapViewController.fixture
  if kind == "--legacy-reconcile" { probeLegacyReconcile() } else { probeLegacyLogging() }
  precondition(fixture.rendererReads == 0, "External map requested legacy renderer")
  fixture.usesExternalMap = false
  if kind == "--legacy-reconcile" { probeLegacyReconcile() } else { probeLegacyLogging() }
  precondition(fixture.rendererReads > 0, "Legacy map no longer used its renderer")
  NSLog("NAVI_LEGACY_CONTRACT_PASSED_%@", kind)
}
'''.replace('__LOGGING_BODY__', textwrap.dedent(logging)).replace('__RECONCILE_BODY__', textwrap.dedent(reconcile)))
app = work/'NaviMapProbe.app'
(app/'Frameworks').mkdir(parents=True, exist_ok=True)
font = app/'noto-0-255.pbf'
urllib.request.urlretrieve('https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/0-255.pbf', font)
assert hashlib.sha256(font.read_bytes()).hexdigest() == 'ef1f38a3f1978591e846e9eaddf8a54f7047f546fc6aaed7872cc53151a5de78'
shutil.copytree(framework, app/'Frameworks/MapLibre.framework', symlinks=True)
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-name', 'NaviMapProbe',
     '-target', 'arm64-apple-ios15.6-simulator', '-sdk', sdk,
     '-F', str(framework.parent), '-framework', 'MapLibre', '-Xlinker', '-rpath',
     '-Xlinker', '@executable_path/Frameworks', str(source), str(route_types), str(contract),
     *(str(repo/'iphone/Maps/UI/NaviMap'/name) for name in
       ['NaviMapPolicy.swift','NaviEsriTransport.swift','NaviMapController.swift']),
     str(repo/'testing/map-apple/FriendsMapScenario.swift'),
     '-o', str(app/'NaviMapProbe')])
subprocess.run([sys.executable, str(Path(__file__).with_name('probe-ios-controls.py')),
                str(out / 'controls')], check=True, timeout=420)
info = {'CFBundleIdentifier':'app.navi.mapprobe', 'CFBundleName':'NaviMapProbe',
        'CFBundleExecutable':'NaviMapProbe', 'CFBundlePackageType':'APPL',
        'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0', 'MinimumOSVersion':'15.6',
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes':False,
          'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication':[
            {'UISceneConfigurationName':'Default', 'UISceneDelegateClassName':'NaviMapProbe.SceneDelegate'}]}}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
run(['codesign', '--force', '--sign', '-', str(app/'Frameworks/MapLibre.framework')])
run(['codesign', '--force', '--sign', '-', str(app)])
inventory = json.loads(run(['xcrun','simctl','list','devices','available','--json']))
device = select(inventory)
runtime = device['runtime']
udid = device['udid']
(out/'simulator.json').write_text(json.dumps({'runtime':runtime, 'device':device}, indent=2))
if device['state'] != 'Booted':
    run(['xcrun','simctl','boot',udid])
run(['xcrun','simctl','bootstatus',udid,'-b'], timeout=180)
run(['xcrun','simctl','install',udid,str(app)])
debug = []
for case in ['--legacy-logging', '--legacy-reconcile']:
    launch = run(['xcrun','simctl','launch','--wait-for-debugger',udid,'app.navi.mapprobe',case])
    pid = re.search(r':\s*(\d+)\s*$', launch).group(1)
    try:
        result = subprocess.run(['xcrun','lldb','--batch','-p',pid,
                                 '-o','breakpoint set --selector probeReadyCheckpoint','-o','continue',
                                 '--one-line-on-crash','thread backtrace all',
                                 '--one-line-on-crash','image list',
                                 '-o','thread backtrace all','-o','image list','-o','detach'],
                                capture_output=True, text=True, timeout=35)
        debug.append(case+'\n'+result.stdout+result.stderr)
    except subprocess.TimeoutExpired as error:
        def decoded(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else (value or '')
        debug.append(case+'\n'+decoded(error.stdout)+decoded(error.stderr))
    subprocess.run(['xcrun','simctl','terminate',udid,'app.navi.mapprobe'],capture_output=True)
(out/'debugger.txt').write_text('\n'.join(debug))
subprocess.run(['xcrun','simctl','io',udid,'screenshot',str(out/'simulator.png')], capture_output=True)
(out/'system.log').write_text(run(['xcrun','simctl','spawn',udid,'log','show','--last','2m','--style','compact',
                                  '--predicate','process == "NaviMapProbe"']))
friends = subprocess.run(['xcrun','simctl','launch','--terminate-running-process','--console',udid,
                          'app.navi.mapprobe','--friends-map'], capture_output=True, text=True, timeout=50)
with (out/'system.log').open('a') as log:
    log.write('\n' + friends.stdout + friends.stderr)
container = Path(run(['xcrun','simctl','get_app_container',udid,'app.navi.mapprobe','data']))
capture = container/'Documents/friends-map.png'
if capture.is_file():
    shutil.copyfile(capture, out/'simulator.png')
if friends.returncode != 0 or 'NAVI_FRIENDS_MAP_SUCCESS' not in friends.stdout:
    raise SystemExit('Actual friends renderer contract failed: ' + friends.stdout + friends.stderr)
print('Minimal pinned MapLibre simulator probe completed; inspect debugger.txt for actual startup evidence')
system = (out/'system.log').read_text()
if system.count('NAVI_LEGACY_CONTRACT_PASSED_') < 2:
    raise SystemExit('Legacy host contract failed; actual debugger evidence retained')
