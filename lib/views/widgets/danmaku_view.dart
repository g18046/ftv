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

      // 快进/快退幅度较大时，清理过期轨道映射以避免跳变
      if ((widget.currentPosition - oldWidget.currentPosition).abs().inSeconds > 2) {
        _assignedTracks.clear();
      }
    }

    if (widget.danmakus != oldWidget.danmakus ||
        widget.danmakus.length != oldWidget.danmakus.length ||
        widget.config.timeOffset != oldWidget.config.timeOffset) {
      _assignedTracks.clear();
      _lastPosition = widget.currentPosition;
      _lastPositionUpdateTime = DateTime.now();
      if (widget.config.enabled && widget.isPlaying && !_animController.isAnimating) {
        _animController.repeat();
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
      currentSeconds += elapsedSec * widget.playbackRate;
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
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || danmakus.isEmpty) return;

    final double lineHeight = (config.fontSize * 1.5).clamp(18.0, 56.0);
    final int calculatedTracks =
        (size.height * config.displayArea / lineHeight).floor();
    final int maxTracks = min(config.maxLines, max(4, calculatedTracks));

    // 每帧独立维护滚动轨道的尾部 X 坐标、速度与顶部弹幕占位时间，彻底杜绝追尾与重叠
    final List<double> currentFrameTailX = List<double>.filled(maxTracks, -9999.0);
    final List<double> currentFrameSpeed = List<double>.filled(maxTracks, 0.0);
    final List<bool> topTrackOccupied = List<bool>.filled(maxTracks, false);

    final double speedDuration = config.speed.clamp(3.0, 15.0);

    // 二分搜索定位时间窗口
    int startIndex = _binarySearchStart(currentSeconds - speedDuration - config.timeOffset);
    if (startIndex < 0) startIndex = 0;

    // 仅清理已完全滑出屏幕的旧弹幕轨道缓存，绝不清理屏幕内弹幕
    if (assignedTracks.length > 600) {
      assignedTracks.removeWhere((idx, _) =>
          idx < startIndex - 20 || idx >= danmakus.length);
    }

    int onScreenCount = 0;

    for (int i = startIndex; i < danmakus.length; i++) {
      final item = danmakus[i];

      // 保证字幕区域清晰：不渲染底部弹幕
      if (item.type == DanmakuType.bottom) continue;

      final effectiveTime = item.time + config.timeOffset;
      final elapsed = currentSeconds - effectiveTime;
      if (elapsed < 0) break; // 列表已按时间升序，后续均未到播放时间
      if (elapsed > speedDuration) continue; // 已离开屏幕

      // 已在入场时被判定丢弃的弹幕，保持丢弃，绝不在中途突然冒出
      final int? cachedTrack = assignedTracks[i];
      if (cachedTrack == -1) continue;

      final progress = elapsed / speedDuration;

      // 1. 颜色与渐变计算 (深度融合色彩设置)
      Color textColor = item.color;
      List<Color>? gradientColors;

      switch (config.colorMode) {
        case '纯白':
          textColor = Colors.white;
          break;
        case '炫彩':
          final colorIndex = (item.text.hashCode ^ i).abs() % _rainbowColors.length;
          textColor = _rainbowColors[colorIndex];
          break;
        case '护眼黄':
          textColor = const Color(0xFFFFF176); // 温润柔和淡黄
          break;
        case '柔和蓝':
          textColor = const Color(0xFF81D4FA); // 舒适护眼天蓝
          break;
        case '薄荷绿':
          textColor = const Color(0xFFA5D6A7); // 清爽薄荷绿
          break;
        case '极光渐变':
          gradientColors = _gradientMap['极光蓝'];
          break;
        case '落霞渐变':
          gradientColors = _gradientMap['落霞红'];
          break;
        case '原色':
        default:
          if (config.isRandomColor) {
            final colorIndex = (item.text.hashCode ^ i).abs() % _rainbowColors.length;
            textColor = _rainbowColors[colorIndex];
          } else if (config.gradientStyle != '无') {
            gradientColors = _gradientMap[config.gradientStyle];
          } else {
            textColor = (item.color == Colors.white) ? config.defaultColor : item.color;
          }
          break;
      }

      final effectiveFontSize = item.fontSize ?? config.fontSize;

      // 构建文字绘制器
      final textSpan = TextSpan(
        text: item.text,
        style: TextStyle(
          fontSize: effectiveFontSize,
          fontWeight: FontWeight.normal,
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

      // 滚动弹幕的起始位置、速度与当前 X
      final double startX = size.width;
      final double endX = -textPainter.width;
      final double currentX = startX - progress * (startX - endX);
      final double currentTailX = currentX + textPainter.width;
      final double velocity = (startX - endX) / speedDuration;
      const double safeGap = 20.0;

      if (item.type == DanmakuType.top) {
        // 顶部固定弹幕独立轨道判重（最多显示 4 秒）
        if (elapsed > 4.0) continue;
        int topTrack;
        if (cachedTrack != null) {
          // 已入场的顶部弹幕保持原轨道走完 4 秒，不中途跳变或消失
          topTrack = cachedTrack.clamp(0, maxTracks - 1);
        } else {
          if (config.maxScreenCount > 0 && onScreenCount >= config.maxScreenCount) {
            assignedTracks[i] = -1;
            continue;
          }
          topTrack = -1;
          for (int t = 0; t < maxTracks; t++) {
            if (!topTrackOccupied[t]) {
              topTrack = t;
              break;
            }
          }
          if (topTrack < 0) {
            assignedTracks[i] = -1;
            continue;
          }
          assignedTracks[i] = topTrack;
        }
        topTrackOccupied[topTrack] = true;
        final double y = topTrack * lineHeight + (lineHeight - effectiveFontSize) / 2;
        final double topX = (size.width - textPainter.width) / 2;
        textPainter.paint(canvas, Offset(topX, y));
        onScreenCount++;
        continue;
      }

      // 2. 滚动弹幕严格防重叠与防追尾轨道分配（已入场弹幕锁定轨道直到完全滑出屏幕）
      bool canFitTrack(int t) {
        final prevTail = currentFrameTailX[t];
        if (prevTail <= -9000.0) return true;
        if (currentX < prevTail + safeGap) return false;
        final prevV = currentFrameSpeed[t];
        if (prevV > 0 && velocity > prevV && prevTail > 0) {
          final exitTime = prevTail / prevV;
          final futureX = currentX - velocity * exitTime;
          if (futureX < safeGap) return false;
        }
        return true;
      }

      int track;
      if (cachedTrack != null) {
        // 已入场弹幕锁定轨道，必须完整走完，绝不中途换轨或被同屏上限截断
        track = cachedTrack.clamp(0, maxTracks - 1);
      } else {
        if (config.maxScreenCount > 0 && onScreenCount >= config.maxScreenCount) {
          assignedTracks[i] = -1;
          continue;
        }
        if (config.antiOverlap) {
          int bestTrack = -1;
          double minTail = 999999.0;
          for (int t = 0; t < maxTracks; t++) {
            if (canFitTrack(t)) {
              if (currentFrameTailX[t] < minTail) {
                minTail = currentFrameTailX[t];
                bestTrack = t;
              }
            }
          }
          if (bestTrack >= 0) {
            track = bestTrack;
            assignedTracks[i] = track;
          } else {
            // 无安全不重叠轨道时在入场阶段直接丢弃，后续帧不再补绘
            assignedTracks[i] = -1;
            continue;
          }
        } else {
          track = i % maxTracks;
          assignedTracks[i] = track;
        }
      }

      if (currentTailX > currentFrameTailX[track]) {
        currentFrameTailX[track] = currentTailX;
        currentFrameSpeed[track] = velocity;
      }

      final double y = track * lineHeight + (lineHeight - effectiveFontSize) / 2;
      textPainter.paint(canvas, Offset(currentX, y));
      onScreenCount++;
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
