import 'package:flutter/material.dart';
import '../../../models/subtitle_model.dart';
import '../../../services/theme_service.dart';
import 'bar_slider_thumb_shape.dart';

/// 字幕样式设置弹窗：支持大小、位置、颜色、透明度及背景开关
void showSubtitleSettingsDialog({
  required BuildContext context,
  required SubtitleConfig subtitleConfig,
  required ThemeService themeService,
  required VoidCallback onStateChanged,
}) {
  final colorPresets = <Map<String, dynamic>>[
    {'label': '纯白', 'value': 0xFFFFFFFF},
    {'label': '明黄', 'value': 0xFFFFEB3B},
    {'label': '天蓝', 'value': 0xFF4FC3F7},
    {'label': '翠绿', 'value': 0xFF81C784},
    {'label': '浅粉', 'value': 0xFFF48FB1},
  ];

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (dCtx, setDialogState) {
        void update(VoidCallback mutate) {
          setDialogState(mutate);
          onStateChanged();
          subtitleConfig.save();
        }

        return AlertDialog(
          backgroundColor: const Color(0xFF1E2028),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.subtitles_outlined, color: themeService.accentColor, size: 22),
              const SizedBox(width: 8),
              const Text(
                '字幕样式设置',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  update(() => subtitleConfig.reset());
                },
                child: const Text('恢复默认', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 实时预览区
                  Container(
                    width: double.infinity,
                    height: 68,
                    alignment: Alignment.bottomCenter,
                    padding: EdgeInsets.only(
                      bottom: (subtitleConfig.bottomPadding / 140.0 * 32.0).clamp(4.0, 32.0),
                      left: 12,
                      right: 12,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF263238), Color(0xFF37474F)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '字幕效果预览 Subtitle Preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: (subtitleConfig.fontSize * 0.42).clamp(12.0, 26.0),
                        color: Color(subtitleConfig.colorValue)
                            .withValues(alpha: subtitleConfig.opacity),
                        fontWeight: FontWeight.w500,
                        backgroundColor: subtitleConfig.showBackground
                            ? Colors.black.withValues(alpha: 0.55 * subtitleConfig.opacity)
                            : Colors.transparent,
                        shadows: subtitleConfig.showBackground
                            ? null
                            : [
                                Shadow(
                                  color: Colors.black
                                      .withValues(alpha: 0.9 * subtitleConfig.opacity),
                                  blurRadius: 4,
                                  offset: const Offset(1, 1),
                                ),
                              ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 1. 字体大小
                  _buildSliderRow(
                    label: '字体大小',
                    value: subtitleConfig.fontSize.clamp(24.0, 72.0),
                    min: 24.0,
                    max: 72.0,
                    displayValue: '${subtitleConfig.fontSize.round()}',
                    accentColor: themeService.accentColor,
                    onChanged: (v) => update(() => subtitleConfig.fontSize = v.roundToDouble()),
                  ),
                  const SizedBox(height: 8),

                  // 2. 字幕位置（底部边距）
                  _buildSliderRow(
                    label: '底部位置',
                    value: subtitleConfig.bottomPadding.clamp(8.0, 140.0),
                    min: 8.0,
                    max: 140.0,
                    displayValue: '${subtitleConfig.bottomPadding.round()}px',
                    accentColor: themeService.accentColor,
                    onChanged: (v) =>
                        update(() => subtitleConfig.bottomPadding = v.roundToDouble()),
                  ),
                  const SizedBox(height: 8),

                  // 3. 透明度
                  _buildSliderRow(
                    label: '透明度',
                    value: subtitleConfig.opacity.clamp(0.2, 1.0),
                    min: 0.2,
                    max: 1.0,
                    displayValue: '${(subtitleConfig.opacity * 100).round()}%',
                    accentColor: themeService.accentColor,
                    onChanged: (v) => update(() => subtitleConfig.opacity = v),
                  ),
                  const SizedBox(height: 14),

                  // 4. 字幕颜色
                  const Text('字幕颜色', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: colorPresets.map((preset) {
                      final int val = preset['value'] as int;
                      final String label = preset['label'] as String;
                      final bool isSel = subtitleConfig.colorValue == val;
                      return InkWell(
                        onTap: () => update(() => subtitleConfig.colorValue = val),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFF2D3240) : const Color(0xFF252832),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSel ? themeService.accentColor : Colors.white12,
                              width: isSel ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: Color(val),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white24),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                label,
                                style: TextStyle(
                                  color: isSel ? themeService.accentColor : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // 5. 字幕背景开关
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('半透明背景框',
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                      Switch(
                        value: subtitleConfig.showBackground,
                        activeColor: themeService.accentColor,
                        onChanged: (v) => update(() => subtitleConfig.showBackground = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('完成', style: TextStyle(color: themeService.accentColor)),
            ),
          ],
        );
      },
    ),
  );
}

Widget _buildSliderRow({
  required String label,
  required double value,
  required double min,
  required double max,
  required String displayValue,
  required Color accentColor,
  required ValueChanged<double> onChanged,
}) {
  return Row(
    children: [
      SizedBox(
        width: 64,
        child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const BarSliderThumbShape(width: 6, height: 16),
            activeTrackColor: accentColor,
            inactiveTrackColor: Colors.white12,
            thumbColor: accentColor,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ),
      SizedBox(
        width: 46,
        child: Text(
          displayValue,
          textAlign: TextAlign.right,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    ],
  );
}
