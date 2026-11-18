import 'dart:convert';
import '../global/storage_bridge.dart';

/// 播放器字幕样式配置（支持持久化）
class SubtitleConfig {
  double fontSize;
  double bottomPadding;
  int colorValue;
  double opacity;
  bool showBackground;

  SubtitleConfig({
    this.fontSize = 34.0,
    this.bottomPadding = 40.0,
    this.colorValue = 0xFFFFFFFF,
    this.opacity = 1.0,
    this.showBackground = false,
  });

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'bottomPadding': bottomPadding,
        'colorValue': colorValue,
        'opacity': opacity,
        'showBackground': showBackground,
      };

  factory SubtitleConfig.fromJson(Map<String, dynamic> json) {
    return SubtitleConfig(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 34.0,
      bottomPadding: (json['bottomPadding'] as num?)?.toDouble() ?? 40.0,
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFFFFFFFF,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      showBackground: json['showBackground'] as bool? ?? false,
    );
  }

  static const String _storageKey = 'player_subtitle_config_v1';

  static Future<SubtitleConfig> load() async {
    try {
      final raw = await StorageBridge.getValue(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return SubtitleConfig.fromJson(decoded);
        }
      }
    } catch (_) {}
    return SubtitleConfig();
  }

  Future<void> save() async {
    try {
      await StorageBridge.setValue(_storageKey, jsonEncode(toJson()));
    } catch (_) {}
  }

  void reset() {
    fontSize = 34.0;
    bottomPadding = 40.0;
    colorValue = 0xFFFFFFFF;
    opacity = 1.0;
    showBackground = false;
  }
}
