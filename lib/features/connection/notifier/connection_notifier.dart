import 'dart:io';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  @override
  Stream<ConnectionStatus> build() async* {
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          // family_vpn fork: persist the connect timestamp so the session
          // duration counter survives app-process restarts while the bg
          // service stays connected. Only set on a true non-Connected ->
          // Connected transition; reopening the app on an already-running
          // session goes through AsyncLoading -> Connected and must NOT
          // overwrite the original start time.
          await ref
              .read(Preferences.connectedSinceMs.notifier)
              .update(DateTime.now().millisecondsSinceEpoch);

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
      // family_vpn fork: fallback for the silent_start / app-reopen-on-stale-
      // session case. If the very first emission lands in Connected (previous
      // is AsyncLoading) and pref is still 0, we don't know the real start
      // time — best-effort: set it to now so the counter at least starts
      // ticking instead of showing 00:00:00 forever.
      if (previous is AsyncLoading<ConnectionStatus>) {
        if (next case AsyncData(value: final Connected _)) {
          if (ref.read(Preferences.connectedSinceMs) == 0) {
            await ref
                .read(Preferences.connectedSinceMs.notifier)
                .update(DateTime.now().millisecondsSinceEpoch);
          }
        }
      }
      // family_vpn fork: clear the persisted connect timestamp only on a
      // genuine Connected -> Disconnected transition (user tapped
      // Disconnect, or core lost the tunnel). On cold-start the Dart side
      // may emit AsyncLoading -> Disconnected briefly before libbox reports
      // the bg tunnel is still up; clearing the pref there would wipe the
      // persisted session start and the subsequent Connected emission
      // would reset the counter to "now" — exactly the timer-resets-on-
      // reopen bug.
      if (next case AsyncData(value: final Disconnected _)) {
        if (previous case AsyncData(value: final Connected _)) {
          final current = ref.read(Preferences.connectedSinceMs);
          if (current != 0) {
            await ref.read(Preferences.connectedSinceMs.notifier).update(0);
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (state case AsyncError()) {
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          await haptic.lightImpact();
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
          await haptic.mediumImpact();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          await _disconnect();
        default:
          loggy.warning("switching status, debounce");
      }
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
  }

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    _singleStart.run(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
      loggy.warning("error connecting", err);
      // family_vpn fork: when the core surfaces a VPN-permission denial,
      // re-trigger the Android system VPN-permission dialog instead of just
      // showing an alert with no remediation. On grant, retry the connect
      // exactly once. Avoids the "tap Connect → cryptic error" UX trap.
      if (Platform.isAndroid && err is MissingVpnPermission) {
        loggy.info("MissingVpnPermission caught — re-triggering system VPN perm dialog");
        try {
          final granted = await ref.read(hiddifyCoreServiceProvider).core.requestVpnPermission();
          loggy.info("re-triggered VPN perm dialog: granted=$granted");
          if (granted) {
            // Retry once; do NOT recurse through _connect's SingleCall guard
            // (it's still held), call the repo directly.
            await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
              ConnectionFailure retryErr,
            ) async {
              loggy.warning("retry after VPN perm grant still failed", retryErr);
              await ref
                  .read(dialogNotifierProvider.notifier)
                  .showCustomAlertFromErr(retryErr.present(ref.read(translationsProvider).requireValue));
              await ref.read(Preferences.startedByUser.notifier).update(false);
              state = AsyncError(retryErr, StackTrace.current);
            }).run();
            return;
          }
        } catch (e, s) {
          loggy.warning("re-triggering VPN perm dialog failed: $e", e, s);
        }
      }
      //Go err is not normal object to see the go errors are string and need to be dumped
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      loggy.warning(err);
      await ref.read(Preferences.startedByUser.notifier).update(false);
      state = AsyncError(err, StackTrace.current);
    }).run();
  }

  Future<void> _disconnect() async {
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      state = AsyncError(err, StackTrace.current);
    }).run();
  }
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}
