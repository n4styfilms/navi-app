package app.organicmaps.fuel;

/** Calculates an estimate in liters/euros from unrounded route meters. No formatting or storage. */
public final class FuelCalculator
{
  private FuelCalculator() {}

  public static FuelEstimate estimate(double distanceMeters, VehicleProfile profile)
  {
    if (!Double.isFinite(distanceMeters) || distanceMeters < 0)
      return FuelEstimate.needs(FuelEstimate.Status.INVALID_DISTANCE);
    if (profile == null || profile.fuelType == null)
      return FuelEstimate.needs(FuelEstimate.Status.NEED_PROFILE);

    boolean personal = profile.personalLitersPer100Km != null;
    Double consumption = personal ? profile.personalLitersPer100Km : profile.wltpLitersPer100Km;
    if (consumption == null || !Double.isFinite(consumption) || consumption <= 0)
      return FuelEstimate.needs(FuelEstimate.Status.NEED_CONSUMPTION);
    if (profile.pricePerLiter == null || !Double.isFinite(profile.pricePerLiter) || profile.pricePerLiter < 0)
      return FuelEstimate.needs(FuelEstimate.Status.NEED_PRICE);

    double liters = distanceMeters / 100000.0 * consumption;
    double euros = liters * profile.pricePerLiter;
    if (!Double.isFinite(liters) || !Double.isFinite(euros))
      return FuelEstimate.needs(FuelEstimate.Status.INVALID_DISTANCE);
    return FuelEstimate.ready(liters, euros, personal ? FuelEstimate.Source.PERSONAL : FuelEstimate.Source.WLTP);
  }
}
