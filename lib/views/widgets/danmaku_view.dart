import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/danmaku_model.dart';

/// 高性能弹幕渲染视图，支持防碰撞多轨道、描边、速度与透明度实时调节
class DanmakuView extends StatefulWidget {
  final List<DanmakuItem> danmakus;
  final Duration currentPosition;
  final bool isPlaying;
  final DanmakuConfig config;

  const DanmakuView({
    super.key,
    required this.danmakus,
    required this.currentPosition,
    required this.isPlaying,
    required this.config,
  });

  @override
  State<DanmakuView> createState() => _DanmakuViewState();
}

class _DanmakuViewState extends State<DanmakuView> with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  final Map<int, int> _assignedTracks = {}; // itemIndex -> trackIndex
  final List<double> _trackLastTailX = []; // trackIndex -> last rightmost X coordinate

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(() {
        if (mounted) setState(() {});
      });
    if (widget.isPlaying) {
      _animController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant DanmakuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        if (!_animController.isAnimating) _animController.repeat();
      } else {
        _animController.stop();
      }
    }
    // 进度跳转较大时清空轨道映射
    if ((widget.currentPosition - oldWidget.currentPosition).abs().inSeconds > 2) {
      _assignedTracks.clear();
      _trackLastTailX.clear();
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

    return IgnorePointer(
      child: Opacity(
        opacity: widget.config.opacity.clamp(0.1, 1.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _DanmakuPainter(
                danmakus: widget.danmakus,
                currentSeconds: widget.currentPosition.inMilliseconds / 1000.0,
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

  _DanmakuPainter({
    required this.danmakus,
    required this.currentSeconds,
    required this.config,
    required this.assignedTracks,
    required this.trackLastTailX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final double lineHeight = (config.fontSize * 1.5).clamp(18.0, 48.0);
    final int maxTracks = max(1, (size.height * config.displayArea / lineHeight).floor());

    // 确保轨道容器大小
    while (trackLastTailX.length < maxTracks) {
      trackLastTailX.add(-9999.0);
    }

    final double speedDuration = config.speed.clamp(3.0, 15.0);

    // 二分搜索快速定位当前时间窗口内的弹幕 [currentSeconds - speedDuration, currentSeconds + 0.5]
    int startIndex = _binarySearchStart(currentSeconds - speedDuration);
    if (startIndex < 0) startIndex = 0;

    for (int i = startIndex; i < danmakus.length; i++) {
      final item = danmakus[i];
      final elapsed = currentSeconds - item.time;

      // 还没到出现时间
      if (elapsed < 0) break;

      // 已经超出右向左滚动生命周期
      if (elapsed > speedDuration) continue;

      final progress = elapsed / speedDuration; // 0.0 -> 1.0

      // 计算轨道 (首次进入窗口时分配)
      int track = assignedTracks[i] ?? -1;
      if (track < 0 || track >= maxTracks) {
        track = i % maxTracks; // 均匀分配轨道
        assignedTracks[i] = track;
      }

      final double y = track * lineHeight + (lineHeight - config.fontSize) / 2;

      final textSpan = TextSpan(
        text: item.text,
        style: TextStyle(
          fontSize: item.fontSize ?? config.fontSize,
          fontWeight: FontWeight.bold,
          color: item.color,
          shadows: config.showStroke
              ? const [
                  Shadow(offset: Offset(-1, -1), color: Colors.black87),
                  Shadow(offset: Offset(1, -1), color: Colors.black87),
                  Shadow(offset: Offset(1, 1), color: Colors.black87),
                  Shadow(offset: Offset(-1, 1), color: Colors.black87),
                ]
              : null,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      if (item.type == DanmakuType.scroll) {
        // 自右向左移动
        final double startX = size.width;
        final double endX = -textPainter.width;
        final double currentX = startX - progress * (startX - endX);

        textPainter.paint(canvas, Offset(currentX, y));
      } else if (item.type == DanmakuType.top) {
        // 顶部固定居中
        final double currentX = (size.width - textPainter.width) / 2;
        textPainter.paint(canvas, Offset(currentX, y));
      } else if (item.type == DanmakuType.bottom) {
        // 底部固定居中
        final double currentX = (size.width - textPainter.width) / 2;
        final double bottomY = size.height - (track + 1) * lineHeight;
        textPainter.paint(canvas, Offset(currentX, bottomY));
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
    return true; // 随动画每一帧刷新
  }
}
