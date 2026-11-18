import 'dart:async';
import 'package:flutter/material.dart';

/// 水平跑马灯无缝自动滚动组件
class MarqueeWidget extends StatefulWidget {
  final Widget child;
  final Axis direction;
  final Duration animationDuration;
  final Duration backDuration;
  final Duration pauseDuration;

  const MarqueeWidget({
    super.key,
    required this.child,
    this.direction = Axis.horizontal,
    this.animationDuration = const Duration(milliseconds: 6000),
    this.backDuration = const Duration(milliseconds: 1000),
    this.pauseDuration = const Duration(milliseconds: 1500),
  });

  @override
  State<MarqueeWidget> createState() => _MarqueeWidgetState();
}

class _MarqueeWidgetState extends State<MarqueeWidget> {
  final ScrollController _scrollController = ScrollController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startMarquee());
  }

  void _startMarquee() async {
    if (!mounted) return;
    _timer?.cancel();

    _timer = Timer.periodic(
        widget.animationDuration + widget.backDuration + widget.pauseDuration * 2,
        (_) async {
      if (!mounted || !_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll <= 0) return;

      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_scrollController.hasClients) return;

      await _scrollController.animateTo(
        maxScroll,
        duration: widget.animationDuration,
        curve: Curves.linear,
      );

      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_scrollController.hasClients) return;

      await _scrollController.animateTo(
        0,
        duration: widget.backDuration,
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: widget.direction,
      physics: const NeverScrollableScrollPhysics(),
      child: widget.child,
    );
  }
}

/// 微信朋友圈风格折叠/展开文本组件
class ExpandableContentWidget extends StatefulWidget {
  final String content;
  final int maxLines;
  final TextStyle style;
  final VoidCallback? onCopy;

  const ExpandableContentWidget({
    super.key,
    required this.content,
    this.maxLines = 3,
    required this.style,
    this.onCopy,
  });

  @override
  State<ExpandableContentWidget> createState() =>
      _ExpandableContentWidgetState();
}

class _ExpandableContentWidgetState extends State<ExpandableContentWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final textSpan = TextSpan(text: widget.content, style: widget.style);
            final textPainter = TextPainter(
              text: textSpan,
              maxLines: widget.maxLines,
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: constraints.maxWidth);

            final isOverflowing = textPainter.didExceedMaxLines;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: widget.onCopy,
                  child: SelectableText(
                    widget.content,
                    style: widget.style,
                    maxLines: _isExpanded ? null : widget.maxLines,
                  ),
                ),
                if (isOverflowing) ...[
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () {
                      setState(() => _isExpanded = !_isExpanded);
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 2.0, horizontal: 4.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _isExpanded ? '收起' : '展开全文',
                            style: const TextStyle(
                              color: Color(0xFF2979FF),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            _isExpanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 16,
                            color: const Color(0xFF2979FF),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

