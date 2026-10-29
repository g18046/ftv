import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 适配 TV 遥控器与桌面端键盘焦点的通用包装组件
/// 具备 OK 影视风格金黄色高亮边框、弹性缩放动画与遥控器确定键激活
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final BorderRadius? borderRadius;
  final double scaleFactor;
  final Color focusBorderColor;
  final EdgeInsets? padding;

  const TvFocusable({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius,
    this.scaleFactor = 1.05,
    this.focusBorderColor = const Color(0xFFE5A00D), // OK影视经典金琥珀焦点色
    this.padding,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode _node;
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode();
    _node.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _node.dispose();
    } else {
      _node.removeListener(_handleFocusChange);
    }
    super.dispose();
  }

  void _handleFocusChange() {
    if (mounted) {
      setState(() => _isFocused = _node.hasFocus);
      if (_node.hasFocus) {
        // TV 端获得焦点时，确保当前组件平滑滚动进入视口中心
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        widget.onPressed?.call();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final active = _isFocused || _isHovered;
    final radius = widget.borderRadius ?? BorderRadius.circular(8);

    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: active ? widget.scaleFactor : 1.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: widget.padding,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: active ? widget.focusBorderColor : Colors.transparent,
                  width: active ? 2.5 : 0.0,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: widget.focusBorderColor.withOpacity(0.35),
                          blurRadius: 10,
                          spreadRadius: 1.5,
                        ),
                      ]
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
