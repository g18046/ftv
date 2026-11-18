export 'category_model.dart';
/// 影视数据模型 (CatVod / OK影视 统一标准)
class VodItem {
  final String vodId;
  final String vodName;
  final String vodPic;
  final String vodRemarks;
  final String? vodType; // 'folder' 表示文件夹类型，非 'folder' 为标准影视卡片

  // 多站点并发搜索标识
  String? siteKey;
  String? siteName;

  // 详情特有字段
  final String vodActor;
  final String vodDirector;
  final String vodArea;
  final String vodYear;
  final String typeName;
  final String vodContent;
  final String? vodPlayFrom; // 线路名称, $$$ 分割
  final String? vodPlayUrl;  // 选集列表, $$$ 分割线路, # 分割集数 (名称$地址)
  final Map<String, dynamic>? style;

  VodItem({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodRemarks,
    this.vodType,
    this.siteKey,
    this.siteName,
    this.vodActor = '',
    this.vodDirector = '',
    this.vodArea = '',
    this.vodYear = '',
    this.typeName = '',
    this.vodContent = '',
    this.vodPlayFrom,
    this.vodPlayUrl,
    this.style,
  });

  bool get isFolder =>
      vodType == 'folder' ||
      (vodType != null && vodType!.toLowerCase() == 'folder') ||
      vodRemarks == 'folder';

  factory VodItem.fromJson(Map<String, dynamic> json) {
    return VodItem(
      vodId: json['vod_id']?.toString() ?? '',
      vodName: json['vod_name']?.toString() ?? '',
      vodPic: json['vod_pic']?.toString() ?? '',
      vodRemarks: json['vod_remarks']?.toString() ?? json['vod_remark']?.toString() ?? '',
      vodType: json['vod_type']?.toString() ?? json['vod_tag']?.toString() ?? json['type']?.toString(),
      siteKey: json['site_key']?.toString(),
      siteName: json['site_name']?.toString(),
      vodActor: json['vod_actor']?.toString() ?? '',
      vodDirector: json['vod_director']?.toString() ?? '',
      vodArea: json['vod_area']?.toString() ?? '',
      vodYear: json['vod_year']?.toString() ?? '',
      typeName: json['type_name']?.toString() ?? '',
      vodContent: json['vod_content']?.toString() ?? '',
      vodPlayFrom: json['vod_play_from']?.toString(),
      vodPlayUrl: json['vod_play_url']?.toString(),
      style: json['style'] is Map
          ? Map<String, dynamic>.from(json['style'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'vod_id': vodId,
      'vod_name': vodName,
      'vod_pic': vodPic,
      'vod_remarks': vodRemarks,
      'vod_type': vodType,
      'site_key': siteKey,
      'site_name': siteName,
      'vod_actor': vodActor,
      'vod_director': vodDirector,
      'vod_area': vodArea,
      'vod_year': vodYear,
      'type_name': typeName,
      'vod_content': vodContent,
      'vod_play_from': vodPlayFrom,
      'vod_play_url': vodPlayUrl,
    };
  }

  /// 解析播放线路与集数列表
  List<PlaySource> get playSources {
    if (vodPlayFrom == null || vodPlayUrl == null) return [];
    final froms = vodPlayFrom!.split('\$\$\$');
    final urls = vodPlayUrl!.split('\$\$\$');

    final List<PlaySource> result = [];
    for (int i = 0; i < froms.length; i++) {
      final name = froms[i];
      final urlGroup = i < urls.length ? urls[i] : '';
      final episodes = urlGroup.split('#').map((e) {
        final parts = e.split('\$');
        if (parts.length >= 2) {
          return EpisodeItem(name: parts[0], url: parts.sublist(1).join('\$'));
        }
        return EpisodeItem(name: e, url: e);
      }).where((e) => e.name.isNotEmpty && e.url.isNotEmpty).toList();

      result.add(PlaySource(name: name, episodes: episodes));
    }
    return result;
  }
}

class PlaySource {
  final String name;
  final List<EpisodeItem> episodes;

  PlaySource({required this.name, required this.episodes});
}

class EpisodeItem {
  final String name;
  final String url;

  EpisodeItem({required this.name, required this.url});
}
