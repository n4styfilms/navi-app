import Foundation

@main
struct PresenceSwiftProbe {
  @MainActor
  static func main() throws {
    let policy = PresencePolicy()
    var queued: [PresencePolicy.Upload] = []
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!
    func optional(_ value: String) -> Double? { value == "null" ? nil : Double(value)! }
    for line in input.split(separator: "\n") {
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      var result: [String: Any] = [:]
      switch f[0] {
      case "begin": policy.begin(owner: f[1], at: Int64(f[2])!)
      case "pause": policy.pause()
      case "error": policy.fail()
      case "off": policy.signOut()
      case "recheck": result["current"] = policy.isCurrent(queued[Int(f[1])!], at: Int64(f[2])!)
      case "sample":
        let sample = PresenceSample(sequence: Int64(f[2])!, measuredAtMs: Int64(f[3])!,
                                    latitude: Double(f[4])!, longitude: Double(f[5])!,
                                    accuracyMeters: optional(f[6]), metersPerSecond: optional(f[7]),
                                    bearingDegrees: optional(f[8]))
        let now = Int64(f[9])!
        let upload = policy.prepare(sample, at: now, generation: UInt64(f[1])!,
                                    foregroundMap: f[10] == "true", moving: f[11] == "true")
        if let upload { queued.append(upload) }
        result["publish"] = upload != nil
        result["valid"] = sample.isValid
        result["fresh"] = sample.isFresh(at: now)
        result["speed"] = sample.speedMetersPerSecond.map { $0 as Any } ?? NSNull()
        result["bearing"] = sample.bearingDegrees.map { $0 as Any } ?? NSNull()
      default: fatalError("Unknown fixture operation")
      }
      result["state"] = policy.state.rawValue
      result["generation"] = policy.generation
      result["owner"] = policy.owner.map { $0 as Any } ?? NSNull()
      let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
      print(String(data: data, encoding: .utf8)!)
    }
  }
}
