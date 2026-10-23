import Foundation

@main enum MapSwiftProbe {
  static func check(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name)
  }
  static func main() throws {
    let key = "SECRET_fixture_do_not_display"
    let config = NaviEsriConfiguration(key: key, language: "de")
    check(config.isConfigured, "configured")
    check(!String(describing: config).contains(key) && !String(reflecting: config).contains(key), "safe configuration description")
    check(!NaviEsriConfiguration(key: "", language: "de").isConfigured, "missing key")
    check(!NaviEsriConfiguration(key: "bad\nkey", language: "de").isConfigured, "header validation")
    check(config.styleURL(.street).absoluteString == "https://tiles.openfreemap.org/styles/liberty", "account-free street style")
    check(config.styleURL(.satellite).absoluteString.contains("arcgis/imagery?"), "hybrid style")
    check(!config.styleURL(.street).absoluteString.contains(key), "no query credential")
    check(config.styleURL(.satellite).absoluteString.contains("echoToken=false"), "child resources without token")
    let missing = NaviEsriConfiguration(key: "", language: "de")
    check(missing.canLoad(.street) && !missing.canLoad(.satellite), "only satellite requires account")
    check(config.authorization(for: config.styleURL(.street)) == nil, "no credential sent to public street map")
    check(NaviEsriConfiguration.isPublicResource(config.styleURL(.street)), "public resource")
    check(!NaviEsriConfiguration.isPublicResource(URL(string: "https://tiles.openfreemap.org.evil.invalid/a")!), "public host boundary")
    for url in ["https://basemapstyles-api.arcgis.com/a", "https://a.arcgisonline.com/a"] {
      check(config.authorization(for: URL(string: url)!) == "Bearer " + key, "trusted auth")
    }
    for url in ["http://arcgis.com/a", "https://arcgis.com.evil.invalid/a", "https://evil.invalid/a",
                "https://name@arcgis.com/a", "https://arcgis.com:444/a"] {
      check(config.authorization(for: URL(string: url)!) == nil, "credential boundary")
    }
    let state = NaviMapLoadState()
    let first = state.begin(.street, configured: true)
    let second = state.begin(.satellite, configured: true)
    check(!state.ready(first), "old style ignored")
    check(!state.fail(first, .authError), "old failure ignored")
    check(state.ready(second), "new style ready")
    check(state.snapshot.mode == .satellite, "mode retained")
    check(state.fail(second, .quotaReached), "quota failure")
    check(!state.canRequest(second), "quota stops transport")
    let retry = state.begin(.satellite, configured: true)
    check(state.canRequest(retry), "explicit retry")
    state.detach()
    check(!state.ready(retry) && !state.canRequest(retry), "detach invalidates")
    let rebuilt = state.begin(.street, configured: true)
    check(state.ready(rebuilt), "reattach rebuild")
    let empty = state.begin(.street, configured: false)
    check(state.snapshot.status == .configurationRequired && !state.canRequest(empty), "setup stops requests")
    for status in NaviMapLoadState.Status.allCases {
      check(!status.message.contains(key), "generic error")
    }
    print("PASS Swift map configuration, generation races, quota, detach and retry")
  }
}
