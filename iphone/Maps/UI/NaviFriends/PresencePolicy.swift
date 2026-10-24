/// Cadence and generation gate. The repository must recheck before sending and
/// discard SDK-pending writes on pause/sign-out; in-flight server revocation is
/// a separate operation and cannot be guaranteed by this local gate.
@MainActor
final class PresencePolicy {
  enum State: String { case off, starting, sharing, paused, error }
  struct Upload: Sendable {
    let owner: String
    let generation: UInt64
    let sample: PresenceSample
  }

  private(set) var state: State = .off
  private(set) var owner: String?
  private(set) var generation: UInt64 = 0
  private var startedAtMs: Int64 = 0
  private var lastReservedAtMs: Int64 = -1
  private var lastSequence: Int64 = -1
  private var lastMeasuredAtMs: Int64 = -1

  @discardableResult
  func begin(owner uid: String?, at nowMs: Int64) -> UInt64 {
    generation += 1
    owner = uid
    startedAtMs = nowMs
    lastReservedAtMs = -1
    lastSequence = -1
    lastMeasuredAtMs = -1
    let validOwner = uid?.unicodeScalars.contains(where: { $0.value > 0x20 }) ?? false
    state = !validOwner || nowMs < 0 ? .error : .starting
    return generation
  }

  func pause() { generation += 1; state = .paused }
  func fail() { generation += 1; state = .error }
  func signOut() { generation += 1; state = .off; owner = nil }

  func prepare(_ sample: PresenceSample, at nowMs: Int64, generation ticket: UInt64,
               foregroundMap: Bool, moving: Bool) -> Upload? {
    guard state == .starting || state == .sharing, ticket == generation,
          sample.isFresh(at: nowMs), sample.measuredAtMs >= startedAtMs,
          sample.sequence > lastSequence, sample.measuredAtMs > lastMeasuredAtMs,
          let owner else { return nil }
    let interval: Int64 = moving ? (foregroundMap ? 5_000 : 15_000) : 60_000
    if lastReservedAtMs >= 0 && (nowMs < lastReservedAtMs || nowMs - lastReservedAtMs < interval) { return nil }
    lastReservedAtMs = nowMs
    lastSequence = sample.sequence
    lastMeasuredAtMs = sample.measuredAtMs
    state = .sharing
    return Upload(owner: owner, generation: generation, sample: sample)
  }

  func isCurrent(_ upload: Upload, at nowMs: Int64) -> Bool {
    state == .sharing && upload.generation == generation && owner == upload.owner
      && upload.sample.sequence == lastSequence && upload.sample.measuredAtMs == lastMeasuredAtMs
      && upload.sample.isFresh(at: nowMs)
  }
}
