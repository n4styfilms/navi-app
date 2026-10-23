package app.organicmaps.fuel;

public final class FuelEstimate
{
  public enum Status { READY, NEED_PROFILE, NEED_CONSUMPTION, NEED_PRICE, INVALID_DISTANCE }
  public enum Source { WLTP, PERSONAL }

  public final Status status;
  public final Double liters;
  public final Double euros;
  public final Source source;

  private FuelEstimate(Status status, Double liters, Double euros, Source source)
  {
    this.status = status;
    this.liters = liters;
    this.euros = euros;
    this.source = source;
  }

  static FuelEstimate needs(Status status) { return new FuelEstimate(status, null, null, null); }
  static FuelEstimate ready(double liters, double euros, Source source)
  {
    return new FuelEstimate(Status.READY, liters, euros, source);
  }
}
