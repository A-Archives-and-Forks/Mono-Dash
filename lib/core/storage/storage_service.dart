import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/server.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'storage_service.g.dart';

/// 同步提供 [StorageService] 的实例。
///
/// 必须在 main.dart 中完成初始化并通过 `ProviderScope.overrides` 覆盖此 Provider，
/// 否则任何读取都会抛出 [UnimplementedError]。
@Riverpod(keepAlive: true)
StorageService storageService(Ref ref) {
  throw UnimplementedError('storageServiceProvider 必须在 main.dart 中 override');
}

class StorageService {
  late final SharedPreferences _prefs;
  late final File _serversFile;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const _legacyAllowInsecureConnectionsKey =
      'allow_insecure_connections';
  static const _serversFileName = 'servers.json';

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    _serversFile = File('${dir.path}/$_serversFileName');
    await _migrateLegacyAllowInsecureConnections();
  }

  Future<void> _migrateLegacyAllowInsecureConnections() async {
    final legacyValue = _prefs.getBool(_legacyAllowInsecureConnectionsKey);
    if (legacyValue != true) return;

    final servers = await _readServers();
    for (final server in servers) {
      server.allowInsecureConnections = true;
    }
    await _writeServers(servers);
    await _prefs.remove(_legacyAllowInsecureConnectionsKey);
  }

  // --- UI State (Shared Preferences) ---

  String? getString(String key) => _prefs.getString(key);

  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  // --- Secure State (Keychain / Keystore) ---

  Future<String?> getSecureString(String key) async {
    return _secureStorage.read(key: key);
  }

  Future<void> setSecureString(String key, String value) async {
    await _secureStorage.write(key: key, value: value);
  }

  Future<void> removeSecureString(String key) async {
    await _secureStorage.delete(key: key);
  }

  // --- Servers (JSON) ---

  Future<List<Server>> getServers() async {
    final servers = await _readServers();
    servers.sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return servers;
  }

  Future<Server?> getServer(int id) async {
    final servers = await _readServers();
    for (final server in servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  Future<void> saveServer(Server server) async {
    final servers = await _readServers();
    if (server.id <= 0) {
      server.id = _nextServerId(servers);
    }

    final index = servers.indexWhere((item) => item.id == server.id);
    if (index == -1) {
      servers.add(server);
    } else {
      servers[index] = server;
    }
    await _writeServers(servers);
  }

  Future<void> deleteServer(int id) async {
    final servers = await _readServers();
    final nextServers = servers.where((server) => server.id != id).toList();
    if (nextServers.length == servers.length) return;

    await _writeServers(nextServers);
    await deleteApiKey(id);
  }

  Future<List<Server>> _readServers() async {
    if (!await _serversFile.exists()) return [];

    final content = await _serversFile.readAsString();
    if (content.trim().isEmpty) return [];

    final json = jsonDecode(content);
    if (json is! List) return [];

    return json
        .whereType<Map>()
        .map((item) => Server.fromJson(Map<String, Object?>.from(item)))
        .toList();
  }

  Future<void> _writeServers(List<Server> servers) async {
    if (!await _serversFile.parent.exists()) {
      await _serversFile.parent.create(recursive: true);
    }

    final content = const JsonEncoder.withIndent(
      '  ',
    ).convert(servers.map((server) => server.toJson()).toList());

    final tmpFile = File('${_serversFile.path}.tmp');
    await tmpFile.writeAsString('$content\n', flush: true);
    await tmpFile.rename(_serversFile.path);
  }

  int _nextServerId(List<Server> servers) {
    var maxId = 0;
    for (final server in servers) {
      if (server.id > maxId) maxId = server.id;
    }
    return maxId + 1;
  }

  // --- API Keys (Secure Storage) ---

  String _apiKeyKey(int id) => 'api_key_$id';

  Future<void> saveApiKey(int id, String apiKey) async {
    await _secureStorage.write(key: _apiKeyKey(id), value: apiKey);
  }

  Future<String?> getApiKey(int id) async {
    return await _secureStorage.read(key: _apiKeyKey(id));
  }

  Future<void> deleteApiKey(int id) async {
    await _secureStorage.delete(key: _apiKeyKey(id));
  }
}
