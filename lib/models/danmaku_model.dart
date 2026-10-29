import 'package:flutter/material.dart';

enum DanmakuType {
  scroll, // 滚动弹幕（自右向左）
  top,    // 顶部固定
  bottom, // 底部固定
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
    // 1. 解析时间点 (time / timepoint / t / p)
    double parsedTime = 0.0;
    if (json.containsKey('time')) {
      parsedTime = (json['time'] as num?)?.toDouble() ?? 0.0;
    } else if (json.containsKey('timepoint')) {
      parsedTime = (json['timepoint'] as num?)?.toDouble() ?? 0.0;
    } else if (json.containsKey('t')) {
      parsedTime = (json['t'] as num?)?.toDouble() ?? 0.0;
    }

    // 2. 解析文字 (text / m / content / msg)
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

    // 3. 解析颜色 (color / c)
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

    // 4. 解析类型 (type / mode)
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
  double fontSize;
  double speed; // 滚动耗时（秒，越小速度越快，默认 6.0）
  double displayArea; // 屏幕显示高度比例 (0.25, 0.5, 0.75, 1.0)
  bool showStroke; // 是否文字描边加黑

  static const String defaultServerUrl = 'https://dm.0256520.xyz/888';

  DanmakuConfig({
    this.enabled = true,
    this.serverUrl = defaultServerUrl,
    this.opacity = 0.85,
    this.fontSize = 16.0,
    this.speed = 6.0,
    this.displayArea = 0.5,
    this.showStroke = true,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'serverUrl': serverUrl,
    'opacity': opacity,
    'fontSize': fontSize,
    'speed': speed,
    'displayArea': displayArea,
    'showStroke': showStroke,
  };

  factory DanmakuConfig.fromJson(Map<String, dynamic> json) {
    final rawUrl = json['serverUrl']?.toString().trim();
    return DanmakuConfig(
      enabled: json['enabled'] as bool? ?? true,
      serverUrl: (rawUrl == null || rawUrl.isEmpty) ? defaultServerUrl : rawUrl,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.85,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
      speed: (json['speed'] as num?)?.toDouble() ?? 6.0,
      displayArea: (json['displayArea'] as num?)?.toDouble() ?? 0.5,
      showStroke: json['showStroke'] as bool? ?? true,
    );
  }
}