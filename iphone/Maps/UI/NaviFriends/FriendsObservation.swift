import Foundation
import CoreFoundation
import FirebaseDatabase

/// Owns a disposable subscription tree. UI receives value copies, never SDK snapshots.
@MainActor final class FriendsObservation {
  private let session: FriendsDataSession
  private let changed: ([FriendsRepository.Peer]) -> Void
  private var peers: [String: WatchedPeer] = [:]
  private var consent: FriendsSubscription?
  private var closing: FriendsSubscription?
  private(set) var isClosed = false

  init(session: FriendsDataSession, changed: @escaping ([FriendsRepository.Peer]) -> Void) throws {
    self.session = session
    self.changed = changed
    closing = session.onClose { [weak self] in self?.close() }
    do {
      consent = try session.listen("friendConsent/\(session.owner)", onValue: { [weak self] snapshot in
        guard let self, !self.isClosed else { return }
        var retained = Set<String>()
        for case let child as DataSnapshot in snapshot.children {
          guard Self.boolean(child.value), child.key != session.owner else { continue }
          retained.insert(child.key)
          if self.peers[child.key] == nil {
            let peer = WatchedPeer(uid: child.key, tree: self)
            self.peers[child.key] = peer
            peer.start()
          }
        }
        for key in Array(self.peers.keys) where !retained.contains(key) {
          self.peers.removeValue(forKey: key)?.close()
        }
        self.emit()
      }, onCancel: { [weak self] _ in self?.close() })
    } catch { close(); throw error }
    emit()
  }

  private func emit() {
    guard !isClosed else { return }
    changed(peers.keys.sorted().compactMap { peers[$0]?.snapshot() })
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    consent?.close(); consent = nil
    closing?.close(); closing = nil
    for peer in peers.values { peer.close() }
    peers.removeAll()
    changed([])
  }

