import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/site_model.dart';
import '../models/vod_model.dart';
export '../models/category_model.dart';
import '../models/config_model.dart';
import '../models/live_model.dart';
import '../services/config_service.dart';
import '../services/js_engine_service.dart';
import '../services/live_service.dart';
import '../global/http_bridge.dart';
import '../global/storage_bridge.dart';

/// 站点与爬虫数据仓库 (业务层核心协调中枢)
class SiteRepository {
  final ConfigService _configService;
  final JsEngineService _jsEngineService;
  final LiveService _liveService;

  List<SiteModel> _sites = [];
  SiteModel? _activeSite;
  String _configBaseUrl = '';
  String? _localPackageDir;
  Map<String, dynamic> _rawConfig = {};

  final ValueNotifier<String?> toastNotifier = ValueNotifier<String?>(null);

  ConfigItemModel? _activeConfigItem;

  SiteRepository({
    ConfigService? configService,
    JsEngineService? jsEngineService,
    LiveService? liveService,
  })  : _configService = configService ?? ConfigService(),
        _jsEngineService = jsEngineService ?? JsEngineService(),
        _liveService = liveService ?? LiveService();

  List<SiteModel> get sites => _sites;
  SiteModel? get activeSite => _activeSite;
  String get configBaseUrl => _configBaseUrl;
  String? get localPackageDir => _localPackageDir;
  ConfigItemModel? get activeConfigItem => _activeConfigItem;
  JsEngineService get jsEngine => _jsEngineService;
  ConfigService get configService => _configService;
  Map<String, dynamic> get rawConfig => _rawConfig;

  Map<String, List<CategoryFilterGroup>> _activeSiteFilters = {};
  Map<String, List<CategoryFilterGroup>> get activeSiteFilters => _activeSiteFilters;

  /// 加载并解析点播配置 (以用户给定的目标路径为准，不进行多余自动探测)
  Future<List<SiteModel>> loadConfig(
    String targetPath, [
    String? customName,
    ConfigType? type,
  ]) async {
    print('📦 开始加载点播配置: $targetPath');
    ConfigLoadResult? result;

    try {
      result = await _configService.loadConfigFromPathOrUrl(targetPath);
    } catch (e) {
      print('loadConfigFromPathOrUrl 异常: $e');
    }

    if (result == null || result.configMap.isEmpty) {
      print('❌ 未能加载到有效点播配置: $targetPath');
      toastNotifier.value = '加载配置失败，请检查路径或链接是否有效。';
      return _sites;
    }

    _configBaseUrl = result.effectiveBaseUrl;
    _localPackageDir = result.localPackageDir;
    _rawConfig = result.configMap;

    HttpBridge.currentBaseUrl = _configBaseUrl;
    HttpBridge.localPackageDir = _localPackageDir;

    if (_rawConfig.containsKey('sites') && _rawConfig['sites'] is List) {
      _sites = (_rawConfig['sites'] as List)
          .map((e) => SiteModel.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.isJsSource) // 筛选 FongMi Spider 源
          .toList();

      print('🎉 成功载入 ${_sites.length} 个可用 FongMi JS 影视站点 (baseUrl: $_configBaseUrl)');

      // 记录到持久化历史管理器
      final item = ConfigItemModel(
        id: targetPath,
        name: customName ?? result.suggestedName,
        urlOrPath: _configBaseUrl,
        type: type ?? result.type,
        lastUsed: DateTime.now(),
        siteCount: _sites.length,
        isActive: true,
        localPackageDir: _localPackageDir,
      );
      _activeConfigItem = item;
      await _configService.recordActiveConfig(item);

      if (_sites.isNotEmpty) {
        String? lastSiteKey;
        String? lastSiteName;
        try {
          lastSiteKey = await StorageBridge.getValue('last_active_site_key');
          lastSiteName = await StorageBridge.getValue('last_active_site_name');
        } catch (_) {}

        SiteModel defaultSite;
        if (lastSiteKey != null && lastSiteKey.isNotEmpty) {
          defaultSite = _sites.firstWhere(
            (s) => s.key == lastSiteKey,
            orElse: () => _sites.firstWhere(
              (s) => s.name == lastSiteName,
              orElse: () => _sites.firstWhere((s) => s.key != 'push_agent', orElse: () => _sites.first),
            ),
          );
        } else {
          defaultSite = _sites.firstWhere((s) => s.key != 'push_agent', orElse: () => _sites.first);
        }

        print('🎯 自动激活站源: [${defaultSite.name}] (${defaultSite.key})');
        try {
          await selectSite(defaultSite).timeout(
            const Duration(seconds: 5),
            onTimeout: () => print('⚠️ 初始激活站源超时，跳过阻塞'),
          );
        } catch (e) {
          print('初始选择站点异常: $e');
        }
      }
    }

    return _sites;
  }

