import app.organicmaps.fuel.FuelCalculator;
import app.organicmaps.fuel.FuelEstimate;
import app.organicmaps.fuel.VehicleProfile;

public final class FuelProbe {
  private static Double number(String value) {
    return value.equals("null") ? null : Double.valueOf(value);
  }

  public static void main(String[] args) {
    VehicleProfile profile = args[1].equals("NO_PROFILE") ? null : new VehicleProfile(
        "Test", "Vehicle", "Engine", 2020, VehicleProfile.FuelType.PETROL,
        number(args[1]), number(args[2]), number(args[3]));
    FuelEstimate result = FuelCalculator.estimate(Double.parseDouble(args[0]), profile);
    System.out.print(result.status.name());
    if (result.status == FuelEstimate.Status.READY)
      System.out.print("\t" + result.liters + "\t" + result.euros + "\t" + result.source.name());
    else if (result.liters != null || result.euros != null || result.source != null)
      throw new AssertionError("Incomplete profile exposed a fabricated estimate");
    System.out.println();
  }
}
