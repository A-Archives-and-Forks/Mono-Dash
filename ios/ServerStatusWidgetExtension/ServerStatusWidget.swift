import AppIntents
import CryptoKit
import Security
import SwiftUI
import WidgetKit

private let appGroupId = "group.cc.boring-lab.monodash"
private let keychainAccessGroup = "53R8Z6YBWK.cc.boring-lab.monodash.widget"
private let keychainService = "MonoDashServerWidget"
private let serversKey = "server_widget_servers"
private let snapshotsKey = "server_widget_snapshots"
private let errorsKey = "server_widget_errors"
private let settingsKey = "server_widget_settings"
private let widgetKind = "ServerStatusWidget"

struct WidgetServer: Codable, Identifiable, Hashable {
  let id: Int
  let name: String?
  let displayName: String
  let host: String
  let port: Int
  let isHttps: Bool
  let allowInsecureConnections: Bool?
  let sortIndex: Int

  var title: String {
    if let name, !name.isEmpty { return name }
    return displayName
  }

  var baseURL: URL? {
    URL(string: "\(isHttps ? "https" : "http")://\(host):\(port)")
  }
}

struct WidgetSettings: Codable {
  let requestTimeoutSeconds: Int
  let customHeaders: [String: String]

  static let fallback = WidgetSettings(
    requestTimeoutSeconds: 60,
    customHeaders: [:]
  )
}

struct ServerSnapshot: Codable, Identifiable {
  let id: Int
  let name: String?
  let displayName: String
  let host: String
  let port: Int
  let isHttps: Bool
  let allowInsecureConnections: Bool?
  let sortIndex: Int
  let title: String
  let subtitle: String
  let osName: String
  let cpuPercent: Double
  let memoryPercent: Double
  let diskPercent: Double?
  let websiteCount: Int
  let databaseCount: Int
  let appCount: Int
  let taskCount: Int
  let netBytesSent: Int64
  let netBytesRecv: Int64
  let uploadBytesPerSecond: Double
  let downloadBytesPerSecond: Double
  let totalTrafficBytes: Int64
  let latencyMs: Int
  let updatedAt: Date
}

struct WidgetStore {
  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupId)
  }

  static func servers() -> [WidgetServer] {
    guard
      let string = defaults?.string(forKey: serversKey),
      let data = string.data(using: .utf8),
      let servers = try? JSONDecoder().decode([WidgetServer].self, from: data)
    else { return [] }
    return servers.sorted { $0.sortIndex < $1.sortIndex }
  }

  static func settings() -> WidgetSettings {
    guard
      let string = defaults?.string(forKey: settingsKey),
      let data = string.data(using: .utf8),
      let settings = try? JSONDecoder().decode(WidgetSettings.self, from: data)
    else { return .fallback }
    return settings
  }

  static func snapshots() -> [String: ServerSnapshot] {
    guard
      let string = defaults?.string(forKey: snapshotsKey),
      let data = string.data(using: .utf8),
      let snapshots = try? decoder.decode([String: ServerSnapshot].self, from: data)
    else { return [:] }
    return snapshots
  }

  static func saveSnapshot(_ snapshot: ServerSnapshot) {
    var snapshots = snapshots()
    snapshots[String(snapshot.id)] = snapshot
    saveSnapshots(snapshots)
    clearError(serverId: snapshot.id)
  }

  static func selectedServer(id: String?) -> WidgetServer? {
    let servers = servers()
    return servers.first { String($0.id) == id } ?? servers.first
  }

  static func selectedSnapshot(id: String?) -> (WidgetServer?, ServerSnapshot?) {
    let server = selectedServer(id: id)
    let snapshot = server.flatMap { snapshots()[String($0.id)] }
    return (server, snapshot)
  }

  static func selectedError(id: String?) -> String? {
    guard let server = selectedServer(id: id) else { return nil }
    return errors()[String(server.id)]
  }

  static func saveError(_ message: String, serverId: Int) {
    var errors = errors()
    errors[String(serverId)] = message
    saveErrors(errors)
  }

  static func clearError(serverId: Int) {
    var errors = errors()
    errors.removeValue(forKey: String(serverId))
    saveErrors(errors)
  }

  static func apiKey(serverId: Int) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "server_\(serverId)",
      kSecAttrAccessGroup as String: keychainAccessGroup,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func saveSnapshots(_ snapshots: [String: ServerSnapshot]) {
    guard
      let data = try? encoder.encode(snapshots),
      let string = String(data: data, encoding: .utf8)
    else { return }
    defaults?.set(string, forKey: snapshotsKey)
  }

  private static func errors() -> [String: String] {
    guard
      let string = defaults?.string(forKey: errorsKey),
      let data = string.data(using: .utf8),
      let errors = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return errors
  }

  private static func saveErrors(_ errors: [String: String]) {
    guard
      let data = try? JSONEncoder().encode(errors),
      let string = String(data: data, encoding: .utf8)
    else { return }
    defaults?.set(string, forKey: errorsKey)
  }
}

