import Foundation
import FirebaseAuth
import FirebaseDatabase

@MainActor enum FriendsSnapshotScenario {
  static func run(alice: User, chris: User, aliceData: FriendsDataSession, chrisData: FriendsDataSession,
                  aliceRepo: FriendsRepository, chrisRepo: FriendsRepository) async throws {
    var peers: [FriendsRepository.Peer] = []
    let observation = try chrisRepo.observe { peers = $0 }
    defer { observation.close() }
    let root = try aliceData.database().reference()
    try await chrisRepo.requestFriend(alice.uid)
    try await aliceRepo.confirmFriend(chris.uid)
    try await aliceRepo.setGrant(chris.uid, grant: .init(position: true, speed: true, trips: false))
    try await FriendsNativeProbe.waitFor("confirmed peer snapshot", { peers.count == 1 })
    try await root.child("liveControl/\(alice.uid)").setValue(["enabled": true, "generation": 3])
    try await FriendsNativeProbe.waitFor("new lease hides old point", {
      peers.first?.awaitingFreshSample == true && peers.first?.position == nil
    })
    let policy = PresencePolicy()
    let initialNow = Int64(Date().timeIntervalSince1970 * 1000)
    let ticket = policy.begin(owner: alice.uid, at: initialNow)
    let first = PresenceSample(sequence: 1, measuredAtMs: initialNow, latitude: 43.7295, longitude: 7.4208,
                               accuracyMeters: 4, metersPerSecond: 8, bearingDegrees: 180)
    guard let firstUpload = policy.prepare(first, at: initialNow, generation: ticket, foregroundMap: true, moving: true)
    else { throw ProbeError.failed("First current candidate missing") }
    try await aliceRepo.publish(policy: policy, upload: firstUpload, lease: 3)
    try await FriendsNativeProbe.waitFor("first point and separate speed", {
      peers.first?.position?.sequence == 1 && peers.first?.speedMetersPerSecond(at: initialNow) == 8
    })
    let frozen = peers[0]
    try FriendsNativeProbe.check(frozen.displayName == "Alice test" && frozen.positionAllowed && frozen.speedAllowed,
                                "Copied profile or rights mismatch")
    try FriendsNativeProbe.check(frozen.speedMetersPerSecond(at: initialNow + 15_000) == 8
      && frozen.speedMetersPerSecond(at: initialNow + 15_001) == nil, "Speed freshness boundary ignored")
    try await Task.sleep(nanoseconds: 5_100_000_000)
    let nextNow = Int64(Date().timeIntervalSince1970 * 1000)
    let second = PresenceSample(sequence: 2, measuredAtMs: nextNow, latitude: 43.7296, longitude: 7.4209,
                                accuracyMeters: 5, metersPerSecond: 9, bearingDegrees: 181)
    guard let secondUpload = policy.prepare(second, at: nextNow, generation: ticket, foregroundMap: true, moving: true)
    else { throw ProbeError.failed("Next current candidate missing") }
    try await aliceRepo.publish(policy: policy, upload: secondUpload, lease: 3)
    try await FriendsNativeProbe.waitFor("next coherent snapshot", {
      peers.first?.position?.sequence == 2 && peers.first?.speedMetersPerSecond(at: nextNow) == 9
    })
    try FriendsNativeProbe.check(frozen.position?.sequence == 1 && frozen.speedMetersPerSecond(at: initialNow) == 8,
                                "Previously copied peer snapshot mutated")
    try await aliceRepo.setGrant(chris.uid, grant: .init(position: true, speed: false, trips: false))
    try await FriendsNativeProbe.waitFor("speed revocation preserves position", {
      peers.first?.speedAllowed == false && peers.first?.position != nil
        && peers.first?.speedMetersPerSecond(at: nextNow) == nil
    })
    try await root.child("liveControl/\(alice.uid)").setValue(["enabled": false, "generation": 4])
    try await FriendsNativeProbe.waitFor("global pause clears peer point", {
      peers.first?.sharingEnabled == false && peers.first?.position == nil
    })
    try await root.child("liveControl/\(alice.uid)").setValue(["enabled": true, "generation": 5])
    try await FriendsNativeProbe.waitFor("resume requires a new point", {
      peers.first?.awaitingFreshSample == true && peers.first?.position == nil
    })
    print("native_apple_peer_snapshots=true")
    policy.pause()
    do {
      try await aliceRepo.publish(policy: policy, upload: secondUpload, lease: 5)
      throw ProbeError.failed("Invalidated candidate was published")
    } catch FriendsRepository.RepositoryError.invalidCandidate { }
    let control = try await root.child("liveControl/\(alice.uid)").getData()
    try FriendsNativeProbe.check(!control.hasChild("publishedSequence"), "Invalidated write advanced server cursor")
    chrisData.close()
    try FriendsNativeProbe.check(peers.isEmpty, "Session close did not synchronously clear current peers")
    print("native_apple_gated_publication=true")
  }
}
