import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';
import '../../../repositories/site_repository.dart';
import '../../../services/history_favorite_service.dart';
import '../../../services/theme_service.dart';
import '../../detail/detail_view.dart';

void showVodFavoritesSheet(BuildContext context, SiteRepository repository) {
  HistoryFavoriteService().loadFavorites();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setSheetState) {
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;

        return Container(
          height: screenHeight * 0.75,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          decoration: const BoxDecoration(
            color: Color(0xFF1E2028),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black45,
                  blurRadius: 20,
                  offset: Offset(0, -4)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.star, color: Color(0xFFE5A00D), size: 24),
                      SizedBox(width: 8),
                      Text(
                        '我的收藏',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline,
                            size: 16, color: Colors.white54),
                        label: const Text('清空',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 13)),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (dCtx) => AlertDialog(
                              backgroundColor: const Color(0xFF262832),
                              title: const Text('清空收藏',
                                  style: TextStyle(color: Colors.white)),
                              content: const Text('确定要清空所有收藏影视吗？',
                                  style: TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(dCtx),
                                    child: const Text('取消')),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent),
                                  onPressed: () async {
                                    await HistoryFavoriteService()
                                        .clearFavorites();
                                    Navigator.pop(dCtx);
                                    setSheetState(() {});
                                  },
                                  child: const Text('确定清空',
                                      style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable:
                      HistoryFavoriteService().favoritesNotifier,
                  builder: (context, favList, _) {
                    if (favList.isEmpty) {
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.star_outline,
                                size: 64, color: Colors.white24),
                            SizedBox(height: 12),
                            Text('暂无收藏影视',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 15)),
                            SizedBox(height: 6),
                            Text('在影视详情页点击右上角星标即可收藏',
                                style: TextStyle(
                                    color: Colors.white30, fontSize: 12)),
                          ],
                        ),
                      );
                    }

                    final crossCount =
                        screenWidth > 900 ? 6 : (screenWidth > 600 ? 4 : 3);

                    return GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossCount,
                        childAspectRatio: 0.65,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: favList.length,
                      itemBuilder: (context, idx) {
                        final item = favList[idx];
                        final vod = VodItem(
                          vodId: item['vodId']?.toString() ?? '',
                          vodName: item['vodName']?.toString() ?? '',
                          vodPic: item['vodPic']?.toString() ?? '',
                          vodRemarks: item['vodRemarks']?.toString() ?? '',
                          siteKey: item['siteKey']?.toString(),
                          siteName: item['siteName']?.toString(),
                        );

                        return Stack(
                          children: [
                            InkWell(
                              onTap: () {
                                Navigator.pop(ctx);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => DetailView(
                                      repository: repository,
                                      vodId: vod.vodId,
                                      vodItem: vod,
                                    ),
                                  ),
                                );
                              },
                              borderRadius: BorderRadius.circular(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Container(
                                        color: Colors.white10,
                                        width: double.infinity,
                                        child: vod.vodPic.isNotEmpty
                                            ? Image.network(
                                                vod.vodPic,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const Icon(
                                                  Icons
                                                      .movie_creation_outlined,
                                                  color: Colors.white24,
                                                  size: 40,
                                                ),
                                              )
                                            : const Icon(
                                                Icons.movie_creation_outlined,
                                                color: Colors.white24,
                                                size: 40,
                                              ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    vod.vodName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (vod.vodRemarks.isNotEmpty)
                                    Text(
                                      vod.vodRemarks,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11),
                                    ),
                                ],
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: InkWell(
                                onTap: () async {
                                  await HistoryFavoriteService()
                                      .toggleFavorite(vod);
                                  setSheetState(() {});
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close,
                                      size: 14, color: Colors.white70),
                                ),
                              ),
                            ),
                          ],
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

void showVodHistorySheet(BuildContext context, SiteRepository repository, ThemeService themeService) {
  HistoryFavoriteService().loadHistory();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setSheetState) {
        final screenHeight = MediaQuery.of(context).size.height;

        return Container(
          height: screenHeight * 0.75,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          decoration: const BoxDecoration(
            color: Color(0xFF1E2028),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black45,
                  blurRadius: 20,
                  offset: Offset(0, -4)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.history,
                          color: themeService.accentColor, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        '播放历史',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline,
                            size: 16, color: Colors.white54),
                        label: const Text('清空历史',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 13)),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (dCtx) => AlertDialog(
                              backgroundColor: const Color(0xFF262832),
                              title: const Text('清空播放历史',
                                  style: TextStyle(color: Colors.white)),
                              content: const Text('确定要清空所有播放记录吗？',
                                  style: TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(dCtx),
                                    child: const Text('取消')),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent),
                                  onPressed: () async {
                                    await HistoryFavoriteService()
                                        .clearHistory();
                                    Navigator.pop(dCtx);
                                    setSheetState(() {});
                                  },
                                  child: const Text('确定清空',
                                      style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable: HistoryFavoriteService().historyNotifier,
                  builder: (context, histList, _) {
                    if (histList.isEmpty) {
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.history_toggle_off,
                                size: 64, color: Colors.white24),
                            SizedBox(height: 12),
                            Text('暂无播放历史',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 15)),
                            SizedBox(height: 6),
                            Text('在影视播放时会自动为您保存进度',
                                style: TextStyle(
                                    color: Colors.white30, fontSize: 12)),
                          ],
                        ),
                      );
                    }

                    return ListView.separated(
                      itemCount: histList.length,
                      separatorBuilder: (_, __) => const Divider(
                          color: Colors.white12, height: 16),
                      itemBuilder: (context, idx) {
                        final item = histList[idx];
                        final vodId = item['vodId']?.toString() ?? '';
                        final vodName = item['vodName']?.toString() ?? '未知影片';
                        final vodPic = item['vodPic']?.toString() ?? '';
                        final epName = item['episodeName']?.toString() ?? '';
                        final pos =
                            (item['positionSec'] as num?)?.toInt() ?? 0;
                        final dur =
                            (item['durationSec'] as num?)?.toInt() ?? 0;
                        final progress =
                            dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;

                        String posText = _formatSeconds(pos);
                        String durText = dur > 0 ? _formatSeconds(dur) : '';
                        String progressDesc = durText.isNotEmpty
                            ? '观看到 $posText / $durText'
                            : '观看到 $posText';
                        if (epName.isNotEmpty) {
                          progressDesc = '$epName · $progressDesc';
                        }

                        final vod = VodItem(
                          vodId: vodId,
                          vodName: vodName,
                          vodPic: vodPic,
                          vodRemarks: item['vodRemarks']?.toString() ?? '',
                          siteKey: item['siteKey']?.toString(),
                          siteName: item['siteName']?.toString(),
                        );

                        return InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DetailView(
                                  repository: repository,
                                  vodId: vod.vodId,
                                  vodItem: vod,
                                ),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 4.0),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    width: 60,
                                    height: 80,
                                    color: Colors.white10,
                                    child: vodPic.isNotEmpty
                                        ? Image.network(
                                            vodPic,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                const Icon(
                                              Icons.movie_creation_outlined,
                                              color: Colors.white24,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.movie_creation_outlined,
                                            color: Colors.white24,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        vodName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        progressDesc,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: themeService.accentColor,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value: progress,
                                          minHeight: 4,
                                          backgroundColor: Colors.white12,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  themeService.accentColor),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: themeService.accentColor
                                        .withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(Icons.play_arrow,
                                      color: themeService.accentColor,
                                      size: 20),
                                ),
                              ],
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

String _formatSeconds(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 长按 Logo 清除缓存并重新载入配置
