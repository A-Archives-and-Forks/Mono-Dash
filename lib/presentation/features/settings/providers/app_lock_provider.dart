import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

final appLockControllerProvider =
    AsyncNotifierProvider<AppLockController, AppLockSettings>(
      AppLockController.new,
    );

class AppLockSettings {
  const AppLockSettings({
    required this.enabled,
    required this.biometricEnabled,
    required this.biometricAvailable,
    required this.hasPassword,
    required this.misleadingPinFeedbackEnabled,
    this.availableBiometrics = const [],
  });

  final bool enabled;
  final bool biometricEnabled;
  final bool biometricAvailable;
  final bool hasPassword;
  final bool misleadingPinFeedbackEnabled;
  final List<BiometricType> availableBiometrics;

  AppLockSettings copyWith({
    bool? enabled,
    bool? biometricEnabled,
    bool? biometricAvailable,
    bool? hasPassword,
    bool? misleadingPinFeedbackEnabled,
    List<BiometricType>? availableBiometrics,
  }) {
    return AppLockSettings(
      enabled: enabled ?? this.enabled,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      biometricAvailable: biometricAvailable ?? this.biometricAvailable,
      hasPassword: hasPassword ?? this.hasPassword,
      misleadingPinFeedbackEnabled:
          misleadingPinFeedbackEnabled ?? this.misleadingPinFeedbackEnabled,
      availableBiometrics: availableBiometrics ?? this.availableBiometrics,
    );
  }
}

class AppLockController extends AsyncNotifier<AppLockSettings> {
  static const _enabledKey = 'app_lock_enabled';
  static const _biometricEnabledKey = 'app_lock_biometric_enabled';
  static const _misleadingPinFeedbackEnabledKey =
      'app_lock_misleading_pin_feedback_enabled';
  static const _passwordHashKey = 'app_lock_password_hash';
  static const _passwordSaltKey = 'app_lock_password_salt';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final LocalAuthentication _localAuth = LocalAuthentication();
  final Random _random = Random.secure();

  @override
  Future<AppLockSettings> build() => _load();

  Future<void> enablePassword({
    required String password,
    required bool enableBiometric,
  }) async {
    final normalized = password.trim();
    if (normalized.length != 6) {
      throw const AppLockPasswordException(AppLockPasswordError.tooShort);
    }
    if (!_isNumericPin(normalized)) {
      throw const AppLockPasswordException(AppLockPasswordError.notNumeric);
    }

    final salt = _makeSalt();
    await _secureStorage.write(key: _passwordSaltKey, value: salt);
    await _secureStorage.write(
      key: _passwordHashKey,
      value: _hashPassword(normalized, salt),
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    final latest = await _load();
    await prefs.setBool(
      _biometricEnabledKey,
      enableBiometric && latest.biometricAvailable,
    );
    state = AsyncValue.data(await _load());
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final isCurrentValid = await verifyPassword(currentPassword);
    if (!isCurrentValid) {
      throw const AppLockPasswordException(AppLockPasswordError.wrongPassword);
    }
    final normalized = newPassword.trim();
    if (normalized.length != 6) {
      throw const AppLockPasswordException(AppLockPasswordError.tooShort);
    }
    if (!_isNumericPin(normalized)) {
      throw const AppLockPasswordException(AppLockPasswordError.notNumeric);
    }

    final salt = _makeSalt();
    await _secureStorage.write(key: _passwordSaltKey, value: salt);
    await _secureStorage.write(
      key: _passwordHashKey,
      value: _hashPassword(normalized, salt),
    );
    state = AsyncValue.data(await _load());
  }

  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_enabledKey);
    await prefs.remove(_biometricEnabledKey);
    await _secureStorage.delete(key: _passwordHashKey);
    await _secureStorage.delete(key: _passwordSaltKey);
    state = AsyncValue.data(await _load());
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    final latest = state.valueOrNull ?? await _load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      _biometricEnabledKey,
      enabled && latest.biometricAvailable,
    );
    state = AsyncValue.data(await _load());
  }

  Future<void> setMisleadingPinFeedbackEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_misleadingPinFeedbackEnabledKey, enabled);
    state = AsyncValue.data(await _load());
  }

  Future<bool> verifyPassword(String password) async {
    final hash = await _secureStorage.read(key: _passwordHashKey);
    final salt = await _secureStorage.read(key: _passwordSaltKey);
    if (hash == null || salt == null) return false;
    return _hashPassword(password.trim(), salt) == hash;
  }

  Future<bool> authenticateBiometric(String localizedReason) async {
    final latest = state.valueOrNull ?? await _load();
    if (!latest.enabled ||
        !latest.biometricEnabled ||
        !latest.biometricAvailable) {
      return false;
    }

    try {
      return await _localAuth.authenticate(
        localizedReason: localizedReason,
        biometricOnly: true,
        persistAcrossBackgrounding: false,
      );
    } catch (_) {
      return false;
    }
  }

  Future<AppLockSettings> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final hasPassword =
        await _secureStorage.read(key: _passwordHashKey) != null &&
        await _secureStorage.read(key: _passwordSaltKey) != null;
    final biometrics = await _availableBiometrics();
    final biometricAvailable = biometrics.isNotEmpty;
    final enabled = (prefs.getBool(_enabledKey) ?? false) && hasPassword;
    final biometricEnabled =
        (prefs.getBool(_biometricEnabledKey) ?? false) && biometricAvailable;
    final misleadingPinFeedbackEnabled =
        prefs.getBool(_misleadingPinFeedbackEnabledKey) ?? false;

    return AppLockSettings(
      enabled: enabled,
      biometricEnabled: biometricEnabled,
      biometricAvailable: biometricAvailable,
      hasPassword: hasPassword,
      misleadingPinFeedbackEnabled: misleadingPinFeedbackEnabled,
      availableBiometrics: biometrics,
    );
  }

  Future<List<BiometricType>> _availableBiometrics() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (!supported) return const [];
      return await _localAuth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  String _makeSalt() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static String _hashPassword(String password, String salt) {
    return sha256.convert(utf8.encode('$salt:$password')).toString();
  }

  static bool _isNumericPin(String value) => RegExp(r'^\d+$').hasMatch(value);
}

enum AppLockPasswordError { tooShort, notNumeric, wrongPassword }

class AppLockPasswordException implements Exception {
  const AppLockPasswordException(this.error);

  final AppLockPasswordError error;
}
