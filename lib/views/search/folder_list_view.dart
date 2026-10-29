import 'package:flutter/material.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../detail/detail_view.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/execution_log_dialog.dart';

/// 文件夹二级/深层列表视图 (严格遵循 1.md: 搜索结果 vod_type 为 'folder' 时，点击打开新一页展示列表，可返回回退到搜索列表页)
class FolderListView extends StatefulWidget {
  final SiteRepository repository;
  final VodItem folderVod;

  const FolderListView({
    super.key,
    required this.repository,
    required this.folderVod,
  });

  @override
  State<FolderListView> createState() => _FolderListViewState();
}

class _FolderListViewState extends State<FolderListView> {
  List<VodItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFolderItems();
  }

  Future<void> _loadFolderItems() async {
    setState(() => _isLoading = true);
    // 如果带指定站点 key，先确保切至该站点
    if (widget.folderVod.siteKey != null) {
      final target = widget.repository.sites.firstWhere(
        (s) => s.key == widget.folderVod.siteKey,
        orElse: () => widget.repository.activeSite ?? widget.repository.sites.first,
      );
      await widget.repository.setActiveSite(target);
    }

    final list = await widget.repository.fetchCategoryList(widget.folderVod.vodId, 1, {});
    if (mounted) {
      setState(() {
        _items = list;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181A22),
        elevation: 1,
        title: Row(
          children: [
            const Icon(Icons.folder_open, color: Color(0xFFE5A00D), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.folderVod.vodName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: '刷新目录',
            onPressed: _loadFolderItems,
          ),
          IconButton(
            icon: const Icon(Icons.terminal, color: Colors.green),
            tooltip: '查看 QJS 日志',
            onPressed: () => ExecutionLogDialog.show(context, widget.repository.jsEngine),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFE5A00D)))
          : _items.isEmpty
              ? const Center(
                  child: Text('文件夹内容为空', style: TextStyle(color: Colors.white60)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12.0),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.68,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return TvFocusable(
                      onPressed: () {
                        if (item.isFolder) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FolderListView(
                                repository: widget.repository,
                                folderVod: item,
                              ),
                            ),
                          );
                        } else {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DetailView(
                                repository: widget.repository,
                                vodId: item.vodId,
                              ),
                            ),
                          );
                        }
                      },
                      child: Card(
                        color: const Color(0xFF1C1E26),
                        clipBehavior: Clip.antiAlias,
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            item.vodPic.isNotEmpty
                                ? Image.network(
                                    item.vodPic,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: const Color(0xFF262832),
                                      child: Icon(
                                        item.isFolder ? Icons.folder : Icons.movie,
                                        size: 40,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  )
                                : Container(
                                    color: const Color(0xFF262832),
                                    child: Icon(
                                      item.isFolder ? Icons.folder : Icons.movie,
                                      size: 40,
                                      color: Colors.grey,
                                    ),
                                  ),
                            if (item.isFolder)
                              Positioned(
                                top: 4,
                                left: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE5A00D),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('目录', style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                color: Colors.black87,
                                padding: const EdgeInsets.all(5),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.vodName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    if (item.vodRemarks.isNotEmpty)
                                      Text(
                                        item.vodRemarks,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white70, fontSize: 9),
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
                ),
    );
  }
}
