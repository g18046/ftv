import 'dart:math';
import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';

/// 根据可用宽度与剧集名称长度，动态计算合适的列数与卡片宽高比
({int crossAxisCount, double childAspectRatio}) computeDynamicEpisodeGrid({
  required double availableWidth,
  required List<EpisodeItem> episodes,
  int maxColumns = 8,
  double spacing = 10.0,
  double targetCardHeight = 46.0,
}) {
  if (episodes.isEmpty || availableWidth <= 0) {
    return (crossAxisCount: 4, childAspectRatio: 2.3);
  }

  int maxUnits = 0;
  int totalUnits = 0;
  final sampleCount = min(episodes.length, 30);
  for (int i = 0; i < sampleCount; i++) {
    final name = episodes[i].name.trim();
    int units = 0;
    for (final rune in name.runes) {
      units += rune > 127 ? 2 : 1;
    }
    if (units > maxUnits) maxUnits = units;
    totalUnits += units;
  }
  final avgUnits = (totalUnits / sampleCount).ceil();
  // 兼顾平均长度与最长名称，避免个别超长名称把整体列数压得过少，同时保证长名称有足够宽度
  final effectiveUnits = ((avgUnits * 0.65) + (maxUnits * 0.35)).ceil();

  // 每个字符单位约 7.2px，加上内边距与徽章空间
  final desiredCardWidth = (effectiveUnits * 6.8 + 30.0).clamp(84.0, 230.0);
  final cols = (availableWidth / (desiredCardWidth + spacing))
      .floor()
      .clamp(1, maxColumns);

  final actualCardWidth = (availableWidth - spacing * (cols - 1)) / cols;
  final ratio = (actualCardWidth / targetCardHeight).clamp(1.8, 8.0);
  return (crossAxisCount: cols, childAspectRatio: ratio);
}

/// 从剧集名称中提取清晰的剧集号与剩余描述
({String? badge, String desc}) splitEpisodeBadgeAndDesc(String rawName) {
  final name = rawName.trim();
  if (name.isEmpty) return (badge: null, desc: '');

  // 1. 优先匹配 S01E01 / S1E12 / 第01集 / EP01 / E01 等明确剧集标识
  final patterns = <RegExp>[
    RegExp(r'\bS\d{1,2}E\d{1,4}\b', caseSensitive: false),
    RegExp(r'第\s*\d{1,4}\s*[集话期部]'),
    RegExp(r'\bEP?\s*0?\d{1,4}\b', caseSensitive: false),
  ];

  for (final re in patterns) {
    final m = re.firstMatch(name);
    if (m != null) {
      final badge = m.group(0)!.replaceAll(RegExp(r'\s+'), '');
      final before = name.substring(0, m.start).trim();
      final after = name.substring(m.end).trim();
      final rest = [before, after]
          .where((s) => s.isNotEmpty)
          .join(' ')
          .replaceFirst(RegExp(r'^[-_|:：\s]+'), '')
          .trim();
      if (rest.isEmpty) {
        return (badge: null, desc: name);
      }
      return (badge: badge, desc: rest);
    }
  }

  // 2. 匹配如 "[1.26GB] 159" 或纯末尾数字剧集号（排除分辨率 1080/2160/4K 等）
  final trailingNum = RegExp(r'(?:^|\s)(\d{1,4})$').firstMatch(name);
  if (trailingNum != null) {
    final numStr = trailingNum.group(1)!;
    if (numStr != '1080' && numStr != '2160' && numStr != '720' && numStr != '480') {
      final rest = name.substring(0, trailingNum.start).trim();
      if (rest.isNotEmpty) {
        return (badge: '第$numStr集', desc: rest);
      }
    }
  }

  return (badge: null, desc: name);
}

/// 剧集卡片内容：展示不下时突出剧集号，并对描述启用快速跑马灯
class EpisodeCardContent extends StatelessWidget {
  final String name;
  final TextStyle textStyle;
  final Color badgeBgColor;
  final Color badgeTextColor;
  final bool enableMarquee;

  const EpisodeCardContent({
    super.key,
    required this.name,
    required this.textStyle,
    required this.badgeBgColor,
    required this.badgeTextColor,
    this.enableMarquee = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        if (maxW <= 0) return const SizedBox.shrink();

        // 先测量完整标题是否能直接一行放下
        final fullPainter = TextPainter(
          text: TextSpan(text: name, style: textStyle),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();

        if (fullPainter.width <= maxW) {
          return Center(
            child: Text(
              name,
              maxLines: 1,
              style: textStyle,
              textAlign: TextAlign.center,
            ),
          );
        }

        // 展示不下：提取剧集号固定展示 + 描述快速跑马灯
        final parsed = splitEpisodeBadgeAndDesc(name);
        if (parsed.badge != null && parsed.desc.isNotEmpty) {
          return Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeBgColor,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  parsed.badge!,
                  maxLines: 1,
                  style: textStyle.copyWith(
                    color: badgeTextColor,
                    fontWeight: FontWeight.bold,
                    fontSize: (textStyle.fontSize ?? 12.5) - 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: enableMarquee
                    ? FastMarqueeText(
                        text: parsed.desc,
                        style: textStyle,
                      )
                    : Text(
                        parsed.desc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textStyle,
                      ),
              ),
            ],
          );
        }

        return enableMarquee
            ? FastMarqueeText(
                text: name,
                style: textStyle,
              )
            : Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              );
      },
    );
  }
}

class FastMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const FastMarqueeText({
    required this.text,
    required this.style,
  });

  @override
  State<FastMarqueeText> createState() => FastMarqueeTextState();
}

class FastMarqueeTextState extends State<FastMarqueeText>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  double _textWidth = 0;
  double _containerWidth = 0;
  static const double _gap = 28.0;
  static const double _speedPxPerSec = 68.0;

  @override
  void didUpdateWidget(covariant FastMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _reconfigure(_containerWidth);
    }
  }

  void _reconfigure(double availableWidth) {
    _containerWidth = availableWidth;
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = tp.width;

    if (_textWidth <= availableWidth || availableWidth <= 0) {
      _controller?.stop();
      return;
    }

    final cycleDistance = _textWidth + _gap;
    final durationMs = max(1200, (cycleDistance / _speedPxPerSec * 1000).round());
    if (_controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: durationMs),
      )..repeat();
    } else {
      _controller!.duration = Duration(milliseconds: durationMs);
      if (!_controller!.isAnimating) {
        _controller!.repeat();
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        if ((w - _containerWidth).abs() > 0.5 || _textWidth == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _reconfigure(w));
            }
          });
        }

        if (_textWidth <= w || _controller == null) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        final cycleDistance = _textWidth + _gap;
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller!,
            builder: (context, child) {
              final offset = -_controller!.value * cycleDistance;
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Transform.translate(
                    offset: Offset(offset, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
                        const SizedBox(width: _gap),
                        Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
