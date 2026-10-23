"""Execute the production Java callback with camera/router boundary doubles.

This is a callback unit check, not an Android/MapLibre rendered runtime test.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RouteReadyCallbackTests(unittest.TestCase):
    def test_reroute_preserves_following_and_preview_fits(self):
        suffix = '.exe' if os.name == 'nt' else ''
        home = os.environ.get('JAVA_HOME')
        javac = str(Path(home) / 'bin' / ('javac' + suffix)) if home else shutil.which('javac')
        java = str(Path(home) / 'bin' / ('java' + suffix)) if home else shutil.which('java')
        if not javac or not java:
            self.skipTest('JDK required')
        root = Path(__file__).resolve().parents[3]
        source = (root / 'android/app/src/main/java/app/organicmaps/navi/NaviActivity.java').read_text(encoding='utf-8')
        start = source.index('@Override public void onBuiltRoute()')
        opening = source.index('{', start)
        depth, end = 1, opening + 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        callback = source[start:end]
        # Compile the actual callback, rather than repeat its conditional in a test.
        harness = '''
interface RouteReady { void onBuiltRoute(); }
public final class RouteReadyProbe implements RouteReady {
  static final class NaviRouteSnapshot {
    enum State { NONE, BUILDING, PREVIEW, NAVIGATING, FAILED }
    State state;
    NaviRouteSnapshot(State value) { state = value; }
  }
  static final class Camera {
    boolean following = true; int fits;
    void fitRoute() { following = false; ++fits; }
  }
  static final class Router {
    boolean navigating;
    boolean isNavigating() { return navigating; }
  }
  final Camera map = new Camera(); final Router routing = new Router();
  NaviRouteSnapshot snapshot; int refreshes;
  void refresh() { ++refreshes; }
  CALLBACK
  static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
  public static void main(String[] args) {
    var probe = new RouteReadyProbe();
    probe.snapshot = new NaviRouteSnapshot(NaviRouteSnapshot.State.PREVIEW);
    probe.onBuiltRoute();
    check(probe.map.fits == 1, "Ready preview must fit its route");
    probe.routing.navigating = true; probe.map.following = true;
    for (var state : NaviRouteSnapshot.State.values()) {
      probe.snapshot = new NaviRouteSnapshot(state);
      probe.onBuiltRoute();
      check(probe.map.following && probe.map.fits == 1,
            "Driving reroute must preserve camera following, including late preview snapshots");
    }
    probe.routing.navigating = false;
    for (var state : new NaviRouteSnapshot.State[]{NaviRouteSnapshot.State.NONE,
        NaviRouteSnapshot.State.BUILDING, NaviRouteSnapshot.State.FAILED}) {
      probe.snapshot = new NaviRouteSnapshot(state); probe.onBuiltRoute();
      check(probe.map.fits == 1, "Non-ready route must not fit stale geometry");
    }
    probe.snapshot = null; probe.onBuiltRoute();
    check(probe.map.fits == 1 && probe.refreshes == 10, "Callback refresh/null safety");
    System.out.println("PASS actual route-ready callback preserves driving camera");
  }
}
'''.replace('CALLBACK', callback)
        with tempfile.TemporaryDirectory(prefix='navi-route-ready-') as directory:
            fixture = Path(directory) / 'RouteReadyProbe.java'
            fixture.write_text(harness, encoding='utf-8')
            built = subprocess.run([javac, '-encoding', 'UTF-8', '-d', directory, str(fixture)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([java, '-cp', directory, 'RouteReadyProbe'],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS actual route-ready callback', result.stdout)
