// family_vpn fork: build a single shareable file that combines the app log
// (Flutter side, written by FileLogPrinter) and the core log (sing-box side,
// written by libhiddify-core). Replaces the two separate "Логи core" /
// "Логи приложения" share buttons with one entrypoint relatives can tap.

import 'dart:io';

import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LogBundle {
  LogBundle(this.resolver);

  final LogPathResolver resolver;

  /// Build a single combined log file in app cache and return its path.
  ///
  /// Layout — clearly sectioned so it's obvious to a human reader (or a
  /// remote operator receiving the file via Telegram) which side a given
  /// entry came from:
  ///
  ///     ===== family_vpn — combined log =====
  ///     generated: <iso utc>
  ///     device tz: <local now>
  ///
  ///     ----- app log (Flutter side) -----
  ///     <app.log contents>
  ///
  ///     ----- core log (sing-box / xray) -----
  ///     <box.log contents>
  ///
  /// We deliberately keep both halves verbatim instead of trying to merge
  /// them by timestamp — app.log has `HH:MM:SS.mmm` only (no date), box.log
  /// has its own sing-box timestamp shape, and a partial parse would be
  /// worse than two clearly delimited sections.
  Future<File> buildCombinedFile() async {
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

      sink.writeln("----- app log (Flutter side) -----");
      await _streamFileInto(sink, resolver.appFile());
      sink.writeln("");

      sink.writeln("----- core log (sing-box / xray) -----");
      await _streamFileInto(sink, resolver.coreFile());
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
}
