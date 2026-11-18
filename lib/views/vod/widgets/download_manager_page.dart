import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';
import '../../../repositories/site_repository.dart';
import '../../../services/download_service.dart';
import '../../../services/theme_service.dart';
import '../../detail/detail_view.dart';

/// 全局下载管理页（支持「下载中 / 已下载」双 Tab 切换、进度条、暂停/继续/删除及点击播放）
class DownloadManagerPage extends StatefulWidget {
  final SiteRepository repository;
  final ThemeService themeService;

  const DownloadManagerPage({
    super.key,
    required this.repository,
    required this.themeService,
  });

  @override
  State<DownloadManagerPage> createState() => _DownloadManagerPageState();
}

class _DownloadManagerPageState extends State<DownloadManagerPage> {
  @override
  void initState() {
    super.initState();
    DownloadService().init();
  }

  Future<void> _confirmClearAll(List<DownloadTask> tasks) async {
    if (tasks.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('清空下载', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text('确定清空所有下载记录及缓存文件吗？', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      for (final t in List<DownloadTask>.from(tasks)) {
        await DownloadService().deleteTask(t.id);
      }
    }
  }

  void _openDownloadedTask(DownloadTask task) {
    final vod = VodItem(
      vodId: task.vodId,
      vodName: task.vodName,
      vodPic: '',
      vodRemarks: task.episodeName,
      vodPlayFrom: '本地缓存',
      vodPlayUrl: '${task.episodeName}\$${Uri.file(task.savePath).toString()}',
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailView(
          vodId: task.vodId,
          repository: widget.repository,
          vodItem: vod,
        ),
      ),
    );
  }

  Widget _buildTaskList(List<DownloadTask> list, String emptyText) {
    if (list.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, idx) {
        final task = list[idx];
        final isDone = task.status == DownloadStatus.completed;
        final isDl = task.status == DownloadStatus.downloading;
        final isFail = task.status == DownloadStatus.failed;
        final statusText = isDl
            ? '${DownloadService.formatBytes(task.speedBytesPerSec.toInt())}/s'
            : (isDone ? '已完成' : (isFail ? '失败' : '暂停'));
        final sizeText = task.totalBytes > 0
            ? DownloadService.formatBytes(task.totalBytes)
            : DownloadService.formatBytes(task.receivedBytes);

        return InkWell(
          onTap: () {
            if (isDone) {
              _openDownloadedTask(task);
            } else if (isDl) {
              DownloadService().pauseTask(task.id);
            } else {
              DownloadService().resumeTask(task);
            }
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0x44000000),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${task.vodName}-${task.episodeName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.only(left: 8),
                      icon: Icon(
                        isDone
                            ? Icons.play_circle_outline
                            : (isDl
                                ? Icons.pause_circle_outline
                                : Icons.play_circle_outline),
                        color: Colors.white70,
                        size: 20,
                      ),
                      onPressed: () {
                        if (isDone) {
                          _openDownloadedTask(task);
                        } else if (isDl) {
                          DownloadService().pauseTask(task.id);
                        } else {
                          DownloadService().resumeTask(task);
                        }
                      },
                    ),
                    IconButton(
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.only(left: 10),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white54,
                        size: 19,
                      ),
                      onPressed: () => DownloadService().deleteTask(task.id),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: isDone ? 1.0 : task.progress,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDone ? Colors.greenAccent : const Color(0xFF42A5F5),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        color: isDone
                            ? Colors.greenAccent
                            : (isFail ? Colors.redAccent : Colors.white),
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      sizeText,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.themeService.accentColor;

    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: DownloadService().tasksNotifier,
      builder: (_, tasks, _) {
        final downloadingList = tasks
            .where((t) => t.status != DownloadStatus.completed)
            .toList();
        final completedList = tasks
            .where((t) => t.status == DownloadStatus.completed)
            .toList();

        return DefaultTabController(
          length: 2,
          initialIndex: downloadingList.isEmpty && completedList.isNotEmpty ? 1 : 0,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Container(
              decoration: BoxDecoration(gradient: widget.themeService.currentGradient),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back, color: Colors.white),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '下载',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.white),
                            tooltip: '清空全部',
                            onPressed: tasks.isEmpty ? null : () => _confirmClearAll(tasks),
                          ),
                        ],
                      ),
                    ),
                    TabBar(
                      indicatorColor: accent,
                      indicatorWeight: 2.5,
                      dividerColor: Colors.white12,
                      labelColor: accent,
                      unselectedLabelColor: Colors.white70,
                      labelStyle: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.normal,
                      ),
                      tabs: [
                        Tab(text: '下载中 (${downloadingList.length})'),
                        Tab(text: '已下载 (${completedList.length})'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildTaskList(downloadingList, '暂无正在下载的任务'),
                          _buildTaskList(completedList, '暂无已下载的视频'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
