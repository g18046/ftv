import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';
import '../../../repositories/site_repository.dart';
import '../../../services/download_service.dart';
import '../../../services/theme_service.dart';

/// 剧集下载与下载管理底部弹窗：默认开启 App 内置下载，支持按集下载与批量选择下载，也支持切换 IDM+
void showEpisodeDownloadSheet({
  required BuildContext context,
  required VodItem? vodDetail,
  required int selectedSourceIndex,
  required String currentEpisodeName,
  required String currentPlayUrl,
  required Map<String, String> currentHeaders,
  required String? targetSiteKey,
  required SiteRepository repository,
  required ThemeService themeService,
  required void Function(String localPath, String episodeName) onPlayLocalFile,
  required void Function(IconData icon, String text) onShowHud,
}) {
  final sources = vodDetail?.playSources ?? [];
  if (sources.isEmpty) {
    onShowHud(Icons.info_outline, '暂无可下载的剧集');
    return;
  }
  final source = sources[selectedSourceIndex.clamp(0, sources.length - 1)];
  final episodes = source.episodes;
  if (episodes.isEmpty) {
    onShowHud(Icons.info_outline, '当前线路暂无剧集');
    return;
  }

  DownloadService().init();

  int activeTab = 0; // 0: 选集下载, 1: 下载管理
  bool useIdmPlus = false; // 默认开启 App 内置下载
  bool isBatchMode = false;
  bool isBatchStarting = false;
  int rangeIndex = 0;
  const int pageSize = 20;
  final int rangeCount = (episodes.length / pageSize).ceil().clamp(1, 999);
  final Set<int> selectedIndices = {};
  String? resolvingEpUrl;

  Map<String, String> parseHeaders(dynamic headerObj) {
    if (headerObj is String && headerObj.trim().startsWith('{')) {
      try {
        headerObj = jsonDecode(headerObj.trim());
      } catch (_) {}
    }
    final Map<String, String> headers = {};
    if (headerObj is Map) {
      headerObj.forEach((k, v) {
        if (k != null && v != null) {
          final ck = k.toString().replaceAll(RegExp(r'[\r\n]'), '').trim();
          final cv = v.toString().replaceAll(RegExp(r'[\r\n]'), '').trim();
          if (ck.isNotEmpty) headers[ck] = cv;
        }
      });
    }
    return headers;
  }

  Future<bool> resolveAndQueueEpisode(
    EpisodeItem ep,
    StateSetter setSheetState, {
    bool silentHud = false,
  }) async {
    String playUrl = '';
    Map<String, String> headers = {};

    if (ep.name == currentEpisodeName && currentPlayUrl.isNotEmpty) {
      playUrl = currentPlayUrl;
      headers = Map<String, String>.from(currentHeaders);
    } else {
      if (context.mounted) {
        setSheetState(() => resolvingEpUrl = ep.url);
      }
      try {
        final res = await repository.fetchPlayInfo(
          source.name,
          ep.url,
          siteKey: targetSiteKey,
        );
        playUrl = res['url']?.toString() ?? '';
        headers = parseHeaders(res['header']);
        final msg = res['msg']?.toString().trim() ?? '';
        if (playUrl.isEmpty) {
          if (!silentHud) {
            onShowHud(Icons.error_outline, msg.isNotEmpty ? msg : '解析下载地址失败');
          }
          return false;
        }
      } catch (e) {
        if (!silentHud) {
          onShowHud(Icons.error_outline, '解析下载地址异常: $e');
        }
        return false;
      } finally {
        if (context.mounted) {
          setSheetState(() => resolvingEpUrl = null);
        }
      }
    }

    final isMovie = episodes.length <= 1;
    if (useIdmPlus) {
      final res = await DownloadService().launchIdmPlus(
        url: playUrl,
        vodName: vodDetail?.vodName ?? 'FTV',
        episodeName: ep.name,
        headers: headers,
        isMovie: isMovie,
      );
      if (!silentHud) {
        onShowHud(
          res.ok ? Icons.download_done : Icons.warning_amber_rounded,
          res.message ?? (res.ok ? '已发送到 1DM+ / IDM+' : '拉起 1DM+ / IDM+ 失败'),
        );
      }
      return res.ok;
    } else {
      await DownloadService().startInAppDownload(
        vodId: vodDetail?.vodId ?? '',
        vodName: vodDetail?.vodName ?? 'FTV视频',
        episodeName: ep.name,
        sourceName: source.name,
        url: playUrl,
        headers: headers,
        isMovie: isMovie,
      );
      if (!silentHud) {
        onShowHud(Icons.downloading, '已加入下载队列: ${ep.name}');
      }
      return true;
    }
  }

  Future<void> handleDownloadEpisode(
    EpisodeItem ep,
    StateSetter setSheetState,
  ) async {
    if (resolvingEpUrl != null || isBatchStarting) return;
    await resolveAndQueueEpisode(ep, setSheetState);
  }

  Future<void> handleBatchDownload(StateSetter setSheetState) async {
    if (selectedIndices.isEmpty || isBatchStarting) return;
    final indices = selectedIndices.toList()..sort();
    setSheetState(() => isBatchStarting = true);
    int okCount = 0;
    for (final idx in indices) {
      if (idx < 0 || idx >= episodes.length) continue;
      final ok = await resolveAndQueueEpisode(
        episodes[idx],
        setSheetState,
        silentHud: true,
      );
      if (ok) okCount++;
    }
    if (context.mounted) {
      setSheetState(() {
        isBatchStarting = false;
        isBatchMode = false;
        selectedIndices.clear();
      });
    }
    onShowHud(
      Icons.download_done,
      '批量加入完成：$okCount / ${indices.length} 集',
    );
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (sCtx, setSheetState) {
        final screenHeight = MediaQuery.of(sCtx).size.height;
        final accent = themeService.accentColor;

        final startIdx = rangeIndex * pageSize;
        final endIdx = (startIdx + pageSize).clamp(0, episodes.length);
        final visibleIndices = List<int>.generate(
          (endIdx - startIdx).clamp(0, pageSize),
          (i) => startIdx + i,
        );

        return Container(
          height: screenHeight * 0.78,
          decoration: const BoxDecoration(
            color: Color(0xFF1A1D24),
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部标题与 Tab 切换
              Row(
                children: [
                  _buildTabBtn(
                    label: '按集下载',
                    selected: activeTab == 0,
                    accent: accent,
                    onTap: () => setSheetState(() => activeTab = 0),
                  ),
                  const SizedBox(width: 10),
                  ValueListenableBuilder<List<DownloadTask>>(
                    valueListenable: DownloadService().tasksNotifier,
                    builder: (_, tasks, __) {
                      final activeCount = tasks
                          .where((t) => t.status == DownloadStatus.downloading)
                          .length;
                      final label = activeCount > 0
                          ? '下载列表 ($activeCount)'
                          : '下载列表 (${tasks.length})';
                      return _buildTabBtn(
                        label: label,
                        selected: activeTab == 1,
                        accent: accent,
                        onTap: () => setSheetState(() => activeTab = 1),
                      );
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              if (activeTab == 0) ...[
                // 下载方式 + 批量模式切换栏
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF242834),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      _buildModePill(
                        label: '内置下载',
                        selected: !useIdmPlus,
                        accent: accent,
                        onTap: () => setSheetState(() => useIdmPlus = false),
                      ),
                      const SizedBox(width: 8),
                      if (Platform.isAndroid)
                        _buildModePill(
                          label: '1DM+',
                          selected: useIdmPlus,
                          accent: accent,
                          onTap: () => setSheetState(() => useIdmPlus = true),
                        ),
                      const Spacer(),
                      InkWell(
                        onTap: () {
                          setSheetState(() {
                            isBatchMode = !isBatchMode;
                            if (!isBatchMode) selectedIndices.clear();
                          });
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: isBatchMode ? accent.withValues(alpha: 0.22) : const Color(0xFF1A1D24),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isBatchMode ? accent : Colors.white24,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isBatchMode ? Icons.check_box : Icons.checklist_rtl,
                                size: 14,
                                color: isBatchMode ? accent : Colors.white70,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isBatchMode ? '退出批量' : '批量下载',
                                style: TextStyle(
                                  color: isBatchMode ? accent : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 分段标签 (1-20, 21-40...)
                if (rangeCount > 1) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 30,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: rangeCount,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (_, rIdx) {
                        final rStart = rIdx * pageSize + 1;
                        final rEnd = ((rIdx + 1) * pageSize).clamp(1, episodes.length);
                        final isSel = rangeIndex == rIdx;
                        return InkWell(
                          onTap: () => setSheetState(() => rangeIndex = rIdx),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$rStart - $rEnd',
                                style: TextStyle(
                                  color: isSel ? accent : Colors.white54,
                                  fontSize: 12.5,
                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                width: 28,
                                height: 2.5,
                                decoration: BoxDecoration(
                                  color: isSel ? accent : Colors.transparent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 10),

                // 剧集网格
                Expanded(
                  child: ValueListenableBuilder<List<DownloadTask>>(
                    valueListenable: DownloadService().tasksNotifier,
                    builder: (_, tasks, __) {
                      return LayoutBuilder(
                        builder: (gCtx, gCons) {
                          final cols = gCons.maxWidth >= 520 ? 3 : 2;
                          return GridView.builder(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: cols,
                              childAspectRatio: 2.6,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                            ),
                            itemCount: visibleIndices.length,
                            itemBuilder: (_, i) {
                              final realIdx = visibleIndices[i];
                              final ep = episodes[realIdx];
                              final isResolving = resolvingEpUrl == ep.url;
                              final isBatchSelected = selectedIndices.contains(realIdx);
                              final existing = tasks.where((t) =>
                                  t.vodId == (vodDetail?.vodId ?? '') &&
                                  t.episodeName == ep.name).firstOrNull;

                              String? badge;
                              if (existing != null) {
                                if (existing.status == DownloadStatus.completed) {
                                  badge = '已缓存';
                                } else if (existing.status == DownloadStatus.downloading) {
                                  badge = '${(existing.progress * 100).toInt()}%';
                                } else if (existing.status == DownloadStatus.paused) {
                                  badge = '已暂停';
                                }
                              }

                              return InkWell(
                                onTap: () {
                                  if (isBatchMode) {
                                    setSheetState(() {
                                      if (isBatchSelected) {
                                        selectedIndices.remove(realIdx);
                                      } else {
                                        selectedIndices.add(realIdx);
                                      }
                                    });
                                  } else {
                                    handleDownloadEpisode(ep, setSheetState);
                                  }
                                },
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isBatchSelected
                                        ? accent.withValues(alpha: 0.18)
                                        : const Color(0xFF262A36),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isBatchSelected
                                          ? accent
                                          : (ep.name == currentEpisodeName
                                              ? accent.withValues(alpha: 0.7)
                                              : Colors.white10),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      if (isBatchMode) ...[
                                        Icon(
                                          isBatchSelected
                                              ? Icons.check_circle
                                              : Icons.radio_button_unchecked,
                                          size: 16,
                                          color: isBatchSelected ? accent : Colors.white38,
                                        ),
                                        const SizedBox(width: 6),
                                      ],
                                      Expanded(
                                        child: Text(
                                          ep.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            height: 1.2,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      if (isResolving)
                                        SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: accent,
                                          ),
                                        )
                                      else if (badge != null)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 5, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: accent.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            badge,
                                            style: TextStyle(
                                              color: accent,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        )
                                      else if (!isBatchMode)
                                        Icon(
                                          useIdmPlus
                                              ? Icons.open_in_new
                                              : Icons.download_rounded,
                                          size: 16,
                                          color: Colors.white54,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),

                // 批量操作底栏
                if (isBatchMode) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setSheetState(() {
                            final allSelected = visibleIndices.every(selectedIndices.contains);
                            if (allSelected) {
                              selectedIndices.removeAll(visibleIndices);
                            } else {
                              selectedIndices.addAll(visibleIndices);
                            }
                          });
                        },
                        child: Text(
                          visibleIndices.every(selectedIndices.contains) ? '取消本页' : '全选本页',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setSheetState(() {
                            if (selectedIndices.length == episodes.length) {
                              selectedIndices.clear();
                            } else {
                              selectedIndices.addAll(List.generate(episodes.length, (i) => i));
                            }
                          });
                        },
                        child: Text(
                          selectedIndices.length == episodes.length ? '清空全选' : '全选全部 (${episodes.length})',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: (selectedIndices.isEmpty || isBatchStarting)
                            ? null
                            : () => handleBatchDownload(setSheetState),
                        icon: isBatchStarting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.download_rounded, size: 18),
                        label: Text(
                          isBatchStarting
                              ? '正在加入...'
                              : '下载选中 (${selectedIndices.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ] else ...[
                // 下载管理列表
                Expanded(
                  child: ValueListenableBuilder<List<DownloadTask>>(
                    valueListenable: DownloadService().tasksNotifier,
                    builder: (_, tasks, __) {
                      if (tasks.isEmpty) {
                        return const Center(
                          child: Text('暂无内置下载任务',
                              style: TextStyle(color: Colors.white54, fontSize: 13)),
                        );
                      }
                      return ListView.separated(
                        itemCount: tasks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, idx) {
                          final task = tasks[idx];
                          final isDone = task.status == DownloadStatus.completed;
                          final isDl = task.status == DownloadStatus.downloading;
                          final isFail = task.status == DownloadStatus.failed;
                          final speedText = isDl
                              ? '${DownloadService.formatBytes(task.speedBytesPerSec.toInt())}/s'
                              : (isDone
                                  ? '已完成'
                                  : (isFail ? '失败' : '暂停'));

                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF242834),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${task.vodName} - ${task.episodeName}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      speedText,
                                      style: TextStyle(
                                        color: isDone
                                            ? Colors.greenAccent
                                            : (isFail ? Colors.redAccent : accent),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: isDone ? 1.0 : task.progress,
                                    minHeight: 5,
                                    backgroundColor: Colors.white12,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        isDone ? Colors.greenAccent : accent),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      '${DownloadService.formatBytes(task.receivedBytes)}'
                                      '${task.totalBytes > 0 ? " / ${DownloadService.formatBytes(task.totalBytes)}" : ""}',
                                      style: const TextStyle(
                                          color: Colors.white54, fontSize: 11),
                                    ),
                                    const Spacer(),
                                    if (isDone)
                                      TextButton.icon(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          onPlayLocalFile(Uri.file(task.savePath).toString(), task.episodeName);
                                        },
                                        icon: const Icon(Icons.play_arrow, size: 16),
                                        label: const Text('本地播放', style: TextStyle(fontSize: 12)),
                                      )
                                    else
                                      IconButton(
                                        icon: Icon(
                                          isDl ? Icons.pause_circle_outline : Icons.play_circle_outline,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                        onPressed: () {
                                          if (isDl) {
                                            DownloadService().pauseTask(task.id);
                                          } else {
                                            DownloadService().resumeTask(task);
                                          }
                                        },
                                      ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.white54, size: 18),
                                      onPressed: () =>
                                          DownloadService().deleteTask(task.id),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

Widget _buildTabBtn({
  required String label,
  required bool selected,
  required Color accent,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.2) : const Color(0xFF242834),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? accent : Colors.transparent),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? accent : Colors.white70,
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    ),
  );
}

Widget _buildModePill({
  required String label,
  required bool selected,
  required Color accent,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? accent : const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.black : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
  );
}
