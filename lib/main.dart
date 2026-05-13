import 'dart:async';
import 'dart:io' show Platform;

import 'package:dynamic_app_icon_flutter_plus/dynamic_app_icon_flutter_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:toastification/toastification.dart';

import 'core/localization/generated/app_localizations.dart';
import 'core/localization/locale_controller.dart';
import 'core/router/app_router.dart';
import 'core/storage/storage_service.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/ios_server_widget_bridge.dart';
import 'presentation/features/purchases/providers/purchase_provider.dart';
import 'presentation/features/settings/providers/app_settings_provider.dart';
import 'presentation/features/settings/widgets/app_lock_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('Mono Dash booted');

  final storageService = StorageService();
  await storageService.init();

  runApp(
    ProviderScope(
      overrides: [storageServiceProvider.overrideWithValue(storageService)],
      child: const ToastificationWrapper(child: MyApp()),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localeOption = ref.watch(localeControllerProvider);
    final platformLocale = WidgetsBinding.instance.platformDispatcher.locale;
    unawaited(
      IosServerWidgetBridge.syncLocale(
        localeOption.widgetLocaleCode(platformLocale),
      ),
    );
    final settingsAsync = ref.watch(appSettingsControllerProvider);
    final appearanceMode =
        settingsAsync.valueOrNull?.appearanceMode ?? AppAppearanceMode.system;
    final appIconVariant =
        settingsAsync.valueOrNull?.appIconVariant ?? AppIconVariant.defaultIcon;
    final effectiveBrightness = switch (appearanceMode) {
      AppAppearanceMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
      AppAppearanceMode.light => Brightness.light,
      AppAppearanceMode.dark => Brightness.dark,
    };
    unawaited(
      IosServerWidgetBridge.syncAppIcon(
        appIconVariant.effectiveAlternateIconName(effectiveBrightness),
      ),
    );

    return _AppIconAutoSync(
      enabled: settingsAsync.hasValue,
      appearanceMode: appearanceMode,
      variant: appIconVariant,
      child: _PurchaseEntitlementMaintenance(
        child: CupertinoApp.router(
          debugShowCheckedModeBanner: false,
          onGenerateTitle: (context) => AppLocalizations.of(context).app_title,
          theme: switch (appearanceMode) {
            AppAppearanceMode.system => AppTheme.systemTheme,
            AppAppearanceMode.light => AppTheme.lightTheme,
            AppAppearanceMode.dark => AppTheme.darkTheme,
          },
          routerConfig: appRouter,
          builder: (context, child) =>
              AppLockGate(child: child ?? const SizedBox.shrink()),
          locale: localeOption.toLocale(),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
        ),
      ),
    );
  }
}

class _PurchaseEntitlementMaintenance extends ConsumerStatefulWidget {
  const _PurchaseEntitlementMaintenance({required this.child});

  final Widget child;

  @override
  ConsumerState<_PurchaseEntitlementMaintenance> createState() =>
      _PurchaseEntitlementMaintenanceState();
}

class _PurchaseEntitlementMaintenanceState
    extends ConsumerState<_PurchaseEntitlementMaintenance> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduled) return;
      _scheduled = true;
      unawaited(
        ref
            .read(purchaseControllerProvider.notifier)
            .maybeRefreshEntitlementAfterFirstFrame(),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AppIconAutoSync extends StatefulWidget {
  const _AppIconAutoSync({
    required this.enabled,
    required this.appearanceMode,
    required this.variant,
    required this.child,
  });

  final bool enabled;
  final AppAppearanceMode appearanceMode;
  final AppIconVariant variant;
  final Widget child;

  @override
  State<_AppIconAutoSync> createState() => _AppIconAutoSyncState();
}

class _AppIconAutoSyncState extends State<_AppIconAutoSync>
    with WidgetsBindingObserver {
  bool _hasAppliedIconName = false;
  String? _lastAppliedIconName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAppIcon());
  }

  @override
  void didUpdateWidget(covariant _AppIconAutoSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.appearanceMode != widget.appearanceMode ||
        oldWidget.variant != widget.variant) {
      _syncAppIcon();
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    _syncAppIcon();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _syncAppIcon();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  Future<void> _syncAppIcon() async {
    if (!widget.enabled || !Platform.isIOS) return;

    final brightness = switch (widget.appearanceMode) {
      AppAppearanceMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
      AppAppearanceMode.light => Brightness.light,
      AppAppearanceMode.dark => Brightness.dark,
    };
    final iconName = widget.variant.effectiveAlternateIconName(brightness);
    if (_hasAppliedIconName && _lastAppliedIconName == iconName) return;

    try {
      final isSupported =
          await DynamicAppIconFlutterPlus.supportsAlternateIcons;
      if (!isSupported) return;

      final currentIconName =
          await DynamicAppIconFlutterPlus.getAlternateIconName();
      if (currentIconName == iconName) {
        _hasAppliedIconName = true;
        _lastAppliedIconName = iconName;
        return;
      }

      await DynamicAppIconFlutterPlus.setAlternateIconName(
        iconName,
        showAlert: false,
      );
      _hasAppliedIconName = true;
      _lastAppliedIconName = iconName;
    } catch (error) {
      debugPrint('Failed to sync app icon: $error');
    }
  }
}
