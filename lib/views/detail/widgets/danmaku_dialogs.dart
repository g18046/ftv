import 'dart:math';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/danmaku_model.dart';
import '../../../models/vod_model.dart';
import '../../../services/danmaku_service.dart';
import '../../../services/local_http_server.dart';
import 'bar_slider_thumb_shape.dart';
import 'marquee_widget.dart';

/// 弹幕设置窗口 (严格按图 2 优化：纯净白底、圆角滑块与标准 5 行调节)
void showDanmakuSettingsDialog({
required BuildContext context,
required DanmakuConfig danmakuConfig,
required DanmakuService danmakuService,
required VoidCallback onStateChanged,
}) {
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        final screenWidth = MediaQuery.of(context).size.width;

        String getTimeText(int offset) {
          if (offset == 0) return '推迟0s';
          if (offset > 0) return '推迟${offset}s';
          return '提前${-offset}s';
        }

        String getSpeedText(double s) {
          if (s >= 9.0) return '极慢';
          if (s >= 7.5) return '较慢';
          if (s >= 5.5) return '适中';
          if (s >= 4.0) return '较快';
          return '极快';
        }

        final screenHeight = MediaQuery.of(context).size.height;

        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Container(
            width: min(520, screenWidth * 0.92),
            constraints: BoxConstraints(maxHeight: min(420, screenHeight * 0.92)),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '弹幕',
                    style: TextStyle(
                      color: Color(0xFF222222),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),

                // 1. 弹幕时间
                buildDanmakuSettingSliderRow(
                  label: '弹幕时间',
                  value: danmakuConfig.timeOffset.toDouble().clamp(-10.0, 10.0),
                  min: -10.0,
                  max: 10.0,
                  divisions: 20,
                  displayValue: getTimeText(danmakuConfig.timeOffset),
                  onChanged: (val) {
                    setDialogState(() => danmakuConfig.timeOffset = val.round());
                    onStateChanged();
                    danmakuService.saveConfig(danmakuConfig);
                  },
                ),

                // 2. 弹幕速度 (speed: 3.0 ~ 11.0; 越小越快)
                buildDanmakuSettingSliderRow(
                  label: '弹幕速度',
                  value: (14.0 - danmakuConfig.speed).clamp(3.0, 11.0),
                  min: 3.0,
                  max: 11.0,
                  displayValue: getSpeedText(danmakuConfig.speed),
                  onChanged: (val) {
                    final targetSpeed = (14.0 - val).clamp(3.0, 11.0);
                    setDialogState(() => danmakuConfig.speed = targetSpeed);
                    onStateChanged();
                    danmakuService.saveConfig(danmakuConfig);
                  },
                ),

                // 3. 弹幕大小
                buildDanmakuSettingSliderRow(
                  label: '弹幕大小',
                  value: (danmakuConfig.fontSize / 16.0).clamp(0.6, 2.0),
                  min: 0.6,
                  max: 2.0,
                  displayValue: '${(danmakuConfig.fontSize / 16.0).toStringAsFixed(1)}倍',
                  onChanged: (val) {
                    setDialogState(() => danmakuConfig.fontSize = val * 16.0);
                    onStateChanged();
                    danmakuService.saveConfig(danmakuConfig);
                  },
                ),

                // 4. 弹幕行数
                buildDanmakuSettingSliderRow(
                  label: '弹幕行数',
                  value: danmakuConfig.maxLines.toDouble().clamp(1.0, 12.0),
                  min: 1.0,
                  max: 12.0,
                  divisions: 11,
                  displayValue: '${danmakuConfig.maxLines}行',
                  onChanged: (val) {
                    setDialogState(() => danmakuConfig.maxLines = val.round());
                    onStateChanged();
                    danmakuService.saveConfig(danmakuConfig);
                  },
                ),

                // 5. 弹幕透明
                buildDanmakuSettingSliderRow(
                  label: '弹幕透明',
                  value: danmakuConfig.opacity.clamp(0.1, 1.0),
                  min: 0.1,
                  max: 1.0,
                  displayValue: '${(danmakuConfig.opacity * 100).toInt()}%',
                  onChanged: (val) {
                    setDialogState(() => danmakuConfig.opacity = val);
                    onStateChanged();
                    danmakuService.saveConfig(danmakuConfig);
                  },
                ),
                const SizedBox(height: 10),

                // 6. 弹幕色彩选择
                const Text(
                  '弹幕色彩',
                  style: TextStyle(
                    color: Color(0xFF222222),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: ['原色', '纯白', '炫彩', '护眼黄', '柔和蓝', '薄荷绿', '极光渐变'].map((mode) {
                    final isSel = danmakuConfig.colorMode == mode;
                    return ChoiceChip(
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      label: Text(
                        mode,
                        style: TextStyle(
                          color: isSel ? Colors.white : Colors.black87,
                          fontSize: 12,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      selected: isSel,
                      selectedColor: const Color(0xFF2196F3),
                      backgroundColor: const Color(0xFFF0F2F5),
                      onSelected: (selected) {
                        if (selected) {
                          setDialogState(() => danmakuConfig.colorMode = mode);
                          onStateChanged();
                          danmakuService.saveConfig(danmakuConfig);
                        }
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),

                // 7. 弹幕描边开关 (默认不描边)
                Row(
                  children: [
                    const Text(
                      '弹幕描边',
                      style: TextStyle(
                        color: Color(0xFF222222),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ChoiceChip(
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      label: Text(
                        '不描边',
                        style: TextStyle(
                          color: !danmakuConfig.showStroke ? Colors.white : Colors.black87,
                          fontSize: 12,
                          fontWeight: !danmakuConfig.showStroke ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      selected: !danmakuConfig.showStroke,
                      selectedColor: const Color(0xFF2196F3),
                      backgroundColor: const Color(0xFFF0F2F5),
                      onSelected: (selected) {
                        if (selected) {
                          setDialogState(() => danmakuConfig.showStroke = false);
                          onStateChanged();
                          danmakuService.saveConfig(danmakuConfig);
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      label: Text(
                        '描边',
                        style: TextStyle(
                          color: danmakuConfig.showStroke ? Colors.white : Colors.black87,
                          fontSize: 12,
                          fontWeight: danmakuConfig.showStroke ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      selected: danmakuConfig.showStroke,
                      selectedColor: const Color(0xFF2196F3),
                      backgroundColor: const Color(0xFFF0F2F5),
                      onSelected: (selected) {
                        if (selected) {
                          setDialogState(() => danmakuConfig.showStroke = true);
                          onStateChanged();
                          danmakuService.saveConfig(danmakuConfig);
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          ),
        );
      },
    ),
  );
}

Widget buildDanmakuSettingSliderRow({
  required String label,
  required double value,
  required double min,
  required double max,
  int? divisions,
  required String displayValue,
  required ValueChanged<double> onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2.0),
    child: Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF222222),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 6.0,
              activeTrackColor: const Color(0xFF2196F3),
              inactiveTrackColor: const Color(0xFFE8F1FC),
              thumbColor: const Color(0xFF2196F3),
              overlayColor: Colors.transparent,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const BarSliderThumbShape(width: 3.0, height: 16.0),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        Container(
          width: 76,
          alignment: Alignment.centerRight,
          child: Text(
            displayValue,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: Color(0xFF333333),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 搜索弹幕窗口 (严格按图 1 优化：前缀智能搜索、紫色搜索胶囊、蓝色全部分类、四列集数卡片、闪电推送胶囊)
void showDanmakuSearchDialog({
required BuildContext context,
required VodItem? vodDetail,
required String currentEpisodeName,
required DanmakuConfig danmakuConfig,
required DanmakuService danmakuService,
required String? matchedAnimeTitle,
required String? matchedEpisodeTitle,
required int? matchedLogVarEpisodeId,
required List<LogVarAnimeSource> initialSources,
required String initialQuery,
required void Function(String query, List<LogVarAnimeSource> sources) onCacheSearchSources,
required bool Function() isHostMounted,
required void Function(List<DanmakuItem> items, String animeTitle, String episodeTitle, String matchedUrl, int? episodeId) onApplyDanmaku,
required void Function(IconData icon, String text) onShowHud,
}) {
  final (_, cleanEp) = danmakuService.sanitizeVodNameAndEpisode(
    vodDetail?.vodName ?? '',
    currentEpisodeName,
  );
  final cleanDefaultTitle = initialQuery.isNotEmpty
      ? initialQuery
      : danmakuService.sanitizeVodName(vodDetail?.vodName ?? '');
  final titleController = TextEditingController(text: cleanDefaultTitle);
  List<LogVarAnimeSource> animeSources = List<LogVarAnimeSource>.from(initialSources);
  int? selectedEpId = matchedLogVarEpisodeId;
  int initialExpandIdx = 0;
  if (selectedEpId != null) {
    final idx = animeSources.indexWhere((s) => s.episodes.any((e) => e.episodeId == selectedEpId));
    if (idx >= 0) initialExpandIdx = idx;
  }
  final Set<int> expandedSourceIndices = {initialExpandIdx};
  final ScrollController listScrollController = ScrollController();
  bool hasAutoScrolled = false;
  bool isSearchingLogVar = false;
  String? localPillMsg;

  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dCtx, setDialogState) {
        void doSearch(String kw) async {
          final query = kw.trim();
          if (query.isEmpty) return;
          setDialogState(() {
            isSearchingLogVar = true;
            localPillMsg = null;
          });
          final res = await danmakuService.searchLogVarAnimes(query);
          onCacheSearchSources(query, res);
          if (dCtx.mounted) {
            setDialogState(() {
              animeSources = res;
              int expandIdx = 0;
              if (selectedEpId != null) {
                final found = res.indexWhere((s) => s.episodes.any((e) => e.episodeId == selectedEpId));
                if (found >= 0) expandIdx = found;
              }
              expandedSourceIndices
                ..clear()
                ..add(expandIdx);
              isSearchingLogVar = false;
            });
          }
        }

        if (animeSources.isEmpty && !isSearchingLogVar && titleController.text.isNotEmpty) {
          Future.microtask(() => doSearch(titleController.text));
        }

        final screenHeight = MediaQuery.of(dCtx).size.height;
        final screenWidth = MediaQuery.of(dCtx).size.width;

        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: SizedBox(
            width: min(540, screenWidth * 0.92),
            height: min(440, screenHeight * 0.88),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. 顶部搜索栏：输入框 + 紫色圆角"搜索"按钮
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F7),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: titleController,
                                style: const TextStyle(
                                  color: Color(0xFF222222),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                                textInputAction: TextInputAction.search,
                                onSubmitted: (kw) => doSearch(kw),
                                decoration: const InputDecoration(
                                  hintText: '搜索剧名 / 关键词',
                                  hintStyle: TextStyle(color: Colors.black38, fontSize: 14),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: isSearchingLogVar ? null : () => doSearch(titleController.text),
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF6B58E6), // 优雅紫色
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: isSearchingLogVar
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Text(
                                        '搜索',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 2. 蓝色分类与当前播放剧集指示
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '全部 (无)',
                            style: TextStyle(
                              color: Color(0xFF2196F3),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (currentEpisodeName.isNotEmpty || cleanEp.isNotEmpty)
                            Flexible(
                              child: Text(
                                '当前播放: ${currentEpisodeName.isNotEmpty ? currentEpisodeName : "第$cleanEp集"}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFFF8F00),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 3. 搜索结果与选集区域
                      Expanded(
                        child: isSearchingLogVar
                            ? const Center(
                                child: CircularProgressIndicator(color: Color(0xFF6B58E6)),
                              )
                            : animeSources.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.subtitles_off, size: 36, color: Colors.grey),
                                        const SizedBox(height: 8),
                                        const Text(
                                          '未在弹幕库检索到相关剧集',
                                          style: TextStyle(color: Colors.black54, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  )
                                : Builder(
                                    builder: (listWrapCtx) {
                                      if (!hasAutoScrolled && animeSources.isNotEmpty && expandedSourceIndices.isNotEmpty) {
                                        hasAutoScrolled = true;
                                        final expIdx = expandedSourceIndices.first;
                                        if (expIdx >= 0 && expIdx < animeSources.length) {
                                          final src = animeSources[expIdx];
                                          int targetEpIdx = -1;
                                          if (selectedEpId != null) {
                                            targetEpIdx = src.episodes.indexWhere((e) => e.episodeId == selectedEpId);
                                          }
                                          if (targetEpIdx < 0 && cleanEp.isNotEmpty) {
                                            final targetEpInt = int.tryParse(cleanEp);
                                            targetEpIdx = src.episodes.indexWhere((e) {
                                              final t = e.episodeTitle.trim();
                                              if (t == cleanEp) return true;
                                              final m = RegExp(r'(\d+)').firstMatch(t);
                                              return m != null && targetEpInt != null && int.tryParse(m.group(1)!) == targetEpInt;
                                            });
                                          }
                                          if (targetEpIdx > 0) {
                                            final cols = screenWidth >= 520 ? 4 : 3;
                                            final row = targetEpIdx ~/ cols;
                                            WidgetsBinding.instance.addPostFrameCallback((_) {
                                              if (listScrollController.hasClients) {
                                                final approxOffset = (expIdx * 52.0) + (row * 58.0);
                                                listScrollController.jumpTo(
                                                  approxOffset.clamp(0.0, listScrollController.position.maxScrollExtent),
                                                );
                                              }
                                            });
                                          }
                                        }
                                      }
                                      return ListView.builder(
                                    controller: listScrollController,
                                    itemCount: animeSources.length,
                                    itemBuilder: (listCtx, sIdx) {
                                      final source = animeSources[sIdx];
                                      final isExpanded = expandedSourceIndices.contains(sIdx);
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 12.0),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // 剧名来源标题 (点击支持收起/展开)
                                            InkWell(
                                              onTap: () {
                                                setDialogState(() {
                                                  if (isExpanded) {
                                                    expandedSourceIndices.remove(sIdx);
                                                  } else {
                                                    expandedSourceIndices.add(sIdx);
                                                  }
                                                });
                                              },
                                              borderRadius: BorderRadius.circular(8),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFF5F6FA),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        '${source.animeTitle} (${source.typeDescription})',
                                                        style: const TextStyle(
                                                          color: Color(0xFF222222),
                                                          fontSize: 13.5,
                                                          fontWeight: FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                    Text(
                                                      '${source.episodes.length}集',
                                                      style: const TextStyle(color: Colors.black45, fontSize: 12),
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Icon(
                                                      isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                                      color: Colors.black54,
                                                      size: 20,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),

                                            if (isExpanded) ...[
                                              const SizedBox(height: 8),
                                              // 剧集网格：完整显示剧集标题 + 跑马灯滚动
                                              GridView.builder(
                                                shrinkWrap: true,
                                                physics: const NeverScrollableScrollPhysics(),
                                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: screenWidth >= 520 ? 4 : 3,
                                                  childAspectRatio: screenWidth >= 520 ? 2.1 : 2.05,
                                                  crossAxisSpacing: 8,
                                                  mainAxisSpacing: 8,
                                                ),
                                                itemCount: source.episodes.length,
                                                itemBuilder: (gridCtx, epIdx) {
                                                  final ep = source.episodes[epIdx];
                                                  bool isSelected = selectedEpId != null && selectedEpId == ep.episodeId;
                                                  if (!isSelected && selectedEpId == null && cleanEp.isNotEmpty) {
                                                    final t = ep.episodeTitle.trim();
                                                    final epNumMatch = RegExp(r'(\d+)').firstMatch(t);
                                                    if (t == cleanEp || (epNumMatch != null && epNumMatch.group(1) == cleanEp)) {
                                                      isSelected = true;
                                                    }
                                                  }
                                                  final fullTitle = ep.episodeTitle.trim().isNotEmpty
                                                      ? ep.episodeTitle.trim()
                                                      : '第${epIdx + 1}集';

                                                  return InkWell(
                                                    onTap: () {
                                                      if (dCtx.mounted) {
                                                        setDialogState(() {
                                                          selectedEpId = ep.episodeId;
                                                          localPillMsg = '正在拉取 [${ep.episodeTitle}] 弹幕...';
                                                        });
                                                      }
                                                      print('🚀 [DANMAKU-PUSH] 点击推送: [${source.animeTitle}] 第${epIdx + 1}集 (${ep.episodeTitle}), episodeId=${ep.episodeId}');
                                                      // 独立异步拉取并推送弹幕：即使关闭弹窗也不受 dCtx.mounted 影响
                                                      danmakuService.fetchDanmakuByEpisodeId(ep.episodeId).then((items) {
                                                        print('✅ [DANMAKU-PUSH] 拉取完成: [${source.animeTitle}] 第${epIdx + 1}集 -> ${items.length} 条, hostMounted=${isHostMounted()}');
                                                        if (isHostMounted()) {
                                                          onApplyDanmaku(
                                                            items,
                                                            source.animeTitle,
                                                            ep.episodeTitle,
                                                            '${LocalHttpServer().baseUrl}/danmu?box_id=${source.animeTitle}_ep${ep.episodeTitle}_${source.animeTitle}(${source.typeDescription}).xml',
                                                            ep.episodeId,
                                                          );
                                                          onShowHud(Icons.subtitles, '${source.animeTitle} 第${epIdx + 1}集 ${items.length}条');
                                                        }
                                                        if (dCtx.mounted) {
                                                          setDialogState(() {
                                                            localPillMsg =
                                                                '${source.animeTitle} 第${epIdx + 1}集 ${items.length}条';
                                                          });
                                                        }
                                                      });
                                                    },
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: Container(
                                                      alignment: Alignment.center,
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: isSelected ? const Color(0xFFFFC107) : Colors.white,
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: Border.all(
                                                          color: isSelected ? const Color(0xFFFFC107) : const Color(0xFFE2E4E8),
                                                          width: 1.0,
                                                        ),
                                                      ),
                                                      child: Column(
                                                        mainAxisAlignment: MainAxisAlignment.center,
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Builder(
                                                            builder: (_) {
                                                              final epMatch = RegExp(r'(?:第\s*|EP?\s*)(\d+)\s*[集话期]?', caseSensitive: false).firstMatch(fullTitle);
                                                              final cardLabel = epMatch != null ? '第${int.tryParse(epMatch.group(1)!) ?? epMatch.group(1)}集' : '第${epIdx + 1}集';
                                                              return Text(
                                                                cardLabel,
                                                                maxLines: 1,
                                                                style: TextStyle(
                                                                  color: const Color(0xFF222222),
                                                                  fontSize: 13,
                                                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                          if (fullTitle != '第${epIdx + 1}集') ...[
                                                            const SizedBox(height: 2),
                                                            SizedBox(
                                                              height: 14,
                                                              child: MarqueeWidget(
                                                                animationDuration: const Duration(milliseconds: 2200),
                                                                backDuration: const Duration(milliseconds: 450),
                                                                pauseDuration: const Duration(milliseconds: 400),
                                                                child: Text(
                                                                  fullTitle,
                                                                  maxLines: 1,
                                                                  style: TextStyle(
                                                                    color: isSelected ? const Color(0xFF444444) : Colors.black54,
                                                                    fontSize: 10,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                    },
                                  ),
                      ),
                    ],
                  ),
                ),

                // 4. 底部微浮动消息提示卡片 (支持跑马灯无缝滚动长剧名信息)
                if (localPillMsg != null)
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 12,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 3)),
                          ],
                          border: Border.all(color: const Color(0xFFEAEAEA)),
                        ),
                        child: SizedBox(
                          height: 18,
                          child: MarqueeWidget(
                            child: Text(
                              localPillMsg!,
                              style: const TextStyle(
                                color: Color(0xFF222222),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 右下角选择弹幕窗口 (严格按图 4 优化：纯净白底、选择弹幕标题、文件夹选取图标、单行蓝字链接展示框，点击即可选择和不选切换)
void showMatchedDanmakuDialog({
required BuildContext context,
required VodItem? vodDetail,
required String currentEpisodeName,
required DanmakuConfig danmakuConfig,
required DanmakuService danmakuService,
required List<DanmakuItem> danmakus,
required String? matchedDanmakuUrl,
required void Function(List<DanmakuItem> items, String path) onLoadLocalDanmaku,
required VoidCallback onToggleDanmakuEnabled,
required VoidCallback onClearDanmakus,
required VoidCallback onOpenSearch,
required void Function(IconData icon, String text) onShowHud,
}) {
  final cleanName = danmakuService.sanitizeVodName(vodDetail?.vodName ?? '嫁金钗');
  final cleanEp = currentEpisodeName.replaceAll(RegExp(r'[^\d]'), '');
  final epTag = cleanEp.isNotEmpty ? 'ep' : 'ep1';
  final fallbackUrl = '${LocalHttpServer().baseUrl}/danmu?box_id=' + cleanName + '_' + epTag + '_' + cleanName + '(youku).xml';
  final currentUrl = matchedDanmakuUrl ?? fallbackUrl;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (bottomCtx) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          // 当前弹幕是否处于“选中”状态（开启即选中）
          final bool isSelected = danmakuConfig.enabled;

          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部标题与文件夹图标
                  Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '选择弹幕',
                    style: TextStyle(
                      color: Color(0xFF222222),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_outlined, color: Color(0xFF555555), size: 22),
                    tooltip: '选择本地弹幕文件',
                    onPressed: () async {
                      try {
                        final file = await FilePicker.pickFile(
                          type: FileType.custom,
                          allowedExtensions: ['xml', 'json'],
                        );
                        if (file != null && file.path != null) {
                          final path = file.path!;
                          final content = await File(path).readAsString();
                          final items = danmakuService.parseXmlDanmaku(content);
                          if (items.isNotEmpty) {
                            danmakus = items;
                            danmakuConfig.enabled = true;
                            matchedDanmakuUrl = path;
                            onLoadLocalDanmaku(items, path);
                            setModalState(() {});
                          }
                        }
                      } catch (e) {
                        print('选取本地弹幕异常: ');
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 弹幕链接展示框：点击即可切换【选择】与【不选】
              InkWell(
                onTap: () {
                  setModalState(() {
                    danmakuConfig.enabled = !danmakuConfig.enabled;
                  });
                  onToggleDanmakuEnabled();
                  danmakuService.saveConfig(danmakuConfig);
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 48,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFFF4F9FF) : const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF2196F3) : const Color(0xFFD6D6D6),
                      width: isSelected ? 1.4 : 1.0,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            currentUrl,
                            style: TextStyle(
                              color: isSelected ? const Color(0xFF1E88E5) : Colors.black45,
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: isSelected ? const Color(0xFF2196F3) : Colors.grey.shade400,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
          );
        },
      );
    },
  );
}

void showSendDanmakuDialog({
required BuildContext context,
required VodItem? vodDetail,
required String currentEpisodeName,
required int? matchedLogVarEpisodeId,
required Duration position,
required DanmakuService danmakuService,
required void Function(DanmakuItem item) onAddLocalDanmaku,
required void Function(IconData icon, String text) onShowHud,
}) {
  final textController = TextEditingController();
  Color selectedColor = Colors.white;
  DanmakuType selectedType = DanmakuType.scroll;

  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setModalState) {
        final colors = [
          Colors.white,
          const Color(0xFFFFEB3B),
          const Color(0xFF00E5FF),
          const Color(0xFF69F0AE),
          const Color(0xFFFF5252),
          const Color(0xFFE040FB),
        ];

        return AlertDialog(
          backgroundColor: const Color(0xFF1E2028),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.send, color: Color(0xFFE5A00D), size: 20),
              SizedBox(width: 8),
              Text('发送实时弹幕', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: textController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: '输入你想说的弹幕内容...',
                    hintStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('选择弹幕颜色:', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: colors.map((c) {
                    final isSel = selectedColor == c;
                    return GestureDetector(
                      onTap: () => setModalState(() => selectedColor = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSel ? const Color(0xFFE5A00D) : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE5A00D)),
              onPressed: () async {
                final text = textController.text.trim();
                if (text.isNotEmpty) {
                  Navigator.pop(context);
                  final newItem = DanmakuItem(
                    time: position.inMilliseconds / 1000.0,
                    text: text,
                    color: selectedColor,
                    type: selectedType,
                  );
                  onAddLocalDanmaku(newItem);
                  onShowHud(Icons.check, '✅ 弹幕即刻发射成功！');
                  await danmakuService.sendDanmaku(
                    vodName: vodDetail?.vodName ?? '',
                    episodeName: currentEpisodeName,
                    episodeId: matchedLogVarEpisodeId,
                    time: position.inMilliseconds / 1000.0,
                    text: text,
                    color: selectedColor,
                    type: selectedType,
                  );
                }
              },
              child: const Text('发射', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    ),
  );
}

