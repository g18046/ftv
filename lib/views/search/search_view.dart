import 'package:flutter/material.dart';
import '../../models/site_model.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../detail/detail_view.dart';
import '../search/folder_list_view.dart';
import '../widgets/execution_log_dialog.dart';
import '../widgets/tv_focusable.dart';

class SearchView extends StatefulWidget {
  final SiteRepository repository;

  const SearchView({super.key, required this.repository});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _searchController = TextEditingController(text: '凡人修仙传');
  List<VodItem> _searchResults = [];
  bool _isSearching = false;
  SiteModel? _selectedSearchSite; // null 代表“全站并发搜索”

  Future<void> _performSearch() async {
    final kw = _searchController.text.trim();
    if (kw.isEmpty) return;

    setState(() => _isSearching = true);

    List<VodItem> results = [];
    if (_selectedSearchSite == null) {
      // 全站并发搜索
      results = await widget.repository.searchAllSites(kw);
    } else {
      // 指定站点搜索
      results = await widget.repository.searchVodOnSite(_selectedSearchSite!, kw);
    }

    setState(() {
      _searchResults = results;
      _isSearching = false;
    });
  }

  void _onTapVodItem(VodItem vod) {
    if (vod.isFolder) {
      // 搜索结果 vod_type 为 'folder' 时，点击打开新一页展示列表，可返回回退到搜索列表页
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FolderListView(
            repository: widget.repository,
            folderVod: vod,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DetailView(
            repository: widget.repository,
            vodId: vod.vodId,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sites = widget.repository.sites.where((s) => s.key != 'push_agent').toList();

    return Scaffold(backgroundColor: const Color(0xFF101216),
      appBar: AppBar(backgroundColor: const Color(0xFF181A22),
        title: const Text('全网影视搜索'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal, color: Colors.green),
            tooltip: '查看 QJS 运行日志',
            onPressed: () => ExecutionLogDialog.show(context, widget.repository.jsEngine),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 搜索输入框与搜索按钮
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '输入关键词搜索...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _performSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isSearching ? null : _performSearch,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  ),
                  child: _isSearching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('搜索'),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 搜索站点选择 Dropdown / Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('搜索范围: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Padding(
                    padding: const EdgeInsets.only(right: 6.0),
                    child: ChoiceChip(
                      label: const Text('⚡ 全站并发搜索'),
                      selected: _selectedSearchSite == null,
                      onSelected: (_) => setState(() => _selectedSearchSite = null),
                    ),
                  ),
                  ...sites.map((site) {
                    final isSelected = _selectedSearchSite?.key == site.key;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6.0),
                      child: ChoiceChip(
                        label: Text(site.name),
                        selected: isSelected,
                        onSelected: (_) => setState(() => _selectedSearchSite = site),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 搜索结果网格
            Expanded(
              child: _searchResults.isEmpty
                  ? Center(
                      child: Text(
                        _isSearching ? '正在多站点并发调用 QuickJS search() 搜索...' : '请输入关键词开始搜索',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 0.65,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final vod = _searchResults[index];
                        return TvFocusable(
                          onPressed: () => _onTapVodItem(vod),
                          child: Card(
                            color: const Color(0xFF1C1E26),
                            clipBehavior: Clip.antiAlias,
                            elevation: 2,
                            child: InkWell(
                              onTap: () => _onTapVodItem(vod),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                vod.vodPic.isNotEmpty
                                    ? Image.network(
                                        vod.vodPic,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Container(
                                          color: Colors.grey.shade300,
                                          child: Icon(vod.isFolder ? Icons.folder : Icons.movie, size: 40, color: Colors.grey),
                                        ),
                                      )
                                    : Container(
                                        color: Colors.grey.shade300,
                                        child: Icon(vod.isFolder ? Icons.folder : Icons.movie, size: 40, color: Colors.grey),
                                      ),

                                // 站点来源 Badge
                                if (vod.siteName != null)
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      child: Text(
                                        vod.siteName!,
                                        style: const TextStyle(color: Colors.amberAccent, fontSize: 9, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),

                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    color: Colors.black87,
                                    padding: const EdgeInsets.all(4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          vod.vodName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                        if (vod.vodRemarks.isNotEmpty)
                                          Text(
                                            vod.vodRemarks,
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
                        ),
                      );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