final class DashboardFetcher: NSObject, URLSessionDelegate {
  private let allowInsecureConnections: Bool

  init(allowInsecureConnections: Bool) {
    self.allowInsecureConnections = allowInsecureConnections
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard
      allowInsecureConnections,
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}

enum ServerWidgetFetcher {
  static func fetch(server: WidgetServer) async -> ServerSnapshot? {
    guard let baseURL = server.baseURL else {
      WidgetStore.saveError("Invalid server URL", serverId: server.id)
      return WidgetStore.selectedSnapshot(id: String(server.id)).1
    }
    guard let apiKey = WidgetStore.apiKey(serverId: server.id), !apiKey.isEmpty else {
      WidgetStore.saveError("Missing API key. Open Mono Dash once.", serverId: server.id)
      return WidgetStore.selectedSnapshot(id: String(server.id)).1
    }

    let previous = WidgetStore.selectedSnapshot(id: String(server.id)).1
    let settings = WidgetStore.settings()
    let start = Date()

    do {
      async let baseJson = request(
        baseURL: baseURL,
        path: "/api/v2/dashboard/base/all/all",
        apiKey: apiKey,
        server: server,
        settings: settings
      )
      async let currentJson = request(
        baseURL: baseURL,
        path: "/api/v2/dashboard/current/all/all",
        apiKey: apiKey,
        server: server,
        settings: settings
      )

      let base = try await baseJson
      let current = try await currentJson
      let latencyMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
      let snapshot = makeSnapshot(
        server: server,
        base: base,
        current: current,
        previous: previous,
        latencyMs: latencyMs,
        updatedAt: Date()
      )
      WidgetStore.saveSnapshot(snapshot)
      return snapshot
    } catch {
      let message = errorMessage(error)
      if let base = try? await request(
        baseURL: baseURL,
        path: "/api/v2/dashboard/base/all/all",
        apiKey: apiKey,
        server: server,
        settings: settings
      ) {
        let current = dictionary(base["currentInfo"])
        let snapshot = makeSnapshot(
          server: server,
          base: base,
          current: current,
          previous: previous,
          latencyMs: max(0, Int(Date().timeIntervalSince(start) * 1000)),
          updatedAt: Date()
        )
        WidgetStore.saveSnapshot(snapshot)
        return snapshot
      }
      WidgetStore.saveError(message, serverId: server.id)
      return previous
    }
  }

