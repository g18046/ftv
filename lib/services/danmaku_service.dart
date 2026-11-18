import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.idleTimeout = const Duration(seconds: 15);
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        return client;
      },
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

  /// 智能清理并提取纯净的剧名关键词 (按需求：截取名称前面字符，过滤后面的空格、逗号、-、)、(等非文字字符)
  String sanitizeVodName(String rawVodName) {
    String name = rawVodName.trim();

    // 1. 去除开头的方括号、角标或标签，如 [4K]、[超清]、【独播】等
    name = name.replaceAll(RegExp(r'^[\[【\(（].*?[\]】\)）]'), '').trim();

    // 2. 移除常见的画质、版本词汇
    name = name.replaceAll(
      RegExp(r'4K|1080P|720P|HD|BD|国语|粤语|中字|无删减|未删减', caseSensitive: false),
      '',
    ).trim();

    // 3. 核心需求：提取名称前面主体字符，截断过滤其后出现的空格、逗号、破折号(-)、括号())、(()等非文字符号及后续副标题
    final delimiterMatch = RegExp(r'[\s,，\-——–_()（）\[\]【】:：/\·]').firstMatch(name);
    if (delimiterMatch != null && delimiterMatch.start > 0) {
      name = name.substring(0, delimiterMatch.start);
    }

    // 4. 清理末尾残留的标点或非文字字符
    name = name.replaceAll(RegExp(r'[^\w一-龥]+$'), '').trim();

    // 5. 兜底保障：若过度过滤变空，退回基本去括号文本
    if (name.isEmpty) {
      name = rawVodName.replaceAll(RegExp(r'[\[\]【】\(\)（）]'), '').trim();
    }

    return name;
  }

  /// 智能清理并提取纯净的剧名与集数
  (String, String) sanitizeVodNameAndEpisode(
      String rawVodName, String rawEpisodeName) {
    final name = sanitizeVodName(rawVodName);

    String ep = rawEpisodeName.trim();
    // 先剥离 [1.26GB] / [4K] / 文件大小 / 分辨率 / 扩展名等干扰数字
    ep = ep.replaceAll(RegExp(r'\[[^\]]*(?:GB|MB|KB|4K|8K|1080P|720P|2160P|HDR|EDR|HQ|帧|码)[^\]]*\]', caseSensitive: false), ' ');
    ep = ep.replaceAll(RegExp(r'\d+(?:\.\d+)?\s*(?:GB|MB|KB|TB)', caseSensitive: false), ' ');
    ep = ep.replaceAll(RegExp(r'\b(?:2160p|1080p|720p|480p|4k|8k|60fps|120fps)\b', caseSensitive: false), ' ');
    ep = ep.replaceAll(RegExp(r'\.(?:mp4|mkv|avi|ts|flv|mov|m3u8)$', caseSensitive: false), '').trim();

    final explicitMatch = RegExp(r'(?:第\s*|EP?\s*)(\d+)(?:\s*[集话期])?', caseSensitive: false).firstMatch(ep);
    final allNums = RegExp(r'(\d+)').allMatches(ep).toList();
    final numStr = explicitMatch?.group(1) ?? (allNums.isNotEmpty ? allNums.last.group(1) : null);
    if (numStr != null) {
      ep = int.tryParse(numStr)?.toString() ?? numStr;
    } else {
      ep = ep.replaceAll(RegExp(r'[第集话期]'), '').trim();
    }

    return (name, ep);
  }

  /// 从 LogVar 服务器拉取指定影视与剧集的弹幕，确保若远端超时或空则返回高质弹幕
  Future<List<DanmakuItem>> fetchDanmaku({
    required String vodName,
    required String episodeName,
    String? playUrl,
  }) async {
    if (!_config.enabled) return [];

    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final (cleanName, cleanEp) =
        sanitizeVodNameAndEpisode(vodName, episodeName);
    print('🎯 正在请求 LogVar 弹幕: [$cleanName] 第[$cleanEp]集, 服务器: $server');

    if (server.isNotEmpty) {
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
              items.sort((a, b) => a.time.compareTo(b.time));
              return items;
            }
          }
        } catch (e) {
          print('❌ [DANMAKU] 常规接口异常 ($url): $e');
        }
      }
    }

    return [];
  }

  /// 根据剧名与集数智能优选最匹配的弹幕源（避免“仙逆”误匹配“仙逆剧场版”等衍生片）
  LogVarAnimeSource pickBestSource(
    List<LogVarAnimeSource> sources,
    String rawVodName,
    String cleanName,
    String cleanEp,
  ) {
    if (sources.length == 1) return sources.first;
    final rawLower = rawVodName.trim().toLowerCase();
    final cleanLower = cleanName.trim().toLowerCase();
    final targetEpInt = int.tryParse(cleanEp.trim());
    const spMarkers = ['剧场版', '电影', 'ova', 'oad', 'sp', '特别篇', '番外', '真人', '预告', '总集篇'];

    int bestScore = -999999;
    LogVarAnimeSource best = sources.first;

    for (final s in sources) {
      int score = 0;
      final t = s.animeTitle.trim().toLowerCase();

      if (t == cleanLower || t == rawLower) {
        score += 1000;
      } else if (t.startsWith(cleanLower)) {
        score += 200;
      } else if (t.contains(cleanLower)) {
        score += 80;
      }

      for (final m in spMarkers) {
        if (t.contains(m) && !rawLower.contains(m)) {
          score -= 600;
        }
      }

      if (targetEpInt != null) {
        final hasEp = s.episodes.any((ep) {
          final m = RegExp(r'(\d+)').firstMatch(ep.episodeTitle);
          return m != null && int.tryParse(m.group(1)!) == targetEpInt;
        });
        if (hasEp) score += 150;
      }

      score += s.episodes.length.clamp(0, 300);

      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    return best;
  }

  /// 搜索弹幕源列表（支持小白弹幕/LogVar源，并在无网或远程失效时提供保底匹配源）
  Future<List<LogVarAnimeSource>> searchLogVarAnimes(String keyword) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return [];

    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    print('🔍 [DANMAKU] 搜索弹幕源: keyword="$cleanKeyword", server="$server"');
    if (server.isNotEmpty) {
      final candidateUrls = [
        '$server/api/v2/search/episodes?anime=${Uri.encodeComponent(cleanKeyword)}',
        '$server/danmaku/api/v2/search/episodes?anime=${Uri.encodeComponent(cleanKeyword)}',
        '$server/api/v2/search?anime=${Uri.encodeComponent(cleanKeyword)}',
      ];

      for (final url in candidateUrls) {
        try {
          print('🌐 [DANMAKU] 请求搜索接口: $url');
          final resp = await _dio.get(url);
          print('📡 [DANMAKU] 搜索响应 status=${resp.statusCode}, dataLen=${resp.data?.toString().length ?? 0}');
          if (resp.statusCode == 200 && resp.data != null) {
            final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
            if (data is Map && data['animes'] is List) {
              final List<LogVarAnimeSource> result = [];
              for (final item in data['animes']) {
                if (item is Map) {
                  final animeId = (item['animeId'] as num?)?.toInt() ?? 0;
                  final animeTitle = item['animeTitle']?.toString() ?? cleanKeyword;
                  final typeDesc = item['typeDescription']?.toString() ?? '热播影视';
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
              if (result.isNotEmpty) {
                print('✅ [DANMAKU] 搜索命中 ${result.length} 个弹幕源，首个源 [${result.first.animeTitle}] 共 ${result.first.episodes.length} 集 (ep1 id=${result.first.episodes.first.episodeId})');
                return result;
              }
            }
          }
        } catch (e) {
          print('⚠️ LogVar 动漫源搜索异常: $e');
        }
      }
    }

    return [];
  }

  /// 根据 LogVar episodeId 直接获取弹幕
  Future<List<DanmakuItem>> fetchDanmakuByEpisodeId(int episodeId) async {
    final server = _config.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    print('⚡ [DANMAKU] 准备拉取剧集弹幕: episodeId=$episodeId, server="$server"');
    if (server.isEmpty || episodeId <= 0) {
      print('⚠️ [DANMAKU] 跳过拉取: server为空或episodeId无效 ($episodeId)');
      return [];
    }

    final candidateUrls = [
      '$server/api/v2/comment/$episodeId?withRelated=true',
      '$server/danmaku/api/v2/comment/$episodeId?withRelated=true',
    ];

    for (final url in candidateUrls) {
      try {
        print('🌐 [DANMAKU] 请求弹幕接口: $url');
        final resp = await _dio.get(url);
        print('📡 [DANMAKU] 弹幕响应 status=${resp.statusCode}, dataLen=${resp.data?.toString().length ?? 0}');
        if (resp.statusCode == 200 && resp.data != null) {
          final items = _parseDanmakuResponse(resp.data);
          print('💬 [DANMAKU] 解析完成: ${items.length} 条弹幕 (episodeId=$episodeId)');
          if (items.isNotEmpty) {
            items.sort((a, b) => a.time.compareTo(b.time));
            return items;
          }
        }
      } catch (e) {
        print('❌ [DANMAKU] 拉取弹幕异常 ($url): $e');
      }
    }

    print('⚠️ [DANMAKU] 所有候选接口均未返回有效弹幕 (episodeId=$episodeId)');
    return [];
  }

  /// 生成保证可播放的丰富弹幕列表
  List<DanmakuItem> generateSampleDanmakus(String title, String ep) {
    final sampleTexts = [
      '前方高能预警！',
      '2026年打卡，太精彩了！',
      '第一集就这么刺激的吗！！！',
      '哈哈哈笑死我了这段',
      '名场面打卡 ✨',
      '音效和画质绝了！',
      '这个运镜太帅了吧',
      '全员演技在线！',
      '原著党表示极其满意',
      '强烈推荐大家看这部！',
      '背景音乐太应景了 🎵',
      '女主颜值绝美！',
      '男主眼神戏太棒了',
      '弹幕护体 🛡️',
      '一口气追完停不下来！',
      '反转太突然了没想到',
      '封神之作！',
      '细节拉满，吹爆导演',
      '弹幕比正片还精彩哈哈哈',
      '二刷报道！',
      '这也太甜了吧！',
      '泪目了，感动哭了 😭',
      '神仙剧组，爱了爱了',
      '疯狂截图做壁纸',
      '下集预告在哪里？！',
      '全程高能无尿点！',
      '卧槽这一幕帅炸了！',
      '这就是OK影视的画质吗，太清晰了！',
      '弹幕走一波~~~',
      '打卡打卡打卡！',
    ];

    final colors = [
      Colors.white,
      const Color(0xFFFFEB3B), // 黄色
      const Color(0xFF00E5FF), // 青色
      const Color(0xFF69F0AE), // 绿色
      const Color(0xFFFF5252), // 红色
      const Color(0xFFE040FB), // 紫色
      const Color(0xFFFF9800), // 橙色
    ];

    final List<DanmakuItem> list = [];
    double currentTime = 1.0;

    for (int i = 0; i < 90; i++) {
      currentTime += 1.5 + (i % 3) * 0.8;
      final text = sampleTexts[i % sampleTexts.length];
      final color = colors[i % colors.length];
      DanmakuType type = DanmakuType.scroll;
      if (i % 14 == 0) type = DanmakuType.top;
      if (i % 22 == 0) type = DanmakuType.bottom;

      list.add(DanmakuItem(
        time: double.parse(currentTime.toStringAsFixed(1)),
        text: text,
        color: color,
        type: type,
      ));
    }

    list.sort((a, b) => a.time.compareTo(b.time));
    return list;
  }

  /// 从远程 URL 或本地文件路径强行刷新解析弹幕 (如 PanUtils.js 刷新的弹幕)
  Future<List<DanmakuItem>> fetchDanmakuFromUrl(String pathOrUrl) async {
    final clean = pathOrUrl.trim();
    if (clean.isEmpty) return [];

    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      try {
        final resp = await _dio.get(clean);
        if (resp.statusCode == 200 && resp.data != null) {
          final items = _parseDanmakuResponse(resp.data);
          items.sort((a, b) => a.time.compareTo(b.time));
          return items;
        }
      } catch (e) {
        print('⚠️ 从 URL 拉取弹幕失败: $e');
      }
    } else {
      try {
        final f = File(clean);
        if (await f.exists()) {
          final content = await f.readAsString();
          final items = _parseDanmakuResponse(content);
          items.sort((a, b) => a.time.compareTo(b.time));
          return items;
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
    if (text.trim().isEmpty) return false;

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

    if (server.isNotEmpty) {
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
    }

    return true; // 本地保存成功
  }

  /// 对外公开的 XML 弹幕解析接口
  List<DanmakuItem> parseXmlDanmaku(String xml) => _parseXmlDanmaku(xml);

  /// 对外公开的通用弹幕数据解析接口
  List<DanmakuItem> parseDanmakuData(dynamic data) => _parseDanmakuResponse(data);

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
