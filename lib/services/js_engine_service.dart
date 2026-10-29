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
/// 1. 完美支持用户本地包目录 `D:/code/ok影视js源/my` 与离线 ZIP 包
/// 2. 完美解析 clan://localhost/ 本地虚拟协议与 assets:// 资产
/// 3. 支持 ESM 模块解析 (含 ../lib/utils、./api115.js、PanUtils.js 等无缝多级嵌套)
/// 4. 自动桥接 req, http, local, pdfa, pdfh, pd, getPort, getProxy, js2Proxy 等 FongMi 内置环境
class JsEngineService {
  IsolateQjs? _engine;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  String? _currentBaseUrl;
  String? _localPackageDir;
  String? _currentMainJsCode;
  bool _isInitialized = false;

  /// 提取的 spider 接口函数映射
  Set<String> _availableMethods = {};

  /// 日志通知器
  final ValueNotifier<List<JsLogEntry>> logNotifier =
      ValueNotifier<List<JsLogEntry>>([]);

  bool get isInitialized => _isInitialized;

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

  /// 初始化 QuickJS 引擎
  Future<void> initEngine({
    String? baseUrl,
    String? configBaseUrl,
    localPackageDir,
  }) async {
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

    // 注入 FongMi 原生全局桥接
    await _injectGlobalBridge();
    _isInitialized = true;
  }

  /// FongMi 模块解析器
  Future<String> _handleModuleResolve(String module) async {
    _addLog('MODULE', '正在解析依赖模块: $module');
    String clean = module.trim();
    if (clean.startsWith('\'') && clean.endsWith('\''))
      clean = clean.substring(1, clean.length - 1);
    if (clean.startsWith('"') && clean.endsWith('"'))
      clean = clean.substring(1, clean.length - 1);

    // 0. 主入口模块 main.js 回传
    if (clean == 'main.js' || clean == './main.js') {
      if (_currentMainJsCode != null) {
        return _currentMainJsCode!;
      }
    }

    // 1. 虚拟网络模块 req / http
    if (clean == 'req' || clean == 'http') {
      return '''
        export default {
          get: (url, options) => globalThis.__nativeHttp(url, Object.assign({ method: 'GET' }, options)),
          post: (url, options) => globalThis.__nativeHttp(url, Object.assign({ method: 'POST' }, options))
        };
      ''';
    }

    // file:// 绝对文件协议解析
    if (clean.startsWith('file://')) {
      final fsPath = ConfigService.fromFileUri(clean);
      final f = File(fsPath);
      if (await f.exists()) {
        _addLog('MODULE', '从 file:// 绝对路径命中模块: $fsPath');
        return await f.readAsString();
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
          return await f.readAsString();
        }
      }
      return await _loadFromAssets(rel);
    }

    // 3. assets:// 协议
    if (clean.startsWith('assets://')) {
      final assetPath = clean.replaceFirst('assets://', '');
      return await _loadFromAssets(assetPath);
    }

