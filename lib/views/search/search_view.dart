import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/site_model.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/theme_service.dart';
import '../../global/storage_bridge.dart';
import '../detail/detail_view.dart';
import '../search/folder_list_view.dart';
import '../widgets/tv_focusable.dart';

/// OK 影视标准全网搜索页
/// 完美复刻参考图规范：
/// 1. 初始态 (参考图 3)：展示搜索历史与高频联想/建议热词胶囊，点击直达搜索
/// 2. 结果态 (参考图 1 & 2)：左侧站源垂直筛选列表 (全部 + 各独立站源)，右侧双列超清影视卡片 (带红色站源角标)
class SearchView extends StatefulWidget {
  final SiteRepository repository;

  const SearchView({super.key, required this.repository});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _searchController =
      TextEditingController(text: '仙逆');
  final ThemeService _themeService = ThemeService();

  List<VodItem> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _selectedSiteName; // null 代表“全部”站源

  List<String> _historyKeywords = ['仙逆', 'SMBD-160.iso', '凡人修仙传', '斗罗大陆'];
  static const List<String> _suggestKeywords = [
    '仙逆',
    '仙逆剧场版 弑仙之战',
    '仙逆剧场版 神临之战',
    '《仙逆》王林',
    '《仙逆》王林踏天之路',
    '仙逆 合集篇',
    '仙逆动画正确观影顺序',
    '仙逆全集',
    '仙逆剧场版',
    '仙逆动画',
    '仙逆i',
    '仙逆弑仙之战',
    '仙逆院线剧场版',
    '仙逆第一季',
    '仙逆弑神之战',
    '仙逆剧场版2',
    '仙逆游戏',
    '仙逆万族围猎',
    '仙逆彩蛋·逆仙客栈',
    '仙逆全集免费',
    '仙逆国漫',
    '仙逆神临之战',
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
        if (list is List && list.isNotEmpty) {
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
      _selectedSiteName = null; // 重置过滤为“全部”
      _searchResults = [];
    });

