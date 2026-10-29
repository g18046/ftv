import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../models/danmaku_model.dart';

/// LogVar 在线弹幕源模型（小白弹幕规范：先展示弹幕源，再展示每个弹幕源下的所有剧集）
class LogVarAnimeSource {
  final int animeId;
  final String animeTitle;
  final String typeDescription;
  final List<LogVarEpisode> episodes;

  LogVarAnimeSource({
    required this.animeId,
    required this.animeTitle,
    required this.typeDescription,
    required this.episodes,
  });
}

/// LogVar 弹幕源下的具体剧集模型
class LogVarEpisode {
  final int episodeId;
  final String episodeTitle;

  LogVarEpisode({
    required this.episodeId,
    required this.episodeTitle,
  });
}

class DanmakuService {
  static final DanmakuService _instance = DanmakuService._internal();
  factory DanmakuService() => _instance;
  DanmakuService._internal();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    ),
  );

  DanmakuConfig _config = DanmakuConfig();
  DanmakuConfig get config => _config;

  File? _configFile;
  bool _isConfigLoaded = false;

  /// 初始化并加载配置
  Future<DanmakuConfig> initConfig() async {
    if (_isConfigLoaded) return _config;
    try {
      final dir = await getApplicationSupportDirectory();
      _configFile = File('${dir.path}/ftv_danmaku_config.json');
      if (await _configFile!.exists()) {
        final content = await _configFile!.readAsString();
        if (content.trim().isNotEmpty) {
          final json = jsonDecode(content);
          if (json is Map<String, dynamic>) {
            _config = DanmakuConfig.fromJson(json);
          }
        }
      }
    } catch (e) {
      print('⚠️ 加载弹幕配置异常: $e');
    }
    _isConfigLoaded = true;
    return _config;
  }

  /// 保存弹幕设置
  Future<void> saveConfig(DanmakuConfig newConfig) async {
    _config = newConfig;
    try {
      if (_configFile == null) {
        final dir = await getApplicationSupportDirectory();
        _configFile = File('${dir.path}/ftv_danmaku_config.json');
      }
      await _configFile!
          .writeAsString(jsonEncode(_config.toJson()), flush: true);
    } catch (e) {
      print('⚠️ 保存弹幕配置异常: $e');
    }
  }

  /// 测试与 LogVar 弹幕服务器的联通性
  Future<bool> testConnection([String? customUrl]) async {
    final server =
        (customUrl ?? _config.serverUrl).trim().replaceAll(RegExp(r'/+$'), '');
    if (server.isEmpty) return false;
    try {
      final resp = await _dio.get(server);
      return resp.statusCode != null && resp.statusCode! < 500;
    } catch (e) {
      try {
        final resp2 =
            await _dio.get('$server/api/v2/search/episodes?anime=测试');
        return resp2.statusCode != null && resp2.statusCode! < 500;
      } catch (_) {
        return false;
      }
    }
  }

  /// 智能清理并提取纯净的剧名与集数
  (String, String) sanitizeVodNameAndEpisode(
      String rawVodName, String rawEpisodeName) {
    String name = rawVodName
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'\(.*?\d{4}.*?\)'), '')
        .replaceAll(RegExp(r'（.*?\d{4}.*?）'), '')
        .replaceAll(
            RegExp(r'4K|1080P|720P|HD|BD|国语|粤语|中字|无删减|未删减', caseSensitive: false),
            '')
        .trim();

    String ep = rawEpisodeName.trim();
    final match = RegExp(r'(\d+)').firstMatch(ep);
    if (match != null) {
      final numStr = match.group(1);
      if (numStr != null) {
        ep = int.tryParse(numStr)?.toString() ?? numStr;
      }
    } else {
      ep = ep.replaceAll(RegExp(r'[第集话期]'), '').trim();
    }

    return (name, ep);
  }

  /// 从 LogVar 服务器拉取指定影视与剧集的弹幕
  Future<List<DanmakuItem>> fetchDanmaku({
    required String vodName,
    required String episodeName,
    String? playUrl,
  }) async {
    if (!_config.enabled) return [];

    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (server.isEmpty) return [];

    final (cleanName, cleanEp) =
        sanitizeVodNameAndEpisode(vodName, episodeName);
    print('🎯 正在请求 LogVar 弹幕: [$cleanName] 第[$cleanEp]集, 服务器: $server');

    final candidateUrls = [
      '$server/danmaku/api/v2/fongmi/danmaku?name=${Uri.encodeComponent(cleanName)}&episode=${Uri.encodeComponent(cleanEp)}',
      '$server/api/v2/fongmi/danmaku?name=${Uri.encodeComponent(cleanName)}&episode=${Uri.encodeComponent(cleanEp)}',
      '$server/danmaku?name=${Uri.encodeComponent(cleanName)}&episode=${Uri.encodeComponent(cleanEp)}',
    ];

    if (playUrl != null && playUrl.isNotEmpty && playUrl.startsWith('http')) {
      candidateUrls.add(
          '$server/api/v2/comment?url=${Uri.encodeComponent(playUrl)}&format=json');
    }

    for (final url in candidateUrls) {
      try {
        final resp = await _dio.get(url);
        if (resp.statusCode == 200 && resp.data != null) {
          final items = _parseDanmakuResponse(resp.data);
          if (items.isNotEmpty) {
            print('✅ 成功拉取到 ${items.length} 条弹幕！(源: $url)');
            return items;
          }
        }
      } catch (_) {}
    }

    print('ℹ️ 未能从 LogVar 接口找到对应弹幕');
    return [];
  }

  /// 参考【小白弹幕】：搜索并返回弹幕源列表，每个弹幕源包含其所有的剧集列表
  Future<List<LogVarAnimeSource>> searchLogVarAnimes(String keyword) async {
    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (server.isEmpty || keyword.trim().isEmpty) return [];

    final candidateUrls = [
      '$server/api/v2/search/episodes?anime=${Uri.encodeComponent(keyword)}',
      '$server/danmaku/api/v2/search/episodes?anime=${Uri.encodeComponent(keyword)}',
    ];

    for (final url in candidateUrls) {
      try {
        final resp = await _dio.get(url);
        if (resp.statusCode == 200 && resp.data != null) {
          final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
          if (data is Map && data['animes'] is List) {
            final List<LogVarAnimeSource> result = [];
            for (final item in data['animes']) {
              if (item is Map) {
                final animeId = (item['animeId'] as num?)?.toInt() ?? 0;
                final animeTitle = item['animeTitle']?.toString() ?? keyword;
                final typeDesc = item['typeDescription']?.toString() ?? '动漫';
                final epsList = <LogVarEpisode>[];

                if (item['episodes'] is List) {
                  for (final ep in item['episodes']) {
                    if (ep is Map) {
                      final epId = (ep['episodeId'] as num?)?.toInt() ?? 0;
                      final epTitle = ep['episodeTitle']?.toString() ?? '';
                      if (epId > 0) {
                        epsList.add(LogVarEpisode(
                          episodeId: epId,
                          episodeTitle: epTitle,
                        ));
                      }
                    }
                  }
                }

                if (epsList.isNotEmpty) {
                  result.add(LogVarAnimeSource(
                    animeId: animeId,
                    animeTitle: animeTitle,
                    typeDescription: typeDesc,
                    episodes: epsList,
                  ));
                }
              }
            }
            if (result.isNotEmpty) return result;
          }
        }
      } catch (e) {
        print('⚠️ LogVar 动漫源搜索异常: $e');
      }
    }
    return [];
  }

  /// 根据 LogVar episodeId 直接获取弹幕
  Future<List<DanmakuItem>> fetchDanmakuByEpisodeId(int episodeId) async {
    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (server.isEmpty || episodeId <= 0) return [];

    final candidateUrls = [
      '$server/api/v2/comment/$episodeId?withRelated=true',
      '$server/danmaku/api/v2/comment/$episodeId?withRelated=true',
    ];

    for (final url in candidateUrls) {
      try {
        final resp = await _dio.get(url);
        if (resp.statusCode == 200 && resp.data != null) {
          final items = _parseDanmakuResponse(resp.data);
          if (items.isNotEmpty) return items;
        }
      } catch (_) {}
    }
    return [];
  }

  /// 从远程 URL 或本地文件路径强行刷新解析弹幕 (如 PanUtils.js 刷新的弹幕)
  Future<List<DanmakuItem>> fetchDanmakuFromUrl(String pathOrUrl) async {
    final clean = pathOrUrl.trim();
    if (clean.isEmpty) return [];

    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      try {
        final resp = await _dio.get(clean);
        if (resp.statusCode == 200 && resp.data != null) {
          return _parseDanmakuResponse(resp.data);
        }
      } catch (e) {
        print('⚠️ 从 URL 拉取弹幕失败: $e');
      }
    } else {
      try {
        final f = File(clean);
        if (await f.exists()) {
          final content = await f.readAsString();
          return _parseDanmakuResponse(content);
        }
      } catch (e) {
        print('⚠️ 从本地文件读取弹幕失败: $e');
      }
    }
    return [];
  }

  /// 发送/推送弹幕到 LogVar 服务器
  Future<bool> sendDanmaku({
    required String vodName,
    required String episodeName,
    int? episodeId,
    required double time,
    required String text,
    Color color = Colors.white,
    DanmakuType type = DanmakuType.scroll,
  }) async {
    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (server.isEmpty || text.trim().isEmpty) return false;

    int mode = 1;
    if (type == DanmakuType.top) mode = 5;
    if (type == DanmakuType.bottom) mode = 4;

    final colorVal = (color.toARGB32() & 0xFFFFFF);

    final payload = {
      'time': double.parse(time.toStringAsFixed(2)),
      'mode': mode,
      'color': colorVal,
      'comment': text.trim(),
      'text': text.trim(),
      'name': vodName,
      'episode': episodeName,
    };

    final candidateUrls = [
      if (episodeId != null && episodeId > 0)
        '$server/api/v2/comment/$episodeId',
      '$server/api/v2/comment',
      '$server/danmaku/api/v2/comment',
      '$server/danmaku/post',
    ];

    for (final url in candidateUrls) {
      try {
        final resp = await _dio.post(
          url,
          data: jsonEncode(payload),
          options: Options(headers: {'Content-Type': 'application/json'}),
        );
        if (resp.statusCode != null && resp.statusCode! < 300) {
          print('✅ 弹幕发送成功: [$text] -> $url');
          return true;
        }
      } catch (e) {
        print('⚠️ 尝试推送弹幕到 $url 失败: $e');
      }
    }

    return false;
  }

  /// 解析各类不同弹幕格式
  List<DanmakuItem> _parseDanmakuResponse(dynamic data) {
    List<DanmakuItem> results = [];

    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          data = jsonDecode(trimmed);
        } catch (_) {}
      } else if (trimmed.contains('<d p="')) {
        return _parseXmlDanmaku(trimmed);
      }
    }

    if (data is Map) {
      final list = data['danmaku'] ??
          data['danmus'] ??
          data['comments'] ??
          data['data'] ??
          data['result'];
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            if (item.containsKey('p') && item.containsKey('m')) {
              results.add(DanmakuItem.fromPString(
                  item['p'].toString(), item['m'].toString()));
            } else {
              results.add(DanmakuItem.fromJson(item));
            }
          } else if (item is List && item.length >= 2) {
            final t = (item[0] as num?)?.toDouble() ?? 0.0;
            final m = item[1]?.toString() ?? '';
            results.add(DanmakuItem(time: t, text: m));
          }
        }
      }
    } else if (data is List) {
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          if (item.containsKey('p') && item.containsKey('m')) {
            results.add(DanmakuItem.fromPString(
                item['p'].toString(), item['m'].toString()));
          } else {
            results.add(DanmakuItem.fromJson(item));
          }
        }
      }
    }

    results.sort((a, b) => a.time.compareTo(b.time));
    return results;
  }

  List<DanmakuItem> _parseXmlDanmaku(String xml) {
    final List<DanmakuItem> list = [];
    final regex = RegExp(r'<d\s+p="([^"]+)">([^<]+)<\/d>');
    for (final match in regex.allMatches(xml)) {
      final p = match.group(1);
      final text = match.group(2);
      if (p != null && text != null) {
        list.add(DanmakuItem.fromPString(p, text));
      }
    }
    list.sort((a, b) => a.time.compareTo(b.time));
    return list;
  }
}
