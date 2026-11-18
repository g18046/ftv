import 'package:flutter/gestures.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/vod_model.dart';
import 'episode_item_content.dart';
import '../../../repositories/site_repository.dart';
import '../../../services/theme_service.dart';
import '../detail_view.dart';
import '../../widgets/tv_focusable.dart';

Widget buildDetailVodMetaInfo({
required BuildContext context,
required VodItem? vodDetail,
required String? siteName,
required String? vodRemarks,
required void Function(IconData icon, String text) onShowHud,
}) {
  final vod = vodDetail!;
  final year = vod.vodYear.trim();
  final area = vod.vodArea.trim();
  final type = vod.typeName.trim();
  final remarks = (vodRemarks != null && vodRemarks.trim().isNotEmpty)
      ? vodRemarks.trim()
      : vod.vodRemarks.trim();
  final metaParts = <String>[
    if (year.isNotEmpty) '年份: $year',
    if (area.isNotEmpty) '地区: $area',
    if (type.isNotEmpty) '类型: $type',
  ];

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: vod.vodName));
          onShowHud(Icons.check, '已复制剧名: ${vod.vodName}');
        },
        child: Tooltip(
          message: '长按复制剧名',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  vod.vodName,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: vod.vodName));
                  onShowHud(Icons.check, '已复制剧名: ${vod.vodName}');
                },
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(4.0),
                  child: Icon(Icons.copy, size: 14, color: Colors.white38),
                ),
              ),
            ],
          ),
        ),
      ),
      if (remarks.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          remarks,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
      if (siteName != null && siteName.isNotEmpty) ...[
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Text(
            '站源: $siteName',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
      if (metaParts.isNotEmpty) ...[
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Text(
            metaParts.join('  '),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
      if (vod.vodDirector.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          '导演: ${vod.vodDirector}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
      if (vod.vodActor.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          '演员: ${vod.vodActor}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
      // 简介展示：Desktop/TV 端置于右上角元数据下方；手机端置于选集下方
      if ((Platform.isWindows || Platform.isMacOS || Platform.isLinux) && vod.vodContent.isNotEmpty) ...[
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('简介', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.white)),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: vod.vodContent));
                onShowHud(Icons.check, '已复制简介至剪贴板');
              },
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.copy, size: 12, color: Color(0xFF2979FF)),
                  SizedBox(width: 3),
                  Text('复制', style: TextStyle(color: Color(0xFF2979FF), fontSize: 11.5, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0x11FFFFFF),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: SelectableText(
              vod.vodContent,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.5),
            ),
          ),
        ),
      ],
    ],
  );
}

