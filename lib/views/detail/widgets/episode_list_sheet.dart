import 'dart:math';
import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';
import 'episode_item_content.dart';

void showEpisodeListBottomSheet({
required BuildContext context,
required VodItem? vodDetail,
required int selectedSourceIndex,
required String currentEpisodeName,
bool isReversedOrder = false,
required void Function(String flag, EpisodeItem ep) onPlayEpisode,
}) {
  final sources = vodDetail?.playSources ?? [];
  if (sources.isEmpty) return;
  final rawEpisodes = sources[selectedSourceIndex].episodes;
  if (rawEpisodes.isEmpty) return;
  final episodes = isReversedOrder ? rawEpisodes.reversed.toList() : rawEpisodes;

  final int totalCount = episodes.length;
  const int pageSize = 20;
  final int groupCount = (totalCount / pageSize).ceil();

  int curGroupIndex = 0;
  final curIdx = episodes.indexWhere((e) => e.name == currentEpisodeName);
  if (curIdx >= 0) {
    curGroupIndex = curIdx ~/ pageSize;
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setModalState) {
        final startIdx = curGroupIndex * pageSize;
        final endIdx = min(startIdx + pageSize, totalCount);
        final pageEpisodes = episodes.sublist(startIdx, endIdx);

        return Container(
          height: MediaQuery.of(context).size.height * 0.68,
          decoration: const BoxDecoration(
            color: Color(0xFFF9FAFB),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(color: Colors.black26, blurRadius: 20, offset: Offset(0, -4)),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 标题
              const Text(
                '选集',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 14),

              // 2. 分组 Tab (1 - 20, 21 - 40...)
              if (groupCount > 1)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(groupCount, (gIdx) {
                      final gStart = gIdx * pageSize + 1;
                      final gEnd = min((gIdx + 1) * pageSize, totalCount);
                      final isSel = curGroupIndex == gIdx;
                      final tabLabel = '$gStart - $gEnd';

                      return Padding(
                        padding: const EdgeInsets.only(right: 18.0),
                        child: InkWell(
                          onTap: () => setModalState(() => curGroupIndex = gIdx),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tabLabel,
                                style: TextStyle(
                                  color: isSel ? const Color(0xFF2979FF) : Colors.black54,
                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                width: 28,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: isSel ? const Color(0xFF2979FF) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),

              const SizedBox(height: 14),

              // 3. 3列剧集方框网格
              Expanded(
                child: LayoutBuilder(
                  builder: (gridCtx, gridCons) {
                    final gridCfg = computeDynamicEpisodeGrid(
                      availableWidth: gridCons.maxWidth,
                      episodes: pageEpisodes,
                      maxColumns: gridCons.maxWidth >= 520 ? 5 : 4,
                      spacing: 10.0,
                      targetCardHeight: 46.0,
                    );
                    return GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: gridCfg.crossAxisCount,
                        childAspectRatio: gridCfg.childAspectRatio,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: pageEpisodes.length,
                      itemBuilder: (context, idx) {
                        final ep = pageEpisodes[idx];
                        final isCurrent = ep.name == currentEpisodeName;

                        return InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            onPlayEpisode(sources[selectedSourceIndex].name, ep);
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isCurrent ? const Color(0xFF2979FF) : Colors.black12,
                                width: isCurrent ? 1.5 : 1,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            child: EpisodeCardContent(
                              name: ep.name,
                              textStyle: TextStyle(
                                color: isCurrent ? const Color(0xFF2979FF) : Colors.black87,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                fontSize: 12.5,
                              ),
                              badgeBgColor: isCurrent
                                  ? const Color(0xFF2979FF).withOpacity(0.14)
                                  : Colors.black.withOpacity(0.06),
                              enableMarquee: isCurrent,
                          badgeTextColor: isCurrent ? const Color(0xFF2979FF) : Colors.black87,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

