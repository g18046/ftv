import 'package:flutter/material.dart';

enum DanmakuType {
  scroll, // 滚动弹幕（自右向左）
  top,    // 顶部固定
  bottom, // 底部固定（用户配置默认不支持/忽略，避免遮挡字幕）
}

/// 单条弹幕数据模型
class DanmakuItem {
  final double time; // 出现时间点（单位：秒）
  final String text; // 弹幕文字内容
  final Color color; // 弹幕颜色
  final DanmakuType type; // 弹幕展示类型
  final double? fontSize; // 单独字体大小设置

  DanmakuItem({
    required this.time,
    required this.text,
    this.color = Colors.white,
    this.type = DanmakuType.scroll,
    this.fontSize,
  });

  Map<String, dynamic> toJson() {
    int mode = 1;
    if (type == DanmakuType.top) mode = 5;
    if (type == DanmakuType.bottom) mode = 4;
    return {
      'time': time,
      'text': text,
      'color': color.toARGB32() & 0xFFFFFF,
      'type': mode,
    };
  }

  /// 从各类 JSON / 字段容错解析
  factory DanmakuItem.fromJson(Map<String, dynamic> json) {
    double parsedTime = 0.0;
    if (json.containsKey('time')) {
      parsedTime = (json['time'] as num?)?.toDouble() ?? 0.0;
    } else if (json.containsKey('timepoint')) {
      parsedTime = (json['timepoint'] as num?)?.toDouble() ?? 0.0;
    } else if (json.containsKey('t')) {
      parsedTime = (json['t'] as num?)?.toDouble() ?? 0.0;
    }

    String parsedText = '';
    if (json.containsKey('text')) {
      parsedText = json['text']?.toString() ?? '';
    } else if (json.containsKey('m')) {
      parsedText = json['m']?.toString() ?? '';
    } else if (json.containsKey('content')) {
      parsedText = json['content']?.toString() ?? '';
    } else if (json.containsKey('msg')) {
      parsedText = json['msg']?.toString() ?? '';
    }

    Color parsedColor = Colors.white;
    final rawColor = json['color'] ?? json['c'];
    if (rawColor is int) {
      if (rawColor <= 0xFFFFFF) {
        parsedColor = Color(0xFF000000 | rawColor);
      } else {
        parsedColor = Color(rawColor);
      }
    } else if (rawColor is String && rawColor.isNotEmpty) {
      String hex = rawColor.replaceAll('#', '').trim();
      if (hex.length == 6) {
        final val = int.tryParse('FF$hex', radix: 16);
        if (val != null) parsedColor = Color(val);
      } else if (hex.length == 8) {
        final val = int.tryParse(hex, radix: 16);
        if (val != null) parsedColor = Color(val);
      }
    }

    DanmakuType parsedType = DanmakuType.scroll;
    final rawType = json['type'] ?? json['mode'];
    if (rawType == 1 || rawType == '1' || rawType == 'top' || rawType == 5) {
      parsedType = DanmakuType.top;
    } else if (rawType == 2 || rawType == 4 || rawType == 'bottom') {
      parsedType = DanmakuType.bottom;
    }

    return DanmakuItem(
      time: parsedTime,
      text: parsedText,
      color: parsedColor,
      type: parsedType,
    );
  }

  /// 解析 Bilibili 标准 P 属性格式: "time,type,size,color,timestamp,pool,uid,rowid"
  factory DanmakuItem.fromPString(String p, String text) {
    final parts = p.split(',');
    double parsedTime = 0.0;
    DanmakuType parsedType = DanmakuType.scroll;
    Color parsedColor = Colors.white;

    if (parts.isNotEmpty) {
      parsedTime = double.tryParse(parts[0]) ?? 0.0;
    }
    if (parts.length > 1) {
      final t = int.tryParse(parts[1]) ?? 1;
      if (t == 5) parsedType = DanmakuType.top;
      if (t == 4) parsedType = DanmakuType.bottom;
    }
    if (parts.length > 3) {
      final colorVal = int.tryParse(parts[3]);
      if (colorVal != null && colorVal > 0) {
        parsedColor = Color(0xFF000000 | colorVal);
      }
    }

    return DanmakuItem(
      time: parsedTime,
      text: text,
      color: parsedColor,
      type: parsedType,
    );
  }
}

