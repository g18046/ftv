import 'dart:math';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../../../global/storage_bridge.dart';
import '../../../models/danmaku_model.dart';
import '../../../models/vod_model.dart';
import '../../../services/danmaku_service.dart';
import '../../../services/theme_service.dart';

/// 播放器设置弹窗 (右上角齿轮设置功能)
void showPlayerSettingsDialog({
required BuildContext context,
required bool isHardwareDecode,
required String playerCoreName,
required String longPressSpeedOption,
required String bgPlayMode,
required String simPlayMode,
required String bufferTimeOption,
required String userAgentOption,
required String dvCorrectionMode,
required DanmakuConfig danmakuConfig,
required DanmakuService danmakuService,
required ThemeService themeService,
required Player? player,
required String currentPlayUrl,
required VodItem? vodDetail,
required String currentEpisodeName,
required ValueChanged<bool> onSetHardwareDecode,
required ValueChanged<String> onSetPlayerCore,
required ValueChanged<String> onSetLongPressSpeed,
required ValueChanged<String> onSetBgPlayMode,
required ValueChanged<String> onSetSimPlayMode,
required ValueChanged<String> onSetBufferTime,
required ValueChanged<String> onSetUserAgent,
required ValueChanged<String> onSetDvCorrection,
required ValueChanged<bool> onSetDanmakuEnabled,
required VoidCallback onSyncAutoPip,
required VoidCallback onSaveHistory,
required VoidCallback onRestoreHistory,
required VoidCallback onToggleFavorite,
required VoidCallback onOpenSubtitleSettings,
required VoidCallback onOpenSkipTimes,
required int skipIntroSeconds,
required int skipOutroSeconds,
required String Function(int) formatSeconds,
required void Function(IconData icon, String text) onShowHud,
}) {
  final onAccentColor = themeService.accentColor.computeLuminance() > 0.5
      ? Colors.black
      : Colors.white;
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setSettingState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.settings, color: themeService.accentColor),
                const SizedBox(width: 8),
                const Text('播放器高级设置', style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. 解码方式
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('解码方式:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        Row(
                          children: [
                            ChoiceChip(
                              label: Text(
                                '硬解',
                                style: TextStyle(
                                  color: isHardwareDecode ? onAccentColor : Colors.white,
                                  fontWeight: isHardwareDecode ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              backgroundColor: const Color(0xFF2B2E3A),
                              checkmarkColor: onAccentColor,
                              selected: isHardwareDecode,
                              selectedColor: themeService.accentColor,
                              onSelected: (val) {
                                setSettingState(() => isHardwareDecode = true);
                                onSetHardwareDecode(true);
                                try {
                                  (player?.platform as dynamic)?.setProperty('hwdec', 'auto');
                                } catch (_) {}
                              },
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: Text(
                                '软解',
                                style: TextStyle(
                                  color: !isHardwareDecode ? onAccentColor : Colors.white,
                                  fontWeight: !isHardwareDecode ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              backgroundColor: const Color(0xFF2B2E3A),
                              checkmarkColor: onAccentColor,
                              selected: !isHardwareDecode,
                              selectedColor: themeService.accentColor,
                              onSelected: (val) {
                                setSettingState(() => isHardwareDecode = false);
                                onSetHardwareDecode(false);
                                try {
                                  (player?.platform as dynamic)?.setProperty('hwdec', 'no');
                                } catch (_) {}
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 2. 播放内核
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('播放内核:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        DropdownButton<String>(
                          value: playerCoreName,
                          dropdownColor: const Color(0xFF262832),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 'EXO', child: Text('EXO 内核')),
                            DropdownMenuItem(value: 'MPV', child: Text('MPV 跨平台内核')),
                            DropdownMenuItem(value: 'IJK', child: Text('IJK 原生内核')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setSettingState(() => playerCoreName = val);
                              onSetPlayerCore(val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 长按倍速 (2.0x, 2.5x, 3.0x, 4.0x, 5.0x, 关闭)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('长按倍速:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        DropdownButton<String>(
                          value: longPressSpeedOption,
                          dropdownColor: const Color(0xFF262832),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: '2.0x', child: Text('2.0x')),
                            DropdownMenuItem(value: '2.5x', child: Text('2.5x')),
                            DropdownMenuItem(value: '3.0x', child: Text('3.0x (默认)')),
                            DropdownMenuItem(value: '4.0x', child: Text('4.0x')),
                            DropdownMenuItem(value: '5.0x', child: Text('5.0x')),
                            DropdownMenuItem(value: '关闭', child: Text('关闭')),
                          ],
                          onChanged: (val) async {
                            if (val != null) {
                              setSettingState(() => longPressSpeedOption = val);
                              onSetLongPressSpeed(val);
                              await StorageBridge.setValue('player_long_press_speed', val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 3. 后台播放 (关闭、开启、画中画)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('后台播放:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        Row(
                          children: ['画中画', '开启', '关闭'].map((opt) {
                            final isSel = bgPlayMode == opt;
                            return Padding(
                              padding: const EdgeInsets.only(left: 6.0),
                              child: ChoiceChip(
                                label: Text(
                                  opt,
                                  style: TextStyle(
                                    color: isSel ? onAccentColor : Colors.white,
                                    fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                backgroundColor: const Color(0xFF2B2E3A),
                                checkmarkColor: onAccentColor,
                                selected: isSel,
                                selectedColor: themeService.accentColor,
                                onSelected: (_) async {
                                  setSettingState(() => bgPlayMode = opt);
                                  onSetBgPlayMode(opt);
                                  await StorageBridge.setValue('player_bg_play', opt);
                                  // 切换后立即生效：关闭时显式撤销系统级自动画中画
                                  onSyncAutoPip();
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 4. 同时播放
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('同时播放:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        Row(
                          children: ['开启', '关闭'].map((opt) {
                            final isSel = simPlayMode == opt;
                            return Padding(
                              padding: const EdgeInsets.only(left: 6.0),
                              child: ChoiceChip(
                                label: Text(
                                  opt,
                                  style: TextStyle(
                                    color: isSel ? onAccentColor : Colors.white,
                                    fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                backgroundColor: const Color(0xFF2B2E3A),
                                checkmarkColor: onAccentColor,
                                selected: isSel,
                                selectedColor: themeService.accentColor,
                                onSelected: (_) async {
                                  setSettingState(() => simPlayMode = opt);
                                  onSetSimPlayMode(opt);
                                  await StorageBridge.setValue('player_sim_play', opt);
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 5. 缓冲时间 (可点击滑动调节 1~30 倍预缓存)
                    InkWell(
                      onTap: () {
                        double curVal = 1.0;
                        final m = RegExp(r'(\d+)').firstMatch(bufferTimeOption);
                        if (m != null) curVal = double.tryParse(m.group(1)!) ?? 1.0;
                        curVal = curVal.clamp(1.0, 30.0);

                        showDialog(
                          context: context,
                          builder: (bCtx) {
                            double tempV = curVal;
                            return StatefulBuilder(
                              builder: (context, setSliderState) {
                                return AlertDialog(
                                  backgroundColor: const Color(0xFFEBEAEF),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  title: const Text('缓冲时间', style: TextStyle(color: Color(0xFF1E1E1E), fontSize: 18, fontWeight: FontWeight.bold)),
                                  content: SizedBox(
                                    width: 300,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SliderTheme(
                                          data: SliderThemeData(
                                            trackHeight: 12.0,
                                            activeTrackColor: const Color(0xFF1E88E5),
                                            inactiveTrackColor: const Color(0xFFD6E4F0),
                                            thumbColor: const Color(0xFF1E88E5),
                                            overlayColor: Colors.transparent,
                                            overlayShape: SliderComponentShape.noOverlay,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10.0),
                                            trackShape: const RoundedRectSliderTrackShape(),
                                          ),
                                          child: Slider(
                                            value: tempV,
                                            min: 1.0,
                                            max: 30.0,
                                            divisions: 29,
                                            onChanged: (v) => setSliderState(() => tempV = v),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${tempV.toInt()} 倍 (预读缓存约 ${tempV.toInt() * 16}MB / ${tempV.toInt() * 15}秒)',
                                          style: const TextStyle(color: Color(0xFF555555), fontSize: 12.5),
                                        ),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(bCtx),
                                      child: const Text('取消', style: TextStyle(color: Color(0xFF1E88E5), fontSize: 14)),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        final clean = '${tempV.toInt()} 倍';
                                        setSettingState(() => bufferTimeOption = clean);
                                        onSetBufferTime(clean);
                                        await StorageBridge.setValue('player_buffer_time', clean);

                                        // 动态应用至当前播放内核
                                        try {
                                          final mVal = tempV.toInt();
                                          final cBytes = (mVal * 16 * 1024 * 1024).clamp(16 * 1024 * 1024, 320 * 1024 * 1024);
                                          final cSecs = (mVal * 15).clamp(15, 300);
                                          final platform = player?.platform as dynamic;
                                          platform?.setProperty('demuxer-max-bytes', cBytes.toString());
                                          platform?.setProperty('demuxer-readahead-secs', cSecs.toString());
                                        } catch (_) {}

                                        Navigator.pop(bCtx);
                                        onShowHud(Icons.speed, '已应用缓冲配置: $clean');
                                      },
                                      child: const Text('确定', style: TextStyle(color: Color(0xFF1E88E5), fontSize: 14, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('缓冲时间:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                            Row(
                              children: [
                                Text(bufferTimeOption, style: TextStyle(color: themeService.accentColor, fontSize: 13, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 4),
                                const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.white38),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 6. User-Agent
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('User-Agent:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        DropdownButton<String>(
                          value: userAgentOption,
                          dropdownColor: const Color(0xFF262832),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: '系统默认', child: Text('系统默认')),
                            DropdownMenuItem(value: '移动端', child: Text('移动端 (Android)')),
                            DropdownMenuItem(value: '电视端', child: Text('电视端 (TV)')),
                          ],
                          onChanged: (val) async {
                            if (val != null) {
                              setSettingState(() => userAgentOption = val);
                              onSetUserAgent(val);
                              await StorageBridge.setValue('player_ua', val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 7. 片头片尾跳过
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        onOpenSkipTimes();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Row(
                                  children: [
                                    Text('跳过片头:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                                    SizedBox(width: 4),
                                    Icon(Icons.edit, size: 13, color: Colors.white54),
                                  ],
                                ),
                                Text('${formatSeconds(skipIntroSeconds)} ($skipIntroSeconds 秒)',
                                    style: TextStyle(color: themeService.accentColor, fontSize: 13, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Row(
                                  children: [
                                    Text('跳过片尾:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                                    SizedBox(width: 4),
                                    Icon(Icons.edit, size: 13, color: Colors.white54),
                                  ],
                                ),
                                Text('${formatSeconds(skipOutroSeconds)} ($skipOutroSeconds 秒)',
                                    style: TextStyle(color: themeService.accentColor, fontSize: 13, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 8. 杜比视界校色 (自动校色、色彩反转校正、原生直通)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('杜比视界校色:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        DropdownButton<String>(
                          value: dvCorrectionMode,
                          dropdownColor: const Color(0xFF262832),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: '自动校色', child: Text('自动校色 (推荐)')),
                            DropdownMenuItem(value: '色彩反转校正', child: Text('防发紫强力校准')),
                            DropdownMenuItem(value: '原生直通', child: Text('原生直通')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setSettingState(() => dvCorrectionMode = val);
                              onSetDvCorrection(val);
                              try {
                                final platform = player?.platform as dynamic;
                                if (val == '自动校色') {
                                  platform?.setProperty('tone-mapping', 'spline');
                                  platform?.setProperty('gamut-mapping-mode', 'perceptual');
                                  platform?.setProperty('target-colorspace-hint', 'no');
                                  platform?.setProperty('vf', '');
                                } else if (val == '色彩反转校正') {
                                  platform?.setProperty('tone-mapping', 'reinhard');
                                  platform?.setProperty('target-colorspace-hint', 'no');
                                  platform?.setProperty('vf', 'format=colormatrix=bt.709');
                                } else {
                                  platform?.setProperty('tone-mapping', 'auto');
                                  platform?.setProperty('target-colorspace-hint', 'yes');
                                  platform?.setProperty('vf', '');
                                }
                              } catch (_) {}
                              onShowHud(Icons.palette, '已应用杜比色彩设置: ');
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 8.5 字幕样式设置
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.subtitles_outlined, color: Colors.white70, size: 20),
                      title: const Text('字幕样式设置', style: TextStyle(color: Colors.white, fontSize: 13)),
                      subtitle: const Text('大小、位置、颜色、透明度、背景', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                      onTap: () {
                        Navigator.pop(ctx);
                        onOpenSubtitleSettings();
                      },
                    ),

                    // 9. 弹幕开关
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('弹幕总开关', style: TextStyle(color: Colors.white, fontSize: 13)),
                      value: danmakuConfig.enabled,
                      activeColor: themeService.accentColor,
                      onChanged: (val) {
                        setSettingState(() => danmakuConfig.enabled = val);
                        onSetDanmakuEnabled(val);
                        danmakuService.saveConfig(danmakuConfig);
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
            ],
          );
        },
      );
    },
  );
}


void showSkipTimesDialog({
required BuildContext context,
required int skipIntroSeconds,
required int skipOutroSeconds,
required Duration position,
required Duration duration,
required String vodSkipKey,
required String Function(int) formatSeconds,
required String Function(Duration) formatDuration,
required void Function(int intro, int outro) onApplySkipTimes,
required ThemeService themeService,
  required void Function(IconData icon, String text) onShowHud,
}) {
  int tempIntro = skipIntroSeconds;
  int tempOutro = skipOutroSeconds;

  final onAccentColor = themeService.accentColor.computeLuminance() > 0.5
      ? Colors.black
      : Colors.white;
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2028),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Icon(Icons.skip_next, color: themeService.accentColor, size: 22),
              const SizedBox(width: 8),
              const Text('跳过片头片尾设置', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 片头设置
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('跳过片头时长', style: TextStyle(color: Colors.white, fontSize: 14)),
                    Text('${formatSeconds(tempIntro)} ($tempIntro 秒)',
                        style: TextStyle(color: themeService.accentColor, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    buildSkipAdjustBtn('-10s', () => setDialogState(() => tempIntro = max(0, tempIntro - 10))),
                    buildSkipAdjustBtn('-5s', () => setDialogState(() => tempIntro = max(0, tempIntro - 5))),
                    buildSkipAdjustBtn('+5s', () => setDialogState(() => tempIntro += 5)),
                    buildSkipAdjustBtn('+10s', () => setDialogState(() => tempIntro += 10)),
                    buildSkipAdjustBtn('0s (关闭)', () => setDialogState(() => tempIntro = 0)),
                  ],
                ),
                const SizedBox(height: 20),

                // 片尾设置
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('跳过片尾时长', style: TextStyle(color: Colors.white, fontSize: 14)),
                    Text('${formatSeconds(tempOutro)} ($tempOutro 秒)',
                        style: TextStyle(color: themeService.accentColor, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    buildSkipAdjustBtn('-10s', () => setDialogState(() => tempOutro = max(0, tempOutro - 10))),
                    buildSkipAdjustBtn('-5s', () => setDialogState(() => tempOutro = max(0, tempOutro - 5))),
                    buildSkipAdjustBtn('+5s', () => setDialogState(() => tempOutro += 5)),
                    buildSkipAdjustBtn('+10s', () => setDialogState(() => tempOutro += 10)),
                    buildSkipAdjustBtn('0s (关闭)', () => setDialogState(() => tempOutro = 0)),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: themeService.accentColor,
                foregroundColor: themeService.accentColor.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                onApplySkipTimes(tempIntro, tempOutro);
                await StorageBridge.setValue('player_skip_intro_${vodSkipKey}', '$tempIntro');
                await StorageBridge.setValue('player_skip_outro_${vodSkipKey}', '$tempOutro');
                Navigator.pop(ctx);
                onShowHud(Icons.check, '片头片尾跳过时长已保存');
              },
              child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    ),
  );
}

Widget buildSkipAdjustBtn(String label, VoidCallback onTap) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2E3A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    ),
  );
}

