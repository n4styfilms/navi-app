package app.organicmaps.navi.friends;

/** Upload cadence and generation gate, independent of GPS or Firebase SDKs.
 * The caller must recheck a candidate immediately before sending on its serialized
 * upload queue, and discard SDK-pending writes on pause/sign-out. This class does
 * not claim that a network request already in flight has been revoked.
 */
public final class PresencePolicy {
  public enum State { OFF, STARTING, SHARING, PAUSED, ERROR }
  public static final class Upload {
    public final String owner;
    public final long generation;
    public final PresenceSample sample;
    private Upload(String owner, long generation, PresenceSample sample) {
      this.owner = owner; this.generation = generation; this.sample = sample;
    }
  }

  private State state = State.OFF;
  private String owner;
  private long generation;
  private long startedAtMs;
  private long lastReservedAtMs = -1;
  private long lastSequence = -1;
  private long lastMeasuredAtMs = -1;

  public synchronized State state() { return state; }
  public synchronized String owner() { return owner; }
  public synchronized long generation() { return generation; }

  public synchronized long begin(String uid, long nowMs) {
    generation++;
    owner = uid;
    startedAtMs = nowMs;
    lastReservedAtMs = lastSequence = lastMeasuredAtMs = -1;
    state = uid == null || uid.trim().isEmpty() || nowMs < 0 ? State.ERROR : State.STARTING;
    return generation;
  }

  public synchronized void pause() { generation++; state = State.PAUSED; }
  public synchronized void fail() { generation++; state = State.ERROR; }
  public synchronized void signOut() { generation++; state = State.OFF; owner = null; }

  public synchronized Upload prepare(PresenceSample sample, long nowMs, long ticket,
                                      boolean foregroundMap, boolean moving) {
    if ((state != State.STARTING && state != State.SHARING) || ticket != generation
        || sample == null || !sample.isFreshAt(nowMs) || sample.measuredAtMs < startedAtMs
        || sample.sequence <= lastSequence || sample.measuredAtMs <= lastMeasuredAtMs)
      return null;
    long interval = moving ? (foregroundMap ? 5000 : 15000) : 60000;
    if (lastReservedAtMs >= 0 && (nowMs < lastReservedAtMs || nowMs - lastReservedAtMs < interval))
      return null;
    lastReservedAtMs = nowMs;
    lastSequence = sample.sequence;
    lastMeasuredAtMs = sample.measuredAtMs;
    state = State.SHARING;
    return new Upload(owner, generation, sample);
  }

  public synchronized boolean isCurrent(Upload upload, long nowMs) {
    return upload != null && state == State.SHARING && upload.generation == generation
        && owner != null && owner.equals(upload.owner) && upload.sample.sequence == lastSequence
        && upload.sample.measuredAtMs == lastMeasuredAtMs && upload.sample.isFreshAt(nowMs);
  }
}
