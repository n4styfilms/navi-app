package app.organicmaps.navi.map;

/** Style-request lifecycle, shared by map callbacks and the HTTP request gate. No route/GPS ownership. */
public final class MapLoadState
{
  public enum Status
  {
    CONFIGURATION_REQUIRED, LOADING, READY, AUTH_ERROR, QUOTA_REACHED, NETWORK_ERROR, STYLE_ERROR, DETACHED
  }
  public static final class Snapshot
  {
    public final long generation;
    public final BasemapMode mode;
    public final Status status;
    private Snapshot(long generation, BasemapMode mode, Status status)
    {
      this.generation = generation;
      this.mode = mode;
      this.status = status;
    }
  }
  private Snapshot current = new Snapshot(0, BasemapMode.STREET, Status.DETACHED);

  public synchronized Snapshot snapshot() { return current; }

  public synchronized long begin(BasemapMode mode, boolean configured)
  {
    if (mode == null) throw new IllegalArgumentException("Map mode is required");
    current = new Snapshot(current.generation + 1, mode,
                           configured ? Status.LOADING : Status.CONFIGURATION_REQUIRED);
    return current.generation;
  }

  public synchronized boolean complete(long generation)
  {
    if (current.generation != generation || current.status != Status.LOADING) return false;
    current = new Snapshot(generation, current.mode, Status.READY);
    return true;
  }

  public synchronized boolean fail(long generation, Status failure)
  {
    if (failure != Status.AUTH_ERROR && failure != Status.QUOTA_REACHED &&
        failure != Status.NETWORK_ERROR && failure != Status.STYLE_ERROR)
      throw new IllegalArgumentException("Expected map failure status");
    if (!canRequest(generation)) return false;
    current = new Snapshot(generation, current.mode, failure);
    return true;
  }

  public synchronized long retry(boolean configured) { return begin(current.mode, configured); }

  public synchronized void detach()
  {
    current = new Snapshot(current.generation + 1, current.mode, Status.DETACHED);
  }

  public synchronized boolean canRequest(long generation)
  {
    return generation == current.generation && (current.status == Status.LOADING || current.status == Status.READY);
  }

  public static Status failureForHttpStatus(int status)
  {
    if (status == 401 || status == 403 || status == 498 || status == 499) return Status.AUTH_ERROR;
    if (status == 429) return Status.QUOTA_REACHED;
    return status >= 500 ? Status.NETWORK_ERROR : Status.STYLE_ERROR;
  }
}
