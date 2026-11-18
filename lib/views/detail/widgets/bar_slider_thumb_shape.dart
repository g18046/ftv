import 'package:flutter/material.dart';

/// 自定义垂直粗指示条滑块 Thumb (匹配图 2 弹幕设置中的滑块竖条设计)
class BarSliderThumbShape extends SliderComponentShape {
  final double width;
  final double height;
  const BarSliderThumbShape({this.width = 3.0, this.height = 16.0});

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      const Radius.circular(2),
    );
    canvas.drawRRect(rrect, paint);
  }
}
