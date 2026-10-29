/// 直播频道模型 (OK影视 / TVBox 规范)
class LiveChannel {
  final int num;
  final String name;
  final String? logo;
  final List<String> urls;
  int currentUrlIndex;

  LiveChannel({
    required this.num,
    required this.name,
    this.logo,
    required this.urls,
    this.currentUrlIndex = 0,
  });

  String get currentUrl => urls.isNotEmpty ? urls[currentUrlIndex] : '';

  void nextUrl() {
    if (urls.length > 1) {
      currentUrlIndex = (currentUrlIndex + 1) % urls.length;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'num': num,
      'name': name,
      'logo': logo,
      'urls': urls,
      'currentUrlIndex': currentUrlIndex,
    };
  }

  factory LiveChannel.fromJson(Map<String, dynamic> json) {
    final rawUrls = json['urls'] as List? ?? [];
    return LiveChannel(
      num: json['num'] as int? ?? 1,
      name: json['name']?.toString() ?? '',
      logo: json['logo']?.toString(),
      urls: rawUrls.map((e) => e.toString()).toList(),
      currentUrlIndex: json['currentUrlIndex'] as int? ?? 0,
    );
  }
}

/// 直播频道分组模型 (如 央视频道, 卫视频道, 影视轮播等)
class LiveGroup {
  final String name;
  final List<LiveChannel> channels;

  LiveGroup({
    required this.name,
    required this.channels,
  });
}
