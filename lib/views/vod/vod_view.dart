import 'package:flutter/services.dart';
import '../../services/history_favorite_service.dart';
import 'dart:io';
import '../../services/theme_service.dart';
import 'package:flutter/material.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../../global/storage_bridge.dart';
import '../detail/detail_view.dart';
import '../search/search_view.dart';
import '../widgets/execution_log_dialog.dart';
import '../widgets/tv_focusable.dart';

/// OK影视风格 统一点播主页
class VodView extends StatefulWidget {
  final SiteRepository repository;

  const VodView({super.key, required this.repository});

  @override
  State<VodView> createState() => _VodViewState();
}

class _VodViewState extends State<VodView> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _tabScrollController = ScrollController();

  List<CategoryItem> _categories = [];
  Map<String, List<CategoryFilterGroup>> _filterMap = {};

  CategoryItem? _selectedCategory; // null 代表“推荐”
  final Map<String, dynamic> _activeFilters = {};

  // 分类数据高速缓存 (支持滑动切 Tab 时瞬间显示)
  final Map<String, List<VodItem>> _categoryCache = {};
  double _horizontalDragOffset = 0;
  bool _isSwipeNext = true;

  // 文件夹穿透历史栈
  final List<VodItem> _folderHistory = [];
  final ThemeService _themeService = ThemeService();

  List<VodItem> _vodList = [];
  bool _isLoading = true;
  bool _isChangingSite = false;
  bool _showFilterPanel = false;
  bool _hasHomeVod = false;
  int _page = 1;
  bool _showScrollTopBtn = false;

  @override
  void initState() {
    super.initState();
    HistoryFavoriteService().init();
    _scrollController.addListener(_onScroll);
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
    _loadSiteAndData();
  }

  @override
  void dispose() {
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final showBtn = _scrollController.offset > 300;
      if (showBtn != _showScrollTopBtn) {
        setState(() => _showScrollTopBtn = showBtn);
      }
    }
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// 初始化并加载站点数据
  Future<void> _loadSiteAndData() async {
    setState(() => _isLoading = true);

    try {
      if (widget.repository.activeSite == null && widget.repository.sites.isNotEmpty) {
        String? lastKey;
        try {
          lastKey = await StorageBridge.getValue('last_active_site_key');
        } catch (_) {}

        final sites = widget.repository.sites;
        final target = (lastKey != null && lastKey.isNotEmpty)
            ? sites.firstWhere(
                (s) => s.key == lastKey,
                orElse: () => sites.firstWhere((s) => s.key != 'push_agent', orElse: () => sites.first),
              )
            : sites.firstWhere((s) => s.key != 'push_agent', orElse: () => sites.first);

        await widget.repository.setActiveSite(target).timeout(
          const Duration(seconds: 5),
          onTimeout: () => print('⚠️ 设置默认站点超时，继续执行'),
        );
      }

      if (widget.repository.activeSite != null) {
        final catData = await widget.repository.fetchCategories().timeout(
          const Duration(seconds: 6),
          onTimeout: () => {'categories': <CategoryItem>[], 'filters': {}},
        );
        final List<CategoryItem> cats = (catData['categories'] is List)
            ? (catData['categories'] as List).whereType<CategoryItem>().toList()
            : <CategoryItem>[];

        final Map<String, List<CategoryFilterGroup>> filters = {};
        final rawFilters = catData['filters'];
        if (rawFilters is Map) {
          rawFilters.forEach((k, v) {
            if (v is List) {
              filters[k.toString()] = v.whereType<CategoryFilterGroup>().toList();
            }
          });
        }
        if (filters.isEmpty) {
          filters.addAll(widget.repository.activeSiteFilters);
        }

        List<VodItem> initialVods = [];
        bool homeAvailable = false;

        try {
          final homeVods = await widget.repository.fetchHomeVods().timeout(
            const Duration(seconds: 4),
            onTimeout: () => [],
          );
          if (homeVods.isNotEmpty) {
            initialVods = homeVods;
            homeAvailable = true;
          }
        } catch (_) {}

        if (initialVods.isEmpty && cats.isNotEmpty) {
          initialVods = await widget.repository.fetchCategoryList(cats.first.typeId, 1).timeout(
            const Duration(seconds: 4),
            onTimeout: () => [],
          );
        }

        if (mounted) {
          setState(() {
            _categories = cats;
            _filterMap = filters;
            _hasHomeVod = homeAvailable;
            _vodList = initialVods;
            _categoryCache.clear();
            if (initialVods.isNotEmpty) _categoryCache['__home__'] = initialVods;
            _isLoading = false;
            _selectedCategory = homeAvailable ? null : (cats.isNotEmpty ? cats.first : null);
          });
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadCategoryVods(String typeId, int page) async {
    setState(() => _isLoading = true);
    _folderHistory.clear();
    try {
      final list = await widget.repository.fetchCategoryList(typeId, page, _activeFilters).timeout(
        const Duration(seconds: 6),
        onTimeout: () => [],
      );
      if (mounted) {
        if (page == 1 && _activeFilters.isEmpty && list.isNotEmpty) {
          _categoryCache[typeId] = list;
        }
        setState(() {
          _vodList = list;
          _page = page;
          _isLoading = false;
        });
        if (page == 1 && _scrollController.hasClients) {
          _scrollController.jumpTo(0.0);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int _getCurrentTabIndex() {
    if (_hasHomeVod) {
      if (_selectedCategory == null) return 0;
      final idx = _categories.indexWhere((c) => c.typeId == _selectedCategory?.typeId);
      return idx >= 0 ? idx + 1 : 0;
    } else {
      if (_selectedCategory == null) return 0;
      final idx = _categories.indexWhere((c) => c.typeId == _selectedCategory?.typeId);
      return idx >= 0 ? idx : 0;
    }
  }

  int _getTotalTabCount() {
    return _hasHomeVod ? _categories.length + 1 : _categories.length;
  }

  CategoryItem? _getCategoryAtIndex(int index) {
    if (_hasHomeVod) {
      if (index == 0) return null;
      final catIdx = index - 1;
      if (catIdx >= 0 && catIdx < _categories.length) return _categories[catIdx];
      return null;
    } else {
      if (index >= 0 && index < _categories.length) return _categories[index];
      return null;
    }
  }

  void _switchToTabIndex(int targetIndex) {
    final total = _getTotalTabCount();
    if (targetIndex < 0 || targetIndex >= total) return;
    final targetCat = _getCategoryAtIndex(targetIndex);
    _onSelectCategory(targetCat);
  }

  void _scrollToTab(int index) {
    if (!_tabScrollController.hasClients) return;
    final maxScroll = _tabScrollController.position.maxScrollExtent;
    final target = (index * 75.0 - 100.0).clamp(0.0, maxScroll);
    _tabScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _onSelectCategory(CategoryItem? cat) {
    if (_selectedCategory == cat) return;
    setState(() {
      _selectedCategory = cat;
      _activeFilters.clear();
      _showFilterPanel = false;
    });

    final targetIndex = _getCurrentTabIndex();
    _scrollToTab(targetIndex);

    // 优先从内存缓存中秒开展示
    final cacheKey = cat?.typeId ?? '__home__';
    if (_categoryCache.containsKey(cacheKey) && _categoryCache[cacheKey]!.isNotEmpty) {
      setState(() {
        _vodList = _categoryCache[cacheKey]!;
        _isLoading = false;
      });
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
      return;
    }

    setState(() => _isLoading = true);
    if (cat == null) {
      widget.repository.fetchHomeVods().then((list) {
        if (list.isNotEmpty) _categoryCache['__home__'] = list;
        if (mounted && _selectedCategory == null) {
          setState(() {
            _vodList = list;
            _isLoading = false;
          });
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(0.0);
          }
        }
      }).catchError((_) {
        if (mounted && _selectedCategory == null) setState(() => _isLoading = false);
      });
    } else {
      _loadCategoryVods(cat.typeId, 1);
    }
  }

  void _onOpenFolder(VodItem folder) async {
    setState(() => _isLoading = true);
    _folderHistory.add(folder);
    try {
      final list = await widget.repository.fetchSubFolderList(folder.vodId).timeout(
        const Duration(seconds: 6),
        onTimeout: () => [],
      );
      if (mounted) {
        setState(() {
          _vodList = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _popFolder() async {
    if (_folderHistory.isEmpty) return;
    _folderHistory.removeLast();
    setState(() => _isLoading = true);

    try {
      if (_folderHistory.isNotEmpty) {
        final parent = _folderHistory.last;
        final list = await widget.repository.fetchSubFolderList(parent.vodId).timeout(
          const Duration(seconds: 6),
          onTimeout: () => [],
        );
        if (mounted) setState(() => _vodList = list);
      } else {
        if (_selectedCategory == null) {
          final list = await widget.repository.fetchHomeVods();
          if (mounted) setState(() => _vodList = list);
        } else {
          final list = await widget.repository.fetchCategoryList(_selectedCategory!.typeId, _page, _activeFilters);
          if (mounted) setState(() => _vodList = list);
        }
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSitePickerSheet() {
    final sites = widget.repository.sites;
    final active = widget.repository.activeSite;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz, color: Color(0xFFE5A00D)),
                  const SizedBox(width: 8),
                  Text('切换点播源 (共 ${sites.length} 个)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: ListView.separated(
                itemCount: sites.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                itemBuilder: (context, index) {
                  final s = sites[index];
                  final isCurrent = s.key == active?.key;
                  return InkWell(
                    onTap: () async {
                      Navigator.pop(context);
                      if (isCurrent) return;

                      setState(() => _isChangingSite = true);
                      await widget.repository.setActiveSite(s);
                      setState(() => _isChangingSite = false);
                      _loadSiteAndData();
                    },
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isCurrent ? const Color(0xFFE5A00D) : const Color(0xFF262832),
                        foregroundColor: isCurrent ? Colors.black : Colors.white70,
                        child: Text(s.name.characters.take(1).toString()),
                      ),
                      title: Text(
                        s.name,
                        style: TextStyle(
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent ? const Color(0xFFE5A00D) : Colors.white,
                        ),
                      ),
                      subtitle: Text(s.api, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                      trailing: isCurrent ? const Icon(Icons.check, color: Color(0xFFE5A00D)) : null,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// 分类与榜单筛选弹窗 (严格贴合参考图 8 规范)
  void _showCategoryDrawer() {
    String selectedTimeRank = '日榜';
    String selectedTypeRank = '全部';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFECEFF1),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：榜单周期 (参考图 8: 日榜、周榜、月榜、总榜)
                  Row(
                    children: ['日榜', '周榜', '月榜', '总榜'].map((item) {
                      final isSel = selectedTimeRank == item;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: InkWell(
                            onTap: () => setSheetState(() => selectedTimeRank = item),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isSel ? const Color(0xFF263238) : Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.black12),
                              ),
                              child: Text(
                                item,
                                style: TextStyle(
                                  color: isSel ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),

                  // 第二行：分类类型 (参考图 8: 全部、电影、剧集、短剧、动漫、综艺)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: ['全部', '电影', '剧集', '短剧', '动漫', '综艺'].map((item) {
                        final isSel = selectedTypeRank == item;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            onTap: () => setSheetState(() => selectedTypeRank = item),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: isSel ? const Color(0xFF263238) : Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.black12),
                              ),
                              child: Text(
                                item,
                                style: TextStyle(
                                  color: isSel ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                  if (_categories.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Divider(color: Colors.black12),
                    const SizedBox(height: 8),
                    const Text('全部分类',
                        style: TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_hasHomeVod)
                          ChoiceChip(
                            label: const Text('推荐'),
                            selected: _selectedCategory == null,
                            selectedColor: _themeService.accentColor,
                            onSelected: (_) {
                              Navigator.pop(ctx);
                              _onSelectCategory(null);
                            },
                          ),
                        ..._categories.map((c) {
                          final isSel = _selectedCategory?.typeId == c.typeId;
                          return ChoiceChip(
                            label: Text(c.typeName),
                            selected: isSel,
                            selectedColor: _themeService.accentColor,
                            onSelected: (_) {
                              Navigator.pop(ctx);
                              _onSelectCategory(c);
                            },
                          );
                        }),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showPushDialog() async {
    final controller = TextEditingController();
    bool hasAutoPasted = false;

    // 打开弹窗时自动读取剪贴板信息并填入
    try {
      final clipData = await Clipboard.getData(Clipboard.kTextPlain);
      final clipText = clipData?.text?.trim() ?? '';
      if (clipText.isNotEmpty) {
        controller.text = clipText;
        controller.selection = TextSelection(baseOffset: 0, extentOffset: clipText.length);
        hasAutoPasted = true;
      }
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.link, color: Color(0xFFE5A00D), size: 22),
            SizedBox(width: 8),
            Text('推送影视链接解析', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                hintText: '输入磁力链接 / HTTP 视频流 / 网盘链接',
                hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF262832),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste, color: Color(0xFFE5A00D), size: 20),
                  tooltip: '从剪贴板粘贴',
                  onPressed: () async {
                    final clipData = await Clipboard.getData(Clipboard.kTextPlain);
                    final clipText = clipData?.text?.trim() ?? '';
                    if (clipText.isNotEmpty) {
                      controller.text = clipText;
                      controller.selection = TextSelection(baseOffset: 0, extentOffset: clipText.length);
                    }
                  },
                ),
              ),
            ),
            if (hasAutoPasted) ...[
              const SizedBox(height: 6),
              const Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 14, color: Color(0xFFE5A00D)),
                  SizedBox(width: 4),
                  Text(
                    '已自动检测并填入剪贴板内容',
                    style: TextStyle(color: Color(0xFFE5A00D), fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE5A00D),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              final link = controller.text.trim();
              if (link.isNotEmpty) {
                Navigator.pop(dialogCtx);
                final pushVod = await widget.repository.pushLink(link);
                if (mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DetailView(
                        repository: widget.repository,
                        vodItem: pushVod,
                        vodId: pushVod?.vodId ?? link,
                      ),
                    ),
                  );
                }
              }
            },
            child: const Text('推送解析', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeSite = widget.repository.activeSite;
    final currentFilters = _selectedCategory != null ? _filterMap[_selectedCategory!.typeId] : null;

    final screenWidth = MediaQuery.of(context).size.width;
    final int crossAxisCount = screenWidth >= 1300
        ? 6
        : screenWidth >= 950
            ? 5
            : screenWidth >= 650
                ? 4
                : 3;

    return Scaffold(
      backgroundColor: const Color(0xFF1B483F),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _themeService.currentGradient.colors,
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 顶栏 (参考图 1: 左侧切换源, 右侧搜索、收藏、历史)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    // 站源切换左侧 Logo (长按清除缓存并重新载入配置)
                    GestureDetector(
                      onLongPress: _clearCacheAndReloadConfig,
                      child: Tooltip(
                        message: '长按清除缓存并重载配置',
                        child: InkWell(
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('💡 提示：长按此 Logo 图标可清除缓存并重新载入配置'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.all(7),
                            decoration: const BoxDecoration(
                              color: Color(0x33FFFFFF),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.live_tv, color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                    ),

                    // 站源切换胶囊 (点击切换站源，长按同样触发清除缓存并重载配置)
                    InkWell(
                      onTap: _showSitePickerSheet,
                      onLongPress: _clearCacheAndReloadConfig,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0x33FFFFFF),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.view_in_ar, color: Colors.white, size: 20),
                            const SizedBox(width: 6),
                            Text(
                              activeSite?.name ?? '看剧ai js',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                            ),
                            const Icon(Icons.arrow_drop_down, color: Colors.white70),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.search, color: Colors.white, size: 24),
                      tooltip: '全网搜索',
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => SearchView(repository: widget.repository)),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.star_border, color: Colors.white, size: 24),
                      tooltip: '我的收藏',
                      onPressed: _showFavoritesSheet,
                    ),
                    IconButton(
                      icon: const Icon(Icons.history, color: Colors.white, size: 24),
                      tooltip: '播放历史',
                      onPressed: _showHistorySheet,
                    ),
                  ],
                ),
              ),

              // 分类胶囊行
              _buildCategoryTabBar(),

              if (_folderHistory.isNotEmpty) _buildFolderBreadcrumb(),
              if (_showFilterPanel && currentFilters != null && currentFilters.isNotEmpty)
                _buildFilterPanel(currentFilters),

              Expanded(
                child: _isChangingSite
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Color(0xFFE5A00D)),
                            SizedBox(height: 12),
                            Text('正在加载并编译 JS 源...', style: TextStyle(color: Colors.white70)),
                          ],
                        ),
                      )
                    : GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (details) {
                          _horizontalDragOffset = 0;
                        },
                        onHorizontalDragUpdate: (details) {
                          _horizontalDragOffset += details.primaryDelta ?? 0;
                        },
                        onHorizontalDragEnd: (details) {
                          if (_folderHistory.isNotEmpty) return;
                          final velocity = details.primaryVelocity ?? 0;
                          final curIdx = _getCurrentTabIndex();
                          final total = _getTotalTabCount();

                          // 手指向左滑 (查看右侧下一个分类)
                          if (velocity < -250 || _horizontalDragOffset < -50) {
                            if (curIdx < total - 1) {
                              setState(() => _isSwipeNext = true);
                              _switchToTabIndex(curIdx + 1);
                            }
                          }
                          // 手指向右滑 (查看左侧上一个分类)
                          else if (velocity > 250 || _horizontalDragOffset > 50) {
                            if (curIdx > 0) {
                              setState(() => _isSwipeNext = false);
                              _switchToTabIndex(curIdx - 1);
                            }
                          }
                        },
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, animation) {
                            final beginOffset = _isSwipeNext
                                ? const Offset(0.18, 0.0)
                                : const Offset(-0.18, 0.0);
                            return SlideTransition(
                              position: Tween<Offset>(
                                begin: beginOffset,
                                end: Offset.zero,
                              ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
                              child: child,
                            );
                          },
                          child: KeyedSubtree(
                            key: ValueKey<String>('${_selectedCategory?.typeId ?? "__home__"}'),
                            child: _isLoading
                                ? const Center(child: CircularProgressIndicator(color: Color(0xFFE5A00D)))
                                : _vodList.isEmpty
                                    ? _buildEmptyState()
                                    : RefreshIndicator(
                                        color: const Color(0xFFE5A00D),
                                        backgroundColor: const Color(0xFF1E2028),
                                        onRefresh: () => _selectedCategory == null
                                            ? _loadSiteAndData()
                                            : _loadCategoryVods(_selectedCategory!.typeId, 1),
                                        child: GridView.builder(
                                          controller: _scrollController,
                                          cacheExtent: 500,
                                          padding: const EdgeInsets.all(12.0),
                                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: crossAxisCount,
                                            childAspectRatio: 0.62,
                                            crossAxisSpacing: 10,
                                            mainAxisSpacing: 10,
                                          ),
                                          itemCount: _vodList.length,
                                          itemBuilder: (context, index) {
                                            final vod = _vodList[index];
                                            return _buildVodCard(vod);
                                          },
                                        ),
                                      ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showScrollTopBtn)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: FloatingActionButton.small(
                heroTag: 'scrollTopBtn',
                backgroundColor: const Color(0xFF262832),
                onPressed: _scrollToTop,
                tooltip: '返回顶部',
                child: const Icon(Icons.keyboard_arrow_up, color: Colors.white),
              ),
            ),
          FloatingActionButton(
            heroTag: 'pushBtn',
            backgroundColor: _themeService.accentColor,
            onPressed: _showPushDialog,
            tooltip: '推送链接',
            child: const Icon(Icons.link, color: Colors.white, size: 26),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTabBar() {
    final hasHome = _hasHomeVod;
    final totalCount = hasHome ? _categories.length + 1 : _categories.length;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _tabScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: totalCount,
              padding: const EdgeInsets.symmetric(horizontal: 6.0),
              itemBuilder: (context, index) {
                bool isSelected = false;
                String title = '';
                VoidCallback onTap = () {};

                if (hasHome) {
                  if (index == 0) {
                    isSelected = _selectedCategory == null;
                    title = '推荐';
                    onTap = () => _onSelectCategory(null);
                  } else {
                    final cat = _categories[index - 1];
                    isSelected = _selectedCategory?.typeId == cat.typeId;
                    title = cat.typeName;
                    onTap = () => _onSelectCategory(cat);
                  }
                } else {
                  final cat = _categories[index];
                  isSelected = _selectedCategory?.typeId == cat.typeId;
                  title = cat.typeName;
                  onTap = () => _onSelectCategory(cat);
                }

                return TvFocusable(
                  onPressed: onTap,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF2E6359) : const Color(0x33FFFFFF),
                      borderRadius: BorderRadius.circular(20),
                      border: isSelected ? Border.all(color: const Color(0xFF66C8B5), width: 1.2) : null,
                    ),
                    child: Text(
                      title,
                      style: TextStyle(
                        color: isSelected ? const Color(0xFFFFD54F) : Colors.white,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            tooltip: '全部分类',
            onPressed: _showCategoryDrawer,
          ),
        ],
      ),
    );
  }

  Widget _buildFolderBreadcrumb() {
    return Container(
      color: const Color(0xFF1E2028),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20, color: Color(0xFFE5A00D)),
            onPressed: _popFolder,
            tooltip: '返回上级目录',
          ),
          Expanded(
            child: Text(
              '当前目录: ${_folderHistory.map((e) => e.vodName).join(' / ')}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFE5A00D)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel(List<CategoryFilterGroup> currentFilters) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF181A22),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: currentFilters.map((group) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  '${group.name}:',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(width: 6),
                ...group.options.map((opt) {
                  final isSelected = (_activeFilters[group.key] ?? '') == opt.value;
                  return Padding(
                    padding: const EdgeInsets.only(right: 4.0),
                    child: FilterChip(
                      visualDensity: VisualDensity.compact,
                      selected: isSelected,
                      selectedColor: const Color(0xFFE5A00D),
                      backgroundColor: const Color(0xFF262832),
                      label: Text(
                        opt.name,
                        style: TextStyle(
                          fontSize: 11,
                          color: isSelected ? Colors.black : Colors.white70,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _activeFilters[group.key] = opt.value;
                          } else {
                            _activeFilters.remove(group.key);
                          }
                        });
                        if (_selectedCategory != null) {
                          _loadCategoryVods(_selectedCategory!.typeId, 1);
                        }
                      },
                    ),
                  );
                }),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox, size: 48, color: Colors.white54),
          const SizedBox(height: 12),
          const Text('当前源暂未返回影视数据', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE5A00D)),
            onPressed: _showSitePickerSheet,
            icon: const Icon(Icons.swap_horiz, color: Colors.black),
            label: const Text('切换其他点播源', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// OK影视风格卡片 (参考图 1: 左上角年份 Badge, 底部剧集/清晰度 Badge, 下方居中标题)
  Widget _buildVodCard(VodItem vod) {
    final year = vod.vodYear.isNotEmpty
        ? vod.vodYear
        : RegExp(r'20\d{2}').firstMatch(vod.vodRemarks)?.group(0) ?? '2026';
    final remarks = vod.vodRemarks.isNotEmpty ? vod.vodRemarks : '高清';

    return TvFocusable(
      onPressed: () {
        if (vod.isFolder) {
          _onOpenFolder(vod);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => DetailView(
                repository: widget.repository,
                vodId: vod.vodId,
                vodItem: vod,
              ),
            ),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2E6359),
          borderRadius: BorderRadius.circular(12),
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
                            child: Icon(vod.isFolder ? Icons.folder : Icons.movie, size: 40, color: Colors.white54),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF264841),
                          child: Icon(vod.isFolder ? Icons.folder : Icons.movie, size: 40, color: Colors.white54),
                        ),

                  // 左上角年份 Badge (参考图 1)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E88E5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        year,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),

                  // 底部剧集/清晰度 Remarks Badge (参考图 1)
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

            // 卡片下部标题容器 (参考图 1)
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
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFavoritesSheet() {
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
                BoxShadow(color: Colors.black45, blurRadius: 20, offset: Offset(0, -4)),
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
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white54),
                          label: const Text('清空', style: TextStyle(color: Colors.white54, fontSize: 13)),
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                backgroundColor: const Color(0xFF262832),
                                title: const Text('清空收藏', style: TextStyle(color: Colors.white)),
                                content: const Text('确定要清空所有收藏影视吗？', style: TextStyle(color: Colors.white70)),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                    onPressed: () async {
                                      await HistoryFavoriteService().clearFavorites();
                                      Navigator.pop(dCtx);
                                      setSheetState(() {});
                                    },
                                    child: const Text('确定清空', style: TextStyle(color: Colors.white)),
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
                    valueListenable: HistoryFavoriteService().favoritesNotifier,
                    builder: (context, favList, _) {
                      if (favList.isEmpty) {
                        return const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.star_outline, size: 64, color: Colors.white24),
                              SizedBox(height: 12),
                              Text('暂无收藏影视', style: TextStyle(color: Colors.white54, fontSize: 15)),
                              SizedBox(height: 6),
                              Text('在影视详情页点击右上角星标即可收藏', style: TextStyle(color: Colors.white30, fontSize: 12)),
                            ],
                          ),
                        );
                      }

                      final crossCount = screenWidth > 900 ? 6 : (screenWidth > 600 ? 4 : 3);

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
                                        repository: widget.repository,
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
                                                  errorBuilder: (_, __, ___) => const Icon(
                                                    Icons.movie_creation_outlined,
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
                                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                                      ),
                                  ],
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: InkWell(
                                  onTap: () async {
                                    await HistoryFavoriteService().toggleFavorite(vod);
                                    setSheetState(() {});
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close, size: 14, color: Colors.white70),
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

  void _showHistorySheet() {
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
                BoxShadow(color: Colors.black45, blurRadius: 20, offset: Offset(0, -4)),
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
                        Icon(Icons.history, color: _themeService.accentColor, size: 24),
                        const SizedBox(width: 8),
                        const Text(
                          '播放历史',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white54),
                          label: const Text('清空历史', style: TextStyle(color: Colors.white54, fontSize: 13)),
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                backgroundColor: const Color(0xFF262832),
                                title: const Text('清空播放历史', style: TextStyle(color: Colors.white)),
                                content: const Text('确定要清空所有播放记录吗？', style: TextStyle(color: Colors.white70)),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                    onPressed: () async {
                                      await HistoryFavoriteService().clearHistory();
                                      Navigator.pop(dCtx);
                                      setSheetState(() {});
                                    },
                                    child: const Text('确定清空', style: TextStyle(color: Colors.white)),
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
                              Icon(Icons.history_toggle_off, size: 64, color: Colors.white24),
                              SizedBox(height: 12),
                              Text('暂无播放历史', style: TextStyle(color: Colors.white54, fontSize: 15)),
                              SizedBox(height: 6),
                              Text('在影视播放时会自动为您保存进度', style: TextStyle(color: Colors.white30, fontSize: 12)),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        itemCount: histList.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 16),
                        itemBuilder: (context, idx) {
                          final item = histList[idx];
                          final vodId = item['vodId']?.toString() ?? '';
                          final vodName = item['vodName']?.toString() ?? '未知影片';
                          final vodPic = item['vodPic']?.toString() ?? '';
                          final epName = item['episodeName']?.toString() ?? '';
                          final pos = (item['positionSec'] as num?)?.toInt() ?? 0;
                          final dur = (item['durationSec'] as num?)?.toInt() ?? 0;
                          final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;

                          String posText = _formatSeconds(pos);
                          String durText = dur > 0 ? _formatSeconds(dur) : '';
                          String progressDesc = durText.isNotEmpty ? '观看到 $posText / $durText' : '观看到 $posText';
                          if (epName.isNotEmpty) {
                            progressDesc = '$epName · $progressDesc';
                          }

                          final vod = VodItem(
                            vodId: vodId,
                            vodName: vodName,
                            vodPic: vodPic,
                            vodRemarks: item['vodRemarks']?.toString() ?? '',
                            siteName: item['siteName']?.toString(),
                          );

                          return InkWell(
                            onTap: () {
                              Navigator.pop(ctx);
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
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
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
                                              errorBuilder: (_, __, ___) => const Icon(
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
                                      crossAxisAlignment: CrossAxisAlignment.start,
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
                                            color: _themeService.accentColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(3),
                                          child: LinearProgressIndicator(
                                            value: progress,
                                            minHeight: 4,
                                            backgroundColor: Colors.white12,
                                            valueColor: AlwaysStoppedAnimation<Color>(_themeService.accentColor),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: _themeService.accentColor.withOpacity(0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(Icons.play_arrow, color: _themeService.accentColor, size: 20),
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
  Future<void> _clearCacheAndReloadConfig() async {
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('正在清除站源缓存并重新载入配置...'),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );

    setState(() => _isChangingSite = true);
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await widget.repository.reloadCurrentConfig();
    } catch (e) {
      debugPrint('重载配置提示: $e');
    }

    if (mounted) {
      setState(() => _isChangingSite = false);
      _loadSiteAndData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 缓存已清空，配置已重新载入完成'),
          backgroundColor: Color(0xFF2E7D32),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

}
