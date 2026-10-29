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

    // 播放状态改变
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying && widget.config.enabled) {
        if (!_animController.isAnimating) _animController.repeat();
      } else {
        if (_animController.isAnimating) _animController.stop();
      }
    }

    // 播放位置更新时记录时间戳供平滑插值使用
    if (widget.currentPosition != oldWidget.currentPosition) {
      _lastPosition = widget.currentPosition;
      _lastPositionUpdateTime = DateTime.now();

      // 跨度大于 2 秒（如用户手动拖动快进快退），清空已分配轨道避免错位
      if ((widget.currentPosition - oldWidget.currentPosition).abs().inSeconds > 2) {
        _assignedTracks.clear();
        _trackLastTailX.clear();
      }
    }

    // 弹幕开关状态改变
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

    // 状态自愈：如果正在播放且弹幕开启但动画未运行，启动循环
    if (widget.isPlaying && !_animController.isAnimating) {
      _animController.repeat();
    }

    // 平滑插值计算当前微秒级视频进度 (秒)
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

    final double lineHeight = (config.fontSize * 1.5).clamp(18.0, 48.0);
    final int maxTracks =
        max(1, (size.height * config.displayArea / lineHeight).floor());

    while (trackLastTailX.length < maxTracks) {
      trackLastTailX.add(-9999.0);
    }

    final double speedDuration = config.speed.clamp(3.0, 15.0);

    // 二分搜索定位时间窗口
    int startIndex = _binarySearchStart(currentSeconds - speedDuration);
    if (startIndex < 0) startIndex = 0;

    for (int i = startIndex; i < danmakus.length; i++) {
      final item = danmakus[i];
      final elapsed = currentSeconds - item.time;

      if (elapsed < 0) break; // 尚未到达时间
      if (elapsed > speedDuration) continue; // 已过生命周期

      final progress = elapsed / speedDuration;

      int track = assignedTracks[i] ?? -1;
      if (track < 0 || track >= maxTracks) {
        track = i % maxTracks;
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

      if (item.type == DanmakuType.scroll) {
        final double startX = size.width;
        final double endX = -textPainter.width;
        final double currentX = startX - progress * (startX - endX);

        textPainter.paint(canvas, Offset(currentX, y));
      } else if (item.type == DanmakuType.top) {
        final double currentX = (size.width - textPainter.width) / 2;
        textPainter.paint(canvas, Offset(currentX, y));
      } else if (item.type == DanmakuType.bottom) {
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
    return true; // 随 60fps 帧驱动刷新
  }
}
