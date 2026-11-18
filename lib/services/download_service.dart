import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../global/storage_bridge.dart';

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
}

class DownloadTask {
  final String id;
  final String vodId;
  final String vodName;
  final String episodeName;
  final String sourceName;
  final String url;
  final Map<String, String> headers;
  final String savePath;
  DownloadStatus status;
  int receivedBytes;
  int totalBytes;
  double speedBytesPerSec;
  String? errorMsg;
  final int createdAt;

  DownloadTask({
    required this.id,
    required this.vodId,
    required this.vodName,
    required this.episodeName,
    required this.sourceName,
    required this.url,
    required this.headers,
    required this.savePath,
    this.status = DownloadStatus.queued,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.errorMsg,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'vodId': vodId,
        'vodName': vodName,
        'episodeName': episodeName,
        'sourceName': sourceName,
        'url': url,
        'headers': headers,
        'savePath': savePath,
        'status': status.name,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'errorMsg': errorMsg,
        'createdAt': createdAt,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status']?.toString() ?? 'paused';
    DownloadStatus st = DownloadStatus.values.firstWhere(
      (e) => e.name == statusStr,
      orElse: () => DownloadStatus.paused,
    );
    // 重启后之前正在下载的置为暂停
    if (st == DownloadStatus.downloading || st == DownloadStatus.queued) {
      st = DownloadStatus.paused;
    }
    final rawHeaders = json['headers'];
    final Map<String, String> hdrs = {};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null) hdrs[k.toString()] = v.toString();
      });
    }
    return DownloadTask(
      id: json['id']?.toString() ?? '',
      vodId: json['vodId']?.toString() ?? '',
      vodName: json['vodName']?.toString() ?? '',
      episodeName: json['episodeName']?.toString() ?? '',
      sourceName: json['sourceName']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      headers: hdrs,
      savePath: json['savePath']?.toString() ?? '',
      status: st,
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      errorMsg: json['errorMsg']?.toString(),
      createdAt: (json['createdAt'] as num?)?.toInt(),
    );
  }
}

