import app.organicmaps.navi.friends.PresenceSample;
import app.organicmaps.navi.friends.PresencePolicy;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;

public final class PresenceProbe {
  private static Double optional(String s) { return s.equals("null") ? null : Double.valueOf(s); }
  private static String quoted(String s) { return s == null ? "null" : "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""; }
  public static void main(String[] args) throws Exception {
    PresencePolicy policy = new PresencePolicy();
    ArrayList<PresencePolicy.Upload> queued = new ArrayList<>();
    BufferedReader input = new BufferedReader(new InputStreamReader(System.in));
    for (String line; (line = input.readLine()) != null;) {
      String[] f = line.split("\t", -1);
      String extra = "";
      switch (f[0]) {
        case "begin": policy.begin(f[1], Long.parseLong(f[2])); break;
        case "pause": policy.pause(); break;
        case "error": policy.fail(); break;
        case "off": policy.signOut(); break;
        case "recheck": extra = ",\"current\":" + policy.isCurrent(queued.get(Integer.parseInt(f[1])), Long.parseLong(f[2])); break;
        case "sample":
          PresenceSample sample = new PresenceSample(Long.parseLong(f[2]), Long.parseLong(f[3]),
              Double.parseDouble(f[4]), Double.parseDouble(f[5]), optional(f[6]), optional(f[7]), optional(f[8]));
          long now = Long.parseLong(f[9]);
          PresencePolicy.Upload upload = policy.prepare(sample, now, Long.parseLong(f[1]),
              Boolean.parseBoolean(f[10]), Boolean.parseBoolean(f[11]));
          if (upload != null) queued.add(upload);
          extra = ",\"publish\":" + (upload != null) + ",\"valid\":" + sample.isValid()
              + ",\"fresh\":" + sample.isFreshAt(now) + ",\"speed\":" + sample.speedMetersPerSecond()
              + ",\"bearing\":" + sample.bearingDegrees();
          break;
        default: throw new IllegalArgumentException("Unknown fixture operation: " + f[0]);
      }
      System.out.println("{\"state\":" + quoted(policy.state().name().toLowerCase(java.util.Locale.ROOT))
          + ",\"generation\":" + policy.generation() + ",\"owner\":" + quoted(policy.owner()) + extra + "}");
    }
  }
}