  private static func request(
    baseURL: URL,
    path: String,
    apiKey: String,
    server: WidgetServer,
    settings: WidgetSettings
  ) async throws -> [String: Any] {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = path
    guard let url = components?.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.timeoutInterval = TimeInterval(max(5, min(settings.requestTimeoutSeconds, 300)))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("MonoDashWidget/1.0", forHTTPHeaderField: "User-Agent")
    for (key, value) in settings.customHeaders where key.lowercased() != "user-agent" {
      request.setValue(value, forHTTPHeaderField: key)
    }

    let timestamp = String(Int(Date().timeIntervalSince1970))
    request.setValue(sign(apiKey: apiKey, timestamp: timestamp), forHTTPHeaderField: "1Panel-Token")
    request.setValue(timestamp, forHTTPHeaderField: "1Panel-Timestamp")

    let delegate = DashboardFetcher(
      allowInsecureConnections: server.allowInsecureConnections == true
    )
    let session = URLSession(
      configuration: .ephemeral,
      delegate: delegate,
      delegateQueue: nil
    )
    let (data, response) = try await session.data(for: request)
    session.finishTasksAndInvalidate()

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw FetchError.httpStatus(http.statusCode)
    }
    guard
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let data = envelope["data"] as? [String: Any]
    else {
      if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        throw FetchError.apiEnvelope(
          code: int(envelope["code"]),
          message: string(envelope["message"] ?? envelope["msg"])
        )
      }
      throw URLError(.cannotParseResponse)
    }
    if int(envelope["code"]) != 200 {
      throw FetchError.apiEnvelope(
        code: int(envelope["code"]),
        message: string(envelope["message"] ?? envelope["msg"])
      )
    }
    return data
  }

  private static func makeSnapshot(
    server: WidgetServer,
    base: [String: Any],
    current: [String: Any],
    previous: ServerSnapshot?,
    latencyMs: Int,
    updatedAt: Date
  ) -> ServerSnapshot {
    let hostname = string(base["hostname"])
    let prettyDistro = string(base["prettyDistro"])
    let ip = string(base["ipV4Addr"])
    let title = !(server.name ?? "").isEmpty ? server.name! : (hostname.isEmpty ? server.displayName : hostname)
    let subtitle = [prettyDistro, ip].filter { !$0.isEmpty }.joined(separator: "  |  ")
    let diskPercent = primaryDiskPercent(current["diskData"])
    let sent = int64(current["netBytesSent"])
    let recv = int64(current["netBytesRecv"])
    let elapsed = previous.map { updatedAt.timeIntervalSince($0.updatedAt) } ?? 0
    let uploadRate = rate(current: sent, previous: previous?.netBytesSent, elapsed: elapsed)
    let downloadRate = rate(current: recv, previous: previous?.netBytesRecv, elapsed: elapsed)

    return ServerSnapshot(
      id: server.id,
      name: server.name,
      displayName: server.displayName,
      host: server.host,
      port: server.port,
      isHttps: server.isHttps,
      allowInsecureConnections: server.allowInsecureConnections,
      sortIndex: server.sortIndex,
      title: title,
      subtitle: subtitle.isEmpty ? "\(server.host):\(server.port)" : subtitle,
      osName: osName(base),
      cpuPercent: double(current["cpuUsedPercent"]),
      memoryPercent: double(current["memoryUsedPercent"]),
      diskPercent: diskPercent,
      websiteCount: int(base["websiteNumber"]),
      databaseCount: int(base["databaseNumber"]),
      appCount: int(base["appInstalledNumber"]),
      taskCount: int(base["cronjobNumber"]),
      netBytesSent: sent,
      netBytesRecv: recv,
      uploadBytesPerSecond: uploadRate,
      downloadBytesPerSecond: downloadRate,
      totalTrafficBytes: sent + recv,
      latencyMs: latencyMs,
      updatedAt: updatedAt
    )
  }

  private static func sign(apiKey: String, timestamp: String) -> String {
    let raw = Data("1panel\(apiKey)\(timestamp)".utf8)
    return Insecure.MD5.hash(data: raw).map { String(format: "%02x", $0) }.joined()
  }

  private static func primaryDiskPercent(_ value: Any?) -> Double? {
    guard let disks = value as? [[String: Any]], !disks.isEmpty else { return nil }
    let disk = disks.first { string($0["path"]) == "/" } ?? disks[0]
    return double(disk["usedPercent"])
  }

  private static func osName(_ base: [String: Any]) -> String {
    let source = [
      string(base["prettyDistro"]),
      string(base["platform"]),
      string(base["platformFamily"]),
      string(base["os"])
    ].joined(separator: " ").lowercased()
    if source.contains("ubuntu") { return "Ubuntu" }
    if source.contains("debian") { return "Debian" }
    if source.contains("centos") { return "CentOS" }
    if source.contains("fedora") { return "Fedora" }
    if source.contains("arch") { return "Arch" }
    if source.contains("suse") { return "openSUSE" }
    let platform = string(base["platform"])
    return platform.isEmpty ? "Linux" : platform
  }

  private static func rate(current: Int64, previous: Int64?, elapsed: TimeInterval) -> Double {
    guard let previous, elapsed > 0, current >= previous else { return 0 }
    return Double(current - previous) / elapsed
  }

  private static func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
  }

  private static func string(_ value: Any?) -> String {
    value.map { "\($0)" } ?? ""
  }

  private static func int(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? 0 }
    return 0
  }

  private static func int64(_ value: Any?) -> Int64 {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) ?? 0 }
    return 0
  }

  private static func double(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) ?? 0 }
    return 0
  }

  private static func errorMessage(_ error: Error) -> String {
    if let error = error as? FetchError {
      return error.message
    }
    if let error = error as? URLError {
      return error.localizedDescription
    }
    return "\(error)"
  }
}

enum FetchError: Error {
  case httpStatus(Int)
  case apiEnvelope(code: Int, message: String)

  var message: String {
    switch self {
    case .httpStatus(let code):
      return "HTTP \(code)"
    case .apiEnvelope(let code, let message):
      return message.isEmpty ? "API code \(code)" : message
    }
  }
}

struct ServerEntity: AppEntity, Identifiable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
  static var defaultQuery = ServerEntityQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
  }
}

