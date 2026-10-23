package app.organicmaps.fuel;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Properties;

/** One versioned profile in app-private storage. Pass a file under Context.getFilesDir(). */
public final class VehicleStore
{
  public static final String FILE_NAME = "navi-vehicle.properties";
  public enum Status { EMPTY, READY, INVALID, UNSUPPORTED_SCHEMA }
  public static final class LoadResult
  {
    public final Status status;
    public final VehicleProfile profile;
    private LoadResult(Status status, VehicleProfile profile) { this.status = status; this.profile = profile; }
  }

  private final Path file;
  private final Path temporary;

  public VehicleStore(File file)
  {
    this.file = file.getAbsoluteFile().toPath();
    temporary = this.file.resolveSibling(this.file.getFileName().toString() + ".new");
  }

  public synchronized LoadResult load() throws IOException
  {
    if (!Files.exists(file)) return new LoadResult(Status.EMPTY, null);
    Properties values = new Properties();
    try (FileInputStream input = new FileInputStream(file.toFile()))
    {
      values.load(input);
      String schema = values.getProperty("schema");
      if (schema == null) return new LoadResult(Status.INVALID, null);
      if (!schema.equals("1")) return new LoadResult(Status.UNSUPPORTED_SCHEMA, null);
      String year = values.getProperty("year");
      String fuel = values.getProperty("fuel");
      VehicleProfile profile = new VehicleProfile(values.getProperty("make"), values.getProperty("model"),
          values.getProperty("engine"), year == null ? null : Integer.valueOf(year),
          fuel == null ? null : VehicleProfile.FuelType.valueOf(fuel), number(values,"wltp"),
          number(values,"price"), number(values,"personal"));
      return profile.isComplete() ? new LoadResult(Status.READY, profile) : new LoadResult(Status.INVALID, null);
    }
    catch (IllegalArgumentException e) { return new LoadResult(Status.INVALID, null); }
  }

  public synchronized void save(VehicleProfile profile) throws IOException
  {
    if (profile == null || !profile.isComplete()) throw new IllegalArgumentException("Incomplete vehicle profile");
    Properties values = new Properties();
    values.setProperty("schema", "1");
    values.setProperty("make", profile.make);
    values.setProperty("model", profile.model);
    values.setProperty("engine", profile.engine);
    values.setProperty("year", profile.year.toString());
    values.setProperty("fuel", profile.fuelType.name());
    values.setProperty("wltp", profile.wltpLitersPer100Km.toString());
    values.setProperty("price", profile.pricePerLiter.toString());
    if (profile.personalLitersPer100Km != null) values.setProperty("personal", profile.personalLitersPer100Km.toString());
    try
    {
      try (FileOutputStream output = new FileOutputStream(temporary.toFile()))
      {
        values.store(output, "Navi vehicle profile");
        output.getFD().sync();
      }
      // If the filesystem cannot replace atomically, fail and preserve the previous profile.
      Files.move(temporary, file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }
    finally { Files.deleteIfExists(temporary); }
  }

  public synchronized void delete() throws IOException
  {
    Files.deleteIfExists(file);
    Files.deleteIfExists(temporary);
  }

  private static Double number(Properties values, String key)
  {
    String value = values.getProperty(key);
    return value == null ? null : Double.valueOf(value);
  }
}
