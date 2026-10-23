package app.organicmaps.fuel;

/** Locally entered vehicle data. Validation is shared by the calculator and editor. */
public final class VehicleProfile
{
  public enum FuelType { PETROL, DIESEL }

  public final String make;
  public final String model;
  public final String engine;
  public final Integer year;
  public final FuelType fuelType;
  public final Double wltpLitersPer100Km;
  public final Double pricePerLiter;
  public final Double personalLitersPer100Km;

  public VehicleProfile(String make, String model, String engine, Integer year, FuelType fuelType,
                        Double wltpLitersPer100Km, Double pricePerLiter, Double personalLitersPer100Km)
  {
    this.make = make;
    this.model = model;
    this.engine = engine;
    this.year = year;
    this.fuelType = fuelType;
    this.wltpLitersPer100Km = wltpLitersPer100Km;
    this.pricePerLiter = pricePerLiter;
    this.personalLitersPer100Km = personalLitersPer100Km;
  }

  /** A complete local profile; calculation alone may still report missing fields separately. */
  public boolean isComplete()
  {
    return hasText(make) && hasText(model) && hasText(engine) && year != null && year >= 1000 && year <= 9999 &&
        fuelType != null && positive(wltpLitersPer100Km) && pricePerLiter != null &&
        Double.isFinite(pricePerLiter) && pricePerLiter >= 0 &&
        (personalLitersPer100Km == null || positive(personalLitersPer100Km));
  }

  private static boolean hasText(String value) { return value != null && !value.trim().isEmpty(); }
  private static boolean positive(Double value) { return value != null && Double.isFinite(value) && value > 0; }
}