struct ServerEntityQuery: EntityStringQuery {
  func entities(for identifiers: [ServerEntity.ID]) async throws -> [ServerEntity] {
    WidgetStore.servers()
      .filter { identifiers.contains(String($0.id)) }
      .map { ServerEntity(id: String($0.id), name: $0.title) }
  }

  func entities(matching string: String) async throws -> [ServerEntity] {
    WidgetStore.servers()
      .filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
      .map { ServerEntity(id: String($0.id), name: $0.title) }
  }

  func suggestedEntities() async throws -> [ServerEntity] {
    WidgetStore.servers().map { ServerEntity(id: String($0.id), name: $0.title) }
  }
}

struct ServerSelectionIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Server"
  static var description = IntentDescription("Choose the server shown by the widget.")

  @Parameter(title: "Server")
  var server: ServerEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Show \(\.$server)")
  }
}

struct RefreshServerIntent: AppIntent {
  static var title: LocalizedStringResource = "Refresh Server"

  @Parameter(title: "Server ID")
  var serverId: String

  init() {
    serverId = ""
  }

  init(serverId: String) {
    self.serverId = serverId
  }

  func perform() async throws -> some IntentResult {
    if let server = WidgetStore.selectedServer(id: serverId) {
      _ = await ServerWidgetFetcher.fetch(server: server)
      WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
    return .result()
  }
}

struct ServerEntry: TimelineEntry {
  let date: Date
  let server: WidgetServer?
  let snapshot: ServerSnapshot?
  let errorMessage: String?
}

struct ServerStatusProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> ServerEntry {
    ServerEntry(
      date: Date(),
      server: WidgetServer(
        id: 1,
        name: "Mono Dash",
        displayName: "Mono Dash",
        host: "127.0.0.1",
        port: 10086,
        isHttps: true,
        allowInsecureConnections: false,
        sortIndex: 0
      ),
      snapshot: ServerSnapshot(
        id: 1,
        name: "Mono Dash",
        displayName: "Mono Dash",
        host: "127.0.0.1",
        port: 10086,
        isHttps: true,
        allowInsecureConnections: false,
        sortIndex: 0,
        title: "Mono Dash",
        subtitle: "Ubuntu  |  10.0.0.2",
        osName: "Ubuntu",
        cpuPercent: 24,
        memoryPercent: 58,
        diskPercent: 43,
        websiteCount: 4,
        databaseCount: 2,
        appCount: 8,
        taskCount: 3,
        netBytesSent: 1_200_000_000,
        netBytesRecv: 8_600_000_000,
        uploadBytesPerSecond: 52_000,
        downloadBytesPerSecond: 380_000,
        totalTrafficBytes: 9_800_000_000,
        latencyMs: 86,
        updatedAt: Date()
      ),
      errorMessage: nil
    )
  }

  func snapshot(
    for configuration: ServerSelectionIntent,
    in context: Context
  ) async -> ServerEntry {
    guard let server = WidgetStore.selectedServer(id: configuration.server?.id) else {
      return ServerEntry(date: Date(), server: nil, snapshot: nil, errorMessage: nil)
    }
    let snapshot = context.isPreview
      ? WidgetStore.selectedSnapshot(id: String(server.id)).1
      : await ServerWidgetFetcher.fetch(server: server)
    return ServerEntry(
      date: Date(),
      server: server,
      snapshot: snapshot,
      errorMessage: WidgetStore.selectedError(id: String(server.id))
    )
  }

  func timeline(
    for configuration: ServerSelectionIntent,
    in context: Context
  ) async -> Timeline<ServerEntry> {
    guard let server = WidgetStore.selectedServer(id: configuration.server?.id) else {
      return Timeline(
        entries: [ServerEntry(date: Date(), server: nil, snapshot: nil, errorMessage: nil)],
        policy: .after(Date().addingTimeInterval(900))
      )
    }

    let snapshot = await ServerWidgetFetcher.fetch(server: server)
    let entry = ServerEntry(
      date: Date(),
      server: server,
      snapshot: snapshot,
      errorMessage: WidgetStore.selectedError(id: String(server.id))
    )
    return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900)))
  }
}