    // 4. HTTP / HTTPS 绝对网络路径
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      return await _fetchRemoteJs(clean);
    }

    // 5. 常用原生库裸模块 (crypto-js / cheerio)
    if (clean == 'crypto-js' || clean.endsWith('crypto-js.js')) {
      return await _loadFromAssets('crypto-js.js');
    }
    if (clean == 'cheerio' || clean.endsWith('cheerio.min.js')) {
      return await _loadFromAssets('cheerio.min.js');
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
        if (content.isNotEmpty) return content;
      } catch (_) {}

      // 如果当前源在 /js/ 下，尝试上一层目录 /lib/
      if (_currentBaseUrl!.contains('/js/')) {
        final libUrl = _currentBaseUrl!
            .replaceFirst('/js/', '/lib/')
            .replaceAll(RegExp(r'/[^/]+\.js'), '/$fileWithJs');
        try {
          final content = await _fetchRemoteJs(libUrl);
          if (content.isNotEmpty) return content;
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
          return await f.readAsString();
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
      // 1. 相对当前脚本目录
      if (currentDir != null) '$currentDir/$clean',
      if (currentDir != null) '$currentDir/$cleanWithJs',
      if (currentDir != null) '$currentDir/../lib/$fileWithJs',
      if (currentDir != null) '$currentDir/lib/$fileWithJs',
      // 2. 相对脚本上一级根目录
      if (parentDir != null) '$parentDir/$clean',
      if (parentDir != null) '$parentDir/$cleanWithJs',
      if (parentDir != null) '$parentDir/lib/$fileWithJs',
      if (parentDir != null) '$parentDir/src/lib/$fileWithJs',
      // 3. 用户主本地包路径
      if (_localPackageDir != null) '$_localPackageDir/$clean',
      if (_localPackageDir != null) '$_localPackageDir/$cleanWithJs',
      if (_localPackageDir != null) '$_localPackageDir/lib/$fileWithJs',
      if (_localPackageDir != null) '$_localPackageDir/src/lib/$fileWithJs',
    ];

    for (final p in localCandidates) {
      final f = File(p);
      if (await f.exists()) {
        _addLog('MODULE', '本地路径成功命中依赖: $p');
        return await f.readAsString();
      }
    }

    // 7. 内置资产兜底加载 (cheerio, crypto-js, PanUtils, api115, utils, localCache, req 等)
    try {
      final assetContent = await _loadFromAssets(fileWithJs);
      if (assetContent.isNotEmpty) return assetContent;
    } catch (_) {}

    _addLog('ERROR', '未能找到模块依赖: $clean');
    throw Exception('无法找到模块: $clean');
  }

  Future<String> _loadFromAssets(String path) async {
    final fileName = path.split('/').last;

    try {
      final content = await rootBundle.loadString(
        'lib/quickjs/assets/js/lib/$fileName',
      );
      if (content.isNotEmpty) return content;
    } catch (_) {}

    throw Exception('未找到资产文件: $path');
  }

  Future<String> _fetchRemoteJs(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      return res.data ?? '';
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

    // 注入 CommonJS 容器变量与 window 全局映射
    await _engine!.evaluate('''
      globalThis.window = globalThis;
      globalThis.exports = {};
      globalThis.module = { exports: globalThis.exports };
    ''');

    // 预装载 CryptoJS 核心库至全局 (静默处理语法兼容)
    try {
      final cryptoCode = await _loadFromAssets('crypto-js.js');
      await _engine!.evaluate('''
        (function() {
          try {
            // 如果脚本包含 export，将其转为局部变量避免全局报错
            let module = { exports: {} };
            let exports = module.exports;
            // 简单包裹执行
            (function(module, exports) {
              ${cryptoCode.replaceAll(RegExp(r'export\s+.*'), '')}
            })(module, exports);
            globalThis.CryptoJS = globalThis.CryptoJS || module.exports;
          } catch(err) {
            // 忽略预装载非关键错误，由具体脚本按需通过 module 导入
          }
        })();
      ''', name: 'crypto-js.js');
    } catch (_) {}
  }

  /// 加载并运行 FongMi JS 源码
  Future<dynamic> loadJsSource(
    String jsCode, {
    String? baseUrl,
    String? configBaseUrl,
    String? localPackageDir,
    dynamic ext,
  }) async {
    await initEngine(
      baseUrl: baseUrl,
      configBaseUrl: configBaseUrl,
      localPackageDir: localPackageDir,
    );
    _availableMethods.clear();
    _currentMainJsCode = jsCode;
    _addLog('EXEC', '正在装载 FongMi JS 源...');

    try {
      dynamic evalResult;
      final isEsm = jsCode.contains('import ') || jsCode.contains('export ');

      if (isEsm) {
        _addLog('EXEC', '以 ESM 规范执行...');
        evalResult = await _engine!.evaluate(
          jsCode,
          name: 'main.js',
          evalFlags: JSEvalFlag.MODULE,
        );

        try {
          await _engine!.evaluate(
            "import spiderModule from 'main.js'; globalThis.spider = spiderModule.default || spiderModule;",
            name: 'bridge.js',
            evalFlags: JSEvalFlag.MODULE,
          );
          _addLog('EXEC', '成功绑定 main.js 至 globalThis.spider');
        } catch (e) {
          _addLog('WARN', 'ESM 绑定提示: $e');
        }
      } else {
        _addLog('EXEC', '以普通通用脚本规范执行...');
        evalResult = await _engine!.evaluate(jsCode);
      }

      // 提取可用接口名称列表 (纯字符串返回，避免 Dart 持有 QuickJS 函数指针引发注销泄漏)
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

      if (_availableMethods.isNotEmpty) {
        _addLog('EXEC', 'FongMi 源加载就绪接口: [${_availableMethods.join(', ')}]');
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

          // 【修正】：严格以 config.json 所在的根目录 (configBaseUrl) 为基准转换相对路径
          if (parsedExt is Map) {
            parsedExt = parsedExt.map((key, value) {
              if (value is String &&
                  (value.startsWith('./') || value.startsWith('../'))) {
                // 优先使用明确记录的 configBaseUrl，如果没有则从 baseUrl 剥离 JS 层级退回根目录
                String? baseRoot = configBaseUrl;
                if ((baseRoot == null || baseRoot.isEmpty) &&
                    _currentBaseUrl != null) {
                  if (_currentBaseUrl!.startsWith('http://') ||
                      _currentBaseUrl!.startsWith('https://')) {
                    Uri baseUri = Uri.parse(_currentBaseUrl!);
                    List<String> segments = List.from(baseUri.pathSegments);
                    if (segments.isNotEmpty && segments.last.isEmpty)
                      segments.removeLast();
                    if (segments.isNotEmpty) segments.removeLast(); // 弹出文件名
                    // 如果上一层仍然是 js 目录，再往上弹一层回到 src 根目录
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
                    _addLog('EXEC', '转换配置项 [$key] 基于根目录: $value -> $resolved');
                    return MapEntry(key, resolved);
                  } catch (e) {
                    _addLog('WARN', '解析根目录网络路径异常: $e');
                  }
                } else if (baseRoot != null) {
                  try {
                    final fsPath = ConfigService.fromFileUri(baseRoot);
                    final absolutePath = Directory('$fsPath/$value')
                        .absolute
                        .path;
                    _addLog(
                      'EXEC',
                      '转换配置项 [$key] 基于本地根目录: $value -> $absolutePath',
                    );
                    return MapEntry(key, absolutePath);
                  } catch (e) {
                    _addLog('WARN', '解析根目录本地路径异常: $e');
                  }
                }
              }
              return MapEntry(key, value);
            });
          }

          await callMethod('init', [parsedExt]);
        } catch (e) {
          _addLog('WARN', 'init(ext) 执行提示: $e');
        }
      }

      return evalResult;
    } catch (e) {
      _addLog('ERROR', 'FongMi JS 源解析异常: $e');
      rethrow;
    }
  }

  /// 调用 FongMi 标准接口 (完全在 JS 内部求值返回 JSON，杜绝 Dart 堆持有原生函数引发的崩溃)
  Future<dynamic> callMethod(
    String methodName, [
    List<dynamic> args = const [],
  ]) async {
    if (_engine == null) return null;
    _addLog('CALL', '$methodName(${args.join(', ')})');

    try {
      final jsonArgs = jsonEncode(args);
      final script =
          '''
        (async () => {
          let candidates = [
            globalThis.spider,
            globalThis.spider ? globalThis.spider.default : null,
            globalThis.__js_exports,
            globalThis.module ? globalThis.module.exports : null,
            globalThis.exports,
            globalThis
          ];
          let fn = null;
          let target = null;
          for (let c of candidates) {
            if (c && typeof c['$methodName'] === 'function') {
              fn = c['$methodName'];
              target = c;
              break;
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

      // 【新增】：打印接口返回的数据摘要，方便排查有没有数据
      String resSummary = parsedResult.toString();
      if (resSummary.length > 200) {
        resSummary =
            '${resSummary.substring(0, 200)}... (总长度: ${resSummary.length})';
      }
      _addLog('RESULT', '[$methodName] 返回结果: $resSummary');

      return parsedResult;
    } catch (e) {
      _addLog('WARN', '调用方法 [$methodName] 异常: $e');
      return null;
    }
  }

  Future<void> closeEngine() async {
    _availableMethods.clear();
    _currentMainJsCode = null;
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
