import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../../global/storage_bridge.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/history_favorite_service.dart';
import '../../services/theme_service.dart';
import '../detail/detail_view.dart';
import '../detail/widgets/episode_item_content.dart';
import '../search/search_view.dart';
import '../widgets/tv_focusable.dart';
import 'widgets/download_manager_page.dart';
import 'widgets/vod_card.dart';
import 'widgets/vod_push_dialog.dart';
import 'widgets/vod_records_sheets.dart';

/// OK影视风格 统一点播主页
class VodView extends StatefulWidget {
  final SiteRepository repository;

  const VodView({super.key, required this.repository});

  static bool Function()? _activePopFolder;
  static bool tryPopNestedFolder() => _activePopFolder?.call() ?? false;

  @override
  State<VodView> createState() => _VodViewState();
}

class _VodViewState extends State<VodView> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _categoryMenuBtnKey = GlobalKey();
  final GlobalKey<NavigatorState> _folderNavKey = GlobalKey<NavigatorState>();
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
  bool _isLoadingMore = false;
  bool _hasMore = true;
  DateTime _lastLoadMoreEnd = DateTime.fromMillisecondsSinceEpoch(0);
  bool _showScrollTopBtn = false;

  final FocusNode _keyboardFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    HistoryFavoriteService().init();
    VodView._activePopFolder = _tryPopFolder;
    _scrollController.addListener(_onScroll);
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
    widget.repository.configVersionNotifier.addListener(_onConfigChanged);
    _loadSiteAndData();
  }

  @override
  void dispose() {
    widget.repository.configVersionNotifier.removeListener(_onConfigChanged);
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    if (VodView._activePopFolder == _tryPopFolder) {
      VodView._activePopFolder = null;
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _tabScrollController.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _onConfigChanged() {
    if (mounted) {
      _loadSiteAndData();
    }
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final showBtn = _scrollController.offset > 300;
      if (showBtn != _showScrollTopBtn) {
        setState(() => _showScrollTopBtn = showBtn);
      }

      final pos = _scrollController.position;
      if (_selectedCategory != null &&
          !_isLoading &&
          !_isLoadingMore &&
          _hasMore &&
          _folderHistory.isEmpty &&
          pos.maxScrollExtent > 0 &&
          pos.pixels >= pos.maxScrollExtent - 8 &&
          DateTime.now().difference(_lastLoadMoreEnd).inMilliseconds > 500) {
        _loadNextPage();
      }
    }
  }

  Future<void> _loadNextPage() async {
    if (_selectedCategory == null || _isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    final nextPage = _page + 1;
    try {
      final more = await widget.repository
          .fetchCategoryList(_selectedCategory!.typeId, nextPage, _activeFilters)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => [],
          );
      if (!mounted) return;
      if (more.isEmpty) {
        _lastLoadMoreEnd = DateTime.now();
        setState(() {
          _hasMore = false;
          _isLoadingMore = false;
        });
      } else {
        final existingIds = _vodList.map((v) => v.vodId).toSet();
        final uniqueNew = more.where((v) => !existingIds.contains(v.vodId)).toList();
        _lastLoadMoreEnd = DateTime.now();
        setState(() {
          _page = nextPage;
          if (uniqueNew.isEmpty) {
            _hasMore = false;
          } else {
            _vodList.addAll(uniqueNew);
          }
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
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

  /// 初始化并加载站点数据 (💡 切换/重载时立即重置上次的 VOD 数据与目录历史)
  Future<void> _loadSiteAndData() async {
    _folderNavKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _isLoading = true;
      _vodList = []; // 重置上一次的 vod 数据，杜绝残影
      _categories = [];
      _folderHistory.clear();
      _categoryCache.clear();
      _activeFilters.clear();
      _page = 1;
      _isLoadingMore = false;
      _hasMore = true;
    });

    try {
      if (widget.repository.activeSite == null &&
          widget.repository.sites.isNotEmpty) {
        String? lastKey;
        try {
          lastKey = await StorageBridge.getValue('last_active_site_key');
        } catch (_) {}

        final sites = widget.repository.sites;
        final target = (lastKey != null && lastKey.isNotEmpty)
            ? sites.firstWhere(
                (s) => s.key == lastKey,
                orElse: () => sites.firstWhere((s) => s.key != 'push_agent',
                    orElse: () => sites.first),
              )
            : sites.firstWhere((s) => s.key != 'push_agent',
                orElse: () => sites.first);

        await widget.repository.setActiveSite(target).timeout(
              const Duration(seconds: 5),
              onTimeout: () => debugPrint('⚠️ 设置默认站点超时，继续执行'),
            );
      }

      if (widget.repository.activeSite != null) {
        final catData = await widget.repository.fetchCategories().timeout(
              const Duration(seconds: 6),
              onTimeout: () => {'categories': <CategoryItem>[], 'filters': {}},
            );
        final List<CategoryItem> cats = (catData['categories'] is List)
            ? (catData['categories'] as List)
                .whereType<CategoryItem>()
                .toList()
            : <CategoryItem>[];

        final Map<String, List<CategoryFilterGroup>> filters = {};
        final rawFilters = catData['filters'];
        if (rawFilters is Map) {
          rawFilters.forEach((k, v) {
            if (v is List) {
              filters[k.toString()] =
                  v.whereType<CategoryFilterGroup>().toList();
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
          initialVods = await widget.repository
              .fetchCategoryList(cats.first.typeId, 1)
              .timeout(
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
            if (initialVods.isNotEmpty) {
              _categoryCache['__home__'] = initialVods;
            }
            _isLoading = false;
            _selectedCategory =
                homeAvailable ? null : (cats.isNotEmpty ? cats.first : null);
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
    setState(() {
      _isLoading = true;
      _isLoadingMore = false;
      _hasMore = true;
      _folderHistory.clear();
    });
    try {
      final list = await widget.repository
          .fetchCategoryList(typeId, page, _activeFilters)
          .timeout(
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
      final idx =
          _categories.indexWhere((c) => c.typeId == _selectedCategory?.typeId);
      return idx >= 0 ? idx + 1 : 0;
    } else {
      if (_selectedCategory == null) return 0;
      final idx =
          _categories.indexWhere((c) => c.typeId == _selectedCategory?.typeId);
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
      if (catIdx >= 0 && catIdx < _categories.length)
        return _categories[catIdx];
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
    _folderNavKey.currentState?.popUntil((r) => r.isFirst);
    if (_selectedCategory == cat) return;
    setState(() {
      _selectedCategory = cat;
      _activeFilters.clear();
      _showFilterPanel = false;
      _folderHistory.clear();
    });

    final targetIndex = _getCurrentTabIndex();
    _scrollToTab(targetIndex);

    final cacheKey = cat?.typeId ?? '__home__';
    if (_categoryCache.containsKey(cacheKey) &&
        _categoryCache[cacheKey]!.isNotEmpty) {
      setState(() {
        _vodList = _categoryCache[cacheKey]!;
        _isLoading = false;
      });
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
      return;
    }

    setState(() {
      _isLoading = true;
    });
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
        if (mounted && _selectedCategory == null)
          setState(() => _isLoading = false);
      });
    } else {
      _loadCategoryVods(cat.typeId, 1);
    }
  }

  bool _tryPopFolder() {
    final nav = _folderNavKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return true;
    }
    return false;
  }

  void _onOpenFolder(VodItem folder) {
    _folderNavKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => _VodSubFolderGrid(
          repository: widget.repository,
          folder: folder,
          onOpenSubFolder: _onOpenFolder,
          onOpenDetail: (vod) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => DetailView(
                  repository: widget.repository,
                  vodId: vod.vodId,
                  vodItem: vod,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _popFolder() async {
    if (_folderHistory.isEmpty) return;
    _folderHistory.removeLast();
    setState(() {
      _isLoading = true;
      _vodList = []; // 回退前先清空
    });

    try {
      if (_folderHistory.isNotEmpty) {
        final parent = _folderHistory.last;
        final list = await widget.repository
            .fetchSubFolderList(parent.vodId)
            .timeout(
              const Duration(seconds: 6),
              onTimeout: () => [],
            );
        if (mounted) setState(() => _vodList = list);
      } else {
        if (_selectedCategory == null) {
          final list = await widget.repository.fetchHomeVods();
          if (mounted) setState(() => _vodList = list);
        } else {
          final list = await widget.repository.fetchCategoryList(
              _selectedCategory!.typeId, _page, _activeFilters);
          if (mounted) setState(() => _vodList = list);
        }
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSitePickerSheet() {
    final allSites = widget.repository.sites;
    final active = widget.repository.activeSite;
    final searchCtrl = TextEditingController();
    String query = '';

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final filtered = query.trim().isEmpty
                ? allSites
                : allSites
                    .where((s) =>
                        s.name.toLowerCase().contains(query.trim().toLowerCase()))
                    .toList();

            return Dialog(
              backgroundColor: const Color(0xFFF3EFF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 420,
                  maxHeight: MediaQuery.of(ctx).size.height * 0.72,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 12, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: searchCtrl,
                              style: const TextStyle(
                                  color: Colors.black87, fontSize: 14.5),
                              textAlign: TextAlign.center,
                              onChanged: (val) =>
                                  setDialogState(() => query = val),
                              onSubmitted: (val) =>
                                  setDialogState(() => query = val),
                              decoration: InputDecoration(
                                hintText: '关键字...',
                                hintStyle: const TextStyle(
                                    color: Colors.black45, fontSize: 14.5),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 11),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: const BorderSide(
                                      color: Colors.black54, width: 1.0),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: const BorderSide(
                                      color: Color(0xFF1976D2), width: 1.4),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.search,
                                color: Colors.black87, size: 24),
                            tooltip: '搜索站点',
                            onPressed: () {
                              setDialogState(() => query = searchCtrl.text);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(
                                child: Text(
                                  '未找到匹配站点',
                                  style: TextStyle(
                                      color: Colors.black54, fontSize: 13.5),
                                ),
                              )
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final s = filtered[index];
                                  final isCurrent = s.key == active?.key;
                                  final isLockedDisabled =
                                      s.configChangeable == 0;
                                  final isChangeable = !isLockedDisabled &&
                                      (s.changeable == null ||
                                          s.changeable != 0);

                                  return Row(
                                    children: [
                                      Expanded(
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(24),
                                          onTap: () async {
                                            Navigator.pop(dialogCtx);
                                            if (isCurrent) return;
                                            setState(() {
                                              _isChangingSite = true;
                                              _vodList = [];
                                              _categories = [];
                                              _folderHistory.clear();
                                              _categoryCache.clear();
                                            });
                                            await widget.repository
                                                .setActiveSite(s);
                                            setState(
                                                () => _isChangingSite = false);
                                            _loadSiteAndData();
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 14, vertical: 11),
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(24),
                                              border: Border.all(
                                                color: isCurrent
                                                    ? const Color(0xFF1976D2)
                                                    : Colors.black54,
                                                width: isCurrent ? 1.4 : 1.0,
                                              ),
                                            ),
                                            child: Text(
                                              s.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 14.5,
                                                fontWeight: isCurrent
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                                color: isCurrent
                                                    ? const Color(0xFF1976D2)
                                                    : Colors.black87,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        icon: Icon(
                                          isChangeable
                                              ? Icons.sync
                                              : Icons.block,
                                          color: isLockedDisabled
                                              ? Colors.black26
                                              : (isChangeable
                                                  ? const Color(0xFF1976D2)
                                                  : Colors.black87),
                                          size: 23,
                                        ),
                                        tooltip: isLockedDisabled
                                            ? '配置已禁用换源 (不可启用)'
                                            : (isChangeable
                                                ? '支持自动换源 (点击禁用)'
                                                : '已禁用自动换源 (点击启用)'),
                                        onPressed: isLockedDisabled
                                            ? null
                                            : () async {
                                                await widget.repository
                                                    .setSiteChangeable(
                                                        s, !isChangeable);
                                                setDialogState(() {});
                                              },
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showCategoryDrawer() {
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 600;
    double topOffset = media.padding.top + 104;
    final renderObj = _categoryMenuBtnKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) {
      topOffset = renderObj.localToGlobal(Offset.zero).dy + renderObj.size.height + 6;
    }

    Widget buildCatChip(String label, bool isSel, VoidCallback onTap) {
      final accent = _themeService.accentColor;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: isSel ? accent.withOpacity(0.22) : Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSel ? accent : Colors.white.withOpacity(0.14),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSel ? accent : Colors.white,
              fontSize: 13,
              fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '全部分类',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, anim, secAnim) {
        return Stack(
          children: [
            Positioned(
              top: topOffset,
              right: 12,
              left: isWide ? null : 12,
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isWide ? 460 : media.size.width - 24,
                    maxHeight: media.size.height * 0.62,
                  ),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E222B).withOpacity(0.96),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.14)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.45),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                '全部分类',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              InkWell(
                                onTap: () => Navigator.pop(ctx),
                                borderRadius: BorderRadius.circular(14),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.close, color: Colors.white60, size: 18),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_categories.isEmpty && !_hasHomeVod)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                '当前站点暂无分类数据',
                                style: TextStyle(color: Colors.white54, fontSize: 13),
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (_hasHomeVod)
                                  buildCatChip('推荐', _selectedCategory == null, () {
                                    Navigator.pop(ctx);
                                    _onSelectCategory(null);
                                  }),
                                ..._categories.map((c) {
                                  final isSel = _selectedCategory?.typeId == c.typeId;
                                  return buildCatChip(c.typeName, isSel, () {
                                    Navigator.pop(ctx);
                                    _onSelectCategory(c);
                                  });
                                }),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (ctx, anim, secAnim, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        );
      },
    );
  }

  void _showPushDialog() => showVodPushDialog(context, widget.repository, () => mounted);

  KeyEventResult _handleVodKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // 💡 按 ESC 键、Backspace 键返回上一层目录
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_tryPopFolder()) {
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }


  @override
  Widget build(BuildContext context) {
    final activeSite = widget.repository.activeSite;
    final currentFilters = _selectedCategory != null
        ? _filterMap[_selectedCategory!.typeId]
        : null;

    final screenWidth = MediaQuery.of(context).size.width;
    final int crossAxisCount = screenWidth >= 1300
        ? 6
        : screenWidth >= 950
            ? 5
            : screenWidth >= 650
                ? 4
                : 3;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleVodKeyEvent,
      child: PopScope(
        // 当处于深层文件夹目录时拦截 App 退出，优先回退上一级文件夹
        canPop: _folderHistory.isEmpty,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _folderHistory.isNotEmpty) {
            _popFolder();
          }
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            color: Colors.transparent,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        InkWell(
                          onLongPress: _clearCacheAndReloadConfig,
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content:
                                    Text('💡 提示：长按此 Logo 图标可清除缓存并重新载入配置'),
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
                            child: const Icon(Icons.view_in_ar,
                                color: Colors.white, size: 20),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: InkWell(
                              onTap: _showSitePickerSheet,
                              onLongPress: _clearCacheAndReloadConfig,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0x33FFFFFF),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: FastMarqueeText(
                                  text: (activeSite != null &&
                                          activeSite.name.isNotEmpty)
                                      ? activeSite.name
                                      : '选择站源',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          padding: const EdgeInsets.all(5),
                          constraints: const BoxConstraints(
                              minWidth: 32, minHeight: 32),
                          icon: const Icon(Icons.search,
                              color: Colors.white, size: 22),
                          tooltip: '全网搜索',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      SearchView(repository: widget.repository)),
                            );
                          },
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(5),
                          constraints: const BoxConstraints(
                              minWidth: 32, minHeight: 32),
                          icon: const Icon(Icons.star_border,
                              color: Colors.white, size: 22),
                          tooltip: '我的收藏',
                          onPressed: _showFavoritesSheet,
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(5),
                          constraints: const BoxConstraints(
                              minWidth: 32, minHeight: 32),
                          icon: const Icon(Icons.download_outlined,
                              color: Colors.white, size: 22),
                          tooltip: '下载管理',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DownloadManagerPage(
                                  repository: widget.repository,
                                  themeService: _themeService,
                                ),
                              ),
                            );
                          },
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(5),
                          constraints: const BoxConstraints(
                              minWidth: 32, minHeight: 32),
                          icon: const Icon(Icons.history,
                              color: Colors.white, size: 22),
                          tooltip: '播放历史',
                          onPressed: _showHistorySheet,
                        ),
                      ],
                    ),
                  ),
                  _buildCategoryTabBar(),
                  if (_showFilterPanel &&
                      currentFilters != null &&
                      currentFilters.isNotEmpty)
                    _buildFilterPanel(currentFilters),
                  Expanded(
                    child: Navigator(
                      key: _folderNavKey,
                      onGenerateRoute: (_) => MaterialPageRoute(
                        builder: (navCtx) => Material(
                          color: Colors.transparent,
                          child: _isChangingSite
                        ? const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                    color: Color(0xFFE5A00D)),
                                SizedBox(height: 12),
                                Text('正在加载并编译 JS 源...',
                                    style: TextStyle(color: Colors.white70)),
                              ],
                            ),
                          )
                        : GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragStart: (details) {
                              _horizontalDragOffset = 0;
                            },
                            onHorizontalDragUpdate: (details) {
                              _horizontalDragOffset +=
                                  details.primaryDelta ?? 0;
                            },
                            onHorizontalDragEnd: (details) {
                              if (_folderHistory.isNotEmpty) return;
                              final velocity = details.primaryVelocity ?? 0;
                              final curIdx = _getCurrentTabIndex();
                              final total = _getTotalTabCount();

                              if (velocity < -250 ||
                                  _horizontalDragOffset < -50) {
                                if (curIdx < total - 1) {
                                  setState(() => _isSwipeNext = true);
                                  _switchToTabIndex(curIdx + 1);
                                }
                              } else if (velocity > 250 ||
                                  _horizontalDragOffset > 50) {
                                if (curIdx > 0) {
                                  setState(() => _isSwipeNext = false);
                                  _switchToTabIndex(curIdx - 1);
                                }
                              }
                            },
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 120),
                              layoutBuilder: (currentChild, previousChildren) =>
                                  currentChild ?? const SizedBox.shrink(),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(opacity: animation, child: child),
                              child: KeyedSubtree(
                                key: ValueKey<String>(
                                    '${_selectedCategory?.typeId ?? "__home__"}'),
                                child: _isLoading
                                    ? const Center(
                                        child: CircularProgressIndicator(
                                            color: Color(0xFFE5A00D)))
                                    : _vodList.isEmpty
                                        ? _buildEmptyState()
                                        : Column(
                                            children: [
                                              Expanded(
                                                child: RefreshIndicator(
                                            color: const Color(0xFFE5A00D),
                                            backgroundColor:
                                                const Color(0xFF1E2028),
                                            onRefresh: () =>
                                                _selectedCategory == null
                                                    ? _loadSiteAndData()
                                                    : _loadCategoryVods(
                                                        _selectedCategory!
                                                            .typeId,
                                                        1),
                                            child: Builder(
                                              builder: (_) {
                                                final effStyle = _effectiveStyle();
                                                final styleType = effStyle?['type']?.toString().toLowerCase();
                                                if (styleType == 'list') {
                                                  return ListView.separated(
                                                    controller: _scrollController,
                                                    padding: const EdgeInsets.all(12),
                                                    itemCount: _vodList.length,
                                                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                                                    itemBuilder: (context, index) {
                                                      final vod = _vodList[index];
                                                      return _buildVodListRow(
                                                        vod,
                                                        onTap: () {
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
                                                      );
                                                    },
                                                  );
                                                }
                                                final desktopRatio = _resolveCardAspectRatio(effStyle, 0.66);
                                                final mobileRatio = _resolveCardAspectRatio(effStyle, 0.62);
                                                return GridView.builder(
                                                  controller: _scrollController,
                                                  cacheExtent: 500,
                                                  padding: EdgeInsets.all(
                                                      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                                                          ? 16.0
                                                          : 12.0),
                                                  gridDelegate: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                                                      ? SliverGridDelegateWithMaxCrossAxisExtent(
                                                          maxCrossAxisExtent: desktopRatio >= 1.1 ? 260 : 205,
                                                          childAspectRatio: desktopRatio,
                                                          crossAxisSpacing: 14,
                                                          mainAxisSpacing: 14,
                                                        )
                                                      : SliverGridDelegateWithFixedCrossAxisCount(
                                                          crossAxisCount: mobileRatio >= 1.1 && crossAxisCount >= 3 ? 2 : crossAxisCount,
                                                          childAspectRatio: mobileRatio,
                                                          crossAxisSpacing: 10,
                                                          mainAxisSpacing: 10,
                                                        ),
                                                  itemCount: _vodList.length,
                                                  itemBuilder: (context, index) {
                                                    final vod = _vodList[index];
                                                    return _buildVodCard(vod);
                                                  },
                                                );
                                              },
                                            ),
                                          ),
                                              ),
                                              if (_isLoadingMore)
                                                const Padding(
                                                  padding: EdgeInsets.symmetric(vertical: 10),
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child: CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                      SizedBox(width: 8),
                                                      Text(
                                                        '正在加载下一页...',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                            ],
                                          ),
                              ),
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
          floatingActionButton: FloatingActionButton(
            heroTag: 'vodActionFab',
            backgroundColor: const Color(0xFF2196F3),
            foregroundColor: Colors.white,
            onPressed: _showScrollTopBtn ? _scrollToTop : _showPushDialog,
            tooltip: _showScrollTopBtn ? '返回顶部' : '推送链接',
            child: Icon(
              _showScrollTopBtn ? Icons.arrow_upward : Icons.link,
              size: 26,
            ),
          ),
        ),
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
                  borderRadius: BorderRadius.circular(20),
                  onPressed: onTap,
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 4.0, vertical: 4.0),
                    padding: const EdgeInsets.symmetric(horizontal: 14.0),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF2E6359)
                          : const Color(0x33FFFFFF),
                      borderRadius: BorderRadius.circular(20),
                      border: isSelected
                          ? Border.all(
                              color: const Color(0xFF66C8B5), width: 1.2)
                          : null,
                    ),
                    child: Text(
                      title,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFFFFD54F)
                            : Colors.white,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: _categoryMenuBtnKey,
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
            icon: const Icon(Icons.arrow_back,
                size: 20, color: Color(0xFFE5A00D)),
            onPressed: _popFolder,
            tooltip: '返回上级目录 (可按 ESC / Back 键)',
          ),
          Expanded(
            child: Text(
              '当前目录: ${_folderHistory.map((e) => e.vodName).join(' / ')}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Color(0xFFE5A00D)),
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
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Colors.grey),
                ),
                const SizedBox(width: 6),
                ...group.options.map((opt) {
                  final isSelected =
                      (_activeFilters[group.key] ?? '') == opt.value;
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
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
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
    if (widget.repository.sites.isEmpty) {
      return Center(
        child: IconButton(
          iconSize: 54,
          tooltip: '刷新 / 导入配置',
          icon: const Icon(Icons.refresh, color: Colors.white),
          onPressed: _loadSiteAndData,
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox, size: 48, color: Colors.white54),
          const SizedBox(height: 12),
          const Text('当前源暂未返回影视数据', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE5A00D)),
            onPressed: _showSitePickerSheet,
            icon: const Icon(Icons.swap_horiz, color: Colors.black),
            label: const Text('切换其他点播源',
                style: TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }


  Map<String, dynamic>? _effectiveStyle() {
    return widget.repository.lastResponseStyle ??
        widget.repository.activeSite?.style;
  }

  double _resolveCardAspectRatio(Map<String, dynamic>? style, double fallback) {
    final rawRatio = style?['ratio'];
    double? r;
    if (rawRatio is num) {
      r = rawRatio.toDouble();
    } else if (rawRatio != null) {
      r = double.tryParse(rawRatio.toString());
    }
    if (r == null || r <= 0) return fallback;
    return (r * 0.82).clamp(0.55, 2.2);
  }

  Widget _buildVodListRow(VodItem vod, {required VoidCallback onTap}) {
    return TvFocusable(
      scaleFactor: 1.0,
      borderRadius: BorderRadius.circular(12),
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: vod.isFolder
              ? const Color(0xFF234C43).withValues(alpha: 0.88)
              : const Color(0x33000000),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: vod.isFolder
                ? const Color(0xFFE5A00D).withValues(alpha: 0.35)
                : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            if (vod.vodPic.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  vod.vodPic,
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 52,
                    height: 52,
                    color: Colors.white10,
                    child: Icon(
                      vod.isFolder ? Icons.folder : Icons.movie_outlined,
                      color: vod.isFolder ? const Color(0xFFE5A00D) : Colors.white70,
                    ),
                  ),
                ),
              )
            else
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  vod.isFolder ? Icons.folder : Icons.play_circle_outline,
                  color: vod.isFolder ? const Color(0xFFE5A00D) : Colors.white70,
                  size: 24,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    vod.vodName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (vod.vodRemarks.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      vod.vodRemarks,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildVodCard(VodItem vod) {
    return VodCard(
      vod: vod,
      styleType: _effectiveStyle()?['type']?.toString().toLowerCase(),
      onTap: () {
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
    );
  }

  void _showFavoritesSheet() => showVodFavoritesSheet(context, widget.repository);

  void _showHistorySheet() => showVodHistorySheet(context, widget.repository, _themeService);

  Future<void> _clearCacheAndReloadConfig() async {
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('正在清除站源缓存并重新载入配置...'),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );

    setState(() {
      _isChangingSite = true;
      _vodList = [];
      _categories = [];
      _folderHistory.clear();
      _categoryCache.clear();
    });

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


/// 嵌套在 VodView 内容区的子文件夹路由视图（保持顶部栏与底部导航不变，支持 Back 手势逐层返回）
class _VodSubFolderGrid extends StatefulWidget {
  final SiteRepository repository;
  final VodItem folder;
  final void Function(VodItem folder) onOpenSubFolder;
  final void Function(VodItem vod) onOpenDetail;

  const _VodSubFolderGrid({
    required this.repository,
    required this.folder,
    required this.onOpenSubFolder,
    required this.onOpenDetail,
  });

  @override
  State<_VodSubFolderGrid> createState() => _VodSubFolderGridState();
}

class _VodSubFolderGridState extends State<_VodSubFolderGrid> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  List<VodItem> _items = [];
  Map<String, dynamic>? _responseStyle;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final list = await widget.repository
          .fetchSubFolderList(widget.folder.vodId)
          .timeout(const Duration(seconds: 8), onTimeout: () => []);
      if (mounted) {
        setState(() {
          _items = list;
          _responseStyle = widget.repository.lastResponseStyle;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final int crossAxisCount = screenWidth >= 1300
        ? 6
        : screenWidth >= 950
            ? 5
            : screenWidth >= 650
                ? 4
                : 3;

    return Material(
      color: Colors.transparent,
      child: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFE5A00D)),
            )
          : _items.isEmpty
              ? const Center(
                  child: Text(
                    '该文件夹暂无内容',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                )
              : RefreshIndicator(
                  color: const Color(0xFFE5A00D),
                  backgroundColor: const Color(0xFF1E2028),
                  onRefresh: _load,
                  child: Builder(
                    builder: (_) {
                      final effStyle =
                          _responseStyle ?? widget.repository.activeSite?.style;
                      final styleType =
                          effStyle?['type']?.toString().toLowerCase();
                      if (styleType == 'list') {
                        return ListView.separated(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final vod = _items[index];
                            return TvFocusable(
                              scaleFactor: 1.0,
      borderRadius: BorderRadius.circular(12),
                              onPressed: () {
                                if (vod.isFolder) {
                                  widget.onOpenSubFolder(vod);
                                } else {
                                  widget.onOpenDetail(vod);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: vod.isFolder
                                      ? const Color(0xFF234C43)
                                          .withValues(alpha: 0.88)
                                      : const Color(0x33000000),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: vod.isFolder
                                        ? const Color(0xFFE5A00D)
                                            .withValues(alpha: 0.35)
                                        : Colors.white12,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    if (vod.vodPic.isNotEmpty)
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.network(
                                          vod.vodPic,
                                          width: 52,
                                          height: 52,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              Container(
                                            width: 52,
                                            height: 52,
                                            color: Colors.white10,
                                            child: Icon(
                                              vod.isFolder
                                                  ? Icons.folder
                                                  : Icons.movie_outlined,
                                              color: vod.isFolder
                                                  ? const Color(0xFFE5A00D)
                                                  : Colors.white70,
                                            ),
                                          ),
                                        ),
                                      )
                                    else
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: Colors.white10,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          vod.isFolder
                                              ? Icons.folder
                                              : Icons.play_circle_outline,
                                          color: vod.isFolder
                                              ? const Color(0xFFE5A00D)
                                              : Colors.white70,
                                          size: 24,
                                        ),
                                      ),
                                    const SizedBox(width: 12),
                                    Expanded(
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
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (vod.vodRemarks
                                              .trim()
                                              .isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              vod.vodRemarks,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right,
                                        color: Colors.white54, size: 20),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      }

                      final rawRatio = effStyle?['ratio'];
                      double? r = rawRatio is num
                          ? rawRatio.toDouble()
                          : double.tryParse(rawRatio?.toString() ?? '');
                      final desktopRatio = (r != null && r > 0)
                          ? (r * 0.82).clamp(0.55, 2.2)
                          : 0.66;
                      final mobileRatio = (r != null && r > 0)
                          ? (r * 0.82).clamp(0.55, 2.2)
                          : 0.62;

                      return GridView.builder(
                        controller: _scrollController,
                        padding: EdgeInsets.all(
                          (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                              ? 16.0
                              : 12.0,
                        ),
                        gridDelegate: (Platform.isWindows ||
                                Platform.isLinux ||
                                Platform.isMacOS)
                            ? SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent:
                                    desktopRatio >= 1.1 ? 260 : 205,
                                childAspectRatio: desktopRatio,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 14,
                              )
                            : SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount:
                                    mobileRatio >= 1.1 && crossAxisCount >= 3
                                        ? 2
                                        : crossAxisCount,
                                childAspectRatio: mobileRatio,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final vod = _items[index];
                          return VodCard(
                            vod: vod,
                            styleType: styleType,
                            onTap: () {
                              if (vod.isFolder) {
                                widget.onOpenSubFolder(vod);
                              } else {
                                widget.onOpenDetail(vod);
                              }
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
    );
  }
}
