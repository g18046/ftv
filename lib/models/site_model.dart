/// 站点配置模型 (config.json 中的 sites)
class SiteModel {
  final String key;
  final String name;
  final int type;
  final String api;
  final dynamic ext;
  int? changeable;
  final int? configChangeable;
  final Map<String, dynamic>? style;
  final int? filterable;
  int? searchable; // 可动态切换快速搜索开启/禁用
  final int? quickSearch;
  final int? timeout;
  final int? playerType;

  SiteModel({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    this.ext,
    this.changeable,
    this.configChangeable,
    this.style,
    this.filterable,
    this.searchable,
    this.quickSearch,
    this.timeout,
    this.playerType,
  });

  factory SiteModel.fromJson(Map<String, dynamic> json) {
    return SiteModel(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: json['type'] is int ? json['type'] : int.tryParse(json['type']?.toString() ?? '3') ?? 3,
      api: json['api']?.toString() ?? '',
      ext: json['ext'],
      changeable: json['changeable'] as int?,
      configChangeable: json['changeable'] as int?,
      style: json['style'] is Map
          ? Map<String, dynamic>.from(json['style'] as Map)
          : null,
      filterable: json['filterable'] as int?,
      searchable: json['searchable'] as int?,
      quickSearch: json['quickSearch'] as int?,
      timeout: json['timeout'] as int?,
      playerType: json['playerType'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'type': type,
      'api': api,
      'ext': ext,
      'changeable': changeable,
      if (style != null) 'style': style,
      'filterable': filterable,
      'searchable': searchable,
      'quickSearch': quickSearch,
      'timeout': timeout,
      'playerType': playerType,
    };
  }

  /// 是否为 JS 动态脚本源 (严格排除 csp_ 等 Jar 源与 .py 源，仅保留 .js / /js/ 脚本源)
  bool get isJsSource {
    final lowerApi = api.trim().toLowerCase();
    if (lowerApi.isEmpty ||
        lowerApi.startsWith('csp_') ||
        lowerApi.endsWith('.py') ||
        lowerApi.contains('.py?')) {
      return false;
    }
    return lowerApi.endsWith('.js') ||
        lowerApi.contains('.js?') ||
        lowerApi.contains('/js/');
  }
}
