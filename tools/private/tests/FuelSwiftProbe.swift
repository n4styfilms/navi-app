import Foundation

@main enum FuelSwiftProbe {
  struct Failure: Error { let message: String }
  static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
  }
  static func number(_ value: Any?) -> Double? {
    if value == nil || value is NSNull { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) ?? .nan }
    return .nan
  }
  static func profile(_ personal: Double? = nil) -> NaviVehicleProfile {
    NaviVehicleProfile(make: "Test", model: "Car", engine: "Motor", year: 2020, fuelType: .petrol,
                       wltpLitersPer100Km: 6, pricePerLiter: 1.8, personalLitersPer100Km: personal)
  }
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw Failure(message: "expected mode and path") }
    let url = URL(fileURLWithPath: arguments[2])
    switch arguments[1] {
    case "fuel":
      let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
      for item in cases {
        let name = item["name"] as! String
        var vehicle = profile(number(item["personal"]))
        vehicle.wltpLitersPer100Km = number(item["wltp"])
        vehicle.pricePerLiter = number(item["price"])
        let result = NaviFuelCalculator.estimate(distanceMeters: number(item["distanceMeters"])!, profile: vehicle)
        try check(result.status.rawValue == item["status"] as? String, name + " status")
        if result.status == .ready {
          try check(abs(result.liters! - number(item["liters"])!) < 1e-10, name + " liters")
          try check(abs(result.euros! - number(item["euros"])!) < 1e-10, name + " euros")
          try check(result.source!.rawValue == item["source"] as? String, name + " source")
        }
      }
      try check(NaviFuelCalculator.estimate(distanceMeters: 1000, profile: nil).status == .needProfile, "missing profile")
      print("PASS Swift 16 shared fuel cases")
    case "input":
      var cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
      cases.append(["name": "overflow", "numbers": [String(repeating: "9", count: 400), "1.8", ""], "errors": ["WLTP"]])
      for item in cases {
        let numbers = item["numbers"] as! [String]
        let result = NaviVehicleInput.parse(make: item["make"] as? String ?? "Test",
            model: item["model"] as? String ?? "Car", engine: item["engine"] as? String ?? "Motor",
            year: item["year"] as? String ?? "2020", fuel: item["fuel"] as? String ?? "DIESEL",
            wltp: numbers[0], price: numbers[1], personal: numbers[2])
        let expected = Set(item["errors"] as? [String] ?? [])
        try check(Set(result.errors.keys.map(\.rawValue)) == expected, (item["name"] as! String) + " input errors")
        if expected.isEmpty {
          let values = item["expected"] as! [Any]
          try check(result.profile?.wltpLitersPer100Km == number(values[0]), "WLTP parse")
          try check(result.profile?.pricePerLiter == number(values[1]), "price parse")
          try check(result.profile?.personalLitersPer100Km == number(values[2]), "personal parse")
        } else { try check(result.profile == nil, "invalid draft produced a profile") }
      }
      print("PASS Swift 18 shared input cases")
    case "write":
      let store = NaviVehicleStore(file: url)
      try check(try store.load().status == .empty, "store not empty")
      try store.save(profile(7.1))
      try check(try store.load().profile == profile(7.1), "profile readback")
      let before = try Data(contentsOf: url)
      var invalid = profile(); invalid.wltpLitersPer100Km = .nan
      do { try store.save(invalid); throw Failure(message: "invalid profile saved") }
      catch NaviVehicleStore.StoreError.invalidProfile {}
      try check(try Data(contentsOf: url) == before, "invalid save changed bytes")
      try Data("{\"schema\":2}".utf8).write(to: url)
      try check(try store.load().status == .unsupportedSchema, "unknown schema")
      try check(try Data(contentsOf: url) == Data("{\"schema\":2}".utf8), "unknown schema overwritten")
      try Data("not json".utf8).write(to: url)
      try check(try store.load().status == .invalid, "corrupt profile")
      try store.save(profile())
      print("PASS Swift store validation, atomic replacement and unknown schema")
    case "read":
      try check(try NaviVehicleStore(file: url).load().profile == profile(), "profile lost across process restart")
      print("PASS Swift store process restart and cleared personal average")
    case "delete":
      let store = NaviVehicleStore(file: url)
      try store.delete()
      try check(try store.load().status == .empty, "delete failed")
      print("PASS Swift profile deletion")
    default: throw Failure(message: "unknown mode")
    }
  }
}
