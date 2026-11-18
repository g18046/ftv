import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../global/storage_bridge.dart';

class AppLogger {
  static File? _logFile;
  static IOSink? _sink;
  static bool _initialized = false;
  static bool webDebugEnabled = false;
  static final ValueNotifier<bool> debugModeNotifier = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> hideGlobalDebugFabNotifier = ValueNotifier<bool>(false);
  static final List<String> _recentLogs = [];
  static const int _maxBufferLines = 800;

  static String? get logFilePath => _logFile?.path;

  static List<String> getRecentLogs() => List<String>.unmodifiable(_recentLogs);

  static void clear() {
    _recentLogs.clear();
  }

  static Future<void> setWebDebugEnabled(bool enabled) async {
    webDebugEnabled = enabled;
    debugModeNotifier.value = enabled;
    try {
      await StorageBridge.setValue('debug_web_log', enabled ? '1' : '0');
    } catch (_) {}
  }

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final saved = await StorageBridge.getValue('debug_web_log');
      webDebugEnabled = saved == '1';
      debugModeNotifier.value = webDebugEnabled;
    } catch (_) {}

    try {
      Directory logDir;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final candidate = Directory('${exeDir.path}${Platform.pathSeparator}logs');
        try {
          if (!await candidate.exists()) {
            await candidate.create(recursive: true);
          }
          final probe = File('${candidate.path}${Platform.pathSeparator}.write_test');
          await probe.writeAsString('ok');
          await probe.delete();
          logDir = candidate;
        } catch (_) {
          final support = await getApplicationSupportDirectory();
          logDir = Directory('${support.path}${Platform.pathSeparator}logs');
          if (!await logDir.exists()) {
            await logDir.create(recursive: true);
          }
        }
      } else {
        final support = await getApplicationSupportDirectory();
        logDir = Directory('${support.path}${Platform.pathSeparator}logs');
        if (!await logDir.exists()) {
          await logDir.create(recursive: true);
        }
      }

      final file = File('${logDir.path}${Platform.pathSeparator}ftv.log');
      if (await file.exists() && await file.length() > 3 * 1024 * 1024) {
        final old = File('${logDir.path}${Platform.pathSeparator}ftv.log.old');
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
      _logFile = file;
      _sink = file.openWrite(mode: FileMode.append);

      final oldDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          writeLine(message);
        }
        oldDebugPrint(message, wrapWidth: wrapWidth);
      };

      final oldOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        writeLine('[FlutterError] ${details.exceptionAsString()}\n${details.stack ?? ""}');
        oldOnError?.call(details);
      };

      writeLine('=== FTV 日志启动 (${Platform.operatingSystem}) ===');
    } catch (_) {}
  }

  static void writeLine(String line) {
    try {
      final now = DateTime.now();
      final ts =
          '${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")} '
          '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}.${now.millisecond.toString().padLeft(3, "0")}';
      final formatted = '[$ts] $line';
      _recentLogs.add(formatted);
      if (_recentLogs.length > _maxBufferLines) {
        _recentLogs.removeRange(0, _recentLogs.length - _maxBufferLines);
      }
      _sink?.writeln(formatted);
    } catch (_) {}
  }
}
