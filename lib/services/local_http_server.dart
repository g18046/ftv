import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

/// 局域网/本地内置 HTTP 服务 (NanoHTTPD 规范)
/// 端口由 9978 依次尝试绑定，支持 /device, /media, /action, /cache, /proxy 端点
/// 兼容 OK 影视与 FongMi JS 扩展（如 PanUtils.js）触发的弹幕/字幕刷新与控制指令
class LocalHttpServer {
  static final LocalHttpServer _instance = LocalHttpServer._internal();
  factory LocalHttpServer() => _instance;
  LocalHttpServer._internal();

  HttpServer? _server;
  int _port = 9978;
  int get port => _port;
  bool get isRunning => _server != null;

  final Map<String, String> _cacheNamespace = {};
  final Dio _dio = Dio();

  // 刷新弹幕广播流 (路径/URL)
  final StreamController<String> _danmakuRefreshController =
      StreamController<String>.broadcast();
  Stream<String> get onDanmakuRefresh => _danmakuRefreshController.stream;

  // 刷新字幕广播流 (路径/URL)
  final StreamController<String> _subtitleRefreshController =
      StreamController<String>.broadcast();
  Stream<String> get onSubtitleRefresh => _subtitleRefreshController.stream;

  // 触发动作控制广播流
  final StreamController<Map<String, String>> _actionController =
      StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onAction => _actionController.stream;

  /// 启动服务 (从 9978 端口开始顺序尝试)
  Future<int> start() async {
    if (_server != null) return _port;

    for (int p = 9978; p <= 9995; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _port = p;
        print('🚀 [HTTP-SERVER] 本地  服务成功启动: http://127.0.0.1:$_port');
        _listenRequests();
        return _port;
      } catch (_) {
        // 端口被占用，继续尝试下一个端口
      }
    }
    print('⚠️ [HTTP-SERVER] 未能绑定 9978-9995 范围内的端口');
    return _port;
  }

  void _listenRequests() {
    _server?.listen((HttpRequest request) async {
      try {
        _addCorsHeaders(request.response);
        final path = request.uri.path;
        final params = Map<String, String>.from(request.uri.queryParameters);

        if (path == '/device') {
          _handleDevice(request);
        } else if (path == '/media') {
          _handleMedia(request);
        } else if (path == '/action') {
          await _handleAction(request, params);
        } else if (path == '/cache') {
          _handleCache(request, params);
        } else if (path == '/proxy') {
          await _handleProxy(request, params);
        } else {
          _jsonResponse(request.response, {'status': 'ok', 'port': _port});
        }
      } catch (e) {
        try {
          _jsonResponse(request.response, {'error': e.toString()},
              statusCode: 500);
        } catch (_) {}
      }
    });
  }

  void _addCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', '*');
  }

  void _jsonResponse(HttpResponse response, dynamic data,
      {int statusCode = 200}) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }

  void _handleDevice(HttpRequest request) {
    _jsonResponse(request.response, {
      'device': 'FTV Player',
      'platform': Platform.operatingSystem,
      'port': _port,
      'status': 'online',
    });
  }

  void _handleMedia(HttpRequest request) {
    _jsonResponse(request.response, {
      'status': 'playing',
      'media': 'FTV Media',
    });
  }

  Future<void> _handleAction(
      HttpRequest request, Map<String, String> params) async {
    final actionDo = params['do'] ?? '';
    final actionType = params['type'] ?? '';
    final pathOrUrl = params['path'] ?? params['url'] ?? '';

    print(
        '🔔 [HTTP-SERVER] 收到 /action 控制指令: do=$actionDo, type=$actionType, path=$pathOrUrl');

    if (actionDo == 'refresh') {
      if (actionType == 'danmaku' && pathOrUrl.isNotEmpty) {
        _danmakuRefreshController.add(pathOrUrl);
      } else if (actionType == 'subtitle' && pathOrUrl.isNotEmpty) {
        _subtitleRefreshController.add(pathOrUrl);
      }
    }

    _actionController.add(params);

    _jsonResponse(request.response, {
      'code': 200,
      'msg': 'Action triggered successfully',
      'do': actionDo,
      'type': actionType,
      'path': pathOrUrl,
    });
  }

  void _handleCache(HttpRequest request, Map<String, String> params) {
    final key = params['key'] ?? '';
    final val = params['val'] ?? params['value'];

    if (request.method == 'POST' || val != null) {
      if (key.isNotEmpty) _cacheNamespace[key] = val ?? '';
      _jsonResponse(request.response, {'status': 'saved', 'key': key});
    } else {
      final result = key.isNotEmpty ? _cacheNamespace[key] : _cacheNamespace;
      _jsonResponse(request.response, {'key': key, 'data': result});
    }
  }

  Future<void> _handleProxy(
      HttpRequest request, Map<String, String> params) async {
    final targetUrl = params['url'] ?? '';
    if (targetUrl.isEmpty) {
      _jsonResponse(request.response, {'error': 'Missing url parameter'},
          statusCode: 400);
      return;
    }

    try {
      final resp = await _dio.get(
        targetUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      request.response.statusCode = resp.statusCode ?? 200;
      request.response.add(resp.data);
      await request.response.close();
    } catch (e) {
      _jsonResponse(request.response, {'error': 'Proxy failed: $e'},
          statusCode: 500);
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
