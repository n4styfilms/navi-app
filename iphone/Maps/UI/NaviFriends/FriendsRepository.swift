import Foundation
import FirebaseDatabase

/// Account-owned actions. Confirming friendship never implicitly grants location, speed or trips.
@MainActor final class FriendsRepository {
  enum RepositoryError: Error { case closed, invalidPeer, noIncomingRequest, invalidCandidate }
  struct Peer: Sendable {
    let uid: String
    let displayName: String
    let positionAllowed: Bool
    let speedAllowed: Bool
    let tripsAllowed: Bool
    let sharingEnabled: Bool
    let awaitingFreshSample: Bool
    let liveGeneration: Int64
    let position: PresenceSample?
    let speed: Double?
    func speedMetersPerSecond(at now: Int64) -> Double? {
      speedAllowed && position?.isFresh(at: now) == true ? speed : nil
    }
  }
  struct Grant: Sendable {
    let position: Bool
    let speed: Bool
    let trips: Bool
    var fields: [String: Bool] { ["position": position, "speed": speed, "trips": trips] }
  }

  private let session: FriendsDataSession
  private let owner: String
  private let now: () -> Int64

  init(session: FriendsDataSession, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
    guard !session.isClosed else { throw RepositoryError.closed }
    self.session = session
    owner = session.owner
    self.now = now
  }

  func observe(_ changed: @escaping ([Peer]) -> Void) throws -> FriendsObservation {
    guard !session.isClosed else { throw RepositoryError.closed }
    return try FriendsObservation(session: session, changed: changed)
  }

  func publish(policy: PresencePolicy, upload: PresencePolicy.Upload, lease: Int64) async throws {
    let sample = upload.sample
    var point: [String: Any] = ["sharingGeneration": lease, "sequence": sample.sequence,
      "latitude": sample.latitude, "longitude": sample.longitude,
      "measuredAtMs": sample.measuredAtMs, "receivedAtMs": ServerValue.timestamp()]
    if let accuracy = sample.accuracyMeters { point["accuracyMeters"] = accuracy }
    if let bearing = sample.bearingDegrees { point["bearingDegrees"] = bearing }
    var speed: [String: Any] = ["sharingGeneration": lease, "sequence": sample.sequence,
      "measuredAtMs": sample.measuredAtMs]
    if let value = sample.speedMetersPerSecond { speed["metersPerSecond"] = value }
    let changes: [String: Any] = ["live/\(owner)/position": point, "live/\(owner)/speed": speed,
      "liveControl/\(owner)/publishedSequence": sample.sequence]
    // No suspension between this final main-actor check and SDK enqueue. Server
    // leases, rather than this local gate, revoke writes already on the wire.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      guard !session.isClosed, upload.owner == owner, lease > 0, lease <= 9_007_199_254_740_991,
            policy.isCurrent(upload, at: now()) else {
        continuation.resume(throwing: RepositoryError.invalidCandidate); return
      }
      do {
        try session.database().reference().updateChildValues(changes) { error, _ in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume() }
        }
      } catch { continuation.resume(throwing: error) }
    }
  }

  private func validate(_ peer: String) throws {
    guard !session.isClosed else { throw RepositoryError.closed }
    guard peer != owner,
          let match = peer.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression),
          match == peer.startIndex..<peer.endIndex
    else { throw RepositoryError.invalidPeer }
  }

  func requestFriend(_ peer: String) async throws {
    try validate(peer)
    try await session.database().reference().updateChildValues([
      "friendConsent/\(owner)/\(peer)": true,
      "requests/\(peer)/\(owner)": ["createdAtMs": ServerValue.timestamp()]
    ])
  }

  func confirmFriend(_ peer: String) async throws {
    try validate(peer)
    let request = try await session.database().reference(withPath: "requests/\(owner)/\(peer)").getData()
    // Account changes can close this session while the request lookup is awaiting the server.
    try validate(peer)
    guard request.exists() else { throw RepositoryError.noIncomingRequest }
    try await session.database().reference().updateChildValues([
      "friendConsent/\(owner)/\(peer)": true,
      "requests/\(owner)/\(peer)": NSNull()
    ])
  }

  func setGrant(_ peer: String, grant: Grant) async throws {
    try validate(peer)
    try await session.database().reference(withPath: "grants/\(owner)/\(peer)").setValue(grant.fields)
  }

  func removeFriend(_ peer: String) async throws {
    try validate(peer)
    try await session.database().reference().updateChildValues([
      "friendConsent/\(owner)/\(peer)": NSNull(),
      "grants/\(owner)/\(peer)": NSNull(),
      "requests/\(owner)/\(peer)": NSNull(),
      "requests/\(peer)/\(owner)": NSNull()
    ])
  }
}