/// 弹幕系统全局偏好配置
class DanmakuConfig {
  bool enabled;
  String serverUrl;
  double opacity;
  double fontSize; // 弹幕字体大小 (12 - 28)
  double speed; // 滚动耗时（秒，越小速度越快，默认 6.0）
  double displayArea; // 屏幕显示高度比例
  bool showStroke; // 是否文字描边加黑 (增强清晰度)
  int maxLines; // 默认最大行数 (默认提升至 6 行，更充盈饱满)
  Color defaultColor; // 默认弹幕颜色 (默认白色)
  bool antiOverlap; // 智能防重叠通道碰撞检测 (默认 true)
  bool isRandomColor; // 是否开启随机炫彩颜色
  String gradientStyle; // 渐变风格: '无' (默认), '极光蓝', '落霞红', '赛博紫', '流光金', '荧光绿', '随机渐变'
  int maxScreenCount; // 同屏最大弹幕数限制 (防密集刷屏，默认 120 条充足显示)
  int timeOffset; // 弹幕时间偏移（秒），正数推迟，负数提前，默认 0

  String colorMode; // '原色', '纯白', '炫彩', '护眼黄', '柔和蓝', '薄荷绿', '极光渐变'

  static const String defaultServerUrl = '';

  DanmakuConfig({
    this.enabled = true,
    this.serverUrl = defaultServerUrl,
    this.opacity = 0.85,
    this.fontSize = 19.2, // 默认 1.2 倍（基准 16.0px × 1.2）
    this.speed = 6.0,
    this.displayArea = 0.75, // 显示区域默认 75% 提升可视高度
    this.showStroke = false, // 默认不描边
    this.maxLines = 3, // 默认 3 行
    this.defaultColor = Colors.white, // 默认白色
    this.antiOverlap = true, // 默认开启智能防重叠
    this.isRandomColor = false,
    this.gradientStyle = '无',
    this.maxScreenCount = 120, // 提升同屏上限为 120 条
    this.timeOffset = 0,
    this.colorMode = '炫彩',
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'serverUrl': serverUrl,
    'opacity': opacity,
    'fontSize': fontSize,
    'speed': speed,
    'displayArea': displayArea,
    'showStroke': showStroke,
    'maxLines': maxLines,
    'defaultColor': defaultColor.toARGB32(),
    'antiOverlap': antiOverlap,
    'isRandomColor': isRandomColor,
    'gradientStyle': gradientStyle,
    'maxScreenCount': maxScreenCount,
    'timeOffset': timeOffset,
    'colorMode': colorMode,
  };

  factory DanmakuConfig.fromJson(Map<String, dynamic> json) {
    final rawUrl = json['serverUrl']?.toString().trim();
    Color parsedColor = Colors.white;
    if (json.containsKey('defaultColor')) {
      final cVal = json['defaultColor'];
      if (cVal is int) parsedColor = Color(cVal);
    }

    return DanmakuConfig(
      enabled: json['enabled'] as bool? ?? true,
      serverUrl: (rawUrl == null || rawUrl.isEmpty) ? defaultServerUrl : rawUrl,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.85,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 19.2,
      speed: (json['speed'] as num?)?.toDouble() ?? 6.0,
      displayArea: (json['displayArea'] as num?)?.toDouble() ?? 0.75,
      showStroke: json['showStroke'] as bool? ?? false,
      maxLines: (json['maxLines'] as num?)?.toInt() ?? 3,
      defaultColor: parsedColor,
      antiOverlap: json['antiOverlap'] as bool? ?? true,
      isRandomColor: json['isRandomColor'] as bool? ?? false,
      gradientStyle: json['gradientStyle']?.toString() ?? '无',
      maxScreenCount: (json['maxScreenCount'] as num?)?.toInt() ?? 120,
      timeOffset: (json['timeOffset'] as num?)?.toInt() ?? 0,
      colorMode: json['colorMode']?.toString() ?? '炫彩',
    );
  }
}