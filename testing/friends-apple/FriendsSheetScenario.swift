import UIKit
import FirebaseAuth

/// Real UIKit controls backed by the production runtime and local SDK clients.
@MainActor enum FriendsSheetScenario {
  static func find<T: UIView>(_ id: String, in root: UIView) -> T? {
    if root.accessibilityIdentifier == id, let result = root as? T { return result }
    for child in root.subviews { if let result: T = find(id, in: child) { return result } }
    return nil
  }
  static func tap(_ id: String, in root: UIView) throws {
    guard let button: UIButton = find(id, in: root), button.isEnabled else {
      throw ProbeError.failed("Missing enabled UIKit button " + id)
    }
    button.sendActions(for: .touchUpInside)
  }
  static func capture(_ window: UIWindow, name: String) throws {
    window.layoutIfNeeded()
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    guard let data = image.pngData() else { throw ProbeError.failed("UIKit capture failed") }
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
  }

  static func run() async throws {
    print("native_apple_sheet_stage=unconfigured")
    guard let window = (UIApplication.shared.delegate as? FriendsProbeApp)?.window,
          let host = window.rootViewController else { throw ProbeError.failed("No actual UIKit fixture window") }
    let suite = "navi-sheet-probe-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let runtime = try FriendsRuntime(preferences: preferences, transport: FriendsNativeProbe.local)
    defer { runtime.close() }
    var clockOffset: Int64 = 0
    let sheet = FriendsSheetController(runtime: runtime, now: { runtime.serverNowMs + clockOffset })
    let navigation = UINavigationController(rootViewController: sheet)
    host.present(navigation, animated: false)
    defer { navigation.dismiss(animated: false) }
    try await FriendsNativeProbe.waitFor("sheet presentation completed", {
      host.presentedViewController === navigation && !navigation.isBeingPresented && sheet.view.window != nil
    })
    try tap("friends.group.setup", in: window)
    try await FriendsNativeProbe.waitFor("group editor presentation", {
      let field: UITextView? = find("friends.group.json", in: window)
      return field != nil && navigation.presentedViewController?.isBeingPresented == false
    })
    guard let config: UITextView = find("friends.group.json", in: window) else {
      throw ProbeError.failed("Group editor missing")
    }
    config.text = """
      {"projectId":"demo-navi-friends","applicationId":"1:1234567890:ios:abcdef0123456789","apiKey":"fake-api-key","databaseUrl":"https://demo-navi-friends.firebaseio.com"}
      """
    try tap("friends.group.save", in: window)
    try await FriendsNativeProbe.waitFor("sheet login form", {
      let field: UITextField? = find("friends.auth.email", in: window)
      return field != nil && navigation.presentedViewController == nil
    })
    let email: UITextField = find("friends.auth.email", in: window)!
    let password: UITextField = find("friends.auth.password", in: window)!
    try FriendsNativeProbe.check(password.isSecureTextEntry, "Password field is not secure")
    email.text = "sheet-" + UUID().uuidString + "@example.test"
    password.text = "synthetic-local-password-123"
    try tap("friends.auth.register", in: window)
    try await FriendsNativeProbe.waitFor("sheet registered account", { runtime.snapshot.accountState == .ready })
    try FriendsNativeProbe.check(password.text?.isEmpty != false, "Password retained in the UI after submit")
    print("native_apple_sheet_stage=profile")
    try await FriendsNativeProbe.waitFor("sheet own name field", {
      let field: UITextField? = find("friends.profile.name", in: window); return field != nil
    })
    let name: UITextField = find("friends.profile.name", in: window)!
    name.text = "UI driver"
    try tap("friends.profile.save", in: window)
    try await FriendsNativeProbe.waitFor("sheet saved public name", { runtime.snapshot.ownName == "UI driver" })
    try await FriendsNativeProbe.waitFor("sheet sharing clock", { runtime.serverNowMs > 0 })
    try tap("friends.sharing", in: window)
    try await FriendsNativeProbe.waitFor("sheet share action", {
      let button: UIButton? = find("friends.sharing", in: window)
      return runtime.snapshot.sharingState == .sharing && button?.isEnabled == true
    })
    try tap("friends.sharing", in: window)
    try await FriendsNativeProbe.waitFor("sheet pause action", { runtime.snapshot.sharingState == .paused })
    try FriendsNativeProbe.check(runtime.snapshot.ownName == "UI driver" && name.text == "UI driver",
      "Changing location sharing reverted the saved display name")

    let (peerApp, peerUser) = try await FriendsNativeProbe.identity("sheet-peer")
    defer { try? Auth.auth(app: peerApp).signOut(); peerApp.delete { _ in } }
    let peer = try FriendsRuntime(identityApp: peerApp, preferences: preferences, transport: FriendsNativeProbe.local)
    defer { peer.close() }
    try await FriendsNativeProbe.waitFor("sheet peer ready", { peer.snapshot.accountState == .ready && peer.serverNowMs > 0 })
    try await peer.setName("UI peer")
    try tap("friends.add", in: window)
    try await FriendsNativeProbe.waitFor("friend editor presentation", {
      let field: UITextField? = find("friends.add.code", in: window)
      return field != nil && navigation.presentedViewController?.isBeingPresented == false
    })
    let code: UITextField = find("friends.add.code", in: window)!
    code.text = "wrong-project/" + peerUser.uid
    try tap("friends.add.send", in: window)
    try await FriendsNativeProbe.waitFor("foreign code validation completed", {
      let button: UIButton? = find("friends.add.send", in: window)
      let message: UILabel? = find("friends.editor.message", in: window)
      return button?.isEnabled == true && message?.text?.isEmpty == false
    })
    try FriendsNativeProbe.check(peer.snapshot.requests.isEmpty, "Foreign-project code was accepted")
    code.text = "demo-navi-friends/" + peerUser.uid
    try tap("friends.add.send", in: window)
    try await FriendsNativeProbe.waitFor("sheet friend request", { peer.snapshot.requests.contains(runtime.snapshot.uid) })
    try await peer.confirm(runtime.snapshot.uid)
    try await FriendsNativeProbe.waitFor("sheet editors dismissed", { navigation.presentedViewController == nil })
    let positionID = "friends.peer.\(peerUser.uid).grant.position"
    try await FriendsNativeProbe.waitFor("sheet confirmed peer row", {
      let control: UISwitch? = find(positionID, in: window); return control != nil
    })
    let position: UISwitch = find(positionID, in: window)!
    position.isOn = true; position.sendActions(for: .valueChanged)
    try await FriendsNativeProbe.waitFor("sheet independent position grant", {
      runtime.snapshot.grants[peerUser.uid]?.position == true && position.isEnabled
    })
    try FriendsNativeProbe.check(runtime.snapshot.grants[peerUser.uid]?.speed == false
      && runtime.snapshot.grants[peerUser.uid]?.trips == false, "Position toggle granted additional rights")
    try await peer.grant(runtime.snapshot.uid, grant: .init(position: true, speed: true, trips: false))
    try await peer.setSharing(true)
    try await Task.sleep(nanoseconds: 2_000_000)
    let fresh = FriendsRuntime.Fix(measuredAtDeviceMs: Int64(Date().timeIntervalSince1970 * 1000),
      latitude: 43.7295, longitude: 7.4208, accuracyMeters: 4, metersPerSecond: 9, bearingDegrees: 180)
    _ = try await peer.acceptLocation(fresh)
    let speedID = "friends.peer.\(peerUser.uid).speed"
    try await FriendsNativeProbe.waitFor("sheet actual peer speed", {
      let label: UILabel? = find(speedID, in: window); return label?.text?.contains("32 km/h") == true
    })
    if let scroll: UIScrollView = find("friends.scroll", in: window),
       let label: UILabel = find(speedID, in: window) {
      scroll.scrollRectToVisible(label.convert(label.bounds, to: scroll).insetBy(dx: 0, dy: -60), animated: false)
    }
    try capture(window, name: "friends-ui-light.png")
    clockOffset = 16_000 // UI clock injection; the real SDK and DTO remain unchanged.
    try await FriendsNativeProbe.waitFor("sheet hides stale speed", {
      let label: UILabel? = find(speedID, in: window); return label?.text?.contains("32 km/h") == false
    })
    navigation.overrideUserInterfaceStyle = .dark
    navigation.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), forChild: sheet)
    try await Task.sleep(nanoseconds: 200_000_000)
    if let scroll: UIScrollView = find("friends.scroll", in: window),
       let label: UILabel = find(speedID, in: window) {
      scroll.scrollRectToVisible(label.convert(label.bounds, to: scroll).insetBy(dx: 0, dy: -60), animated: false)
    }
    try capture(window, name: "friends-ui-dark-large.png")
    print("native_apple_sheet=true")
  }
}