  /// 提取当前配置内的直播频道
  Future<List<LiveGroup>> fetchLives() async {
    final rawLives = _rawConfig['lives'] as List?;
    return await _liveService.loadLiveGroups(
      livesConfig: rawLives,
      localPackageDir: _localPackageDir,
      baseUrl: _configBaseUrl,
    );
  }

  /// 切换并加载选中的站点 JS 源（严格以用户配置为准）
  Future<void> selectSite(SiteModel site) async {
    _activeSite = site;
    final apiPath = site.api.trim();

    try {
      await StorageBridge.setValue('last_active_site_key', site.key);
      await StorageBridge.setValue('last_active_site_name', site.name);
    } catch (_) {}

    String jsCode = '';
    String fullJsUrl = apiPath;

    try {
     if (apiPath.startsWith('file://')) {
        final fsPath = ConfigService.fromFileUri(apiPath);
        final f = File(fsPath);
        if (await f.exists()) {
          jsCode = await f.readAsString();
          fullJsUrl = ConfigService.toFileUri(f.path);
        }
      } else if (apiPath.startsWith('http://') || apiPath.startsWith('https://')) {
        fullJsUrl = apiPath;
        jsCode = await _configService.loadRaw(fullJsUrl);
      } else {
        if (_configBaseUrl.startsWith('http://') || _configBaseUrl.startsWith('https://')) {
          fullJsUrl = Uri.parse(_configBaseUrl).resolve(apiPath).toString();
          jsCode = await _configService.loadRaw(fullJsUrl);
        } else {
          final cleanApi = apiPath.startsWith('./') ? apiPath.substring(2) : apiPath;
          String baseFilePath = ConfigService.fromFileUri(_configBaseUrl);
          final configParentDir = File(baseFilePath).parent.path;
          
          final f = File('$configParentDir/$cleanApi');
          if (await f.exists()) {
            jsCode = await f.readAsString();
            fullJsUrl = ConfigService.toFileUri(f.path);
          }
        }
      }

      if (jsCode.isNotEmpty) {
        dynamic extObj = site.ext;

        if (extObj is String) {
          final extStr = extObj.trim();
          if (extStr.startsWith('clan://localhost/')) {
            final rel = extStr.replaceFirst('clan://localhost/', '');
            final baseDir = _configBaseUrl.isNotEmpty && !_configBaseUrl.startsWith('http')
                ? File(ConfigService.fromFileUri(_configBaseUrl)).parent.path
                : _localPackageDir;
            if (baseDir != null) {
              final f = File('$baseDir/$rel');
              if (await f.exists()) extObj = await f.readAsString();
            }
          } else if (extStr.startsWith('./') || extStr.endsWith('.json') || extStr.endsWith('.txt')) {
            if (_configBaseUrl.startsWith('http')) {
              final extUrl = Uri.parse(_configBaseUrl).resolve(extStr).toString();
              final content = await _configService.loadRaw(extUrl);
              if (content.isNotEmpty) extObj = content;
            } else {
              String baseFilePath = ConfigService.fromFileUri(_configBaseUrl);
              final configParentDir = File(baseFilePath).parent.path;
              final cleanExt = extStr.replaceFirst('./', '');
              final f = File('$configParentDir/$cleanExt');
              if (await f.exists()) extObj = await f.readAsString();
            }
          }
        }

        await _jsEngineService.loadJsSource(
          jsCode,
          baseUrl: fullJsUrl,
          configBaseUrl: _configBaseUrl,
          localPackageDir: _localPackageDir,
          ext: extObj,
        );

        debugPrint('🚀 站点 [${site.name}] QuickJS 加载完成 (baseUrl: $fullJsUrl)');
      } else {
        debugPrint('❌ 未能获取到站点 [${site.name}] 的有效 JS 源码: $apiPath');
        toastNotifier.value = '未找到站点 [${site.name}] 的JS脚本文件。';
      }
    } catch (e) {
      debugPrint('❌ selectSite 异常: $e');
      if (e.toString().contains('Permission denied') || e.toString().contains('errno = 13')) {
        toastNotifier.value = '读取本地JS受限(Permission denied)，请授予存储权限！';
      } else {
        toastNotifier.value = '站点 [${site.name}] 初始化失败: $e';
      }
    }
  }

  Future<VodItem?> pushLink(String link) async {
    try {
      final pushAgentSite = _sites.firstWhere(
        (s) => s.key == 'push_agent',
        orElse: () => _activeSite ?? _sites.first,
      );
      await selectSite(pushAgentSite);
      return await fetchDetail(link);
    } catch (e) {
      return null;
    }
  }

