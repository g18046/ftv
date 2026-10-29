import 'dart:convert';
import 'dart:io';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:path_provider/path_provider.dart';

/// JS 全局 Key-Value 本地持久化存储 (local.get / local.set / local.delete) 桥接
/// 参考 OK 影视: 确保站点 Cookie、播放历史断点进度跨应用重启不丢失
class StorageBridge {
  static final StorageBridge _instance = StorageBridge._internal();
  factory StorageBridge() => _instance;
  StorageBridge._internal();

  static final Map<String, String> _memoryStorage = {};
  static bool _isLoaded = false;
  static const String _storageFileName = 'ftv_storage.json';

  /// 便捷提供给 Dart 侧持久化读取与写入
  Future<String?> get(String key) async => getValue(key);
  Future<void> set(String key, String val) async => setValue(key, val);
  Future<void> delete(String key) async => deleteValue(key);

  static Future<String?> getValue(String key) async {
    await init();
    return _memoryStorage[key];
  }

  static Future<void> setValue(String key, String val) async {
    await init();
    _memoryStorage[key] = val;
    await _saveToDisk();
  }

  static Future<void> deleteValue(String key) async {
    await init();
    _memoryStorage.remove(key);
    await _saveToDisk();
  }

  /// 初始化并从本地磁盘载入存储数据
  static Future<void> init() async {
    if (_isLoaded) return;
    try {
      final file = await _getStorageFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final Map<String, dynamic> data = jsonDecode(content);
          data.forEach((k, v) {
            _memoryStorage[k] = v.toString();
          });
          print('💾 成功从本地恢复持久化存储: ${_memoryStorage.length} 项条目');
        }
      }
    } catch (e) {
      print('载入本地持久化存储异常: $e');
    } finally {
      _isLoaded = true;
    }
  }

  static Future<File> _getStorageFile() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      return File('${appDir.path}/$_storageFileName');
    } catch (_) {
      return File('${Directory.systemTemp.path}/$_storageFileName');
    }
  }

  static Future<void> _saveToDisk() async {
    try {
      final file = await _getStorageFile();
      await file.writeAsString(jsonEncode(_memoryStorage));
    } catch (e) {
      print('持久化写入磁盘失败: $e');
    }
  }

  static Future<void> inject(
    IsolateQjs engine, {
    required void Function(String level, String message) onLog,
  }) async {
    await init();

    final setGlobal = (await engine.evaluate('(key, val) => { globalThis[key] = val; }')) as JSInvokable;

    await setGlobal.invoke([
      '__nativeLocalGet',
      IsolateFunction((String rule, String key) {
        final storageKey = '$rule:$key';
        final val = _memoryStorage[storageKey];
        onLog('STORAGE', 'local.get($rule, $key) -> ${val != null ? "[值存在, 长度${val.length}]" : "null"}');
        return val;
      }),
    ]);

    await setGlobal.invoke([
      '__nativeLocalSet',
      IsolateFunction((String rule, String key, String val) {
        final storageKey = '$rule:$key';
        _memoryStorage[storageKey] = val;
        _saveToDisk();
        onLog('STORAGE', 'local.set($rule, $key, [长度${val.length}]) 已持久化');
      }),
    ]);

    await setGlobal.invoke([
      '__nativeLocalDelete',
      IsolateFunction((String rule, String key) {
        final storageKey = '$rule:$key';
        _memoryStorage.remove(storageKey);
        _saveToDisk();
        onLog('STORAGE', 'local.delete($rule, $key) 已移除');
      }),
    ]);

    setGlobal.free();

    // 注入 FongMi / CatVod 规范的 local 全局对象
    await engine.evaluate(r'''
      globalThis.local = {
        get: (rule, key) => globalThis.__nativeLocalGet(String(rule), String(key)),
        set: (rule, key, val) => globalThis.__nativeLocalSet(String(rule), String(key), String(val)),
        delete: (rule, key) => globalThis.__nativeLocalDelete(String(rule), String(key))
      };
    ''');
  }
}
