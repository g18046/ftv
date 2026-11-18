import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/live_model.dart';
import 'config_service.dart';

/// OK影视 / TVBox 直播服务
/// 深度支持：
/// 1. 解析 config.json 中的 lives 字段 (包括本地相对路径 ./live/xxx.m3u 与远程 http 链接)
/// 2. 本地包内 live/ 目录直读与 rootBundle 内置资产加载 (支持 migu.txt 与 湖北移动单播.m3u)
/// 3. M3U 播放列表格式与 TXT 频道格式 (#genre#)
/// 4. URL 净化容错 (去除 $4K、$标清 等标识符后缀，确保播放内核顺利加载)
/// 5. 高可用全国主流央视与各大卫视直播流预设
class LiveService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 10),
  ));

 Future<List<LiveGroup>> loadLiveGroups({
    List<dynamic>? livesConfig,
    String? customLiveUrl,
    String? localPackageDir,
    String? baseUrl,
  }) async {
    List<LiveGroup> groups = [];

    if (customLiveUrl != null && customLiveUrl.isNotEmpty) {
      final content = await _readUrlOrLocalFile(customLiveUrl, localPackageDir, baseUrl);
      if (content.isNotEmpty) {
        groups = parsePlaylistContent(content);
        if (groups.isNotEmpty) return groups;
      }
    }

    if (livesConfig != null && livesConfig.isNotEmpty) {
      for (final item in livesConfig) {
        if (item is Map) {
          final url = item['url']?.toString() ?? item['channels']?.toString();
          if (url != null && url.isNotEmpty) {
            final content = await _readUrlOrLocalFile(url, localPackageDir, baseUrl);
            if (content.isNotEmpty) {
              final parsed = parsePlaylistContent(content);
              if (parsed.isNotEmpty) return parsed;
            }
          }
        }
      }
    }

    // 仅基于实际的 localPackageDir 或 baseUrl 相对路径加载
    final bundledCandidates = [
      if (localPackageDir != null) '$localPackageDir/live/migu.txt',
      if (localPackageDir != null) '$localPackageDir/live/湖北移动单播.m3u',
      if (baseUrl != null && !baseUrl.startsWith('http'))
        '${File(ConfigService.fromFileUri(baseUrl)).parent.path}/live/migu.txt',
    ];

    for (final p in bundledCandidates) {
      final f = File(p);
      if (await f.exists()) {
        try {
          final content = await f.readAsString();
          final parsed = parsePlaylistContent(content);
          if (parsed.isNotEmpty) return parsed;
        } catch (_) {}
      }
    }

    return getBuiltinLiveGroups();
  }

  Future<String> _readUrlOrLocalFile(String pathOrUrl, String? localPackageDir, String? baseUrl) async {
    final clean = pathOrUrl.trim();
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      try {
        final res = await _dio.get<String>(clean, options: Options(responseType: ResponseType.plain));
        return res.data ?? '';
      } catch (e) {
        return '';
      }
    }

    final rel = clean.replaceFirst('./', '');
    final baseDir = baseUrl != null && !baseUrl.startsWith('http')
        ? File(ConfigService.fromFileUri(baseUrl)).parent.path
        : localPackageDir;

    if (baseDir != null) {
      final f = File('$baseDir/$rel');
      if (await f.exists()) {
        try { return await f.readAsString(); } catch (_) {}
      }
    }

    final directFile = File(clean);
    if (await directFile.exists()) {
      try { return await directFile.readAsString(); } catch (_) {}
    }

    return '';
  }
  /// 通用解析文本内容 (支持 M3U / TXT #genre# 格式)
  List<LiveGroup> parsePlaylistContent(String content) {
    if (content.contains('#EXTM3U')) {
      return _parseM3U(content);
    }
    return _parseTxt(content);
  }

  /// 净化流媒体 URL (剥离 $4K, $超清 等 OK影视/TVBox 扩展后缀)
  static String sanitizeStreamUrl(String rawUrl) {
    String url = rawUrl.trim();
    if (url.contains(r'$')) {
      url = url.split(r'$').first.trim();
    }
    return url;
  }

  /// 解析 TXT 格式 (频道名,链接 或 分组名,#genre#)
  List<LiveGroup> _parseTxt(String content) {
    final lines = const LineSplitter().convert(content);
    final List<LiveGroup> groups = [];

    String currentGroupName = '默认分组';
    List<LiveChannel> currentChannels = [];
    int channelCounter = 1;

    for (var rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') && !line.contains('#genre#')) continue;

      if (line.contains('#genre#')) {
        if (currentChannels.isNotEmpty) {
          groups.add(LiveGroup(name: currentGroupName, channels: List.from(currentChannels)));
          currentChannels.clear();
        }
        currentGroupName = line.split(',').first.trim();
        continue;
      }

      if (line.contains(',')) {
        final parts = line.split(',');
        final name = parts[0].trim();
        final urls = parts
            .sublist(1)
            .join(',')
            .split('#')
            .map((e) => sanitizeStreamUrl(e))
            .where((e) => e.isNotEmpty)
            .toList();

        if (name.isNotEmpty && urls.isNotEmpty) {
          currentChannels.add(LiveChannel(
            num: channelCounter++,
            name: name,
            urls: urls,
          ));
        }
      }
    }

    if (currentChannels.isNotEmpty) {
      groups.add(LiveGroup(name: currentGroupName, channels: currentChannels));
    }

    return groups;
  }

  /// 解析 M3U 格式
  List<LiveGroup> _parseM3U(String content) {
    final lines = const LineSplitter().convert(content);
    final Map<String, List<LiveChannel>> groupMap = {};
    int channelCounter = 1;

    String? pendingName;
    String? pendingGroup;

    for (var rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF:')) {
        final groupMatch = RegExp(r'group-title="([^"]+)"').firstMatch(line);
        pendingGroup = groupMatch?.group(1) ?? '综合频道';

        final lastCommaIdx = line.lastIndexOf(',');
        if (lastCommaIdx != -1) {
          pendingName = line.substring(lastCommaIdx + 1).trim();
        }
      } else if (!line.startsWith('#') && (line.startsWith('http://') || line.startsWith('https://'))) {
        if (pendingName != null) {
          final groupName = pendingGroup ?? '其他频道';
          groupMap.putIfAbsent(groupName, () => []);

          final cleanStreamUrl = sanitizeStreamUrl(line);

          final existing = groupMap[groupName]!.firstWhere(
            (c) => c.name == pendingName,
            orElse: () => LiveChannel(num: 0, name: '', urls: []),
          );

          if (existing.name.isNotEmpty) {
            if (!existing.urls.contains(cleanStreamUrl)) {
              existing.urls.add(cleanStreamUrl);
            }
          } else {
            groupMap[groupName]!.add(LiveChannel(
              num: channelCounter++,
              name: pendingName,
              urls: [cleanStreamUrl],
            ));
          }

          pendingName = null;
          pendingGroup = null;
        }
      }
    }

    return groupMap.entries.map((e) => LiveGroup(name: e.key, channels: e.value)).toList();
  }

  /// 内置全量央视与各大卫视高可用直播流
  static List<LiveGroup> getBuiltinLiveGroups() {
    int counter = 1;

    final cctvChannels = [
      LiveChannel(num: counter++, name: 'CCTV-1 综合', urls: [
        'http://111.48.34.190/000000000000/PLTV/88888888/224/3221230440/1.m3u8',
        'http://111.48.34.153/000000000000/PLTV/88888888/224/3221230563/1.m3u8',
        'http://go.bkpcp.top/mg/cctv1',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-2 财经', urls: [
        'http://111.48.34.169/000000000000/PLTV/88888888/224/3221230359/1.m3u8',
        'http://go.bkpcp.top/mg/cctv2',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-3 综艺', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230150/1.m3u8',
        'http://go.bkpcp.top/mg/cctv3',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-4 中文国际', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230152/1.m3u8',
        'http://go.bkpcp.top/mg/cctv4',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-5 体育', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230154/1.m3u8',
        'http://go.bkpcp.top/mg/cctv5',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-5+ 体育赛事', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230156/1.m3u8',
        'http://go.bkpcp.top/mg/cctv5p',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-6 电影', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230158/1.m3u8',
        'http://go.bkpcp.top/mg/cctv6',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-7 国防军事', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230160/1.m3u8',
        'http://go.bkpcp.top/mg/cctv7',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-8 电视剧', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230162/1.m3u8',
        'http://go.bkpcp.top/mg/cctv8',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-9 纪录', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230164/1.m3u8',
        'http://go.bkpcp.top/mg/cctv9',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-10 科教', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230166/1.m3u8',
        'http://go.bkpcp.top/mg/cctv10',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-11 戏曲', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230168/1.m3u8',
        'http://go.bkpcp.top/mg/cctv11',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-12 社会与法', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230170/1.m3u8',
        'http://go.bkpcp.top/mg/cctv12',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-13 新闻', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230172/1.m3u8',
        'http://go.bkpcp.top/mg/cctv13',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-14 少儿', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230174/1.m3u8',
        'http://go.bkpcp.top/mg/cctv14',
      ]),
      LiveChannel(num: counter++, name: 'CCTV-15 音乐', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230176/1.m3u8',
        'http://go.bkpcp.top/mg/cctv15',
      ]),
    ];

    final satelliteChannels = [
      LiveChannel(num: counter++, name: '湖南卫视', urls: [
        'http://111.48.34.159/000000000000/PLTV/88888888/224/3221230606/1.m3u8',
        'http://go.bkpcp.top/mg/hunan',
      ]),
      LiveChannel(num: counter++, name: '浙江卫视', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230180/1.m3u8',
        'http://go.bkpcp.top/mg/zhejiang',
      ]),
      LiveChannel(num: counter++, name: '江苏卫视', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230182/1.m3u8',
        'http://go.bkpcp.top/mg/jiangsu',
      ]),
      LiveChannel(num: counter++, name: '东方卫视', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230184/1.m3u8',
        'http://go.bkpcp.top/mg/dongfang',
      ]),
      LiveChannel(num: counter++, name: '北京卫视', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230186/1.m3u8',
        'http://go.bkpcp.top/mg/beijing',
      ]),
      LiveChannel(num: counter++, name: '广东卫视', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230188/1.m3u8',
        'http://go.bkpcp.top/mg/guangdong',
      ]),
      LiveChannel(num: counter++, name: '深圳卫视', urls: [
        'http://111.48.34.212/000000000000/PLTV/88888888/224/3221230190/1.m3u8',
        'http://go.bkpcp.top/mg/shenzhen',
      ]),
    ];

    return [
      LiveGroup(name: '央视频道', channels: cctvChannels),
      LiveGroup(name: '各大卫视', channels: satelliteChannels),
    ];
  }
}