    // ⚡ 全网并发秒搜：流式渐进呈现
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
              // 顶栏 (带返回键、关键词输入/展示、清空与视图切换)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () {
                        if (_hasSearched) {
                          setState(() => _hasSearched = false);
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
                        child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // 搜索关键词输入框
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
                          hintStyle: const TextStyle(color: Colors.white54, fontSize: 14),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _hasSearched = false);
                                  },
                                )
                              : null,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _performSearch(),
                      ),
                    ),

                    // 右侧操作
                    if (!_hasSearched)
                      IconButton(
                        icon: const Icon(Icons.search, color: Colors.white, size: 24),
                        tooltip: '搜索',
                        onPressed: () => _performSearch(),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.format_list_bulleted, color: Colors.white, size: 22),
                        tooltip: '切换布局',
                        onPressed: () {},
                      ),
                  ],
                ),
              ),

              // 主视口区域：根据是否已搜索切换展示
              Expanded(
                child: _hasSearched
                    ? _buildSearchResultsLayout()
                    : _buildInitialSearchSuggestions(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 初始态 (参考图 3)：历史搜索与搜索建议热词胶囊
  Widget _buildInitialSearchSuggestions() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      children: [
        // 1. 历史搜索
        if (_historyKeywords.isNotEmpty) ...[
          Row(
            children: [
              const Text('历史',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white60, size: 20),
                tooltip: '清空历史',
                onPressed: _clearHistory,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _historyKeywords.map((kw) {
              return InkWell(
                onTap: () => _performSearch(kw),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    kw,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
        ],

        // 2. 搜索建议
        const Text('建议',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _suggestKeywords.map((kw) {
            return InkWell(
              onTap: () => _performSearch(kw),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  kw,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// 搜索结果态 (参考图 1 & 2)：左侧站源列表 + 右侧双列超清影视卡片
  Widget _buildSearchResultsLayout() {
    // 聚合当前结果中包含的所有站源名称
    final Set<String> resultSiteNames = {};
    for (final v in _searchResults) {
      if (v.siteName != null && v.siteName!.isNotEmpty) {
        resultSiteNames.add(v.siteName!);
      }
    }

    // 若搜索中或无结果时，展示库中默认站点列表供用户查看
    if (resultSiteNames.isEmpty) {
      for (final s in widget.repository.sites) {
        if (s.key != 'push_agent') resultSiteNames.add(s.name);
      }
    }

    // 过滤出当前选中站源对应的结果
    final filteredResults = _selectedSiteName == null
        ? _searchResults
        : _searchResults
            .where((v) => v.siteName == _selectedSiteName || v.siteKey == _selectedSiteName)
            .toList();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧栏：站源过滤选择列表 (全部 + 各独立站源，参考图 1 & 2)
        Container(
          width: 125,
          margin: const EdgeInsets.only(left: 10, bottom: 8),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              // “全部”站源
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: InkWell(
                  onTap: () => setState(() => _selectedSiteName = null),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _selectedSiteName == null
                          ? const Color(0x66336B61)
                          : const Color(0x33FFFFFF),
                      borderRadius: BorderRadius.circular(8),
                      border: _selectedSiteName == null
                          ? Border.all(color: _themeService.accentColor, width: 1.2)
                          : null,
                    ),
                    child: Text(
                      '全部',
                      style: TextStyle(
                        color: _selectedSiteName == null ? _themeService.accentColor : Colors.white,
                        fontWeight: _selectedSiteName == null ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),

              // 各独立站源按钮
              ...resultSiteNames.map((siteName) {
                final isSel = _selectedSiteName == siteName;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: InkWell(
                    onTap: () => setState(() => _selectedSiteName = siteName),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSel ? const Color(0x66336B61) : const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(8),
                        border: isSel ? Border.all(color: _themeService.accentColor, width: 1.2) : null,
                      ),
                      child: Text(
                        siteName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSel ? _themeService.accentColor : Colors.white,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),

        const SizedBox(width: 10),

        // 右侧区域：影视卡片网格 (双列展示，参考图 1 & 2)
        Expanded(
          child: filteredResults.isEmpty
              ? Center(
                  child: _isSearching
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: _themeService.accentColor),
                            const SizedBox(height: 14),
                            const Text('正在全网多站并发秒搜中...',
                                style: TextStyle(color: Colors.white70, fontSize: 13)),
                          ],
                        )
                      : const Text('未找到相关影视结果', style: TextStyle(color: Colors.white60)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.only(right: 12, bottom: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, // 参考图 1 & 2 为标准双列网格
                    childAspectRatio: 0.62,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: filteredResults.length,
                  itemBuilder: (context, idx) {
                    final vod = filteredResults[idx];
                    return _buildResultCard(vod);
                  },
                ),
        ),
      ],
    );
  }

  /// 搜索结果单项卡片 (带左上角橙红站源 Badge、底部状态、居中标题，参考图 1 & 2)
  Widget _buildResultCard(VodItem vod) {
    final remarks = vod.vodRemarks.isNotEmpty ? vod.vodRemarks : '4K';
    final site = vod.siteName ?? '默认源';

    return TvFocusable(
      onPressed: () => _onTapVodItem(vod),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2E6359),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  vod.vodPic.isNotEmpty
                      ? Image.network(
                          vod.vodPic,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: const Color(0xFF264841),
                            child: Icon(vod.isFolder ? Icons.folder : Icons.movie,
                                size: 36, color: Colors.white54),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF264841),
                          child: Icon(vod.isFolder ? Icons.folder : Icons.movie,
                              size: 36, color: Colors.white54),
                        ),

                  // 左上角橙红色站源 Badge (参考图 1 & 2: 欧歌4k js, 虎斑4k js 等)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE64A19),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        site,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // 底部清晰度 / 更新集数状态条
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      color: Colors.black.withOpacity(0.55),
                      child: Text(
                        remarks,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 卡片底部居中标题
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              alignment: Alignment.center,
              child: Text(
                vod.vodName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
