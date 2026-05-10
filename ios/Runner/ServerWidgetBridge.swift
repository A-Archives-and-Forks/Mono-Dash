import Flutter
import Foundation
import Security
import WidgetKit

final class ServerWidgetBridge {
  private static let appGroupId = "group.cc.boring-lab.monodash"
  private static let keychainAccessGroup = "53R8Z6YBWK.cc.boring-lab.monodash.widget"
  private static let keychainService = "MonoDashServerWidget"
  private static let channelName = "mono_dash/server_widget"
  private static let serversKey = "server_widget_servers"
  private static let snapshotsKey = "server_widget_snapshots"
  private static let settingsKey = "server_widget_settings"
  private static let widgetKind = "ServerStatusWidget"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "syncServers":
        syncServers(from: call.arguments)
        result(nil)
      case "upsertSnapshot":
        upsertSnapshot(from: call.arguments)
        result(nil)
      case "removeServer":
        removeServer(from: call.arguments)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func syncServers(from arguments: Any?) {
    guard
      let arguments = arguments as? [String: Any],
      let servers = arguments["servers"] as? [[String: Any]]
    else { return }

    let sortedServers = servers.sorted { lhs, rhs in
      intValue(lhs["sortIndex"]) < intValue(rhs["sortIndex"])
    }
    for server in sortedServers {
      let id = intValue(server["id"])
      if let apiKey = server["apiKey"] as? String, !apiKey.isEmpty {
        saveApiKey(apiKey, serverId: id)
      }
    }
    setJsonValue(sortedServers.map(sanitize), forKey: serversKey)

    if let settings = arguments["settings"] as? [String: Any] {
      setJsonValue(sanitize(settings), forKey: settingsKey)
    }

    let validIds = Set(sortedServers.map { String(intValue($0["id"])) })
    var snapshots = jsonDictionary(forKey: snapshotsKey)
    snapshots = snapshots.filter { validIds.contains($0.key) }
    setJsonValue(snapshots, forKey: snapshotsKey)
    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
  }

  private static func upsertSnapshot(from arguments: Any?) {
    guard
      let arguments = arguments as? [String: Any],
      let snapshot = arguments["snapshot"] as? [String: Any]
    else { return }

    let id = String(intValue(snapshot["id"]))
    guard id != "0" else { return }

    var snapshots = jsonDictionary(forKey: snapshotsKey)
    snapshots[id] = sanitize(snapshot)
    setJsonValue(snapshots, forKey: snapshotsKey)
    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
  }

  private static func removeServer(from arguments: Any?) {
    guard
      let arguments = arguments as? [String: Any],
      let id = arguments["id"]
    else { return }

    let idString = String(intValue(id))
    var servers = jsonArray(forKey: serversKey)
    servers.removeAll { String(intValue($0["id"])) == idString }
    setJsonValue(servers, forKey: serversKey)
    deleteApiKey(serverId: intValue(id))

    var snapshots = jsonDictionary(forKey: snapshotsKey)
    snapshots.removeValue(forKey: idString)
    setJsonValue(snapshots, forKey: snapshotsKey)
    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
  }

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupId)
  }

  private static func setJsonValue(_ value: Any, forKey key: String) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8)
    else { return }
    defaults?.set(string, forKey: key)
  }

  private static func jsonArray(forKey key: String) -> [[String: Any]] {
    guard
      let string = defaults?.string(forKey: key),
      let data = string.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return value
  }

  private static func jsonDictionary(forKey key: String) -> [String: [String: Any]] {
    guard
      let string = defaults?.string(forKey: key),
      let data = string.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return [:] }
    return value
  }

  private static func sanitize(_ value: [String: Any]) -> [String: Any] {
    value.compactMapValues { item in
      switch item {
      case Optional<Any>.none:
        return nil
      case let number as NSNumber:
        return number
      case let string as String:
        return string
      case let bool as Bool:
        return bool
      default:
        return item
      }
    }
    .filter { $0.key != "apiKey" }
  }

  private static func intValue(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? 0 }
    return 0
  }

  private static func keychainQuery(serverId: Int) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "server_\(serverId)",
      kSecAttrAccessGroup as String: keychainAccessGroup
    ]
  }

  private static func saveApiKey(_ apiKey: String, serverId: Int) {
    guard serverId > 0, let data = apiKey.data(using: .utf8) else { return }
    var query = keychainQuery(serverId: serverId)
    SecItemDelete(query as CFDictionary)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(query as CFDictionary, nil)
  }

  private static func deleteApiKey(serverId: Int) {
    guard serverId > 0 else { return }
    SecItemDelete(keychainQuery(serverId: serverId) as CFDictionary)
  }
}
