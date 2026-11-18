import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'app_logger.dart';
import 'js_engine_service.dart';
import 'iso_parser_service.dart';

/// 局域网/本地内置 HTTP 服务 (NanoHTTPD 规范)
/// 端口由 9978 依次尝试绑定，支持 /device, /media, /action, /cache, /proxy 端点
/// 兼容 OK 影视与 FongMi JS 扩展（如 PanUtils.js）触发的弹幕/字幕刷新与控制指令
class LocalHttpServer {
  static final LocalHttpServer _instance = LocalHttpServer._internal();
  factory LocalHttpServer() => _instance;
  LocalHttpServer._internal();

  HttpServer? _server;
  int _port = 9978;
  String _lanIp = '127.0.0.1';
  int get port => _port;
  String get hostIp => _lanIp;
  String get baseUrl => 'http://$_lanIp:$_port';
  bool get isRunning => _server != null;

  Future<String> resolveLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? fallback;
      for (final iface in interfaces) {
        final nameLower = iface.name.toLowerCase();
        if (nameLower.contains('virtual') ||
            nameLower.contains('vmware') ||
            nameLower.contains('vbox') ||
            nameLower.contains('wsl') ||
            nameLower.contains('vethernet') ||
            nameLower.contains('hyper-v') ||
            nameLower.contains('bluetooth')) {
          continue;
        }
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.') || ip.startsWith('127.')) continue;
          if (ip.startsWith('192.168.')) {
            _lanIp = ip;
            return _lanIp;
          }
          if (ip.startsWith('10.') || ip.startsWith('172.')) {
            fallback ??= ip;
            continue;
          }
          fallback ??= ip;
        }
      }
      if (fallback != null) {
        _lanIp = fallback;
      }
    } catch (_) {}
    return _lanIp;
  }

  final Map<String, String> _cacheNamespace = {};
  final Map<String, Map<String, dynamic>> _streamRoutes = {};
  int _streamSeq = 0;
  final Map<String, Map<String, dynamic>> _isoRoutes = {};
  int _isoSeq = 0;

  /// 注册 ISO 虚拟流媒体路由，将 UDF/ISO9660 内部正片分片映射为标准可拖拽 HTTP Range 流
  String registerIsoStreamProxy(
    IsoStreamEntry entry,
    String sourceUrl,
    Map<String, String> headers, {
    String discType = 'ISO',
  }) {
    final id = (++_isoSeq).toString();
    _isoRoutes[id] = {
      'entry': entry,
      'url': sourceUrl,
      'headers': Map<String, String>.from(headers),
      'discType': discType,
    };
    if (_isoRoutes.length > 100) {
      _isoRoutes.remove(_isoRoutes.keys.first);
    }
    final safeName = entry.name
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]+'), '_')
        .trim();
    final encoded = Uri.encodeComponent(safeName.isNotEmpty ? safeName : 'movie.m2ts');
    final host = Platform.isWindows ? '127.0.0.1' : _lanIp;
    return 'http://$host:$_port/iso_stream/$encoded?id=$id';
  }

  /// 注册带自定义请求头（Cookie / User-Agent / Referer）的本地流媒体代理，规避 mpv 对逗号和长 Cookie 的解析问题
  String registerStreamProxy(String url, Map<String, String> headers, {String? title}) {
    final id = (++_streamSeq).toString();
    final safeTitle = (title ?? '')
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final lower = url.toLowerCase();
    final ext = lower.contains('.m3u8')
        ? '.m3u8'
        : (lower.contains('.mkv')
            ? '.mkv'
            : (lower.contains('.flv')
                ? '.flv'
                : (lower.contains('.iso') ? '.iso' : '.mp4')));
    _streamRoutes[id] = {
      'url': url,
      'headers': Map<String, String>.from(headers),
      'filename': safeTitle.isNotEmpty ? '$safeTitle$ext' : '',
    };
    if (_streamRoutes.length > 500) {
      _streamRoutes.remove(_streamRoutes.keys.first);
    }
    final host = Platform.isWindows ? '127.0.0.1' : _lanIp;
    if (safeTitle.isNotEmpty) {
      final encodedName = Uri.encodeComponent(safeTitle);
      return 'http://$host:$_port/stream/$encodedName$ext?id=$id';
    }
    return 'http://$host:$_port/stream$ext?id=$id';
  }
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (status) => status != null && status < 500,
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final c = HttpClient();
        c.badCertificateCallback = (_, __, ___) => true;
        return c;
      },
    );

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
    await resolveLanIp();
    if (_server != null) return _port;

    for (int p = 9978; p <= 9995; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _port = p;
        print('🚀 [HTTP-SERVER] 本地服务成功启动: http://$_lanIp:$_port');
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
          await _handleCache(request, params);
        } else if (path == '/proxy') {
          await _handleProxy(request, params);
        } else if (path.startsWith('/iso_stream')) {
          await _handleIsoStream(request, params);
        } else if (path.startsWith('/stream')) {
          await _handleStream(request, params);
        } else if (path == '/logs') {
          _handleLogsPage(request);
        } else if (path == '/logs/raw') {
          _handleLogsRaw(request, params);
        } else if (path == '/logs/clear') {
          _handleLogsClear(request);
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


  void _handleLogsPage(HttpRequest request) {
    if (!AppLogger.webDebugEnabled) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!DOCTYPE html><html><meta charset="utf-8"><body style="background:#111;color:#eee;font-family:sans-serif;padding:32px;"><h3>网页调试日志未开启</h3><p>请在 App「设置 -> 网页调试日志」中开启后再访问。</p></body></html>',
      );
      request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.html;
    request.response.write(r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FTV 实时运行日志</title>
<style>
  body { margin:0; background:#0f1117; color:#e6edf3; font-family:ui-monospace,SFMono-Regular,Consolas,monospace; }
  header { position:sticky; top:0; background:#161b22; border-bottom:1px solid #30363d; padding:10px 14px; display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  h1 { font-size:14px; margin:0 8px 0 0; color:#58a6ff; }
  input { background:#0d1117; color:#e6edf3; border:1px solid #30363d; border-radius:6px; padding:5px 10px; font-size:12px; width:180px; }
  button, a.btn { background:#21262d; color:#e6edf3; border:1px solid #30363d; border-radius:6px; padding:5px 10px; font-size:12px; cursor:pointer; text-decoration:none; }
  button:hover, a.btn:hover { background:#30363d; }
  #log { padding:12px 14px; white-space:pre-wrap; word-break:break-all; font-size:12px; line-height:1.5; }
</style>
</head>
<body>
<header>
  <h1>FTV 运行日志</h1>
  <input id="kw" placeholder="正则/关键字过滤 (如: flutter|com)..." oninput="render()">
  <button id="pauseBtn" onclick="togglePause()">暂停刷新</button>
  <button onclick="clearLogs()">清空</button>
  <a class="btn" href="/logs/raw?download=1" download="ftv.log">下载日志</a>
</header>
<div id="log">加载中...</div>
<script>
let paused = false, rawLines = [];
function togglePause() {
  paused = !paused;
  document.getElementById("pauseBtn").innerText = paused ? "恢复刷新" : "暂停刷新";
}
function render() {
  const kw = document.getElementById("kw").value.trim();
  let list = rawLines;
  if (kw) {
    try {
      const re = new RegExp(kw, "i");
      list = rawLines.filter(l => re.test(l));
    } catch (e) {
      const low = kw.toLowerCase();
      list = rawLines.filter(l => l.toLowerCase().includes(low));
    }
  }
  const el = document.getElementById("log");
  const atBottom = (window.innerHeight + window.scrollY) >= (document.body.offsetHeight - 60);
  el.textContent = list.join("\n") || "(暂无日志)";
  if (atBottom && !paused) window.scrollTo(0, document.body.scrollHeight);
}
async function fetchLogs() {
  if (paused) return;
  try {
    const r = await fetch("/logs/raw");
    if (!r.ok) { document.getElementById("log").textContent = "日志未开启或请求失败 (" + r.status + ")"; return; }
    const txt = await r.text();
    rawLines = txt ? txt.split("\n") : [];
    render();
  } catch (e) {}
}
async function clearLogs() {
  await fetch("/logs/clear");
  rawLines = [];
  render();
}
fetchLogs();
setInterval(fetchLogs, 2000);
</script>
</body>
</html>''');
    request.response.close();
  }

  void _handleLogsRaw(HttpRequest request, Map<String, String> params) {
    if (!AppLogger.webDebugEnabled) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('Web debug log is disabled.');
      request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.text;
    if (params['download'] == '1') {
      request.response.headers.set(
        'Content-Disposition',
        'attachment; filename="ftv.log"',
      );
    }
    request.response.write(AppLogger.getRecentLogs().join('\n'));
    request.response.close();
  }

  void _handleLogsClear(HttpRequest request) {
    if (!AppLogger.webDebugEnabled) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.close();
      return;
    }
    AppLogger.clear();
    _jsonResponse(request.response, {'ok': true});
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

    final subTarget = pathOrUrl.isNotEmpty
        ? pathOrUrl
        : (params['sub'] ?? params['subtitle'] ?? '');
    if (actionDo == 'refresh') {
      if (actionType == 'danmaku' && pathOrUrl.isNotEmpty) {
        _danmakuRefreshController.add(pathOrUrl);
      } else if ((actionType == 'subtitle' || actionType == 'sub') &&
          subTarget.isNotEmpty) {
        _subtitleRefreshController.add(subTarget);
      }
    } else if ((actionDo == 'subtitle' || actionDo == 'sub') &&
        subTarget.isNotEmpty) {
      _subtitleRefreshController.add(subTarget);
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

  Future<void> _handleCache(HttpRequest request, Map<String, String> params) async {
    final key = params['key'] ?? '';
    String? val = params['val'] ?? params['value'];

    if (request.method == 'POST' && val == null) {
      try {
        val = await utf8.decoder.bind(request).join();
      } catch (_) {}
    }

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
    if (params['do'] == 'js' || (params['siteKey'] ?? '').isNotEmpty) {
      try {
        final js = JsEngineService.currentInstance;
        if (js != null && js.isInitialized) {
          final reqHdrs = <String, String>{};
          request.headers.forEach((name, values) {
            if (values.isNotEmpty) reqHdrs[name] = values.join(', ');
          });
          final jsParams = <String, dynamic>{
            ...params,
            'client': 'ftv',
            'header': reqHdrs,
          };
          final res = await js.callMethod(
            'proxy',
            [jsParams],
            params['siteKey'] ?? params['key'],
          );
          if (res is Map && (res['url'] ?? '').toString().isNotEmpty) {
            final u = res['url'].toString();
            final hdrs = <String, String>{};
            final rawH = res['header'] ?? res['headers'];
            if (rawH is Map) {
              rawH.forEach((k, v) {
                if (v != null) hdrs[k.toString()] = v.toString();
              });
            }
            final sid = registerStreamProxy(u, hdrs).split('id=').last;
            await _handleStream(request, {'id': sid});
            return;
          }
          if (res is List && res.length >= 3) {
            final resHdrs = <String, String>{};
            if (res.length > 3 && res[3] is Map) {
              (res[3] as Map).forEach((k, v) {
                if (v != null) resHdrs[k.toString()] = v.toString();
              });
            }
            final locUrl = resHdrs['Location'] ?? resHdrs['location'] ?? '';
            final hasAuthHdr = resHdrs.keys.any((k) {
              final lk = k.toLowerCase();
              return lk == 'cookie' || lk == 'referer' || lk == 'user-agent' || lk == 'authorization';
            });
            if (locUrl.isNotEmpty && hasAuthHdr) {
              resHdrs.remove('Location');
              resHdrs.remove('location');
              final sid = registerStreamProxy(locUrl, resHdrs).split('id=').last;
              await _handleStream(request, {'id': sid});
              return;
            }
            final code = int.tryParse(res[0]?.toString() ?? '200') ?? 200;
            final ct = res[1]?.toString() ?? 'application/octet-stream';
            final body = res[2];
            request.response.statusCode = code;
            request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
            if (res.length > 3 && res[3] is Map) {
              (res[3] as Map).forEach((k, v) {
                if (v != null) {
                  request.response.headers.set(k.toString(), v.toString());
                }
              });
            }
            final isBase64 = (res.length > 4 && (res[4] == 1 || res[4] == true)) ||
                ct.startsWith('image/');
            if (body is List<int>) {
              request.response.add(body);
            } else if (body != null) {
              final str = body.toString();
              if (isBase64 && str.isNotEmpty) {
                try {
                  request.response.add(base64Decode(str));
                } catch (_) {
                  request.response.write(str);
                }
              } else {
                request.response.write(str);
              }
            }
            await request.response.close();
            return;
          }
        }
      } catch (e) {
        print('❌ [HTTP-PROXY] JS proxy 执行失败: $e');
      }
    }

    final targetUrl = params['url'] ?? '';
    if (targetUrl.isEmpty) {
      _jsonResponse(request.response, {'error': 'Missing url parameter'},
          statusCode: 400);
      return;
    }

    final reqHeaders = <String, dynamic>{};
    final rawHeaders = params['headers'];
    if (rawHeaders != null && rawHeaders.trim().isNotEmpty) {
      try {
        String decoded = rawHeaders.trim();
        if (!decoded.startsWith('{')) {
          decoded = utf8.decode(base64Decode(decoded));
        }
        final map = jsonDecode(decoded);
        if (map is Map) {
          map.forEach((k, v) {
            if (v != null) reqHeaders[k.toString()] = v.toString();
          });
        }
      } catch (_) {}
    }
    reqHeaders.putIfAbsent(
      'User-Agent',
      () => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    );

    try {
      final resp = await _dio.get<List<int>>(
        targetUrl,
        options: Options(
          headers: reqHeaders,
          responseType: ResponseType.bytes,
        ),
      );
      final code = resp.statusCode ?? 200;
      if (code >= 400) {
        print('❌ [HTTP-PROXY] 请求异常 Status=$code, url=$targetUrl');
      }
      request.response.statusCode = code;
      final ct = resp.headers.value(HttpHeaders.contentTypeHeader);
      if (ct != null && ct.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
      }
      if (resp.data != null) {
        request.response.add(resp.data!);
      }
      await request.response.close();
    } catch (e) {
      print('❌ [HTTP-PROXY] 代理异常: $e (url=$targetUrl)');
      _jsonResponse(request.response, {'error': 'Proxy failed: $e'},
          statusCode: 500);
    }
  }


  Future<void> _handleStream(
      HttpRequest request, Map<String, String> params) async {
    final id = params['id'] ?? '';
    final entry = _streamRoutes[id];
    if (entry == null) {
      _jsonResponse(request.response, {'error': 'Stream not found'},
          statusCode: 404);
      return;
    }

    final targetUrl = entry['url'] as String;
    final customHeaders = Map<String, String>.from(entry['headers'] as Map);

    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15)
      ..badCertificateCallback = (cert, host, port) => true;
    client.userAgent = null;

    try {
      final upstreamReq = await client.openUrl(request.method, Uri.parse(targetUrl));
      customHeaders.forEach((k, v) {
        if (k.trim().isNotEmpty && v.isNotEmpty) {
          upstreamReq.headers.set(k.trim(), v);
        }
      });

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }

      final upstreamResp = await upstreamReq.close();
      request.response.statusCode = upstreamResp.statusCode;

      final copyHeaders = [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
      ];
      for (final h in copyHeaders) {
        final val = upstreamResp.headers.value(h);
        if (val != null && val.isNotEmpty) {
          request.response.headers.set(h, val);
        }
      }

      final contentTypeStr =
          upstreamResp.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ?? '';
      final isM3u8 = targetUrl.toLowerCase().contains('.m3u8') ||
          contentTypeStr.contains('mpegurl');

      if (request.method == 'HEAD') {
        await request.response.close();
      } else if (isM3u8 && upstreamResp.statusCode == 200) {
        final bytes = await upstreamResp.fold<List<int>>([], (acc, c) => acc..addAll(c));
        final rawText = utf8.decode(bytes, allowMalformed: true);
        final baseUri = Uri.parse(targetUrl);
        final rewritten = rawText.split('\n').map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;
          if (trimmed.startsWith('#')) {
            return line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (m) {
              final absUri = baseUri.resolve(m.group(1)!).toString();
              final proxied = registerStreamProxy(absUri, customHeaders);
              return 'URI="$proxied"';
            });
          }
          final absUri = baseUri.resolve(trimmed).toString();
          return registerStreamProxy(absUri, customHeaders);
        }).join('\n');
        final outBytes = utf8.encode(rewritten);
        request.response.headers.set(HttpHeaders.contentLengthHeader, outBytes.length.toString());
        request.response.add(outBytes);
        await request.response.close();
      } else {
        await request.response.addStream(upstreamResp);
        await request.response.close();
      }
    } catch (e) {
      try {
        if (request.response.headers.contentType == null) {
          _jsonResponse(request.response, {'error': 'Stream proxy failed: $e'},
              statusCode: 502);
        } else {
          await request.response.close();
        }
      } catch (_) {}
    } finally {
      client.close(force: false);
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleIsoStream(
      HttpRequest request, Map<String, String> params) async {
    final id = params['id'] ?? '';
    final route = _isoRoutes[id];
    if (route == null) {
      _jsonResponse(request.response, {'error': 'ISO stream not found'},
          statusCode: 404);
      return;
    }

    final entry = route['entry'] as IsoStreamEntry;
    final sourceUrl = route['url'] as String;
    final customHeaders = Map<String, String>.from(route['headers'] as Map);
    final totalSize = entry.totalSize;

    final ext = entry.ext;
    final mime = (ext == '.m2ts' || ext == '.mts' || ext == '.ts')
        ? 'video/mp2t'
        : (ext == '.vob' || ext == '.mpg' || ext == '.mpeg')
            ? 'video/mpeg'
            : (ext == '.mkv' ? 'video/x-matroska' : 'video/mp4');

    int start = 0;
    int end = totalSize - 1;
    bool isPartial = false;

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      isPartial = true;
      final spec = rangeHeader.substring(6).split(',').first.trim();
      final parts = spec.split('-');
      if (parts.length == 2) {
        if (parts[0].isEmpty && parts[1].isNotEmpty) {
          final suffix = int.tryParse(parts[1]) ?? 0;
          start = (totalSize - suffix).clamp(0, totalSize - 1);
          end = totalSize - 1;
        } else {
          start = int.tryParse(parts[0]) ?? 0;
          end = parts[1].isNotEmpty ? (int.tryParse(parts[1]) ?? (totalSize - 1)) : (totalSize - 1);
        }
      }
    }

    if (start < 0) start = 0;
    if (end >= totalSize) end = totalSize - 1;
    if (start >= totalSize || end < start) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalSize');
      await request.response.close();
      return;
    }

    final contentLength = end - start + 1;
    request.response.statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set(HttpHeaders.contentTypeHeader, mime);
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
    if (isPartial) {
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalSize');
    }

    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }

    final isHttp = sourceUrl.startsWith('http://') || sourceUrl.startsWith('https://');
    RandomAccessFile? raf;
    HttpClient? client;

    try {
      if (!isHttp) {
        final localPath = sourceUrl.startsWith('file://')
            ? Uri.parse(sourceUrl).toFilePath()
            : sourceUrl;
        raf = await File(localPath).open(mode: FileMode.read);
      } else {
        client = HttpClient()
          ..autoUncompress = false
          ..connectionTimeout = const Duration(seconds: 15)
          ..badCertificateCallback = (cert, host, port) => true;
        client.userAgent = null;
      }

      int virtualCursor = 0;
      for (final extent in entry.extents) {
        final extStart = virtualCursor;
        final extEnd = virtualCursor + extent.length - 1;
        virtualCursor += extent.length;

        if (extEnd < start) continue;
        if (extStart > end) break;

        final overlapStart = start > extStart ? start : extStart;
        final overlapEnd = end < extEnd ? end : extEnd;
        final isoOffset = extent.offset + (overlapStart - extStart);
        final chunkLen = overlapEnd - overlapStart + 1;

        if (raf != null) {
          await raf.setPosition(isoOffset);
          int remaining = chunkLen;
          while (remaining > 0) {
            final toRead = remaining > 65536 ? 65536 : remaining;
            final bytes = await raf.read(toRead);
            if (bytes.isEmpty) break;
            request.response.add(bytes);
            remaining -= bytes.length;
          }
        } else if (client != null) {
          final upstreamReq = await client.openUrl('GET', Uri.parse(sourceUrl));
          customHeaders.forEach((k, v) {
            if (k.trim().isNotEmpty && v.isNotEmpty) {
              upstreamReq.headers.set(k.trim(), v);
            }
          });
          upstreamReq.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=$isoOffset-${isoOffset + chunkLen - 1}',
          );
          final upstreamResp = await upstreamReq.close();
          if (upstreamResp.statusCode != 200 && upstreamResp.statusCode != 206) {
            await upstreamResp.drain<void>();
            break;
          }
          await for (final data in upstreamResp) {
            request.response.add(data);
          }
        }
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
      try {
        await raf?.close();
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

}
