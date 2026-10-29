import "config_service.dart";

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';

import '../global/js_bridge.dart';
import '../global/http_bridge.dart';

/// JS 日志条目
class JsLogEntry {
  final DateTime time;
  final String level; // INFO, HTTP, MODULE, ERROR, JS
  final String message;

  JsLogEntry({required this.level, required this.message})
    : time = DateTime.now();

  @override
  String toString() {
    final t =
        "${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}";
    return "[$t] [$level] $message";
  }
}

/// 蜂蜜 (FongMi) 原生 JS 引擎核心服务
/// 深度适配 FongMi Spider 原生规范：
/// 1. 引擎单例常驻运行，模块加载内存高速缓存，杜绝重复磁盘与网络 I/O
/// 2. 切换站源时仅更新站源上下文与对应实例，全局 JS 依赖（CryptoJS、桥接环境）保持不变
/// 3. 支持多站源 spider 实例隔离与并发调用
class JsEngineService {
  IsolateQjs? _engine;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
    ),
  );

  String? _currentBaseUrl;
  String? _localPackageDir;
  String? _currentMainJsCode;
  String? _activeSiteKey;
  bool _isInitialized = false;

  /// 提取的 spider 接口函数映射
  Set<String> _availableMethods = {};

  /// 模块源码内存缓存 (key: 模块名/路径 -> 源码)
  final Map<String, String> _moduleCache = {};

  /// 已成功编译初始化的站源集合 (siteKey)
  final Set<String> _initializedSites = {};

  /// 日志通知器
  final ValueNotifier<List<JsLogEntry>> logNotifier =
      ValueNotifier<List<JsLogEntry>>([]);

  bool get isInitialized => _isInitialized;
  String? get activeSiteKey => _activeSiteKey;

  void _addLog(String level, String message) {
    print("[$level] $message");
    final currentLogs = List<JsLogEntry>.from(logNotifier.value);
    currentLogs.add(JsLogEntry(level: level, message: message));
    if (currentLogs.length > 250) currentLogs.removeAt(0);
    logNotifier.value = currentLogs;
  }

  void clearLogs() {
    logNotifier.value = [];
  }

  void clearModuleCache() {
    _moduleCache.clear();
    _initializedSites.clear();
    _addLog('MODULE', '已清空 JS 模块内存缓存');
  }

  /// 初始化 QuickJS 引擎 (全局仅在初次或强制重建时执行一次，保持全局依赖不变)
  Future<void> initEngine({
    String? baseUrl,
    String? configBaseUrl,
    String? localPackageDir,
    bool forceRecreate = false,
  }) async {
    // 💡 优化需求1：引擎已初始化时，复用现有实例，仅更新路径配置，不重复注销重创
    if (_isInitialized && _engine != null && !forceRecreate) {
      _currentBaseUrl = baseUrl ?? _currentBaseUrl;
      _localPackageDir = localPackageDir ?? _localPackageDir;
      HttpBridge.currentBaseUrl = _currentBaseUrl;
      HttpBridge.localPackageDir = _localPackageDir;
      return;
    }

    await closeEngine();
    _currentBaseUrl = baseUrl;
    _localPackageDir = localPackageDir ?? 'D:/code/ok影视js源/my';
    HttpBridge.currentBaseUrl = baseUrl;
    HttpBridge.localPackageDir = _localPackageDir;
    _availableMethods.clear();

    _addLog(
      'ENGINE',
      '初始化 FongMi QuickJS 运行时 (baseUrl: ${baseUrl ?? "无"}, localPkg: $_localPackageDir)',
    );

    _engine = IsolateQjs(
      moduleHandler: (String module) async {
        return await _handleModuleResolve(module);
      },
    );

    // 注入全局不变依赖 (Console, HTTP, Storage, window, CommonJS 容器, 全局 CryptoJS)
    await _injectGlobalBridge();
    _isInitialized = true;
  }

  /// FongMi 模块解析器 (带内存高速缓存)
  Future<String> _handleModuleResolve(String module) async {
    String clean = module.trim();
    if (clean.startsWith('\'') && clean.endsWith('\'')) {
      clean = clean.substring(1, clean.length - 1);
    }
    if (clean.startsWith('"') && clean.endsWith('"')) {
      clean = clean.substring(1, clean.length - 1);
    }

    // 0. 主入口模块 main.js 回传
    if (clean == 'main.js' || clean == './main.js') {
      if (_currentMainJsCode != null) {
        return _currentMainJsCode!;
      }
    }

    // 💡 优化需求1：优先命中模块内存缓存，秒级返回，避免重复读盘与重复网络拉取
    if (_moduleCache.containsKey(clean)) {
      return _moduleCache[clean]!;
    }

    _addLog('MODULE', '正在解析依赖模块: $clean');

    // 1. 虚拟网络模块 req / http
    if (clean == 'req' || clean == 'http') {
      const code = '''
        export default {
          get: (url, options) => globalThis.__nativeHttp(url, Object.assign({ method: 'GET' }, options)),
          post: (url, options) => globalThis.__nativeHttp(url, Object.assign({ method: 'POST' }, options))
        };
      ''';
      _moduleCache[clean] = code;
      return code;
    }

    // file:// 绝对文件协议解析
    if (clean.startsWith('file://')) {
      final fsPath = ConfigService.fromFileUri(clean);
      final f = File(fsPath);
      if (await f.exists()) {
        _addLog('MODULE', '从 file:// 绝对路径命中模块: $fsPath');
        final content = await f.readAsString();
        _moduleCache[clean] = content;
        return content;
      }
    }

    // 2. clan://localhost/ 协议
    if (clean.startsWith('clan://localhost/')) {
      final rel = clean.replaceFirst('clan://localhost/', '');
      final candidates = [
        if (_localPackageDir != null) '$_localPackageDir/$rel',
        if (_currentBaseUrl != null && !_currentBaseUrl!.startsWith('http'))
          '${File(ConfigService.fromFileUri(_currentBaseUrl!)).parent.path}/$rel',
        if (_currentBaseUrl != null && !_currentBaseUrl!.startsWith('http'))
          '${File(ConfigService.fromFileUri(_currentBaseUrl!)).parent.parent.path}/$rel',
      ];

      for (final p in candidates) {
        final f = File(p);
        if (await f.exists()) {
          _addLog('MODULE', '从 clan:// 成功命中本地文件: $p');
          final content = await f.readAsString();
          _moduleCache[clean] = content;
          return content;
        }
      }
      final assetContent = await _loadFromAssets(rel);
      _moduleCache[clean] = assetContent;
      return assetContent;
    }

    // 3. assets:// 协议
    if (clean.startsWith('assets://')) {
      final assetPath = clean.replaceFirst('assets://', '');
      final content = await _loadFromAssets(assetPath);
      _moduleCache[clean] = content;
      return content;
    }

    // 4. HTTP / HTTPS 绝对网络路径
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      final content = await _fetchRemoteJs(clean);
      _moduleCache[clean] = content;
      return content;
    }

    // 5. 常用原生库裸模块 (crypto-js / cheerio)
    if (clean == 'crypto-js' || clean.endsWith('crypto-js.js')) {
      final content = await _loadFromAssets('crypto-js.js');
      _moduleCache[clean] = content;
      return content;
    }
    if (clean == 'cheerio' || clean.endsWith('cheerio.min.js')) {
      final content = await _loadFromAssets('cheerio.min.js');
      _moduleCache[clean] = content;
      return content;
    }

    // 6. 相对路径解析 (如 ../lib/utils.js, ../lib/utils, ./api115.js, ./PanUtils.js)
    final fileName = clean.split('/').last;
    final fileWithJs = fileName.endsWith('.js') ? fileName : '$fileName.js';
    final cleanWithJs = clean.endsWith('.js') ? clean : '$clean.js';

    // A. 网络 URL 相对路径解析
    if (_currentBaseUrl != null &&
        (_currentBaseUrl!.startsWith('http://') ||
            _currentBaseUrl!.startsWith('https://'))) {
      final resolvedUrl = Uri.parse(_currentBaseUrl!)
          .resolve(cleanWithJs)
          .toString();
      try {
        final content = await _fetchRemoteJs(resolvedUrl);
        if (content.isNotEmpty) {
          _moduleCache[clean] = content;
          return content;
        }
      } catch (_) {}

      // 如果当前源在 /js/ 下，尝试上一层目录 /lib/
      if (_currentBaseUrl!.contains('/js/')) {
        final libUrl = _currentBaseUrl!
            .replaceFirst('/js/', '/lib/')
            .replaceAll(RegExp(r'/[^/]+\.js'), '/$fileWithJs');
        try {
          final content = await _fetchRemoteJs(libUrl);
          if (content.isNotEmpty) {
            _moduleCache[clean] = content;
            return content;
          }
        } catch (_) {}
      }
    } else if (_currentBaseUrl != null &&
        _currentBaseUrl!.startsWith('file://')) {
      try {
        final baseUri = Uri.parse(_currentBaseUrl!);
        final resolvedUri = baseUri.resolve(cleanWithJs);
        final fsPath = ConfigService.fromFileUri(resolvedUri.toString());
        final f = File(fsPath);
        if (await f.exists()) {
          _addLog('MODULE', '从 file:// 相对解析成功命中: $fsPath');
          final content = await f.readAsString();
          _moduleCache[clean] = content;
          return content;
        }
      } catch (_) {}
    }

    // B. 本地文件系统多目录精确匹配
    String? currentDir;
    String? parentDir;
    if (_currentBaseUrl != null && !_currentBaseUrl!.startsWith('http')) {
      final fsPath = ConfigService.fromFileUri(_currentBaseUrl!);
      currentDir = File(fsPath).parent.path;
      parentDir = File(fsPath).parent.parent.path;
    }

    final localCandidates = [
      if (currentDir != null) '$currentDir/$clean',
      if (currentDir != null) '$currentDir/$cleanWithJs',
      if (currentDir != null) '$currentDir/../lib/$fileWithJs',
      if (currentDir != null) '$currentDir/lib/$fileWithJs',
      if (parentDir != null) '$parentDir/$clean',
      if (parentDir != null) '$parentDir/$cleanWithJs',
      if (parentDir != null) '$parentDir/lib/$fileWithJs',
      if (parentDir != null) '$parentDir/src/lib/$fileWithJs',
      if (_localPackageDir != null) '$_localPackageDir/$clean',
      if (_localPackageDir != null) '$_localPackageDir/$cleanWithJs',
      if (_localPackageDir != null) '$_localPackageDir/lib/$fileWithJs',
      if (_localPackageDir != null) '$_localPackageDir/src/lib/$fileWithJs',
    ];

    for (final p in localCandidates) {
      final f = File(p);
      if (await f.exists()) {
        _addLog('MODULE', '本地路径成功命中依赖: $p');
        final content = await f.readAsString();
        _moduleCache[clean] = content;
        return content;
      }
    }

    // 7. 内置资产兜底加载
    try {
      final assetContent = await _loadFromAssets(fileWithJs);
      if (assetContent.isNotEmpty) {
        _moduleCache[clean] = assetContent;
        return assetContent;
      }
    } catch (_) {}

    _addLog('ERROR', '未能找到模块依赖: $clean');
    throw Exception('无法找到模块: $clean');
  }

  Future<String> _loadFromAssets(String path) async {
    final fileName = path.split('/').last;
    if (_moduleCache.containsKey('asset_$fileName')) {
      return _moduleCache['asset_$fileName']!;
    }

    try {
      final content = await rootBundle.loadString(
        'lib/quickjs/assets/js/lib/$fileName',
      );
      if (content.isNotEmpty) {
        _moduleCache['asset_$fileName'] = content;
        return content;
      }
    } catch (_) {}

    throw Exception('未找到资产文件: $path');
  }

  Future<String> _fetchRemoteJs(String url) async {
    if (_moduleCache.containsKey(url)) {
      return _moduleCache[url]!;
    }
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final data = res.data ?? '';
      _moduleCache[url] = data;
      return data;
    } catch (e) {
      _addLog('ERROR', '远程 JS 模块拉取失败: $url ($e)');
      throw Exception('网络加载模块失败: $url');
    }
  }

  Future<void> _injectGlobalBridge() async {
    if (_engine == null) return;
    await JsBridge.injectAll(
      _engine!,
      onLog: (level, msg) => _addLog(level, msg),
    );

    // 注入 CommonJS 容器变量、window 全局映射及站点 spider 存储池
    await _engine!.evaluate('''
      globalThis.window = globalThis;
      globalThis.exports = {};
      globalThis.module = { exports: globalThis.exports };
      globalThis.__site_spiders = globalThis.__site_spiders || {};
    ''');

    // 预装载 CryptoJS 核心库至全局 (保证全局依赖不变)
    try {
      final cryptoCode = await _loadFromAssets('crypto-js.js');
      await _engine!.evaluate('''
        (function() {
          try {
            let module = { exports: {} };
            let exports = module.exports;
            (function(module, exports) {
              ${cryptoCode.replaceAll(RegExp(r'export\s+.*'), '')}
            })(module, exports);
            globalThis.CryptoJS = globalThis.CryptoJS || module.exports;
          } catch(err) {}
        })();
      ''', name: 'crypto-js.js');
    } catch (_) {}
  }

  /// 加载并运行 FongMi JS 源码
  /// 💡 优化：切换站源时，仅更新当前站源对应的上下文与 spider 实例，全局 JS 依赖完全不变
  Future<dynamic> loadJsSource(
    String jsCode, {
    String? baseUrl,
    String? configBaseUrl,
    String? localPackageDir,
    dynamic ext,
    String? siteKey,
  }) async {
    // 确保引擎初始化就绪（若已启动则复用，绝不重复销毁重启）
    if (!_isInitialized || _engine == null) {
      await initEngine(
        baseUrl: baseUrl,
        configBaseUrl: configBaseUrl,
        localPackageDir: localPackageDir,
      );
    } else {
      // 仅更新站源对应路径信息
      _currentBaseUrl = baseUrl;
      _localPackageDir = localPackageDir ?? _localPackageDir;
      HttpBridge.currentBaseUrl = baseUrl;
      HttpBridge.localPackageDir = _localPackageDir;
    }

    final key = siteKey ?? 'default_site';
    _activeSiteKey = key;
    _currentMainJsCode = jsCode;

    // 💡 快速切换机制：如果该站点已在 JS 运行时编译过，直接切换激活引用，无需重跑编译
    if (_initializedSites.contains(key)) {
      _addLog('EXEC', '⚡ 命中站源 [$key] 已就绪实例，秒级切换激活');
      await _engine!.evaluate('''
        if (globalThis.__site_spiders && globalThis.__site_spiders['$key']) {
          globalThis.spider = globalThis.__site_spiders['$key'];
        }
      ''');
      await _refreshAvailableMethods();
      return globalThisRef();
    }

    _availableMethods.clear();
    _addLog('EXEC', '正在装载 FongMi 站源 [$key]...');

    try {
      dynamic evalResult;
      final isEsm = jsCode.contains('import ') || jsCode.contains('export ');

      // 清理当前站源专属导出，保持全局依赖纯净
      await _engine!.evaluate('''
        globalThis.spider = null;
        globalThis.__js_exports = null;
        globalThis.exports = {};
        globalThis.module = { exports: globalThis.exports };
      ''');

      if (isEsm) {
        _addLog('EXEC', '以 ESM 规范执行...');
        evalResult = await _engine!.evaluate(
          jsCode,
          name: '${key}_main.js',
          evalFlags: JSEvalFlag.MODULE,
        );

        try {
          await _engine!.evaluate(
            '''
            import spiderModule from '${key}_main.js';
            let sp = spiderModule.default || spiderModule;
            globalThis.spider = sp;
            globalThis.__site_spiders['$key'] = sp;
            ''',
            name: '${key}_bridge.js',
            evalFlags: JSEvalFlag.MODULE,
          );
          _addLog('EXEC', '成功绑定 [$key] 至 globalThis.spider 与 __site_spiders');
        } catch (e) {
          _addLog('WARN', 'ESM 绑定提示: $e');
        }
      } else {
        _addLog('EXEC', '以普通通用脚本规范执行...');
        evalResult = await _engine!.evaluate(jsCode);
        await _engine!.evaluate('''
          let sp = globalThis.spider || globalThis.__js_exports || (globalThis.module ? globalThis.module.exports : null) || globalThis.exports;
          globalThis.__site_spiders['$key'] = sp;
        ''');
      }

      await _refreshAvailableMethods();

      if (_availableMethods.isNotEmpty) {
        _addLog('EXEC', '站源 [$key] 加载就绪接口: [${_availableMethods.join(', ')}]');
      }

      // 执行 init(ext)
      if (ext != null) {
        _addLog('EXEC', '执行 init(ext)...');
        try {
          dynamic parsedExt = ext;
          if (ext is String && (ext.startsWith('{') || ext.startsWith('['))) {
            try {
              parsedExt = jsonDecode(ext);
            } catch (_) {}
          }

          if (parsedExt is Map) {
            parsedExt = parsedExt.map((k, value) {
              if (value is String &&
                  (value.startsWith('./') || value.startsWith('../'))) {
                String? baseRoot = configBaseUrl;
                if ((baseRoot == null || baseRoot.isEmpty) &&
                    _currentBaseUrl != null) {
                  if (_currentBaseUrl!.startsWith('http://') ||
                      _currentBaseUrl!.startsWith('https://')) {
                    Uri baseUri = Uri.parse(_currentBaseUrl!);
                    List<String> segments = List.from(baseUri.pathSegments);
                    if (segments.isNotEmpty && segments.last.isEmpty) {
                      segments.removeLast();
                    }
                    if (segments.isNotEmpty) segments.removeLast();
                    if (segments.isNotEmpty && segments.last == 'js') {
                      segments.removeLast();
                    }
                    baseRoot = baseUri
                        .replace(pathSegments: segments)
                        .toString();
                  }
                }

                if (baseRoot != null &&
                    (baseRoot.startsWith('http://') ||
                        baseRoot.startsWith('https://'))) {
                  try {
                    final resolved = Uri.parse(baseRoot)
                        .resolve(value)
                        .toString();
                    return MapEntry(k, resolved);
                  } catch (e) {
                    _addLog('WARN', '解析根目录网络路径异常: $e');
                  }
                } else if (baseRoot != null) {
                  try {
                    final fsPath = ConfigService.fromFileUri(baseRoot);
                    final absolutePath = Directory('$fsPath/$value')
                        .absolute
                        .path;
                    return MapEntry(k, absolutePath);
                  } catch (e) {
                    _addLog('WARN', '解析根目录本地路径异常: $e');
                  }
                }
              }
              return MapEntry(k, value);
            });
          }

          await callMethod('init', [parsedExt], key);
        } catch (e) {
          _addLog('WARN', 'init(ext) 执行提示: $e');
        }
      }

      _initializedSites.add(key);
      return evalResult;
    } catch (e) {
      _addLog('ERROR', 'FongMi JS 源解析异常: $e');
      rethrow;
    }
  }

  Future<void> _refreshAvailableMethods() async {
    if (_engine == null) return;
    final extractScript = '''
      (() => {
        let candidates = [
          globalThis.spider,
          globalThis.spider ? globalThis.spider.default : null,
          globalThis.__js_exports,
          globalThis.module ? globalThis.module.exports : null,
          globalThis.exports,
          globalThis
        ];
        let methodNames = [];
        ['init', 'home', 'homeVod', 'category', 'detail', 'play', 'search', 'live', 'sniffer', 'isVideo', 'proxy', 'action', 'destroy'].forEach(name => {
          for (let c of candidates) {
            if (c && typeof c[name] === 'function') {
              if (!methodNames.includes(name)) methodNames.push(name);
              break;
            }
          }
        });
        return methodNames;
      })()
    ''';
    final namesRaw = await _engine!.evaluate(extractScript);
    if (namesRaw is List) {
      _availableMethods = Set<String>.from(namesRaw.map((e) => e.toString()));
    }
  }

  dynamic globalThisRef() => null;

  /// 调用 FongMi 标准接口 (支持按特定 siteKey 定向调用，完美适配并发搜索)
  Future<dynamic> callMethod(
    String methodName, [
    List<dynamic> args = const [],
    String? siteKey,
  ]) async {
    if (_engine == null) return null;

    try {
      final jsonArgs = jsonEncode(args);
      final keyFilter = siteKey != null ? "'$siteKey'" : 'null';

      final script = '''
        (async () => {
          let sKey = $keyFilter;
          let target = null;
          let fn = null;

          if (sKey && globalThis.__site_spiders && globalThis.__site_spiders[sKey]) {
            target = globalThis.__site_spiders[sKey];
            if (target && typeof target['$methodName'] === 'function') {
              fn = target['$methodName'];
            }
          }

          if (!fn) {
            let candidates = [
              globalThis.spider,
              globalThis.spider ? globalThis.spider.default : null,
              globalThis.__js_exports,
              globalThis.module ? globalThis.module.exports : null,
              globalThis.exports,
              globalThis
            ];
            for (let c of candidates) {
              if (c && typeof c['$methodName'] === 'function') {
                fn = c['$methodName'];
                target = c;
                break;
              }
            }
          }

          if (fn) {
            let res = await fn.apply(target, $jsonArgs);
            return (typeof res === 'object') ? JSON.stringify(res) : res;
          }
          throw new Error("未找到 FongMi JS 接口: $methodName");
        })()
      ''';

      final result = await _engine!.evaluate(script);
      dynamic parsedResult = result;
      if (result is String &&
          (result.startsWith('{') || result.startsWith('['))) {
        try {
          parsedResult = jsonDecode(result);
        } catch (_) {}
      }

      return parsedResult;
    } catch (e) {
      _addLog('WARN', '调用方法 [$methodName] 异常: $e');
      return null;
    }
  }

  Future<void> closeEngine() async {
    _availableMethods.clear();
    _currentMainJsCode = null;
    _activeSiteKey = null;
    _initializedSites.clear();

    if (_engine != null) {
      final eng = _engine!;
      _engine = null;
      _isInitialized = false;
      await JsBridge.clearAll(eng);
      try {
        await eng.close();
        _addLog('ENGINE', 'QuickJS 运行时已安全注销');
      } catch (e) {
        _addLog('WARN', '注销 QJS 提示: $e');
      }
    }
  }
}