/// 应用内高速多线程/断点下载管理器 + 外部 IDM+ 原生拉起桥接
class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  static const MethodChannel _downloaderChannel =
      MethodChannel('com.example.ftv/downloader');
  static const String _storageKey = 'app_download_tasks_v1';

  final ValueNotifier<List<DownloadTask>> tasksNotifier =
      ValueNotifier<List<DownloadTask>>([]);

  final Map<String, CancelToken> _cancelTokens = {};
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(minutes: 30),
    followRedirects: true,
    maxRedirects: 8,
  ));

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final raw = await StorageBridge.getValue(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          tasksNotifier.value = decoded
              .map((e) => DownloadTask.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      }
    } catch (_) {}
  }

  Future<void> _saveTasks() async {
    try {
      final list = tasksNotifier.value.map((t) => t.toJson()).toList();
      await StorageBridge.setValue(_storageKey, jsonEncode(list));
    } catch (_) {}
  }

  void _notify() {
    tasksNotifier.value = List<DownloadTask>.from(tasksNotifier.value);
  }

  String _sanitizeFileName(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _guessExtension(String url) {
    final lower = url.toLowerCase().split('?').first;
    for (final ext in ['.mp4', '.mkv', '.ts', '.flv', '.webm', '.avi', '.mov']) {
      if (lower.endsWith(ext)) return ext;
    }
    if (lower.contains('.m3u8')) return '.ts';
    return '.mp4';
  }

  String _buildDownloadBaseName(String vodName, String episodeName, {bool isMovie = false}) {
    final safeVod = _sanitizeFileName(vodName.isEmpty ? 'FTV' : vodName);
    final safeEp = _sanitizeFileName(episodeName.trim());
    if (isMovie || safeEp.isEmpty || safeEp == safeVod) {
      return safeVod;
    }
    final epLower = safeEp.toLowerCase();
    const movieTags = {'正片', '全集', '高清', '超清', '蓝光', 'hd', '1080p', '4k', 'bd', 'tc', 'ts'};
    if (movieTags.contains(epLower)) {
      return safeVod;
    }
    return '$safeVod - $safeEp';
  }

  Future<String> _buildSavePath(
      String vodName, String episodeName, String url, {bool isMovie = false}) async {
    final safeVod = _sanitizeFileName(vodName.isEmpty ? 'FTV视频' : vodName);
    final baseName = _buildDownloadBaseName(vodName, episodeName, isMovie: isMovie);
    final ext = _guessExtension(url);

    Directory baseDir;
    if (Platform.isAndroid) {
      final publicDl = Directory('/storage/emulated/0/Download/FTV/$safeVod');
      try {
        if (!await publicDl.exists()) {
          await publicDl.create(recursive: true);
        }
        baseDir = publicDl;
      } catch (_) {
        final extDir = await getExternalStorageDirectory();
        baseDir = Directory('${(extDir ?? await getApplicationDocumentsDirectory()).path}/FTV/$safeVod');
      }
    } else {
      final dlDir = await getDownloadsDirectory();
      final root = dlDir ?? await getApplicationDocumentsDirectory();
      baseDir = Directory('${root.path}${Platform.pathSeparator}FTV${Platform.pathSeparator}$safeVod');
    }

    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    return '${baseDir.path}${Platform.pathSeparator}$baseName$ext';
  }

  /// 启动 App 内下载（支持断点续传与自定义请求头）
  Future<DownloadTask> startInAppDownload({
    required String vodId,
    required String vodName,
    required String episodeName,
    required String sourceName,
    required String url,
    required Map<String, String> headers,
    bool isMovie = false,
  }) async {
    await init();
    final taskId = '${vodId}_${sourceName}_$episodeName'.hashCode.abs().toString();
    final existingIdx = tasksNotifier.value.indexWhere((t) => t.id == taskId);
    if (existingIdx >= 0) {
      final existing = tasksNotifier.value[existingIdx];
      if (existing.status == DownloadStatus.completed &&
          File(existing.savePath).existsSync()) {
        return existing;
      }
      // 更新最新直链与请求头并恢复下载
      final updated = DownloadTask(
        id: existing.id,
        vodId: vodId,
        vodName: vodName,
        episodeName: episodeName,
        sourceName: sourceName,
        url: url,
        headers: headers,
        savePath: existing.savePath,
        status: DownloadStatus.downloading,
        receivedBytes: existing.receivedBytes,
        totalBytes: existing.totalBytes,
        createdAt: existing.createdAt,
      );
      tasksNotifier.value[existingIdx] = updated;
      _notify();
      unawaited(_runDownload(updated));
      return updated;
    }

    final savePath = await _buildSavePath(vodName, episodeName, url, isMovie: isMovie);
    final task = DownloadTask(
      id: taskId,
      vodId: vodId,
      vodName: vodName,
      episodeName: episodeName,
      sourceName: sourceName,
      url: url,
      headers: Map<String, String>.from(headers),
      savePath: savePath,
      status: DownloadStatus.downloading,
    );
    tasksNotifier.value.insert(0, task);
    _notify();
    await _saveTasks();
    unawaited(_runDownload(task));
    return task;
  }

  Future<String> _fetchText(String url, Map<String, dynamic> headers, CancelToken token) async {
    final resp = await _dio.get<String>(
      url,
      cancelToken: token,
      options: Options(headers: headers, responseType: ResponseType.plain),
    );
    return resp.data ?? '';
  }

  Future<List<String>> _resolveM3u8Segments(
    String playlistUrl,
    Map<String, dynamic> headers,
    CancelToken token, {
    int depth = 0,
  }) async {
    if (depth > 3) return [];
    final content = await _fetchText(playlistUrl, headers, token);
    final baseUri = Uri.parse(playlistUrl);
    final lines = LineSplitter.split(content)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // 若为主播放列表 (#EXT-X-STREAM-INF)，自动选取最高码率子列表
    if (lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'))) {
      String? bestSubUrl;
      int bestBandwidth = -1;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
          final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
          final bw = int.tryParse(bwMatch?.group(1) ?? '') ?? 0;
          for (int j = i + 1; j < lines.length; j++) {
            if (!lines[j].startsWith('#')) {
              if (bw >= bestBandwidth) {
                bestBandwidth = bw;
                bestSubUrl = baseUri.resolve(lines[j]).toString();
              }
              break;
            }
          }
        }
      }
      if (bestSubUrl != null) {
        return _resolveM3u8Segments(bestSubUrl, headers, token, depth: depth + 1);
      }
    }

    final List<String> segments = [];
    for (final line in lines) {
      if (line.startsWith('#EXT-X-MAP:')) {
        final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (uriMatch != null) {
          segments.add(baseUri.resolve(uriMatch.group(1)!).toString());
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      segments.add(baseUri.resolve(line).toString());
    }
    return segments;
  }

  /// 下载全部 M3U8 切片并合并为单个完整视频文件 (.ts)
  Future<void> _runM3u8Download(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    task.errorMsg = null;
    _notify();

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;
    final segDir = Directory('${task.savePath}.segs');

    try {
      if (!await segDir.exists()) {
        await segDir.create(recursive: true);
      }
      final reqHeaders = Map<String, dynamic>.from(task.headers);
      final segments = await _resolveM3u8Segments(task.url, reqHeaders, cancelToken);
      if (segments.isEmpty) {
        throw Exception('未解析到有效的 M3U8 视频分片');
      }

      final int totalSegs = segments.length;
      int completedSegs = 0;
      int totalDownloadedBytes = 0;
      int lastSpeedBytes = 0;
      DateTime lastSpeedTime = DateTime.now();

      // 4 路并发下载所有分片，支持断点跳过已下载分片
      const int concurrency = 4;
      int nextIdx = 0;

      Future<void> worker() async {
        while (nextIdx < totalSegs && !cancelToken.isCancelled) {
          final idx = nextIdx++;
          final segUrl = segments[idx];
          final segFile = File('${segDir.path}${Platform.pathSeparator}seg_${idx.toString().padLeft(6, "0")}.ts');

          if (await segFile.exists() && await segFile.length() > 0) {
            final len = await segFile.length();
            totalDownloadedBytes += len;
            completedSegs++;
            task.receivedBytes = totalDownloadedBytes;
            task.totalBytes = ((totalDownloadedBytes / completedSegs) * totalSegs).round();
            _notify();
            continue;
          }

          final tmpSeg = File('${segFile.path}.part');
          final resp = await _dio.get<List<int>>(
            segUrl,
            cancelToken: cancelToken,
            options: Options(
              headers: reqHeaders,
              responseType: ResponseType.bytes,
            ),
          );
          final bytes = resp.data ?? const <int>[];
          await tmpSeg.writeAsBytes(bytes, flush: true);
          await tmpSeg.rename(segFile.path);

          completedSegs++;
          totalDownloadedBytes += bytes.length;
          task.receivedBytes = totalDownloadedBytes;
          task.totalBytes = ((totalDownloadedBytes / completedSegs) * totalSegs).round();

          final now = DateTime.now();
          final diffMs = now.difference(lastSpeedTime).inMilliseconds;
          if (diffMs >= 600) {
            task.speedBytesPerSec =
                (totalDownloadedBytes - lastSpeedBytes) / (diffMs / 1000.0);
            lastSpeedBytes = totalDownloadedBytes;
            lastSpeedTime = now;
            _notify();
          }
        }
      }

      await Future.wait(
        List.generate(totalSegs < concurrency ? totalSegs : concurrency, (_) => worker()),
      );

      if (cancelToken.isCancelled) {
        task.status = DownloadStatus.paused;
        task.speedBytesPerSec = 0;
        _notify();
        await _saveTasks();
        return;
      }

      // 顺序合并所有分片为一个完整视频文件
      final outTmp = File('${task.savePath}.merging');
      final sink = outTmp.openWrite(mode: FileMode.write);
      try {
        for (int i = 0; i < totalSegs; i++) {
          final segFile = File('${segDir.path}${Platform.pathSeparator}seg_${i.toString().padLeft(6, "0")}.ts');
          if (await segFile.exists()) {
            await sink.addStream(segFile.openRead());
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      final finalFile = File(task.savePath);
      if (await finalFile.exists()) await finalFile.delete();
      await outTmp.rename(task.savePath);
      try {
        await segDir.delete(recursive: true);
      } catch (_) {}

      task.receivedBytes = await finalFile.length();
      task.totalBytes = task.receivedBytes;
      task.status = DownloadStatus.completed;
      task.speedBytesPerSec = 0;
      _notify();
      await _saveTasks();
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        task.status = DownloadStatus.paused;
      } else if (cancelToken.isCancelled) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.errorMsg = e.toString();
      }
      task.speedBytesPerSec = 0;
      _notify();
      await _saveTasks();
    } finally {
      _cancelTokens.remove(task.id);
    }
  }

  Future<void> _runDownload(DownloadTask task) async {
    if (task.url.toLowerCase().contains('.m3u8')) {
      await _runM3u8Download(task);
      return;
    }
    final tmpPath = '${task.savePath}.tmp';
    final tmpFile = File(tmpPath);
    int startBytes = 0;
    if (await tmpFile.exists()) {
      startBytes = await tmpFile.length();
    }
    task.receivedBytes = startBytes;
    task.status = DownloadStatus.downloading;
    task.errorMsg = null;
    _notify();

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    int lastBytes = startBytes;
    DateTime lastTime = DateTime.now();

    try {
      final reqHeaders = Map<String, dynamic>.from(task.headers);
      if (startBytes > 0) {
        reqHeaders['Range'] = 'bytes=$startBytes-';
      }

      final response = await _dio.get<ResponseBody>(
        task.url,
        cancelToken: cancelToken,
        options: Options(
          headers: reqHeaders,
          responseType: ResponseType.stream,
          validateStatus: (code) => code != null && code >= 200 && code < 400,
        ),
      );

      final isPartial = response.statusCode == 206;
      if (!isPartial && startBytes > 0) {
        startBytes = 0;
        lastBytes = 0;
        if (await tmpFile.exists()) await tmpFile.delete();
      }

      final contentLengthStr = response.headers.value(Headers.contentLengthHeader);
      final contentLen = int.tryParse(contentLengthStr ?? '') ?? 0;
      if (contentLen > 0) {
        task.totalBytes = startBytes + contentLen;
      }

      final sink = tmpFile.openWrite(
        mode: isPartial ? FileMode.append : FileMode.write,
      );

      try {
        await for (final chunk in response.data!.stream) {
          if (cancelToken.isCancelled) break;
          sink.add(chunk);
          task.receivedBytes += chunk.length;

          final now = DateTime.now();
          final diffMs = now.difference(lastTime).inMilliseconds;
          if (diffMs >= 600) {
            final delta = task.receivedBytes - lastBytes;
            task.speedBytesPerSec = delta / (diffMs / 1000.0);
            lastBytes = task.receivedBytes;
            lastTime = now;
            _notify();
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (!cancelToken.isCancelled) {
        final finalFile = File(task.savePath);
        if (await finalFile.exists()) await finalFile.delete();
        await tmpFile.rename(task.savePath);
        task.status = DownloadStatus.completed;
        task.speedBytesPerSec = 0;
        if (task.totalBytes <= 0) task.totalBytes = task.receivedBytes;
        _notify();
        await _saveTasks();
      }
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        task.status = DownloadStatus.paused;
      } else if (cancelToken.isCancelled) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.errorMsg = e.toString();
      }
      task.speedBytesPerSec = 0;
      _notify();
      await _saveTasks();
    } finally {
      _cancelTokens.remove(task.id);
    }
  }

  Future<void> pauseTask(String taskId) async {
    final token = _cancelTokens[taskId];
    if (token != null && !token.isCancelled) {
      token.cancel('paused');
    }
    final idx = tasksNotifier.value.indexWhere((t) => t.id == taskId);
    if (idx >= 0) {
      tasksNotifier.value[idx].status = DownloadStatus.paused;
      tasksNotifier.value[idx].speedBytesPerSec = 0;
      _notify();
      await _saveTasks();
    }
  }

  Future<void> resumeTask(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading) return;
    unawaited(_runDownload(task));
  }

  Future<void> deleteTask(String taskId, {bool deleteFile = true}) async {
    await pauseTask(taskId);
    final idx = tasksNotifier.value.indexWhere((t) => t.id == taskId);
    if (idx >= 0) {
      final task = tasksNotifier.value[idx];
      if (deleteFile) {
        try {
          final f = File(task.savePath);
          if (await f.exists()) await f.delete();
          final tmp = File('${task.savePath}.tmp');
          if (await tmp.exists()) await tmp.delete();
          final segDir = Directory('${task.savePath}.segs');
          if (await segDir.exists()) await segDir.delete(recursive: true);
        } catch (_) {}
      }
      tasksNotifier.value.removeAt(idx);
      _notify();
      await _saveTasks();
    }
  }

  /// 调用 Android 外部 IDM+ / 1DM+ 下载（完整透传 User-Agent / Cookie / Referer 等请求头）
  Future<({bool ok, String? message})> launchIdmPlus({
    required String url,
    required String vodName,
    required String episodeName,
    required Map<String, String> headers,
    bool isMovie = false,
  }) async {
    if (!Platform.isAndroid) {
      return (ok: false, message: 'IDM+ 外部拉起仅支持 Android 端，桌面端请使用 App 内下载');
    }
    final baseName = _buildDownloadBaseName(vodName, episodeName, isMovie: isMovie);
    final ext = _guessExtension(url);
    final filename = '$baseName$ext';

    try {
      final res = await _downloaderChannel.invokeMethod<dynamic>('launchIdmPlus', {
        'url': url,
        'filename': filename,
        'headers': headers,
      });
      if (res is Map) {
        final ok = res['ok'] == true;
        final pkg = res['package']?.toString();
        final err = res['error']?.toString();
        if (ok) {
          return (ok: true, message: '已携带请求头拉起下载器 ($pkg)');
        }
        return (ok: false, message: err ?? '未能拉起 1DM+ / IDM+');
      }
      return (ok: false, message: '拉起 1DM+ / IDM+ 返回异常');
    } catch (e) {
      return (ok: false, message: '调用 1DM+ / IDM+ 异常: $e');
    }
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toInt()} KB';
    }
    return '$bytes B';
  }
}
