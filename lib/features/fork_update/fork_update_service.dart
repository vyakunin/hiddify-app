import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-app APK update channel for the family_vpn fork.
///
/// Owns the per-launch flow:
///   1. GET <sub-host>/app/version.json (direct, no tunnel — runs at boot
///      before the VPN is up)
///   2. If version_code > our build's versionCode: GET the per-user APK
///      at <sub-host>/app/<token>/family_vpn.apk
///   3. Stash the downloaded APK at app-private cache /family_vpn_update.apk
///   4. Persist the staged path in SharedPreferences under
///      `fork_update.staged_apk_path` + the staged versionCode under
///      `fork_update.staged_version_code`
///
/// The Connect-screen UI is expected to read those prefs and, when a staged
/// path exists, replace the "Connect" CTA with "Update & connect" that fires
/// the system install dialog. That UI hook + Android-side install plumbing
/// (FileProvider + REQUEST_INSTALL_PACKAGES + Intent.ACTION_VIEW with
/// application/vnd.android.package-archive) lives outside this service —
/// see NEXT.md "APK push design".
///
/// Service-level invariants:
///   - Always logs success/failure; never throws into bootstrap.
///   - HTTP timeouts capped at boot-budget (3s metadata, 60s download).
///   - Download writes to a temp filename + renames on completion, so a
///     half-finished download never gets surfaced as ready.
///   - All errors swallowed — a flaky update channel must not block app boot.
class ForkUpdateService {
  ForkUpdateService(this._prefs);

  static const _stagedPathKey = "fork_update.staged_apk_path";
  static const _stagedVersionCodeKey = "fork_update.staged_version_code";

  final SharedPreferences _prefs;

  String? get stagedApkPath {
    final p = _prefs.getString(_stagedPathKey);
    if (p == null || p.isEmpty) return null;
    return File(p).existsSync() ? p : null;
  }

  int? get stagedVersionCode => _prefs.getInt(_stagedVersionCodeKey);

  /// Run the version-check + (conditional) download.
  ///
  /// [currentVersionCode] is the running app's versionCode (from
  /// package_info_plus). The remote /app/version.json returns
  /// `{"version_code": N, "version_name": "x.y.z", "released_at": "..."}`.
  /// If `N > currentVersionCode`, we download the per-user APK.
  ///
  /// Returns a one-line status string suitable for the boot logger:
  ///   "disabled"               — feature flag off
  ///   "missing baked sub url"  — no per-user token to construct urls
  ///   "up to date (N)"         — remote version_code <= currentVersionCode
  ///   "already staged (N)"     — newer version was downloaded on a previous
  ///                              run and is still sitting in cache
  ///   "staged N at /path"      — fresh download succeeded
  ///   "failed: <reason>"       — anything else; details in app log
  Future<String> checkAndStage(int currentVersionCode) async {
    if (!Environment.enableForkUpdate) return "disabled";

    final versionUrl = Environment.forkUpdateVersionJsonUrl;
    final apkUrl = Environment.forkUpdateApkUrl;
    if (versionUrl.isEmpty || apkUrl.isEmpty) return "missing baked sub url";

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      sendTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 5),
      responseType: ResponseType.plain,
    ));

    final int remoteVersionCode;
    try {
      final r = await dio.get<String>(versionUrl);
      if (r.statusCode != 200 || r.data == null) {
        return "failed: version.json status=${r.statusCode}";
      }
      final decoded = json.decode(r.data!) as Map<String, dynamic>;
      final code = decoded["version_code"];
      if (code is! int) return "failed: version.json has no integer version_code";
      remoteVersionCode = code;
    } catch (e) {
      Logger.bootstrap.warning("fork_update: version.json fetch failed: $e");
      return "failed: version.json fetch";
    }

    if (remoteVersionCode <= currentVersionCode) {
      // Clean out any previously-staged APK — once installed (or no longer
      // newer), keeping the file around just wastes app cache.
      await _clearStaged();
      return "up to date ($remoteVersionCode)";
    }

    if (stagedVersionCode == remoteVersionCode && stagedApkPath != null) {
      return "already staged ($remoteVersionCode)";
    }

    final cacheDir = await getApplicationCacheDirectory();
    final tmpFile = File("${cacheDir.path}/family_vpn_update.apk.partial");
    final finalFile = File("${cacheDir.path}/family_vpn_update.apk");

    try {
      // Use a separate Dio for the download — longer receive timeout, and
      // we want to let it stream through whatever proxy chain the
      // baked-sub refresh already nudged into place.
      final dlDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 60),
        responseType: ResponseType.bytes,
      ));
      final r = await dlDio.download(apkUrl, tmpFile.path);
      if (r.statusCode != 200) {
        return "failed: apk download status=${r.statusCode}";
      }
    } catch (e) {
      Logger.bootstrap.warning("fork_update: apk download failed: $e");
      // Don't leave a half-finished file claiming to be the update.
      if (tmpFile.existsSync()) {
        try { tmpFile.deleteSync(); } catch (_) {}
      }
      return "failed: apk download";
    }

    // Atomic rename — finalFile now exists iff download completed cleanly.
    try {
      if (finalFile.existsSync()) finalFile.deleteSync();
      tmpFile.renameSync(finalFile.path);
    } catch (e) {
      Logger.bootstrap.warning("fork_update: rename failed: $e");
      return "failed: rename";
    }

    await _prefs.setString(_stagedPathKey, finalFile.path);
    await _prefs.setInt(_stagedVersionCodeKey, remoteVersionCode);
    return "staged $remoteVersionCode at ${finalFile.path}";
  }

  Future<void> _clearStaged() async {
    final path = _prefs.getString(_stagedPathKey);
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    await _prefs.remove(_stagedPathKey);
    await _prefs.remove(_stagedVersionCodeKey);
  }

  /// Drop the staged APK + the prefs. Use after a successful install.
  Future<void> clearStaged() => _clearStaged();
}
