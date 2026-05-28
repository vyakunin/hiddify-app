// ignore_for_file: avoid_print

import 'dart:io';

import 'package:loggy/loggy.dart';

class ConsolePrinter extends LoggyPrinter {
  const ConsolePrinter({this.showColors = false});

  final bool showColors;

  static final _levelColors = {
    LogLevel.debug: AnsiColor(foregroundColor: AnsiColor.grey(0.5), italic: true),
    LogLevel.info: AnsiColor(foregroundColor: 35),
    LogLevel.warning: AnsiColor(foregroundColor: 214),
    LogLevel.error: AnsiColor(foregroundColor: 196),
  };

  @override
  void onLog(LogRecord record) {
    final colorize = showColors && stdout.supportsAnsiEscapes;
    final time = record.time.toIso8601String().split('T')[1];
    final callerFrame = record.callerFrame == null ? ' ' : ' (${record.callerFrame?.location}) ';

    final String logLevel;
    if (colorize) {
      logLevel = record.level.name.toUpperCase().padRight(8);
    } else {
      logLevel = "[${record.level.name.toUpperCase()}]".padRight(10);
    }

    final color = showColors ? levelColor(record.level) ?? AnsiColor() : AnsiColor();

    print(color('$time $logLevel [${record.loggerName}]$callerFrame${record.message}'));

    if (record.stackTrace != null) {
      print(record.stackTrace);
    }
  }

  AnsiColor? levelColor(LogLevel level) {
    return _levelColors[level];
  }
}

class FileLogPrinter extends LoggyPrinter {
  // Rotate previous session's log to <path>.prev before opening fresh.
  // The current-session writer is FileMode.writeOnly (truncating); without
  // rotation, a crash one session ago is unrecoverable by the time the user
  // reopens the app and taps "Поделиться логами". LogBundle picks up
  // <path>.prev so the operator sees both halves.
  FileLogPrinter(String filePath, {this.minLevel = LogLevel.debug}) : _logFile = File(filePath) {
    try {
      final f = File(filePath);
      if (f.existsSync()) {
        final prev = File("$filePath.prev");
        if (prev.existsSync()) prev.deleteSync();
        f.renameSync(prev.path);
      }
    } catch (_) {
      // rotation failed; new log will still open below.
    }
  }

  final File _logFile;
  final LogLevel minLevel;

  late final _sink = _logFile.openWrite(mode: FileMode.writeOnly);

  @override
  void onLog(LogRecord record) {
    final time = record.time.toIso8601String().split('T')[1];
    _sink.writeln("$time - $record");
    if (record.error != null) {
      _sink.writeln(record.error);
    }
    if (record.stackTrace != null) {
      _sink.writeln(record.stackTrace);
    }
  }

  void dispose() {
    _sink.close();
  }
}
