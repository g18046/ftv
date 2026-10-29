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
  final TextEditingController _searchController =
      TextEditingController(text: '凡人修仙传');
  List<VodItem> _searchResults = [];
  bool _isSearching = false;
  SiteModel? _selectedSearchSite; // null 代表“全站并发搜索”

  Future<void> _performSearch() async {
    final kw = _searchController.text.trim();
    if (kw.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    List<VodItem> results = [];
    if (_selectedSearchSite == null) {
      // ⚡ 全站并发搜索：支持增量流式实时上屏，首批搜索结果秒级展示
      results = await widget.repository.searchAllSites(
        kw,
        onProgress: (batch) {
          if (mounted && batch.isNotEmpty) {
            setState(() {
              _searchResults.addAll(batch);
            });
          }
        },
      );
    } else {
      // 指定站点搜索
      results =
          await widget.repository.searchVodOnSite(_selectedSearchSite!, kw);
    }

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  void _onTapVodItem(VodItem vod) {
    if (vod.isFolder) {
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
            vodItem: vod,
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
    final sites =
        widget.repository.sites.where((s) => s.key != 'push_agent').toList();

    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181A22),
        elevation: 0,
        title: const Text('全网影视搜索',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal, color: Colors.greenAccent),
            tooltip: '查看 QJS 运行日志',
            onPressed: () =>
                ExecutionLogDialog.show(context, widget.repository.jsEngine),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E3A34), Color(0xFF142622), Color(0xFF0F1C19)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 搜索输入框与操作按钮
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '输入影视剧关键词搜索...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      prefixIcon: const Icon(Icons.search,
                          color: Color(0xFFE5A00D)),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear,
                                  size: 18, color: Colors.grey),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {});
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0x33FFFFFF),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _performSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isSearching ? null : _performSearch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE5A00D),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                  ),
                  child: _isSearching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('搜索',
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 搜索站点范围选择 Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('范围: ',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.white70)),
                  Padding(
                    padding: const EdgeInsets.only(right: 6.0),
                    child: ChoiceChip(
                      label: const Text('⚡ 全站并发秒搜'),
                      selected: _selectedSearchSite == null,
                      selectedColor: const Color(0xFFE5A00D),
                      onSelected: (_) =>
                          setState(() => _selectedSearchSite = null),
                    ),
                  ),
                  ...sites.map((site) {
                    final isSelected = _selectedSearchSite?.key == site.key;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6.0),
                      child: ChoiceChip(
                        label: Text(site.name),
                        selected: isSelected,
                        selectedColor: const Color(0xFFE5A00D),
                        onSelected: (_) =>
                            setState(() => _selectedSearchSite = site),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 搜索结果指示与网格展示
            Row(
              children: [
                Text(
                  _searchResults.isNotEmpty
                      ? '已找到 ${_searchResults.length} 条结果'
                      : _isSearching
                          ? '正在并发检索片源中...'
                          : '',
                  style: const TextStyle(
                      color: Color(0xFFE5A00D),
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
                if (_isSearching) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Color(0xFFE5A00D)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),

            // 搜索结果网格
            Expanded(
              child: _searchResults.isEmpty
                  ? Center(
                      child: Text(
                        _isSearching
                            ? '⚡ 正在多站点并发调用 QuickJS search() 检索中...'
                            : '请输入关键词开始搜索',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
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
                            elevation: 3,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                vod.vodPic.isNotEmpty
                                    ? Image.network(
                                        vod.vodPic,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error,
                                                stackTrace) =>
                                            Container(
                                          color: const Color(0xFF262832),
                                          child: Icon(
                                              vod.isFolder
                                                  ? Icons.folder
                                                  : Icons.movie,
                                              size: 40,
                                              color: Colors.grey),
                                        ),
                                      )
                                    : Container(
                                        color: const Color(0xFF262832),
                                        child: Icon(
                                            vod.isFolder
                                                ? Icons.folder
                                                : Icons.movie,
                                            size: 40,
                                            color: Colors.grey),
                                      ),

                                // 站点来源 Badge
                                if (vod.siteName != null)
                                  Positioned(
                                    top: 6,
                                    right: 6,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius:
                                            BorderRadius.circular(4),
                                        border: Border.all(
                                            color: const Color(0xFFE5A00D)
                                                .withOpacity(0.5)),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      child: Text(
                                        vod.siteName!,
                                        style: const TextStyle(
                                            color: Color(0xFFE5A00D),
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),

                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.transparent,
                                          Color(0xDD000000)
                                        ],
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 6),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          vod.vodName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold),
                                        ),
                                        if (vod.vodRemarks.isNotEmpty)
                                          Text(
                                            vod.vodRemarks,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 9),
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
            ),
          ],
        ),
      ),
    );
  }
}