  Future<List<VodItem>> fetchHomeVod() async {
    if (!_jsEngineService.isInitialized) return [];
    try {
      final res = await _jsEngineService.callMethod('homeVod');
      return _parseVodList(res);
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> fetchCategories() async {
    if (!_jsEngineService.isInitialized) return {'categories': <CategoryItem>[], 'filters': {}};
    try {
      final res = await _jsEngineService.callMethod('home', [true]);
      Map<String, dynamic> rawMap = {};
      if (res is Map) {
        rawMap = Map<String, dynamic>.from(res);
      } else if (res is String) {
        try { rawMap = Map<String, dynamic>.from(jsonDecode(res)); } catch (_) {}
      }

      final categories = (rawMap['class'] as List?)
              ?.map((e) => CategoryItem.fromJson(Map<String, dynamic>.from(e)))
              .toList() ?? [];

      final Map<String, List<CategoryFilterGroup>> filters = {};
      if (rawMap['filters'] is Map) {
        (rawMap['filters'] as Map).forEach((key, val) {
          if (val is List) {
            filters[key.toString()] = val
                .map((g) => CategoryFilterGroup.fromJson(Map<String, dynamic>.from(g)))
                .toList();
          }
        });
      }

      _activeSiteFilters = filters;
      return {'categories': categories, 'filters': filters};
    } catch (e) {
      return {'categories': <CategoryItem>[], 'filters': {}};
    }
  }

  Future<List<VodItem>> fetchCategoryList(String tid, int pg, [Map<String, dynamic>? ext]) async {
    if (!_jsEngineService.isInitialized) return [];
    try {
      final res = await _jsEngineService.callMethod('category', [tid.toString(), pg.toString(), true, ext ?? {}]);
      return _parseVodList(res);
    } catch (e) {
      return [];
    }
  }

  Future<VodItem?> fetchDetail(String vodId) async {
    if (!_jsEngineService.isInitialized) return null;
    try {
      final res = await _jsEngineService.callMethod('detail', [vodId]);
      final list = _parseVodList(res);
      return list.isNotEmpty ? list.first : null;
    } catch (e) {
      return null;
    }
  }

  Future<List<VodItem>> searchVod(String keyword, [int pg = 1]) async {
    if (!_jsEngineService.isInitialized) return [];
    try {
      final res = await _jsEngineService.callMethod('search', [keyword, false, pg.toString()]);
      final list = _parseVodList(res);
      if (_activeSite != null) {
        for (var item in list) {
          item.siteKey = _activeSite!.key;
          item.siteName = _activeSite!.name;
        }
      }
      return list;
    } catch (e) {
      return [];
    }
  }

  Future<List<VodItem>> searchAllSites(String keyword, [int pg = 1]) async {
    final activeBackup = _activeSite;
    final List<VodItem> allResults = [];
    final sitesToSearch = _sites.where((s) => s.key != 'push_agent' && (s.searchable == null || s.searchable != 0)).toList();

    for (final site in sitesToSearch) {
      try {
        final results = await searchVodOnSite(site, keyword, pg);
        allResults.addAll(results);
      } catch (_) {}
    }

    if (activeBackup != null) {
      try { await selectSite(activeBackup); } catch (_) {}
    }
    return allResults;
  }

  Future<List<VodItem>> searchVodOnSite(SiteModel site, String keyword, [int pg = 1]) async {
    await selectSite(site);
    return await searchVod(keyword, pg);
  }

  Future<Map<String, dynamic>> fetchPlayInfo(String flag, String playId) async {
    if (!_jsEngineService.isInitialized) return {};
    try {
      final res = await _jsEngineService.callMethod('play', [flag, playId, <String>[]]);
      _checkAndNotifyMsg(res);
      if (res is Map) return Map<String, dynamic>.from(res);
      if (res is String) {
        try { return Map<String, dynamic>.from(jsonDecode(res)); } catch (_) {}
      }
    } catch (_) {}
    return {};
  }

  Future<void> setActiveSite(SiteModel site) => selectSite(site);
  Future<List<VodItem>> fetchHomeVods() => fetchHomeVod();
  Future<List<VodItem>> fetchSubFolderList(String folderId) => fetchCategoryList(folderId, 1, {});
  Future<List<VodItem>> quickSearchAll(String kw) => searchAllSites(kw);

  List<VodItem> _parseVodList(dynamic raw) {
    if (raw == null) return [];
    _checkAndNotifyMsg(raw);
    dynamic parsed = raw;
    if (raw is String) {
      try { parsed = jsonDecode(raw); } catch (_) {}
    }
    List<dynamic> list = [];
    if (parsed is Map && parsed.containsKey('list') && parsed['list'] is List) {
      list = parsed['list'];
    } else if (parsed is List) {
      list = parsed;
    }
    return list.map((e) => VodItem.fromJson(Map<String, dynamic>.from(e))).where((v) => v.vodName.isNotEmpty).toList();
  }

  void _checkAndNotifyMsg(dynamic data) {
    try {
      if (data is Map && data.containsKey('msg')) {
        final msg = data['msg']?.toString();
        if (msg != null && msg.isNotEmpty) toastNotifier.value = msg;
      }
    } catch (_) {}
  }
}