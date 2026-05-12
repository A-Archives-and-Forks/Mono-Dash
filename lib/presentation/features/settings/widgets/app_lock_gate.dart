import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:local_auth/local_auth.dart';

import '../../../../core/localization/l10n_x.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../common/app_toast.dart';
import '../providers/app_lock_provider.dart';
import 'app_passcode_pad.dart';

class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(appLockControllerProvider, (previous, next) {
      final previousSettings = previous?.valueOrNull;
      final nextSettings = next.valueOrNull;
      if (nextSettings == null) return;

      final wasEnabled = previousSettings?.enabled ?? false;
      final isEnabled = nextSettings.enabled;
      if (!isEnabled) {
        _unlocked = false;
      } else if (previousSettings != null && !wasEnabled && isEnabled) {
        _unlocked = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appLockControllerProvider);
    final settings = settingsAsync.valueOrNull;

    if (settings == null) {
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (!settings.enabled || _unlocked) {
      return widget.child;
    }

    return Navigator(
      onGenerateRoute: (_) => CupertinoPageRoute<void>(
        builder: (_) =>
            _AppLockScreen(onUnlocked: () => setState(() => _unlocked = true)),
      ),
    );
  }
}

class _AppLockScreen extends ConsumerStatefulWidget {
  const _AppLockScreen({required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  ConsumerState<_AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<_AppLockScreen> {
  String _password = '';
  bool _passwordAuthenticating = false;
  bool _biometricAuthenticating = false;
  String? _errorText;
  bool _promptedBiometric = false;
  int _pinErrorTrigger = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(appLockControllerProvider).valueOrNull;
    final canUseBiometric =
        settings?.biometricEnabled == true &&
        settings?.biometricAvailable == true;

    if (canUseBiometric && !_promptedBiometric) {
      _promptedBiometric = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _unlockBiometric(showFailureToast: false),
      );
    }

    return CupertinoPageScaffold(
      backgroundColor: AppColors.background(context),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.settings_appLock_unlockTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.label(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.settings_appLock_unlockSubtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.secondaryLabel(context),
                    ),
                  ),
                  const SizedBox(height: 28),
                  AppPasscodePad(
                    value: _password,
                    label: l10n.settings_appLock_passwordLabel,
                    enabled: !_passwordAuthenticating,
                    maxLength: 6,
                    showLabel: false,
                    errorTrigger: _pinErrorTrigger,
                    misleadingFeedbackEnabled:
                        settings?.misleadingPinFeedbackEnabled == true,
                    topContent: canUseBiometric
                        ? _BiometricScanButton(
                            icon: _biometricIcon(settings?.availableBiometrics),
                            isScanning: _biometricAuthenticating,
                            onPressed: _biometricAuthenticating
                                ? null
                                : () =>
                                      _unlockBiometric(showFailureToast: true),
                          )
                        : Icon(
                            TablerIcons.lock,
                            size: 54,
                            color: CupertinoColors.activeBlue.resolveFrom(
                              context,
                            ),
                          ),
                    onChanged: (value) => setState(() {
                      _password = value;
                      _errorText = null;
                    }),
                  ),
                  _LockErrorText(message: _errorText),
                  const SizedBox(height: 16),
                  CupertinoButton.filled(
                    onPressed: _passwordAuthenticating ? null : _unlockPassword,
                    child: _passwordAuthenticating
                        ? const CupertinoActivityIndicator()
                        : Text(l10n.settings_appLock_unlockAction),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _unlockPassword() async {
    final l10n = context.l10n;
    if (_password.isEmpty) {
      setState(() => _errorText = l10n.settings_appLock_passwordRequired);
      return;
    }

    setState(() {
      _passwordAuthenticating = true;
      _errorText = null;
    });
    final ok = await ref
        .read(appLockControllerProvider.notifier)
        .verifyPassword(_password);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _passwordAuthenticating = false;
      _errorText = l10n.settings_appLock_wrongPassword;
      _pinErrorTrigger++;
    });
    await Future<void>.delayed(const Duration(milliseconds: 360));
    if (!mounted) return;
    setState(() => _password = '');
  }

  Future<void> _unlockBiometric({required bool showFailureToast}) async {
    final l10n = context.l10n;
    setState(() {
      _biometricAuthenticating = true;
      _errorText = null;
    });
    final ok = await ref
        .read(appLockControllerProvider.notifier)
        .authenticateBiometric(l10n.settings_appLock_authReason);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() => _biometricAuthenticating = false);
    if (showFailureToast) {
      showAppErrorToast(l10n.settings_appLock_unlockFailed);
    }
  }

  IconData _biometricIcon(List<BiometricType>? biometrics) {
    final values = biometrics ?? const [];
    if (values.contains(BiometricType.face)) return TablerIcons.face_id;
    if (values.contains(BiometricType.fingerprint)) {
      return TablerIcons.fingerprint;
    }
    if (values.contains(BiometricType.iris)) return TablerIcons.eye;
    return TablerIcons.fingerprint;
  }
}

class _BiometricScanButton extends StatefulWidget {
  const _BiometricScanButton({
    required this.icon,
    required this.isScanning,
    required this.onPressed,
  });

  final IconData icon;
  final bool isScanning;
  final VoidCallback? onPressed;

  @override
  State<_BiometricScanButton> createState() => _BiometricScanButtonState();
}

class _BiometricScanButtonState extends State<_BiometricScanButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isScanning) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _BiometricScanButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isScanning && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blue = CupertinoColors.activeBlue.resolveFrom(context);
    return CupertinoButton(
      minimumSize: const Size(72, 72),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(36),
      onPressed: widget.onPressed,
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(widget.icon, size: 54, color: blue),
            if (widget.isScanning)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final y = -28 + (_controller.value * 56);
                  return IgnorePointer(
                    child: Transform.translate(
                      offset: Offset(0, y),
                      child: Container(
                        width: 58,
                        height: 4,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              blue.withValues(alpha: 0.0),
                              CupertinoColors.white.withValues(alpha: 0.9),
                              blue.withValues(alpha: 0.0),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: blue.withValues(alpha: 0.38),
                              blurRadius: 6,
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _LockErrorText extends StatelessWidget {
  const _LockErrorText({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        child: message == null
            ? const SizedBox.shrink()
            : Padding(
                key: ValueKey(message),
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemRed.resolveFrom(context),
                    letterSpacing: 0,
                  ),
                ),
              ),
      ),
    );
  }
}
