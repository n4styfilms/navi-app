import app.organicmaps.fuel.*;
import java.io.File;

public final class VehicleProbe
{
  private static VehicleInput.Result parse(String[] args, int offset)
  {
    return VehicleInput.parse(args[offset], args[offset+1], args[offset+2], args[offset+3],
        args[offset+4], args[offset+5], args[offset+6], args[offset+7]);
  }
  private static void print(VehicleProfile profile)
  {
    System.out.println("READY\t" + profile.make + "\t" + profile.model + "\t" + profile.engine + "\t" +
        profile.year + "\t" + profile.fuelType + "\t" + profile.wltpLitersPer100Km + "\t" +
        profile.pricePerLiter + "\t" + profile.personalLitersPer100Km);
  }
  public static void main(String[] args) throws Exception
  {
    if (args[0].equals("parse"))
    {
      VehicleInput.Result result = parse(args,1);
      if (result.profile != null) print(result.profile);
      else
      {
        if (result.errors.isEmpty()) throw new AssertionError("invalid input has no field errors");
        System.out.print("ERROR");
        for (VehicleInput.Field field : result.errors.keySet()) System.out.print("\t" + field);
        System.out.println();
      }
      return;
    }
    VehicleStore store = new VehicleStore(new File(args[1]));
    switch (args[0])
    {
      case "save":
        store.save(parse(args,2).profile);
        System.out.println("SAVED");
        break;
      case "load":
        VehicleStore.LoadResult result = store.load();
        if (result.profile != null) print(result.profile);
        else System.out.println(result.status);
        break;
      case "invalid":
        try
        {
          store.save(new VehicleProfile("A","B","C",2020,VehicleProfile.FuelType.PETROL,
              Double.NaN,1.8,null));
          throw new AssertionError("invalid profile saved");
        }
        catch (IllegalArgumentException expected) { System.out.println("REJECTED"); }
        break;
      case "delete":
        store.delete();
        System.out.println("DELETED");
        break;
      default: throw new IllegalArgumentException("unknown test mode");
    }
  }
}
