// family_vpn fork: build a single shareable file that combines the app log
// (Flutter side, written by FileLogPrinter) and the core log (sing-box side,
// written by libhiddify-core). Replaces the two separate "Логи core" /
// "Логи приложения" share buttons with one entrypoint relatives can tap.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LogBundle {
  LogBundle(this.resolver);

  final LogPathResolver resolver;

  /// Build a single combined log file in app cache and return its path.
  ///
  /// Sections, in order — keeps the most operator-actionable content at the
  /// top so the first paragraph the operator reads carries the crash:
  ///
  ///     ===== family_vpn — combined log =====
  ///     generated: <iso utc>
  ///     device tz:  <local now>
  ///
  ///     ----- previous session: app log -----
  ///     <app.log.prev contents (if present)>
  ///
  ///     ----- previous session: core log -----
  ///     <box.log.prev contents (if present)>
  ///
  ///     ----- crash reports (<dir>/crashes/, newest first) -----
  ///     <each crash_*.txt>
  ///
  ///     ----- previously-shared crash reports (crashes/sent/) -----
  ///     <each crash_*.txt — sometimes useful when in-app share is the only
  ///      channel back to the operator and the user shared past crashes via
  ///      the system share sheet but the operator never received them>
  ///
  ///     ----- current session: app log -----
  ///     <app.log contents>
  ///
  ///     ----- current session: core log -----
  ///     <box.log contents>
  ///
  /// We deliberately keep timestamps verbatim instead of merging — app.log
  /// has HH:MM:SS.mmm only (no date), box.log has its own sing-box shape,
  /// crash reports have ISO timestamps. A partial parse would be worse than
  /// cleanly delimited sections.
  // family_vpn fork: native method channel (mirrors CoreInterfaceMobile's).
  // Used to ask the Kotlin side to dump this process's own logcat to
  // workingDir/logcat.log right before we assemble the bundle.
  static const _methodChannel = MethodChannel("com.hiddify.app/method");

  Future<File> buildCombinedFile() async {
    // Best-effort: refresh logcat.log before assembling. Never let a failure
    // here (old build without the handler, permission quirk) block the share.
    try {
      await _methodChannel
          .invokeMethod("dump_logcat")
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // ignore — the logcat section will just say "(file missing)".
    }

    final cacheDir = await getApplicationCacheDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(":", "")
        .replaceAll("-", "")
        .split(".")
        .first;
    final out = File(p.join(cacheDir.path, "family_vpn-log-$stamp.txt"));
    final sink = out.openWrite();
    try {
      sink.writeln("===== family_vpn — combined log =====");
      sink.writeln("generated: ${DateTime.now().toUtc().toIso8601String()}");
      sink.writeln("device tz:  ${DateTime.now()}");
      sink.writeln("");

      final appFile = resolver.appFile();
      final coreFile = resolver.coreFile();
      final appPrev = File("${appFile.path}.prev");
      final corePrev = File("${coreFile.path}.prev");

      sink.writeln("----- previous session: app log -----");
      await _streamFileInto(sink, appPrev);
      sink.writeln("");

      sink.writeln("----- previous session: core log -----");
      await _streamFileInto(sink, corePrev);
      sink.writeln("");

      final crashDir = Directory(p.join(resolver.directory.path, "crashes"));
      sink.writeln("----- crash reports (${crashDir.path}, newest first) -----");
      await _streamCrashDir(sink, crashDir);
      sink.writeln("");

      final sentDir = Directory(p.join(crashDir.path, "sent"));
      sink.writeln("----- previously-shared crash reports (${sentDir.path}) -----");
      await _streamCrashDir(sink, sentDir);
      sink.writeln("");

      sink.writeln("----- current session: app log -----");
      await _streamFileInto(sink, appFile);
      sink.writeln("");

      sink.writeln("----- current session: core log -----");
      await _streamFileInto(sink, coreFile);
      sink.writeln("");

      // family_vpn fork: the start-sequence trace — the FIRST thing to read for
      // a tunnel-start failure. Phase markers + full stacktraces pinpoint where
      // BoxService/openTun died, persistently (box.log is empty when the core
      // dies before logging).
      sink.writeln("----- current session: core start trace (core_start.log) -----");
      await _streamFileInto(sink, resolver.coreStartFile());
      sink.writeln("");

      // family_vpn fork: the core's Go stderr. When the tunnel fails to START
      // (core loads but Mobile.setup/start throws, OOM, gvisor/tun-establish
      // failure), box.log is empty and the real cause lands HERE as a Go panic
      // / `runtime: out of memory` / native fatal. Two files because the fork
      // redirects stderr in two places (BoxService.initialize → stderr.log,
      // MethodHandler → stderr2.log).
      sink.writeln("----- current session: core stderr (stderr.log) -----");
      await _streamFileInto(sink, resolver.stderrFile());
      sink.writeln("");

      sink.writeln("----- current session: core stderr (stderr2.log) -----");
      await _streamFileInto(sink, resolver.stderr2File());
      sink.writeln("");

      // family_vpn fork: own-process logcat, dumped by the native side just
      // before this bundle is built (see MethodHandler "dump_logcat"). Captures
      // BoxService Kotlin logs ("starting service", caught setup/start
      // exceptions) + any system kill/ANR lines for our UID that never reach
      // the Dart app.log.
      sink.writeln("----- current session: logcat (own process) -----");
      await _streamFileInto(sink, resolver.logcatFile());
      sink.writeln("");
    } finally {
      await sink.flush();
      await sink.close();
    }
    return out;
  }

  Future<void> _streamFileInto(IOSink sink, File source) async {
    if (!source.existsSync()) {
      sink.writeln("(file missing: ${source.path})");
      return;
    }
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
      }
    } catch (e) {
      sink.writeln("(error reading ${source.path}: $e)");
    }
  }

  Future<void> _streamCrashDir(IOSink sink, Directory dir) async {
    if (!dir.existsSync()) {
      sink.writeln("(none)");
      return;
    }
    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => p.basename(f.path).endsWith(".txt"))
        .toList();
    if (files.isEmpty) {
      sink.writeln("(none)");
      return;
    }
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final f in files) {
      sink.writeln("--- ${p.basename(f.path)} (${f.statSync().modified.toIso8601String()}) ---");
      await _streamFileInto(sink, f);
      sink.writeln("");
    }
  }
}
