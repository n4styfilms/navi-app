import Foundation

@main struct FriendsGroupConfigurationProbe {
  static func main() throws {
    let valid: [String: Any] = ["projectId": "demo-navi-friends",
      "applicationId": "1:1234567890:ios:abcdef0123456789", "apiKey": "fake-api-key",
      "databaseUrl": "https://demo-navi-friends.firebaseio.com"]
    func decode(_ object: [String: Any]) throws -> FriendsGroupConfiguration {
      try FriendsGroupConfiguration(json: JSONSerialization.data(withJSONObject: object))
    }
    let group = try decode(valid)
    precondition(group.projectID == "demo-navi-friends")
    precondition(group.senderID == "1234567890")
    precondition(group.applicationID == "1:1234567890:ios:abcdef0123456789")
    precondition(group.apiKey == "fake-api-key")
    precondition(group.databaseURL.absoluteString == "https://demo-navi-friends.firebaseio.com")
    var european = valid
    european["databaseUrl"] = "https://demo-navi-friends-default-rtdb.europe-west1.firebasedatabase.app/"
    _ = try decode(european)

    var rejected = 0
    func reject(_ object: [String: Any]) {
      do { _ = try decode(object); preconditionFailure("Invalid group accepted after \(rejected) rejected cases") }
      catch { rejected += 1 }
    }
    for key in ["projectId", "applicationId", "apiKey", "databaseUrl"] {
      var missing = valid; missing.removeValue(forKey: key); reject(missing)
      var empty = valid; empty[key] = ""; reject(empty)
      var wrongType = valid; wrongType[key] = 42; reject(wrongType)
    }
    for app in ["1:1234567890:android:abcdef0123456789", "wrong", "1:x:ios:abcdef0123456789",
                "1:1234567890:ios:"] {
      var object = valid; object["applicationId"] = app; reject(object)
    }
    for project in ["space project", "../project", "\nproject", ""] {
      var object = valid; object["projectId"] = project; reject(object)
    }
    for url in ["http://demo-navi-friends.firebaseio.com", "https://evil.test", "https://firebaseio.com",
                "https://demo.firebaseio.com.evil.test", "https://evilfirebaseio.com",
                "https://user:password@demo.firebaseio.com", "https://demo.firebaseio.com/private",
                "https://demo.firebaseio.com?token=x", "https://demo.firebaseio.com#fragment",
                "https://demo.firebaseio.com:9000"] {
      var object = valid; object["databaseUrl"] = url; reject(object)
    }
    var badKey = valid; badKey["apiKey"] = "key\nwith-control"; reject(badKey)
    var serviceAccount = valid; serviceAccount["private_key"] = "synthetic-do-not-store"; reject(serviceAccount)
    precondition(rejected == 32)
    print("PASS Apple group config: valid iOS/region inputs; 32 invalid blocks rejected")
  }
}
