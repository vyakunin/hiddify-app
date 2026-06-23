import 'dart:io';

import 'package:path/path.dart' as p;

class LogPathResolver {
  const LogPathResolver(this._workingDir);

  final Directory _workingDir;

  Directory get directory => _workingDir;

  File coreFile() {
    return File(p.join(directory.path, "box.log"));
  }

  File appFile() {
    return File(p.join(directory.path, "app.log"));
  }

  // family_vpn fork: the core's Go stderr is redirected here by
  // BoxService.initialize() (Libbox.redirectStderr) and by MethodHandler
  // (stderr2.log). This is where a Go panic, `runtime: out of memory`, a
  // gvisor/tun-establish failure, or any native-side fatal lands — i.e. the
  // single most useful artifact when the core dies at tunnel-start and box.log
  // is empty. These were historically NOT collected by LogBundle, which is why
  // a coreless/OOM/start-failure on a relative's device left us with no error
  // text at all (Roza realme C30, 2026-06-23). Collect them now.
  File stderrFile() {
    return File(p.join(directory.path, "stderr.log"));
  }

  File stderr2File() {
    return File(p.join(directory.path, "stderr2.log"));
  }

  File logcatFile() {
    return File(p.join(directory.path, "logcat.log"));
  }

  // family_vpn fork: persistent, timestamped start-sequence diagnostics written
  // by BoxService.diag() — phase markers (startService begin → Mobile.setup →
  // Mobile.start → openTun establish → COMPLETE) and full stacktraces on any
  // failure. The definitive artifact for a tunnel-START failure: unlike box.log
  // (empty when the core dies pre-logging) or logcat (rotates), this persists
  // and pinpoints exactly where the start sequence died.
  File coreStartFile() {
    return File(p.join(directory.path, "core_start.log"));
  }
}