struct ServerStatusWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  let entry: ServerEntry

  var body: some View {
    Group {
      if let snapshot = entry.snapshot {
        serverCard(snapshot)
      } else if let server = entry.server {
        fallbackCard(server, errorMessage: entry.errorMessage)
      } else {
        emptyCard
      }
    }
    .containerBackground(.background, for: .widget)
  }

  private func serverCard(_ snapshot: ServerSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      header(snapshot)
      metricRows(snapshot)
      if family != .systemSmall {
        Divider()
        trafficRow(snapshot)
      }
      Spacer(minLength: 0)
      HStack {
        Text(snapshot.updatedAt, style: .time)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        Button(intent: RefreshServerIntent(serverId: String(snapshot.id))) {
          Image(systemName: "arrow.clockwise")
            .font(.caption.weight(.bold))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(16)
  }

  private func fallbackCard(_ server: WidgetServer, errorMessage: String?) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      header(
        title: server.title,
        subtitle: "\(server.host):\(server.port)",
        osName: "Linux",
        latencyMs: nil
      )
      Text(errorMessage ?? (WidgetStore.apiKey(serverId: server.id) == nil ? "Open Mono Dash once to enable widget refresh." : "Tap refresh to fetch this server."))
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(3)
      Spacer(minLength: 0)
      Button(intent: RefreshServerIntent(serverId: String(server.id))) {
        Label("Refresh", systemImage: "arrow.clockwise")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.bordered)
    }
    .padding(16)
  }

  private var emptyCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: "server.rack")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("No Server")
        .font(.headline)
      Text("Add a server in Mono Dash.")
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(16)
  }

  private func header(_ snapshot: ServerSnapshot) -> some View {
    header(
      title: snapshot.title,
      subtitle: snapshot.subtitle,
      osName: snapshot.osName,
      latencyMs: snapshot.latencyMs
    )
  }

  private func header(
    title: String,
    subtitle: String,
    osName: String,
    latencyMs: Int?
  ) -> some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color.accentColor.opacity(0.12))
        Text(osInitial(osName))
          .font(.caption.weight(.bold))
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline.weight(.bold))
          .lineLimit(1)
        Text(subtitle.isEmpty ? "--" : subtitle)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      if let latencyMs {
        Text("\(latencyMs)ms")
          .font(.caption2.weight(.bold))
          .foregroundStyle(latencyMs > 500 ? .orange : .green)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background((latencyMs > 500 ? Color.orange : Color.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
      }
    }
  }

  private func metricRows(_ snapshot: ServerSnapshot) -> some View {
    VStack(spacing: 8) {
      metric(label: "CPU", value: snapshot.cpuPercent, tint: .blue)
      metric(label: "MEM", value: snapshot.memoryPercent, tint: .purple)
      if let diskPercent = snapshot.diskPercent {
        metric(label: "DISK", value: diskPercent, tint: .orange)
      }
    }
  }

  private func metric(label: String, value: Double, tint: Color) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .frame(width: 30, alignment: .leading)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.secondary.opacity(0.14))
          Capsule()
            .fill(tint)
            .frame(width: proxy.size.width * min(max(value, 0), 100) / 100)
        }
      }
      .frame(height: 6)
      Text(percent(value))
        .font(.caption2.monospacedDigit().weight(.semibold))
        .frame(width: 36, alignment: .trailing)
    }
  }

  private func trafficRow(_ snapshot: ServerSnapshot) -> some View {
    HStack {
      traffic("Up", snapshot.uploadBytesPerSecond)
      traffic("Down", snapshot.downloadBytesPerSecond)
      VStack(alignment: .leading, spacing: 2) {
        Text(bytes(snapshot.totalTrafficBytes))
          .font(.callout.monospacedDigit().weight(.bold))
        Text("Total")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func traffic(_ label: String, _ value: Double) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(bytes(Int64(value)))/s")
        .font(.callout.monospacedDigit().weight(.bold))
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func osInitial(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "L"
  }

  private func percent(_ value: Double) -> String {
    let clamped = min(max(value, 0), 100)
    return clamped >= 10
      ? "\(Int(clamped.rounded()))%"
      : String(format: "%.1f%%", clamped)
  }

  private func bytes(_ value: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var amount = Double(max(value, 0))
    var index = 0
    while amount >= 1024, index < units.count - 1 {
      amount /= 1024
      index += 1
    }
    return amount >= 10 || index == 0
      ? "\(Int(amount.rounded()))\(units[index])"
      : String(format: "%.1f%@", amount, units[index])
  }
}

struct ServerStatusWidget: Widget {
  let kind = widgetKind

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: ServerSelectionIntent.self,
      provider: ServerStatusProvider()
    ) { entry in
      ServerStatusWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Mono Dash Server")
    .description("Show and refresh a selected server status card.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct ServerStatusWidgetBundle: WidgetBundle {
  var body: some Widget {
    ServerStatusWidget()
  }
}
