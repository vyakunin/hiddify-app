import 'package:flutter/foundation.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/fork_update/fork_update_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Singleton ForkUpdateService backed by the shared SharedPreferences
/// instance. Cheap to construct — no I/O at build time.
final forkUpdateServiceProvider = Provider<ForkUpdateService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  return ForkUpdateService(prefs);
});

/// State surfaced to the UI: should we hard-nudge the user on the Connect
/// tap (i.e. show "Update & connect" instead of "Connect")?
///
/// True iff:
///   - A staged APK exists on disk at the path persisted by the bootstrap-
///     time download.
///   - The user hasn't already burned through [maxHardNudgeAttempts]
///     dismissals (Bad-APK escape hatch — see ForkUpdateService).
///
/// Polled directly from SharedPreferences each rebuild; the prefs entry is
/// only written from background bootstrap + the install handler, so we
/// don't need a ChangeNotifier. The Connect screen rebuilds on
/// connectionNotifierProvider anyway, which is plenty frequent.
final forkUpdateShouldHardNudgeProvider = Provider<bool>((ref) {
  // Only Android has the install channel — bail early on other platforms
  // to keep the Connect button identical to upstream.
  if (!kIsWeb && defaultTargetPlatform.toString().contains("android") == false) {
    return false;
  }
  return ref.watch(forkUpdateServiceProvider).shouldHardNudge;
});
