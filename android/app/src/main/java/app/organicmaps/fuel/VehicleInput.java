package app.organicmaps.fuel;

import java.util.Collections;
import java.util.EnumMap;
import java.util.Map;

/** Parses editor drafts without changing the stored profile. Decimal comma and dot are accepted. */
public final class VehicleInput
{
  public enum Field { MAKE, MODEL, ENGINE, YEAR, FUEL, WLTP, PRICE, PERSONAL }
  public enum Error { REQUIRED, INVALID }

  public static final class Result
  {
    public final VehicleProfile profile;
    public final Map<Field, Error> errors;
    private Result(VehicleProfile profile, EnumMap<Field, Error> errors)
    {
      this.profile = profile;
      this.errors = Collections.unmodifiableMap(new EnumMap<>(errors));
    }
  }

  private VehicleInput() {}
  private static String clean(String value) { return value == null ? "" : value.trim(); }

  public static Result parse(String make, String model, String engine, String year, String fuel,
                             String wltp, String price, String personal)
  {
    EnumMap<Field, Error> errors = new EnumMap<>(Field.class);
    make = requiredText(make, Field.MAKE, errors);
    model = requiredText(model, Field.MODEL, errors);
    engine = requiredText(engine, Field.ENGINE, errors);
    year = requiredText(year, Field.YEAR, errors);
    Integer parsedYear = null;
    if (!year.isEmpty())
    {
      if (year.matches("[1-9][0-9]{3}")) parsedYear = Integer.valueOf(year);
      else errors.put(Field.YEAR, Error.INVALID);
    }
    fuel = requiredText(fuel, Field.FUEL, errors);
    VehicleProfile.FuelType fuelType = null;
    if (!fuel.isEmpty())
    {
      try { fuelType = VehicleProfile.FuelType.valueOf(fuel); }
      catch (IllegalArgumentException e) { errors.put(Field.FUEL, Error.INVALID); }
    }
    Double parsedWltp = number(wltp, Field.WLTP, false, false, errors);
    Double parsedPrice = number(price, Field.PRICE, false, true, errors);
    Double parsedPersonal = number(personal, Field.PERSONAL, true, false, errors);
    VehicleProfile profile = errors.isEmpty() ? new VehicleProfile(make, model, engine, parsedYear, fuelType,
        parsedWltp, parsedPrice, parsedPersonal) : null;
    return new Result(profile, errors);
  }

  private static String requiredText(String value, Field field, EnumMap<Field, Error> errors)
  {
    String result = clean(value);
    if (result.isEmpty()) errors.put(field, Error.REQUIRED);
    return result;
  }

  private static Double number(String value, Field field, boolean optional, boolean allowZero,
                                EnumMap<Field, Error> errors)
  {
    String text = clean(value);
    if (text.isEmpty())
    {
      if (!optional) errors.put(field, Error.REQUIRED);
      return null;
    }
    if (text.matches("[0-9]+([.,][0-9]+)?"))
    {
      double parsed = Double.parseDouble(text.replace(',', '.'));
      if (Double.isFinite(parsed) && (allowZero ? parsed >= 0 : parsed > 0)) return parsed;
    }
    errors.put(field, Error.INVALID);
    return null;
  }
}