Widget buildDetailSourceAndEpisodesSection({
required BuildContext context,
required VodItem? vodDetail,
required int selectedSourceIndex,
required String currentEpisodeName,
required bool isReversedOrder,
required bool isLandscape,
required ScrollController sourceScrollController,
required ThemeService themeService,
required ValueChanged<int> onSelectSource,
required VoidCallback onToggleOrder,
required void Function(String flag, EpisodeItem ep) onPlayEpisode,
required VoidCallback onShowEpisodeSheet,
required VoidCallback onOpenDownloadSheet,
required void Function(IconData icon, String text) onShowHud,
}) {
  final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  final sources = vodDetail?.playSources ?? [];
  if (sources.isEmpty) return const SizedBox.shrink();

  final currentEpisodes = sources[selectedSourceIndex].episodes;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // 线路行 (参考图 5)
      Row(
        children: [
          const Text('线路',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
          const Spacer(),
          InkWell(
            onTap: onOpenDownloadSheet,
            child: const Row(
              children: [
                Text('下载', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Icon(Icons.chevron_right, size: 16, color: Colors.white70),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
        ),
        child: Listener(
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent) {
              final double delta = pointerSignal.scrollDelta.dy != 0
                  ? pointerSignal.scrollDelta.dy
                  : pointerSignal.scrollDelta.dx;
              if (sourceScrollController.hasClients) {
                final target = (sourceScrollController.offset + delta).clamp(
                  0.0,
                  sourceScrollController.position.maxScrollExtent,
                );
                sourceScrollController.animateTo(
                  target,
                  duration: const Duration(milliseconds: 100),
                  curve: Curves.easeOut,
                );
              }
            }
          },
          child: SingleChildScrollView(
            controller: sourceScrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: sources.asMap().entries.map((entry) {
                final idx = entry.key;
                final src = entry.value;
                final isSel = idx == selectedSourceIndex;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: InkWell(
                    onTap: () => onSelectSource(idx),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSel ? themeService.accentColor.withOpacity(0.25) : const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(8),
                        border: isSel ? Border.all(color: themeService.accentColor, width: 1.2) : null,
                      ),
                      child: Text(
                        src.name,
                        style: TextStyle(
                          color: isSel ? themeService.accentColor : Colors.white,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),

      // 选集行 (参考图 5: 选集 ⇄ 与 更多 >)
      Row(
        children: [
          InkWell(
            onTap: onToggleOrder,
            child: Row(
              children: [
                const Text('选集',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(width: 4),
                Icon(isReversedOrder ? Icons.arrow_upward : Icons.swap_vert,
                    size: 16, color: Colors.white70),
              ],
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: onShowEpisodeSheet,
            child: const Row(
              children: [
                Text('更多', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Icon(Icons.chevron_right, size: 16, color: Colors.white70),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),

      // 剧集展示：Windows/TV端网格平铺，手机端横向滚动
      Builder(
        builder: (context) {
          final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
          final isWide = isLandscape || isDesktop || (MediaQuery.of(context).size.width > 750 && MediaQuery.of(context).size.width > MediaQuery.of(context).size.height);
          final displayList = isReversedOrder
              ? currentEpisodes.reversed.toList()
              : currentEpisodes;

          if (isWide) {
            return LayoutBuilder(
              builder: (gridCtx, gridCons) {
                final gridCfg = computeDynamicEpisodeGrid(
                  availableWidth: gridCons.maxWidth,
                  episodes: displayList,
                  maxColumns: 8,
                  spacing: 10.0,
                  targetCardHeight: 46.0,
                );
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: gridCfg.crossAxisCount,
                    childAspectRatio: gridCfg.childAspectRatio,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: displayList.length,
                  itemBuilder: (context, idx) {
                    final ep = displayList[idx];
                    final isCurrent = ep.name == currentEpisodeName;
                    return TvFocusable(
                      onPressed: () => onPlayEpisode(sources[selectedSourceIndex].name, ep),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: isCurrent ? const Color(0xFFE5A00D) : const Color(0xFF262832),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isCurrent ? const Color(0xFFE5A00D) : Colors.white12,
                          ),
                        ),
                        child: EpisodeCardContent(
                          name: ep.name,
                          textStyle: TextStyle(
                            color: isCurrent ? Colors.black : Colors.white,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12.5,
                          ),
                          badgeBgColor: isCurrent
                              ? Colors.black.withOpacity(0.15)
                              : const Color(0xFFE5A00D).withOpacity(0.22),
                          enableMarquee: isCurrent,
                          badgeTextColor: isCurrent ? Colors.black : const Color(0xFFFFD54F),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          }

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: displayList.map((ep) {
                final isCurrent = ep.name == currentEpisodeName;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: InkWell(
                    onTap: () => onPlayEpisode(sources[selectedSourceIndex].name, ep),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isCurrent ? const Color(0xFF2C5951) : const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(8),
                        border: isCurrent ? Border.all(color: const Color(0xFF66C8B5), width: 1.2) : null,
                      ),
                      child: Text(
                        ep.name,
                        style: TextStyle(
                          color: isCurrent ? const Color(0xFFFFD54F) : Colors.white,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        },
      ),

      if (!isDesktop && (vodDetail?.vodContent ?? '').isNotEmpty) ...[
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('简介', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: vodDetail!.vodContent));
                onShowHud(Icons.check, '已复制简介至剪贴板');
              },
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy, size: 13, color: Color(0xFF2979FF)),
                    SizedBox(width: 4),
                    Text('复制', style: TextStyle(color: Color(0xFF2979FF), fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText(
          vodDetail!.vodContent,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
      ],
    ],
  );
}

Widget buildDetailQuickSearchSection({
required BuildContext context,
required bool isQuickSearching,
required List<VodItem> quickSearchResults,
required SiteRepository repository,
}) {
  if (quickSearchResults.isEmpty && !isQuickSearching) return const SizedBox.shrink();

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('全网同名秒搜源', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 8),
      ...quickSearchResults.map((vod) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.network(
              vod.vodPic,
              width: 40,
              height: 56,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(width: 40, height: 56, color: Colors.grey),
            ),
          ),
          title: Text(vod.vodName, style: const TextStyle(color: Colors.white, fontSize: 13)),
          subtitle: Text('${vod.siteName ?? ""} - ${vod.vodRemarks}',
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
          trailing: const Icon(Icons.play_circle_fill, color: Color(0xFFE5A00D)),
          onTap: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => DetailView(repository: repository, vodId: vod.vodId, vodItem: vod),
              ),
            );
          },
        );
      }),
    ],
  );
}

Widget buildDetailErrorView({
required BuildContext context,
required String errorMsg,
required VoidCallback onRetry,
}) {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.warning_amber_rounded, size: 52, color: Colors.white),
        const SizedBox(height: 10),
        Text(
          errorMsg,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回上一页'),
        ),
      ],
    ),
  );
}
