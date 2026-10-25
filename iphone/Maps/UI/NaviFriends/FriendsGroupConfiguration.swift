import Foundation

/// Public client configuration only; never accept service-account keys or passwords.
struct FriendsGroupConfiguration: Sendable {
  enum ConfigurationError: Error { case invalid }
  let projectID: String
  let applicationID: String
  let senderID: String
  let apiKey: String
  let databaseURL: URL

  init(json: Data) throws {
    guard let values = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
          Set(values.keys) == Set(["projectId", "applicationId", "apiKey", "databaseUrl"]),
          let project = Self.string(values["projectId"]),
          project.range(of: "^[a-z][a-z0-9-]{4,28}[a-z0-9]$", options: .regularExpression) != nil,
          let application = Self.string(values["applicationId"]),
          application.range(of: "^1:[0-9]+:ios:[a-fA-F0-9]{16,64}$", options: .regularExpression) != nil,
          let key = Self.string(values["apiKey"]),
          key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
          let address = Self.string(values["databaseUrl"]),
          let components = URLComponents(string: address),
          components.scheme?.lowercased() == "https",
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.port == nil || components.port == 443,
          components.path.isEmpty || components.path == "/",
          let host = components.host?.lowercased(), host.count <= 253,
          host.range(of: "^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+(?:firebaseio\\.com|firebasedatabase\\.app)$",
                     options: .regularExpression) != nil,
          let url = components.url else { throw ConfigurationError.invalid }
    projectID = project
    applicationID = application
    senderID = String(application.split(separator: ":")[1])
    apiKey = key
    databaseURL = url
  }

  private static func string(_ value: Any?) -> String? {
    guard let text = value as? String,
          text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.count > 4096 ? nil : trimmed
  }

  func encoded() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["projectId": projectID, "applicationId": applicationID,
      "apiKey": apiKey, "databaseUrl": databaseURL.absoluteString])
  }
}
