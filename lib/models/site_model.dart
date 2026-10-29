/// 站点配置模型 (config.json 中的 sites)
class SiteModel {
  final String key;
  final String name;
  final int type;
  final String api;
  final dynamic ext;
  final int? changeable;
  final int? filterable;
  final int? searchable;
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
      'filterable': filterable,
      'searchable': searchable,
      'quickSearch': quickSearch,
      'timeout': timeout,
      'playerType': playerType,
    };
  }

  /// 是否为 JS 动态脚本源 (CatVod / OK 影视标准: type 3 或 api 包含 .js)
  bool get isJsSource =>
      type == 3 ||
      api.endsWith('.js') ||
      api.contains('.js?') ||
      api.contains('/js/');
}
