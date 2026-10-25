import Foundation
import FirebaseDatabase

/// Account-owned actions. Confirming friendship never implicitly grants location, speed or trips.
@MainActor final class FriendsRepository {
  enum RepositoryError: Error { case closed, invalidPeer, noIncomingRequest }
  struct Grant: Sendable {
    let position: Bool
    let speed: Bool
    let trips: Bool
    var fields: [String: Bool] { ["position": position, "speed": speed, "trips": trips] }
  }

  private let session: FriendsDataSession
  private let owner: String

  init(session: FriendsDataSession) throws {
    guard !session.isClosed else { throw RepositoryError.closed }
    self.session = session
    owner = session.owner
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
