"""Execute the production search-results layout against real UIKit on Simulator."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from select_ios_simulator import select


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    controller = (repo / 'iphone/Maps/UI/NaviMap/NaviViewController.swift').read_text()
    body = controller.split('    table.dataSource = self;', 1)[1].split('    panelScroll.translates', 1)[0]
    body = '    table.dataSource = self;' + body
    palette = (repo / 'iphone/Maps/UI/Vehicle/NaviPalette.swift').read_text()
    source = out / 'Controls.swift'
    source.write_text(palette + '''
@main final class App: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    let owner = Controls()
    window.rootViewController = owner
    self.window = window
    window.makeKeyAndVisible()
    owner.loadViewIfNeeded()
    return true
  }
}
final class Controls: UIViewController, UITableViewDataSource, UITableViewDelegate {
  let table = UITableView(frame: .zero, style: .plain)
  override func viewDidLoad() {
    super.viewDidLoad()
    let top = UIStackView()
    top.axis = .vertical
    view.addSubview(top)
    NSLog("NAVI_CONTROLS_BEFORE_LAYOUT")
''' + body + '''
    precondition(table.isDescendant(of: view))
    view.layoutIfNeeded()
    print("NAVI_CONTROLS_READY"); fflush(stdout)
    DispatchQueue.main.async { exit(0) }
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 0 }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { UITableViewCell() }
}
''')
    app = out / 'Controls.app'
    app.mkdir()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', sdk,
                    '-target', 'arm64-apple-ios15.6-simulator', str(source), '-o', str(app / 'Controls')],
                   check=True, timeout=120)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'app.navi.controlsprobe', 'CFBundleName': 'Controls',
        'CFBundleExecutable': 'Controls', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.6',
        'UILaunchScreen': {}}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, timeout=30)
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    device = select(inventory)
    udid = device['udid']
    if device['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=180)
    subprocess.run(['xcrun', 'simctl', 'install', udid, str(app)], check=True, timeout=180)
    try:
        result = subprocess.run(['xcrun', 'simctl', 'launch', '--console', udid, 'app.navi.controlsprobe'],
                                capture_output=True, timeout=60)
        logs = result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        logs = (error.stdout or b'') + (error.stderr or b'')
    finally:
        try:
            subprocess.run(['xcrun', 'simctl', 'terminate', udid, 'app.navi.controlsprobe'],
                           capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            pass  # Cleanup must not erase the actual launch output.
    (out.parent / 'controls-probe.txt').write_bytes(logs)
    if b'NAVI_CONTROLS_READY' not in logs:
        diagnostics = subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '2m',
            '--style', 'compact', '--predicate', 'process == "Controls"'], capture_output=True, timeout=30)
        logs += diagnostics.stdout + diagnostics.stderr
        (out.parent / 'controls-probe.txt').write_bytes(logs)
        print(logs.decode(errors='replace')[-100000:], flush=True)
        raise SystemExit('Production search-results layout failed before readiness; see controls-probe.txt')
    print('PASS actual UIKit production search-results layout')


if __name__ == '__main__':
    main()
