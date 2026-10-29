import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';

import '../services/config_service.dart';

/// JS 全局 网络/HTTP (req & http) 桥接能力
class HttpBridge {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
    },
    followRedirects: true,
    maxRedirects: 5,
    validateStatus: (status) => status != null && status < 500,
  ));

  /// 当前正在执行的 JS 源 Base URL
  static String? currentBaseUrl;

  /// 当前激活的本地包沙盒根目录 (用于 clan://localhost/ 映射)
  static String? localPackageDir;

  static Future<void> inject(
      IsolateQjs engine, {
        required void Function(String level, String message) onLog,
      }) async {
    onLog('HTTP-INIT', '开始注入 HttpBridge 到 JS 引擎...');

    final setGlobal = (await engine.evaluate(
        '(key, val) => { globalThis[key] = val; }'))
    as JSInvokable;

    // 💡 核心修复死锁：直接通过 IsolateFunction 异步返回 Future<Map>
    // flutter_qjs 会自动将 Dart Future 映射并安全 resolve JS Promise，无需跨跨 engine.evaluate
    await setGlobal.invoke([
      '__triggerNativeHttp',
      IsolateFunction((String url, String optionsJson) async {
        onLog('HTTP-BRIDGE', '[收到JS异步请求] url: $url');
        Map options = {};
        try {
          if (optionsJson.isNotEmpty) {
            options = jsonDecode(optionsJson);
          }
        } catch (e) {
          onLog('HTTP-ERR',
              '[解析选项异常] url: $url, optionsJson: $optionsJson, error: $e');
        }

        return await _executeHttp(url, options, onLog: onLog);
      }),
    ]);

    setGlobal.free();

    // 注入 JS 环境下的统一 Promise 包装与属性代理层
    await engine.evaluate(r'''
      globalThis.__nativeHttp = (url, options) => {
        const p = (async () => {
          try {
            const res = await __triggerNativeHttp(String(url), JSON.stringify(options || {}));
            let headers = {};
            try {
              if (typeof res.headers === 'string' && res.headers) {
                headers = JSON.parse(res.headers);
              } else if (typeof res.headers === 'object' && res.headers) {
                headers = res.headers || {};
              }
            } catch(e) {
              console.error('[JS-ERR] 解析 headers 异常:', e);
            }

            return {
              status: res.status || (res.error ? 500 : 200),
              code: res.code || (res.error ? 500 : 200),
              content: res.content || '',
              headers: headers,
              error: res.error,
              json: function() {
                try { return JSON.parse(this.content); } catch(e) { return {}; }
              },
              text: function() { return this.content || ''; }
            };
          } catch(e) {
            return {
              status: 500,
              code: 500,
              content: '',
              headers: {},
              error: String(e),
              json: function() { return {}; },
              text: function() { return ''; }
            };
          }
        })();

        // 挂载响应字段 getter，彻底支持 await req(url).content 与 Promise.all([req(x).content])
        Object.defineProperty(p, 'content', {
          get: () => p.then(res => res ? res.content : '')
        });
        Object.defineProperty(p, 'headers', {
          get: () => p.then(res => res ? res.headers : {})
        });
        Object.defineProperty(p, 'code', {
          get: () => p.then(res => res ? res.code : 200)
        });
        Object.defineProperty(p, 'status', {
          get: () => p.then(res => res ? res.status : 200)
        });
        Object.defineProperty(p, 'json', {
          value: () => p.then(res => res ? res.json() : {})
        });
        Object.defineProperty(p, 'text', {
          value: () => p.then(res => res ? res.text() : '')
        });

        return p;
      };

      const httpFn = (url, options) => globalThis.__nativeHttp(url, options || {});
      httpFn.get = (url, options) => globalThis.__nativeHttp(url, Object.assign({ method: 'GET' }, options));
      httpFn.post = (url, options) => globalThis.__nativeHttp(url, Object.assign({ method: 'POST' }, options));

      // req 和 http 完全等价
      globalThis.http = httpFn;
      globalThis.req = httpFn;

      // 补充标准 fetch API 包装
      globalThis.fetch = async function(url, options) {
        const res = await globalThis.__nativeHttp(url, options || {});
        return {
          status: res.code || res.status || 200,
          ok: (res.code || res.status || 200) >= 200 && (res.code || res.status || 200) < 300,
          headers: {
            get: (k) => res.headers ? (res.headers[String(k).toLowerCase()] || res.headers[k]) : null,
            forEach: (cb) => {
              if (res.headers) {
                Object.keys(res.headers).forEach(k => cb(res.headers[k], k));
              }
            }
          },
          text: async () => res.content || '',
          json: async () => {
            try { return JSON.parse(res.content); } catch(e) { return {}; }
          }
        };
      };
    ''');
    onLog('HTTP-INIT', 'HttpBridge 注入完成.');
  }

  /// 执行本地文件读取 或 Dio 原生 HTTP 请求（自带强制超时防卡死）
  static Future<Map<String, dynamic>> _executeHttp(
      String url,
      Map options, {
        required void Function(String level, String message) onLog,
      }) async {
    final method = (options['method'] as String?)?.toUpperCase() ?? 'GET';
    final cleanUrl = url.trim();

    // ─────────────────────────────────────────────────────────────────────────
    // 0. 处理 file:// 或本地相对路径文件读取
    // ─────────────────────────────────────────────────────────────────────────
    if (cleanUrl.startsWith('file://') ||
        (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://'))) {
      onLog('HTTP-LOCAL', '尝试作为本地文件处理: $cleanUrl');
      String localFilePath = cleanUrl;
      if (cleanUrl.startsWith('file://')) {
        try {
          localFilePath = Uri.parse(cleanUrl).toFilePath();
        } catch (_) {
          localFilePath = cleanUrl.replaceFirst('file://', '');
          if (Platform.isWindows &&
              RegExp(r'^/[a-zA-Z]:').hasMatch(localFilePath)) {
            localFilePath = localFilePath.substring(1);
          }
        }
      } else {
        final rel = cleanUrl.replaceFirst('./', '');
        final fileName = cleanUrl.split('/').last;

        String? currentDir;
        String? parentDir;
        if (currentBaseUrl != null && !currentBaseUrl!.startsWith('http')) {
          String fsPath = ConfigService.fromFileUri(currentBaseUrl!);
          currentDir = File(fsPath).parent.path;
          parentDir = File(fsPath).parent.parent.path;
        }

        final candidateFiles = [
          if (localPackageDir != null) '$localPackageDir/$rel',
          if (localPackageDir != null) '$localPackageDir/src/$rel',
          if (localPackageDir != null) '$localPackageDir/config/$fileName',
          if (localPackageDir != null) '$localPackageDir/src/config/$fileName',
          if (currentDir != null) '$currentDir/$rel',
          if (currentDir != null) '$currentDir/config/$fileName',
          if (parentDir != null) '$parentDir/$rel',
          if (parentDir != null) '$parentDir/config/$fileName',
          cleanUrl,
        ];

        for (final p in candidateFiles) {
          if (await File(p).exists()) {
            localFilePath = p;
            break;
          }
        }
      }

      final f = File(localFilePath);
      if (await f.exists()) {
        try {
          final content = await f.readAsString();
          onLog('HTTP-LOCAL',
              '成功异步读取本地文件: $localFilePath (${content.length} 字节)');
          return {
            'status': 200,
            'code': 200,
            'content': content,
            'headers': {'content-type': 'text/plain; charset=utf-8'},
          };
        } catch (e) {
          onLog('HTTP-ERR', '读取本地文件异常 ($localFilePath): $e');
        }
      } else {
        onLog('HTTP-LOCAL', '本地文件不存在: $localFilePath');
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. 处理相对网络路径重定向
    // ─────────────────────────────────────────────────────────────────────────
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      if (currentBaseUrl != null &&
          (currentBaseUrl!.startsWith('http://') ||
              currentBaseUrl!.startsWith('https://'))) {
        Uri baseUri = Uri.parse(currentBaseUrl!);
        final resolvedUrl = baseUri.resolve(cleanUrl).toString();
        onLog('HTTP-REQ', '自动重定向相对网络 URL: $cleanUrl -> $resolvedUrl');
        final firstAttempt =
        await _executeHttp(resolvedUrl, options, onLog: onLog);
        if (firstAttempt['status'] == 200 &&
            (firstAttempt['content'] as String).isNotEmpty) {
          return firstAttempt;
        }

        if (baseUri.path.contains('/js/')) {
          final parentUrl = currentBaseUrl!.replaceFirst('/js/', '/');
          final retryUrl = Uri.parse(parentUrl).resolve(cleanUrl).toString();
          onLog('HTTP-REQ', '尝试父级根目录相对 URL: $cleanUrl -> $retryUrl');
          return await _executeHttp(retryUrl, options, onLog: onLog);
        }
        return firstAttempt;
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. 执行 Dio 网络请求 (强制超时防死锁)
    // ─────────────────────────────────────────────────────────────────────────
    final headers = Map<String, dynamic>.from(options['headers'] ?? {});
    final postType = (options['postType'] as String?)?.toLowerCase() ?? 'json';
    dynamic data = options['data'] ?? options['body'];

    if (data != null && data is Map) {
      if (postType == 'form') {
        headers['content-type'] ??= 'application/x-www-form-urlencoded';
      } else if (postType == 'json') {
        headers['content-type'] ??= 'application/json';
        data = jsonEncode(data);
      }
    }

    final queryParameters = options['params'] is Map
        ? Map<String, dynamic>.from(options['params'])
        : null;
    final timeoutSec =
    options['timeout'] is int ? options['timeout'] as int : 15;

    onLog('HTTP-REQ',
        '发起 Dio 请求: [$method] $cleanUrl (Timeout: ${timeoutSec}s)');

    try {
      final response = await _dio.request(
        cleanUrl,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          sendTimeout: Duration(seconds: timeoutSec),
          receiveTimeout: Duration(seconds: timeoutSec),
        ),
      );

      final rawData = response.data;
      String bodyStr = '';
      if (rawData != null) {
        bodyStr = rawData is Map || rawData is List
            ? jsonEncode(rawData)
            : rawData.toString();
      }

      final Map<String, String> flatHeaders = {};
      response.headers.forEach((key, values) {
        flatHeaders[key.toLowerCase()] = values.join('; ');
      });

      onLog('HTTP-SUCCESS',
          'Dio 请求成功: [$method] $cleanUrl -> Status: ${response.statusCode}, 长度: ${bodyStr.length}');

      return {
        'status': response.statusCode ?? 200,
        'code': response.statusCode ?? 200,
        'content': bodyStr,
        'headers': flatHeaders,
      };
    } catch (e) {
      String errorMsg = e is DioException
          ? 'DioException [${e.type}]: ${e.message} (url: $cleanUrl)'
          : e.toString();
      onLog('HTTP-ERR', 'Dio 请求失败或超时: $errorMsg');

      return {
        'status': (e is DioException) ? (e.response?.statusCode ?? 408) : 500,
        'code': (e is DioException) ? (e.response?.statusCode ?? 408) : 500,
        'error': errorMsg,
        'content': '',
        'headers': {},
      };
    }
  }
}
