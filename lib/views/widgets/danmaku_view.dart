import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/danmaku_model.dart';

/// 高性能 60fps 弹幕渲染视图，支持防碰撞多轨道、高对比文字描边、时间平滑插值及实时速度透明度调节
class DanmakuView extends StatefulWidget {
  final List<DanmakuItem> danmakus;
  final Duration currentPosition;
  final bool isPlaying;
  final DanmakuConfig config;
  final double playbackRate;

  const DanmakuView({
    super.key,
    required this.danmakus,
    required this.currentPosition,
    required this.isPlaying,
    required this.config,
    this.playbackRate = 1.0,
  });

  @override
  State<DanmakuView> createState() => _DanmakuViewState();
}

class _DanmakuViewState extends State<DanmakuView>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  final Map<int, int> _assignedTracks = {}; // itemIndex -> trackIndex
  final List<double> _trackLastTailX = []; // trackIndex -> last rightmost X coordinate

  DateTime _lastPositionUpdateTime = DateTime.now();
  Duration _lastPosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    _lastPosition = widget.currentPosition;
    _lastPositionUpdateTime = DateTime.now();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(() {
        if (mounted) setState(() {});
      });

    if (widget.isPlaying && widget.config.enabled) {
      _animController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant DanmakuView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying && widget.config.enabled) {
        if (!_animController.isAnimating) _animController.repeat();
      } else {
        if (_animController.isAnimating) _animController.stop();
      }
    }

    if (widget.currentPosition != oldWidget.currentPosition) {
      _lastPosition = widget.currentPosition;
      _lastPositionUpdateTime = DateTime.now();

      if ((widget.currentPosition - oldWidget.currentPosition).abs().inSeconds > 2) {
        _assignedTracks.clear();
        _trackLastTailX.clear();
      }
    }

    if (widget.config.enabled != oldWidget.config.enabled) {
      if (widget.config.enabled && widget.isPlaying) {
        if (!_animController.isAnimating) _animController.repeat();
      } else {
        if (_animController.isAnimating) _animController.stop();
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.config.enabled || widget.danmakus.isEmpty) {
      return const SizedBox.shrink();
    }

    if (widget.isPlaying && !_animController.isAnimating) {
      _animController.repeat();
    }

    double currentSeconds = _lastPosition.inMilliseconds / 1000.0;
    if (widget.isPlaying) {
      final elapsedSec =
          DateTime.now().difference(_lastPositionUpdateTime).inMicroseconds /
              1000000.0;
      currentSeconds += elapsedSec.clamp(0.0, 1.2) * widget.playbackRate;
    }

    return IgnorePointer(
      child: Opacity(
        opacity: widget.config.opacity.clamp(0.1, 1.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _DanmakuPainter(
                danmakus: widget.danmakus,
                currentSeconds: currentSeconds,
                config: widget.config,
                assignedTracks: _assignedTracks,
                trackLastTailX: _trackLastTailX,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<DanmakuItem> danmakus;
  final double currentSeconds;
  final DanmakuConfig config;
  final Map<int, int> assignedTracks;
  final List<double> trackLastTailX;

  static const List<Color> _rainbowColors = [
    Color(0xFFFF6B81), // 樱花粉
    Color(0xFF00E5FF), // 荧光青
    Color(0xFFFFEB3B), // 柠檬黄
    Color(0xFF69F0AE), // 薄荷绿
    Color(0xFFFF9F43), // 暖橙色
    Color(0xFFE056FD), // 幻梦紫
    Color(0xFF54A0FF), // 晴空蓝
    Color(0xFFFF7675), // 珊瑚红
    Color(0xFF55E6C1), // 绿松石
    Color(0xFFFDCB6E), // 浅金黄
    Color(0xFFFF9FF3), // 浅粉紫
    Color(0xFF48DBFB), // 晴川青
  ];

  static const Map<String, List<Color>> _gradientMap = {
    '极光蓝': [Color(0xFF00F2FE), Color(0xFF4FACFE)],
    '落霞红': [Color(0xFFFF512F), Color(0xFFDD2476)],
    '赛博紫': [Color(0xFFFF007F), Color(0xFF7928CA)],
    '流光金': [Color(0xFFFFE000), Color(0xFFFF8C00)],
    '荧光绿': [Color(0xFF11998E), Color(0xFF38EF7D)],
  };

  _DanmakuPainter({
    required this.danmakus,
    required this.currentSeconds,
    required this.config,
    required this.assignedTracks,
    required this.trackLastTailX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || danmakus.isEmpty) return;

    final double lineHeight = (config.fontSize * 1.5).clamp(18.0, 56.0);
    final int calculatedTracks =
        (size.height * config.displayArea / lineHeight).floor();
    final int maxTracks = min(config.maxLines, max(1, calculatedTracks));

    while (trackLastTailX.length < maxTracks) {
      trackLastTailX.add(-9999.0);
    }

    final double speedDuration = config.speed.clamp(3.0, 15.0);

    // 二分搜索定位时间窗口
    int startIndex = _binarySearchStart(currentSeconds - speedDuration);
    if (startIndex < 0) startIndex = 0;

    int onScreenCount = 0;
    const double minHorizontalGap = 36.0; // 同一轨道前后弹幕的最小安全间距，彻底避免重叠

    for (int i = startIndex; i < danmakus.length; i++) {
      final item = danmakus[i];

      // 💡 需求明确：不支持底部弹幕，直接跳过，保证字幕不被遮盖
      if (item.type == DanmakuType.bottom) continue;

      final elapsed = currentSeconds - item.time;
      if (elapsed < 0) break;
      if (elapsed > speedDuration) continue;

      // 同屏密度限制 (避免过于密集遮挡画面)
      if (config.maxScreenCount > 0 && onScreenCount >= config.maxScreenCount) {
        continue;
      }

      final progress = elapsed / speedDuration;

      // 1. 颜色与渐变计算
      Color textColor = (item.color == Colors.white) ? config.defaultColor : item.color;
      if (config.isRandomColor) {
        final colorIndex = (item.text.hashCode ^ i).abs() % _rainbowColors.length;
        textColor = _rainbowColors[colorIndex];
      }

      List<Color>? gradientColors;
      if (config.gradientStyle != '无') {
        if (config.gradientStyle == '随机渐变') {
          final keys = _gradientMap.keys.toList();
          final gKey = keys[(item.text.hashCode ^ i).abs() % keys.length];
          gradientColors = _gradientMap[gKey];
        } else {
          gradientColors = _gradientMap[config.gradientStyle];
        }
      }

      final effectiveFontSize = item.fontSize ?? config.fontSize;

      // 构建文字绘制器
      final textSpan = TextSpan(
        text: item.text,
        style: TextStyle(
          fontSize: effectiveFontSize,
          fontWeight: FontWeight.bold,
          color: gradientColors == null ? textColor : null,
          foreground: gradientColors != null
              ? (Paint()
                ..shader = LinearGradient(
                  colors: gradientColors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ).createShader(Rect.fromLTWH(0, 0, (item.text.length * effectiveFontSize).toDouble(), effectiveFontSize)))
              : null,
          shadows: config.showStroke
              ? const [
                  Shadow(offset: Offset(-1.2, -1.2), color: Colors.black),
                  Shadow(offset: Offset(1.2, -1.2), color: Colors.black),
                  Shadow(offset: Offset(1.2, 1.2), color: Colors.black),
                  Shadow(offset: Offset(-1.2, 1.2), color: Colors.black),
                ]
              : null,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      // 2. 智能防重叠轨道分配
      int track = assignedTracks[i] ?? -1;
      if (track < 0 || track >= maxTracks) {
        if (config.antiOverlap) {
          int bestTrack = -1;
          double minTail = 999999.0;
          for (int t = 0; t < maxTracks; t++) {
            final lastTail = trackLastTailX[t];
            // 只要该轨道的上一条弹幕已经完全进入屏幕并留出安全间距，就可入轨
            if (lastTail <= size.width - minHorizontalGap) {
              if (lastTail < minTail) {
                minTail = lastTail;
                bestTrack = t;
              }
            }
          }

          if (bestTrack >= 0) {
            track = bestTrack;
            assignedTracks[i] = track;
          } else {
            // 所有轨道当前入轨位置均被占用，开启防重叠时丢弃以避免追尾重叠
            continue;
          }
        } else {
          track = i % maxTracks;
          assignedTracks[i] = track;
        }
      }

      final double y = track * lineHeight + (lineHeight - effectiveFontSize) / 2;

      if (item.type == DanmakuType.scroll) {
        final double startX = size.width;
        final double endX = -textPainter.width;
        final double currentX = startX - progress * (startX - endX);
        final double currentTailX = currentX + textPainter.width;

        trackLastTailX[track] = max(trackLastTailX[track], currentTailX);

        textPainter.paint(canvas, Offset(currentX, y));
        onScreenCount++;
      } else if (item.type == DanmakuType.top) {
        final double currentX = (size.width - textPainter.width) / 2;
        textPainter.paint(canvas, Offset(currentX, y));
        onScreenCount++;
      }
    }
  }

  int _binarySearchStart(double targetTime) {
    int low = 0;
    int high = danmakus.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      if (danmakus[mid].time < targetTime) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return true;
  }
}
