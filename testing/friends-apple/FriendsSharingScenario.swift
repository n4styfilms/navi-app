import Foundation
import FirebaseAuth
import FirebaseDatabase

/// Real SDK/emulator contract for durable intent and ACK-gated location publishing.
@MainActor enum FriendsSharingScenario {
  static func run(alice: User, data: FriendsDataSession) async throws {
    let suite = "navi-sharing-probe-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var clock = Int64(Date().timeIntervalSince1970 * 1000)
    let repo = try FriendsRepository(session: data, now: { clock })
    var controller = try FriendsSharingController(session: data, repository: repo,
      preferences: preferences, now: { clock }, changed: { _ in })
    defer { controller.close() }
    try FriendsNativeProbe.check(controller.state == .off, "Fresh install enabled sharing implicitly")
    try await FriendsNativeProbe.waitFor("sharing connection", { controller.isConnected })
    let beforeACK = PresenceSample(sequence: 10, measuredAtMs: clock - 1, latitude: 43.7295, longitude: 7.4208,
      accuracyMeters: 4, metersPerSecond: 7, bearingDegrees: nil)
    let initiallySent = try await controller.accept(beforeACK, foregroundMap: true, moving: true)
    try FriendsNativeProbe.check(!initiallySent, "OFF state published a location")
    try await controller.setEnabled(true)
    try FriendsNativeProbe.check(controller.state == .sharing, "No sharing state after server ACK")
    let oldSent = try await controller.accept(beforeACK, foregroundMap: true, moving: true)
    try FriendsNativeProbe.check(!oldSent, "Location from before lease ACK was replayed")
    clock = Int64(Date().timeIntervalSince1970 * 1000)
    let fresh = PresenceSample(sequence: 11, measuredAtMs: clock, latitude: 43.7296, longitude: 7.4209,
      accuracyMeters: 5, metersPerSecond: nil, bearingDegrees: nil)
    let sent = try await controller.accept(fresh, foregroundMap: false, moving: true)
    try FriendsNativeProbe.check(sent, "ACK-gated current location was not sent")
    let point = try await data.database().reference(withPath: "live/\(alice.uid)/position").getData()
    try FriendsNativeProbe.check(point.childSnapshot(forPath: "sequence").value as? Int == 11,
      "Server did not receive fresh location")
    let speed = try await data.database().reference(withPath: "live/\(alice.uid)/speed").getData()
    try FriendsNativeProbe.check(!speed.hasChild("metersPerSecond"), "Unknown speed was manufactured")
    print("native_apple_sharing_ack=true")

    try data.database().goOffline()
    try await FriendsNativeProbe.waitFor("sharing offline", { controller.state == .reconnecting })
    let disconnectedSent = try await controller.accept(fresh, foregroundMap: true, moving: true)
    try FriendsNativeProbe.check(!disconnectedSent, "Disconnected controller queued a location")
    let pause = Task { try await controller.setEnabled(false) }
    try await FriendsNativeProbe.waitFor("durable pending pause", { controller.state == .revocationPending })
    controller.close()
    do { try await pause.value; throw ProbeError.failed("Closed pending operation succeeded") }
    catch FriendsSharingController.SharingError.superseded { }
    // Recreate from the same persisted settings while the SDK remains offline.
    controller = try FriendsSharingController(session: data, repository: repo,
      preferences: preferences, now: { clock }, changed: { _ in })
    try FriendsNativeProbe.check(controller.state == .revocationPending,
      "Restart lost pending pause or resumed location sharing")
    let pendingSent = try await controller.accept(fresh, foregroundMap: true, moving: true)
    try FriendsNativeProbe.check(!pendingSent, "Pending pause published a location")
    try data.database().goOnline()
    try await FriendsNativeProbe.waitFor("stored pause acknowledged", { controller.state == .paused })
    let control = try await data.database().reference(withPath: "liveControl/\(alice.uid)").getData()
    try FriendsNativeProbe.check(control.childSnapshot(forPath: "enabled").value as? Bool == false
      && !control.hasChild("publishedSequence"), "Pending pause did not replace server lease")
    print("native_apple_durable_offline_pause=true")
  }
}
