import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/theme_service.dart';
import '../../global/storage_bridge.dart';
import '../detail/detail_view.dart';
import '../search/folder_list_view.dart';
import 'widgets/search_result_card.dart';
import 'widgets/search_suggestions_view.dart';

/// OK 影视标准全网搜索页
/// 1. 初始态：展示搜索历史与热词建议胶囊，点击直达搜索
/// 2. 结果态：左侧站源垂直筛选列表 (全部 + 已返回结果的站源)，右侧双列超清影视卡片 (流式增量呈现)
class SearchView extends StatefulWidget {
  final SiteRepository repository;

  const SearchView({super.key, required this.repository});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _searchController = TextEditingController();
  final ThemeService _themeService = ThemeService();

  List<VodItem> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _selectedSiteName; // null 代表“全部”站源

  List<String> _historyKeywords = [];
  static const List<String> _suggestKeywords = [
    '仙逆',
    '凡人修仙传',
    '完美世界',
    '斗破苍穹',
    '吞噬星空',
    '遮天',
  ];

  @override
  void initState() {
    super.initState();
    _loadSearchHistory();
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSearchHistory() async {
    try {
      final jsonStr = await StorageBridge.getValue('search_history_keywords');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final list = jsonDecode(jsonStr);
        if (list is List && list.isNotEmpty && mounted) {
          setState(() {
            _historyKeywords = list.map((e) => e.toString()).toList();
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSearchHistory(String kw) async {
    final clean = kw.trim();
    if (clean.isEmpty) return;
    _historyKeywords.remove(clean);
    _historyKeywords.insert(0, clean);
    if (_historyKeywords.length > 20) {
      _historyKeywords = _historyKeywords.sublist(0, 20);
    }
    try {
      await StorageBridge.setValue(
        'search_history_keywords',
        jsonEncode(_historyKeywords),
      );
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    setState(() => _historyKeywords.clear());
    try {
      await StorageBridge.setValue('search_history_keywords', '[]');
    } catch (_) {}
  }

  Future<void> _performSearch([String? customKw]) async {
    final kw = (customKw ?? _searchController.text).trim();
    if (kw.isEmpty) return;

    if (customKw != null) {
      _searchController.text = customKw;
    }

    _saveSearchHistory(kw);

    setState(() {
      _isSearching = true;
      _hasSearched = true;
      _selectedSiteName = null;
      _searchResults = [];
    });

    // ⚡ 全网并发秒搜：初始为空，每完成一个站源立即增量追加
    final results = await widget.repository.searchAllSites(
      kw,
      onProgress: (batch) {
        if (mounted && batch.isNotEmpty) {
          setState(() {
            _searchResults.addAll(batch);
          });
        }
      },
    );

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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          gradient: _themeService.currentGradient,
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 顶栏
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () {
                        if (_hasSearched) {
                          setState(() {
                            _hasSearched = false;
                            _searchResults = [];
                          });
                        } else {
                          Navigator.pop(context);
                        }
                      },
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(
                          color: Color(0x33000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          hintText: '搜索影视剧...',
                          hintStyle: const TextStyle(
                              color: Colors.white54, fontSize: 14),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 8),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close,
                                      color: Colors.white70, size: 20),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _hasSearched = false;
                                      _searchResults = [];
                                    });
                                  },
                                )
                              : null,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _performSearch(),
                      ),
                    ),
                    if (!_hasSearched)
                      IconButton(
                        icon: const Icon(Icons.search,
                            color: Colors.white, size: 24),
                        tooltip: '搜索',
                        onPressed: () => _performSearch(),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.format_list_bulleted,
                            color: Colors.white, size: 22),
                        tooltip: '切换布局',
                        onPressed: () {},
                      ),
                  ],
                ),
              ),

              Expanded(
                child: _hasSearched
                    ? _buildSearchResultsLayout()
                    : SearchSuggestionsView(
                        historyKeywords: _historyKeywords,
                        suggestKeywords: _suggestKeywords,
                        onTapKeyword: (kw) => _performSearch(kw),
                        onClearHistory: _clearHistory,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResultsLayout() {
    // 仅聚合当前已返回结果的站源名称（搜索时初始为空，搜完一个才加上去）
    final Set<String> resultSiteNames = {};
    for (final v in _searchResults) {
      if (v.siteName != null && v.siteName!.isNotEmpty) {
        resultSiteNames.add(v.siteName!);
      }
    }

    final filteredResults = _selectedSiteName == null
        ? _searchResults
        : _searchResults
            .where((v) =>
                v.siteName == _selectedSiteName ||
                v.siteKey == _selectedSiteName)
            .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double rightWidth = constraints.maxWidth - 145;
        final int crossAxisCount = (rightWidth / 150).floor().clamp(2, 10);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧栏：站源过滤选择列表
            Container(
              width: 125,
              margin: const EdgeInsets.only(left: 10, bottom: 8),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _buildSiteFilterTile(
                    label: '全部 (${_searchResults.length})',
                    isSelected: _selectedSiteName == null,
                    onTap: () => setState(() => _selectedSiteName = null),
                  ),
                  ...resultSiteNames.map((siteName) {
                    return _buildSiteFilterTile(
                      label: siteName,
                      isSelected: _selectedSiteName == siteName,
                      onTap: () =>
                          setState(() => _selectedSiteName = siteName),
                    );
                  }),
                ],
              ),
            ),

            const SizedBox(width: 10),

            // 右侧区域：影视卡片网格
            Expanded(
              child: filteredResults.isEmpty
                  ? Center(
                      child: _isSearching
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                    color: _themeService.accentColor),
                                const SizedBox(height: 14),
                                const Text('正在全网多站并发秒搜中...',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                              ],
                            )
                          : const Text('未找到相关影视结果',
                              style: TextStyle(color: Colors.white60)),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.only(right: 12, bottom: 16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.65,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: filteredResults.length,
                      itemBuilder: (context, idx) {
                        final vod = filteredResults[idx];
                        return SearchResultCard(
                          vod: vod,
                          onTap: () => _onTapVodItem(vod),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSiteFilterTile({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0x66336B61)
                : const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: isSelected
                ? Border.all(color: _themeService.accentColor, width: 1.2)
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected ? _themeService.accentColor : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }
}