  private static func boolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return number.boolValue
  }
  private static func number(_ snapshot: DataSnapshot) -> Double? {
    guard let number = snapshot.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return nil }
    return number.doubleValue
  }
  private static func integer(_ snapshot: DataSnapshot) -> Int64 {
    guard let value = number(snapshot), value > 0, value <= 9_007_199_254_740_991,
          value.rounded(.down) == value else { return 0 }
    return Int64(value)
  }

  @MainActor private final class WatchedPeer {
    let uid: String
    unowned let tree: FriendsObservation
    var active = true
    var confirmed = false
    var name = ""
    var grant = FriendsRepository.Grant(position: false, speed: false, trips: false)
    var consent, profile, rights, control, point, speed: FriendsSubscription?
    var detailEpoch = 0, controlEpoch = 0, liveEpoch = 0, speedEpoch = 0
    var enabled = false, watching = false
    var generation: Int64 = 0, cursor: Int64 = 0
    var position: PresenceSample?
    var velocity: (generation: Int64, sequence: Int64, measured: Int64, value: Double?)?
    var valid: Bool { active && !tree.isClosed && !tree.session.isClosed }

    init(uid: String, tree: FriendsObservation) { self.uid = uid; self.tree = tree }
    func listen(_ path: String, receive: @escaping (DataSnapshot) -> Void,
                canceled: @escaping () -> Void) -> FriendsSubscription? {
      do { return try tree.session.listen(path, onValue: receive, onCancel: { _ in canceled() }) }
      catch { canceled(); return nil }
    }
    func emit() { tree.emit() }
    func start() {
      consent = listen("friendConsent/\(uid)/\(tree.session.owner)", receive: { [weak self] snapshot in
        guard let self, self.valid else { return }
        let accepted = FriendsObservation.boolean(snapshot.value)
        guard accepted != self.confirmed else { return }
        self.stopDetails(); self.confirmed = accepted
        if accepted { self.startDetails() }
        self.emit()
      }, canceled: { [weak self] in
        guard let self, self.valid else { return }
        self.stopDetails(); self.confirmed = false; self.emit()
      })
    }
    func startDetails() {
      detailEpoch += 1; let ticket = detailEpoch
      profile = listen("profiles/\(uid)", receive: { [weak self] snapshot in
        guard let self, self.valid, self.detailEpoch == ticket else { return }
        self.name = snapshot.childSnapshot(forPath: "displayName").value as? String ?? ""
        self.emit()
      }, canceled: { [weak self] in
        guard let self, self.valid, self.detailEpoch == ticket else { return }
        self.stopDetails(); self.confirmed = false; self.emit()
      })
      rights = listen("grants/\(uid)/\(tree.session.owner)", receive: { [weak self] snapshot in
        guard let self, self.valid, self.confirmed, self.detailEpoch == ticket else { return }
        let old = self.grant
        self.grant = .init(position: FriendsObservation.boolean(snapshot.childSnapshot(forPath: "position").value),
          speed: FriendsObservation.boolean(snapshot.childSnapshot(forPath: "speed").value),
          trips: FriendsObservation.boolean(snapshot.childSnapshot(forPath: "trips").value))
        if old.position != self.grant.position {
          self.stopControl()
          if self.grant.position { self.startControl() }
        } else if old.speed != self.grant.speed {
          self.stopSpeed()
          if self.grant.speed && self.watching { self.startSpeed() }
        }
        self.emit()
      }, canceled: { [weak self] in
        guard let self, self.valid, self.detailEpoch == ticket else { return }
        self.grant = .init(position: false, speed: false, trips: false)
        self.stopControl(); self.emit()
      })
    }
    func stopDetails() {
      detailEpoch += 1
      profile?.close(); profile = nil; rights?.close(); rights = nil
      stopControl(); name = ""; grant = .init(position: false, speed: false, trips: false)
    }
    func startControl() {
      controlEpoch += 1; let ticket = controlEpoch
      control = listen("liveControl/\(uid)", receive: { [weak self] snapshot in
        guard let self, self.valid, self.confirmed, self.grant.position, self.controlEpoch == ticket else { return }
        let next = FriendsObservation.integer(snapshot.childSnapshot(forPath: "generation"))
        guard next >= self.generation else { return }
        let enabled = FriendsObservation.boolean(snapshot.childSnapshot(forPath: "enabled").value)
        let cursor = FriendsObservation.integer(snapshot.childSnapshot(forPath: "publishedSequence"))
        if next != self.generation || !enabled { self.stopLive() }
        self.generation = next; self.enabled = enabled && next > 0; self.cursor = cursor
        // A new lease cannot read the old point. Wait for the first atomic publication.
        if self.enabled && cursor > 0 {
          if !self.watching { self.startLive() }
          else if self.grant.speed && self.speed == nil { self.startSpeed() }
        }
        self.emit()
      }, canceled: { [weak self] in
        guard let self, self.valid, self.controlEpoch == ticket else { return }
        self.stopLive(); self.enabled = false; self.emit()
      })
    }
    func stopControl() {
      controlEpoch += 1; control?.close(); control = nil
      stopLive(); generation = 0; cursor = 0; enabled = false
    }
    func startLive() {
      watching = true; liveEpoch += 1; let ticket = liveEpoch, lease = generation
      point = listen("live/\(uid)/position", receive: { [weak self] snapshot in
        guard let self, self.valid, self.confirmed, self.enabled, self.liveEpoch == ticket,
              self.generation == lease else { return }
        guard FriendsObservation.integer(snapshot.childSnapshot(forPath: "sharingGeneration")) == lease else { return }
        guard let latitude = FriendsObservation.number(snapshot.childSnapshot(forPath: "latitude")),
              let longitude = FriendsObservation.number(snapshot.childSnapshot(forPath: "longitude")) else {
          self.position = nil; self.velocity = nil; self.emit(); return
        }
        let sample = PresenceSample(sequence: FriendsObservation.integer(snapshot.childSnapshot(forPath: "sequence")),
          measuredAtMs: FriendsObservation.integer(snapshot.childSnapshot(forPath: "measuredAtMs")),
          latitude: latitude, longitude: longitude,
          accuracyMeters: FriendsObservation.number(snapshot.childSnapshot(forPath: "accuracyMeters")),
          metersPerSecond: nil, bearingDegrees: FriendsObservation.number(snapshot.childSnapshot(forPath: "bearingDegrees")))
        guard sample.isValid else { self.position = nil; self.velocity = nil; self.emit(); return }
        if let previous = self.position, sample.sequence < previous.sequence { return }
        self.position = sample; self.emit()
      }, canceled: { [weak self] in
        guard let self, self.valid, self.liveEpoch == ticket else { return }
        self.stopLive(); self.emit()
      })
      if grant.speed { startSpeed() }
    }
    func startSpeed() {
      speedEpoch += 1; let ticket = speedEpoch, lease = generation
      speed = listen("live/\(uid)/speed", receive: { [weak self] snapshot in
        guard let self, self.valid, self.confirmed, self.watching, self.enabled, self.grant.speed,
              self.speedEpoch == ticket, self.generation == lease else { return }
        let value = FriendsObservation.number(snapshot.childSnapshot(forPath: "metersPerSecond"))
        self.velocity = (FriendsObservation.integer(snapshot.childSnapshot(forPath: "sharingGeneration")),
          FriendsObservation.integer(snapshot.childSnapshot(forPath: "sequence")),
          FriendsObservation.integer(snapshot.childSnapshot(forPath: "measuredAtMs")),
          value.flatMap { $0 >= 0 ? $0 : nil })
        self.emit()
      }, canceled: { [weak self] in
        guard let self, self.valid, self.speedEpoch == ticket else { return }
        self.stopSpeed(); self.emit()
      })
    }
    func stopSpeed() { speedEpoch += 1; speed?.close(); speed = nil; velocity = nil }
    func stopLive() {
      liveEpoch += 1; point?.close(); point = nil; stopSpeed(); watching = false; position = nil
    }
    func snapshot() -> FriendsRepository.Peer? {
      guard confirmed else { return nil }
      var joined: Double?
      if let position, let velocity, grant.speed, velocity.generation == generation,
         velocity.sequence == position.sequence, velocity.measured == position.measuredAtMs { joined = velocity.value }
      return .init(uid: uid, displayName: name, positionAllowed: grant.position, speedAllowed: grant.speed,
        tripsAllowed: grant.trips, sharingEnabled: enabled, awaitingFreshSample: enabled && (cursor == 0 || position == nil),
        liveGeneration: generation, position: position, speed: joined)
    }
    func close() { active = false; consent?.close(); consent = nil; stopDetails(); confirmed = false }
  }
}
