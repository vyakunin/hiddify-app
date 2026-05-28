import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hiddify/core/analytics/analytics_controller.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/logger/logger_controller.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/app/widget/app.dart';
import 'package:hiddify/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_diagnostics.dart';

import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/fork_update/fork_update_service.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/riverpod_observer.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

Future<void> lazyBootstrap(WidgetsBinding widgetsBinding, Environment env) async {
  if (!kIsWeb) {
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  }
  LoggerController.preInit();
  FlutterError.onError = Logger.logFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = Logger.logPlatformDispatcherError;

  final stopWatch = Stopwatch()..start();

  final container = ProviderContainer(overrides: [environmentProvider.overrideWithValue(env)]);

  await _init("directories", () => container.read(appDirectoriesProvider.future));
  // Rotate box.log → box.log.prev so previous-session sing-box / xray logs
  // survive a relaunch (matches FileLogPrinter's rotation of app.log). The
  // LogBundle picks both .prev halves up — without this, an in-app
  // "Поделиться логами" tap after a crash ships only the freshly-truncated
  // current-session logs and the operator has nothing to debug from.
  try {
    final coreLog = container.read(logPathResolverProvider).coreFile();
    if (coreLog.existsSync()) {
      final prev = File("${coreLog.path}.prev");
      if (prev.existsSync()) prev.deleteSync();
      coreLog.renameSync(prev.path);
    }
  } catch (_) {
    // rotation failed; sing-box will still open a fresh box.log below.
  }
  LoggerController.init(container.read(logPathResolverProvider).appFile().path);

  final appInfo = await _init("app info", () => container.read(appInfoProvider.future));
  await _init("preferences", () => container.read(sharedPreferencesProvider.future));

  final enableAnalytics = await container.read(analyticsControllerProvider.future);
  if (enableAnalytics) {
    await _init("analytics", () => container.read(analyticsControllerProvider.notifier).enableAnalytics());
  }

  await _init("preferences migration", () async {
    try {
      await PreferencesMigration(sharedPreferences: container.read(sharedPreferencesProvider).requireValue).migrate();
    } catch (e, stackTrace) {
      Logger.bootstrap.error("preferences migration failed", e, stackTrace);
      if (env == Environment.dev) rethrow;
      Logger.bootstrap.info("clearing preferences");
      await container.read(sharedPreferencesProvider).requireValue.clear();
    }
  });

  final debug = container.read(debugModeNotifierProvider) || kDebugMode;

  if (PlatformUtils.isDesktop) {
    await _init("window controller", () => container.read(windowNotifierProvider.future));

    final silentStart = container.read(Preferences.silentStart);
    Logger.bootstrap.debug("silent start [${silentStart ? "Enabled" : "Disabled"}]");
    if (!silentStart) {
      await container.read(windowNotifierProvider.notifier).show(focus: false);
    } else {
      Logger.bootstrap.debug("silent start, remain hidden accessible via tray");
    }
    await _init("auto start service", () => container.read(autoStartNotifierProvider.future));
  }
  await _init("logs repository", () => container.read(logRepositoryProvider.future));
  await _init("logger controller", () => LoggerController.postInit(debug));

  Logger.bootstrap.info(appInfo.format());

  await _init("profile repository", () => container.read(profileRepositoryProvider.future));

  await _init("translations", () => container.read(translationsProvider.future));

  await _safeInit("active profile", () => container.read(activeProfileProvider.future), timeout: 1000);

  // family_vpn fork: in-app APK update channel. Polls /app/version.json,
  // downloads a newer APK to app-private cache, persists the path in
  // SharedPreferences. UI hard-nudges via the Connect button when a
  // staged APK exists. Gated by --dart-define=enable_fork_update=true;
  // safe to leave on always once the install-intent plumbing is verified
  // on a real phone.
  // family_vpn fork: in-app updater is for the direct distribution path
  // only. Play handles its own updates, so it MUST stay off in the Play
  // branch even if a build accidentally sets enable_fork_update=true.
  if (Environment.enableForkUpdate && Environment.hasBakedSubscription && !Environment.hasPlayOauth) {
    await _safeInit("fork update check", () async {
      final prefs = container.read(sharedPreferencesProvider).requireValue;
      final service = ForkUpdateService(prefs);
      // PackageInfo.buildNumber surfaces as a string ("123" for versionCode=123).
      final currentCode = int.tryParse(appInfo.buildNumber) ?? 0;
      final status = await service.checkAndStage(currentCode);
      Logger.bootstrap.info("fork update: $status");
    }, timeout: 12000);
  }

  await _init("hiddify-core", () => container.read(hiddifyCoreServiceProvider).init());

  // family_vpn fork: refresh the active profile's subscription URL after
  // hiddify-core init. Daily port-rotation + cover-host rotation invalidates
  // the cached profile; without this the app would silently show "Подключено"
  // with 0 B/s. Must run AFTER hiddify-core init — upsertRemote triggers
  // HiddifyCoreService.changeOptions which needs fgClient initialized.
  //
  // Two flavors share this code path:
  //   - baked sub (general / direct distribution): the URL was baked at build
  //     time and AddProfile imported it on first launch into the profile repo.
  //   - OAuth Play: the URL was fetched after Google sign-in at first launch
  //     and written into the profile repo by the OAuth exchange flow.
  // In both cases, by the time we reach this point the URL we want to refresh
  // is the active profile's URL — derive it from the repo, don't read
  // Environment.bakedSubscriptionUrl (which is empty in the OAuth flavor and
  // was the bug behind 2026-05-26 incident: OAuth users had no per-launch
  // refresh and stayed on a stale cached profile across daily rotation).
  await _safeInit("active profile refresh", () async {
    final hasProfile = await container.read(hasAnyProfileProvider.future);
    if (!hasProfile) {
      Logger.bootstrap.debug("no profile yet — first launch, skipping refresh");
      return;
    }
    final activeProfile = await container.read(activeProfileProvider.future);
    if (activeProfile is! RemoteProfileEntity || activeProfile.url.isEmpty) {
      Logger.bootstrap.debug("active profile is local or missing URL — skipping refresh");
      return;
    }
    final repo = await container.read(profileRepositoryProvider.future);
    await repo
        .upsertRemote(activeProfile.url)
        .match(
          (f) {
            Logger.bootstrap.warning("active profile refresh failed (using cached): $f");
            return null;
          },
          (_) {
            Logger.bootstrap.info("active profile refresh ok");
            return null;
          },
        )
        .run();
  }, timeout: 2500);

  // family_vpn fork: start the diagnostic logger. Pure side-effect provider —
  // attaches a 30s heartbeat + connection-state listener that writes shape
  // and (when stuck) STUCK_CONNECTED markers into app.log. Cheap; runs for
  // the lifetime of the app.
  container.read(connectionDiagnosticsProvider);

  if (!kIsWeb) {
    // await _safeInit(
    //   "deep link service",
    //   () => container.read(deepLinkNotifierProvider.future),
    //   timeout: 1000,
    // );

    if (PlatformUtils.isDesktop) {
      await _safeInit("system tray", () => container.read(systemTrayNotifierProvider.future), timeout: 1000);
    }

    if (PlatformUtils.isAndroid) {
      await _safeInit("android display mode", () async {
        await FlutterDisplayMode.setHighRefreshRate();
      });
    }
  }

  Logger.bootstrap.info("bootstrap took [${stopWatch.elapsedMilliseconds}ms]");
  stopWatch.stop();

  runApp(
    ProviderScope(
      parent: container,
      observers: [RiverpodObserver()],
      child: const App(),
    ),
  );

  if (!kIsWeb) {
    FlutterNativeSplash.remove();
  }

  // family_vpn fork: pre-request the Android system VPN-permission dialog on
  // the very first launch, so the popup appears in an obvious moment instead
  // of mid-Connect tap. Without this, a relative taps Connect, the popup
  // shows, they may accidentally dismiss it, the core fails with
  // "configure tun interface: permission denied", and they don't know what
  // happened. Gated by the vpnPermissionRequested pref — fires exactly once
  // per install.
  if (PlatformUtils.isAndroid) {
    final prefs = container.read(sharedPreferencesProvider).requireValue;
    final alreadyRequested = prefs.getBool("vpn_permission_requested") ?? false;
    if (!alreadyRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final granted = await container.read(hiddifyCoreServiceProvider).core.requestVpnPermission();
          Logger.bootstrap.info("first-launch VPN perm pre-request: granted=$granted");
          await prefs.setBool("vpn_permission_requested", true);
        } catch (e, s) {
          Logger.bootstrap.warning("first-launch VPN perm pre-request failed: $e", e, s);
        }
      });
    }
  }
}

Future<T> _init<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [$name]");
  Future<T> func() => timeout != null ? initializer().timeout(Duration(milliseconds: timeout)) : initializer();
  try {
    final result = await func();
    Logger.bootstrap.debug("[$name] initialized in ${stopWatch.elapsedMilliseconds}ms");
    return result;
  } catch (e, stackTrace) {
    Logger.bootstrap.error("[$name] error initializing", e, stackTrace);
    rethrow;
  } finally {
    stopWatch.stop();
  }
}

Future<T?> _safeInit<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  try {
    return await _init(name, initializer, timeout: timeout);
  } catch (e) {
    return null;
  }
}
