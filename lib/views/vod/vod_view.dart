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

  // 文件夹穿透历史栈
  final List<VodItem> _folderHistory = [];

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
    _scrollController.addListener(_onScroll);
    _loadSiteAndData();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _tabScrollController.dispose();
    super.dispose();
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
        setState(() {
          _vodList = list;
          _page = page;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSelectCategory(CategoryItem? cat) {
    if (_selectedCategory == cat) return;
    setState(() {
      _selectedCategory = cat;
      _activeFilters.clear();
      _showFilterPanel = false;
    });

    if (cat == null) {
      widget.repository.fetchHomeVods().then((list) {
        if (mounted) setState(() => _vodList = list);
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

  void _showCategoryDrawer() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('全部分类', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_hasHomeVod)
                    ChoiceChip(
                      label: const Text('推荐'),
                      selected: _selectedCategory == null,
                      selectedColor: const Color(0xFFE5A00D),
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
                      selectedColor: const Color(0xFFE5A00D),
                      onSelected: (_) {
                        Navigator.pop(ctx);
                        _onSelectCategory(c);
                      },
                    );
                  }),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPushDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        title: const Text('推送影视链接解析', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '输入磁力链接 / HTTP 视频流 / 网盘链接',
            hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE5A00D)),
            onPressed: () async {
              final link = controller.text.trim();
              if (link.isNotEmpty) {
                Navigator.pop(context);
                final pushVod = await widget.repository.pushLink(link);
                if (mounted) {
                  if (pushVod != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DetailView(
                          repository: widget.repository,
                          vodItem: pushVod,
                          vodId: pushVod.vodId,
                        ),
                      ),
                    );
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DetailView(
                          repository: widget.repository,
                          vodId: link,
                        ),
                      ),
                    );
                  }
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
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6FAAA0), Color(0xFF48877C), Color(0xFF296358), Color(0xFF1B483F)],
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
                    InkWell(
                      onTap: _showSitePickerSheet,
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
                      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已进入收藏频道'), duration: Duration(seconds: 1)),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.history, color: Colors.white, size: 24),
                      tooltip: '播放历史',
                      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已展示最近播放历史'), duration: Duration(seconds: 1)),
                      ),
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
                    : _isLoading
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
            backgroundColor: const Color(0xFF2196F3),
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
}