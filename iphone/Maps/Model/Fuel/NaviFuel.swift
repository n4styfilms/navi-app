import Foundation

struct NaviVehicleProfile: Codable, Equatable {
  enum FuelType: String, Codable { case petrol = "PETROL", diesel = "DIESEL" }
  var make: String
  var model: String
  var engine: String
  var year: Int?
  var fuelType: FuelType?
  var wltpLitersPer100Km: Double?
  var pricePerLiter: Double?
  var personalLitersPer100Km: Double?

  var isComplete: Bool {
    !make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !engine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    year.map { (1000...9999).contains($0) } == true && fuelType != nil &&
    wltpLitersPer100Km.map { $0.isFinite && $0 > 0 } == true &&
    pricePerLiter.map { $0.isFinite && $0 >= 0 } == true &&
    personalLitersPer100Km.map { $0.isFinite && $0 > 0 } != false
  }
}

struct NaviFuelEstimate {
  enum Status: String {
    case ready = "READY", needProfile = "NEED_PROFILE", needConsumption = "NEED_CONSUMPTION"
    case needPrice = "NEED_PRICE", invalidDistance = "INVALID_DISTANCE"
  }
  enum Source: String { case wltp = "WLTP", personal = "PERSONAL" }
  let status: Status
  let liters: Double?
  let euros: Double?
  let source: Source?
  static func needs(_ status: Status) -> Self { Self(status: status, liters: nil, euros: nil, source: nil) }
}

enum NaviFuelCalculator {
  static func estimate(distanceMeters: Double, profile: NaviVehicleProfile?) -> NaviFuelEstimate {
    guard distanceMeters.isFinite, distanceMeters >= 0 else { return .needs(.invalidDistance) }
    guard let profile, profile.fuelType != nil else { return .needs(.needProfile) }
    let personal = profile.personalLitersPer100Km != nil
    guard let consumption = personal ? profile.personalLitersPer100Km : profile.wltpLitersPer100Km,
          consumption.isFinite, consumption > 0 else { return .needs(.needConsumption) }
    guard let price = profile.pricePerLiter, price.isFinite, price >= 0 else { return .needs(.needPrice) }
    let liters = distanceMeters / 100_000 * consumption
    let euros = liters * price
    guard liters.isFinite, euros.isFinite else { return .needs(.invalidDistance) }
    return NaviFuelEstimate(status: .ready, liters: liters, euros: euros, source: personal ? .personal : .wltp)
  }
}

enum NaviVehicleInput {
  enum Field: String, CaseIterable { case make = "MAKE", model = "MODEL", engine = "ENGINE", year = "YEAR"
    case fuel = "FUEL", wltp = "WLTP", price = "PRICE", personal = "PERSONAL"
  }
  enum Error { case required, invalid }
  struct Result { let profile: NaviVehicleProfile?; let errors: [Field: Error] }

  static func parse(make: String, model: String, engine: String, year: String, fuel: String,
                    wltp: String, price: String, personal: String) -> Result {
    var errors: [Field: Error] = [:]
    func required(_ value: String, _ field: Field) -> String {
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { errors[field] = .required }
      return text
    }
    let make = required(make, .make), model = required(model, .model), engine = required(engine, .engine)
    let yearText = required(year, .year), fuelText = required(fuel, .fuel)
    var yearValue: Int?
    if !yearText.isEmpty {
      if yearText.range(of: "^[1-9][0-9]{3}$", options: .regularExpression) != nil { yearValue = Int(yearText) }
      else { errors[.year] = .invalid }
    }
    let fuelValue = NaviVehicleProfile.FuelType(rawValue: fuelText)
    if !fuelText.isEmpty && fuelValue == nil { errors[.fuel] = .invalid }
    func number(_ value: String, _ field: Field, optional: Bool = false, zero: Bool = false) -> Double? {
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        if !optional { errors[field] = .required }
        return nil
      }
      if text.range(of: "^[0-9]+([.,][0-9]+)?$", options: .regularExpression) != nil,
         let parsed = Double(text.replacingOccurrences(of: ",", with: ".")), parsed.isFinite,
         zero ? parsed >= 0 : parsed > 0 { return parsed }
      errors[field] = .invalid
      return nil
    }
    let wltpValue = number(wltp, .wltp)
    let priceValue = number(price, .price, zero: true)
    let personalValue = number(personal, .personal, optional: true)
    let profile = errors.isEmpty ? NaviVehicleProfile(make: make, model: model, engine: engine, year: yearValue,
        fuelType: fuelValue, wltpLitersPer100Km: wltpValue, pricePerLiter: priceValue,
        personalLitersPer100Km: personalValue) : nil
    return Result(profile: profile, errors: errors)
  }
}

/// App-private versioned file. Call on its owning GUI thread; no iCloud/user-default synchronization.
final class NaviVehicleStore {
  enum Status { case empty, ready, invalid, unsupportedSchema }
  enum StoreError: Swift.Error { case invalidProfile }
  struct LoadResult { let status: Status; let profile: NaviVehicleProfile? }
  private struct Envelope: Codable { let schema: Int; let profile: NaviVehicleProfile }
  private let file: URL

  init(file: URL) { self.file = file }

  static func local() throws -> NaviVehicleStore {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
    return NaviVehicleStore(file: support.appendingPathComponent("Navi", isDirectory: true)
        .appendingPathComponent("vehicle-v1.json"))
  }

  func load() throws -> LoadResult {
    guard FileManager.default.fileExists(atPath: file.path) else { return LoadResult(status: .empty, profile: nil) }
    let data = try Data(contentsOf: file)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let schema = object["schema"] as? Int else { return LoadResult(status: .invalid, profile: nil) }
    guard schema == 1 else { return LoadResult(status: .unsupportedSchema, profile: nil) }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.profile.isComplete
      else { return LoadResult(status: .invalid, profile: nil) }
    return LoadResult(status: .ready, profile: envelope.profile)
  }

  func save(_ profile: NaviVehicleProfile) throws {
    guard profile.isComplete else { throw StoreError.invalidProfile }
    var directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #if canImport(Darwin)
    var exclusion = URLResourceValues()
    exclusion.isExcludedFromBackup = true
    try directory.setResourceValues(exclusion)
    #endif
    let data = try JSONEncoder().encode(Envelope(schema: 1, profile: profile))
    #if os(iOS)
    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: file, options: .atomic)
    #endif
  }

  func delete() throws {
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
  }
}
