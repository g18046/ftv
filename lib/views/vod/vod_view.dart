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

  /// 初始化并加载站点数据 (已将超时从 4s 调大至 10s，防止 JS 编译或网络慢时卡死)
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
          const Duration(seconds: 10),
          onTimeout: () {
            print('⚠️ 设置默认站点超时，继续执行');
          },
        );
      }

      if (widget.repository.activeSite != null) {
        final catData = await widget.repository.fetchCategories().timeout(
          const Duration(seconds: 10),
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

        final homeVods = await widget.repository.fetchHomeVod().timeout(
          const Duration(seconds: 10),
          onTimeout: () => [],
        );
        final hasHome = homeVods.isNotEmpty;

        if (mounted) {
          setState(() {
            _categories = cats;
            _filterMap = filters;
            _hasHomeVod = hasHome;
            _folderHistory.clear();
            _activeFilters.clear();
            _page = 1;
          });
        }

        if (hasHome) {
          if (mounted) {
            setState(() {
              _selectedCategory = null;
              _vodList = homeVods;
              _isLoading = false;
            });
          }
        } else if (cats.isNotEmpty) {
          _onSelectCategory(cats.first);
        } else {
          if (mounted) {
            setState(() {
              _vodList = [];
              _isLoading = false;
            });
          }
        }
      }
    } catch (e) {
      print('加载点播数据异常: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isChangingSite = false;
        });
      }
    }
  }

  /// 选中分类
  Future<void> _onSelectCategory(CategoryItem? cat) async {
    setState(() {
      _selectedCategory = cat;
      _activeFilters.clear();
      _folderHistory.clear();
      _page = 1;
      _isLoading = true;
    });

    if (cat == null) {
      final homeVods = await widget.repository.fetchHomeVods();
      setState(() {
        _vodList = homeVods;
        _isLoading = false;
      });
    } else {
      await _loadCategoryVods(cat.typeId, 1);
    }
  }

  /// 分页拉取分类影视列表
  Future<void> _loadCategoryVods(String typeId, int page) async {
    final list = await widget.repository.fetchCategoryList(
      typeId,
      page,
      _activeFilters,
    );
    if (mounted) {
      setState(() {
        _vodList = list;
        _page = page;
        _isLoading = false;
      });
    }
  }

  /// 文件夹穿透打开
  Future<void> _onOpenFolder(VodItem folder) async {
    setState(() {
      _folderHistory.add(folder);
      _isLoading = true;
    });

    final subList = await widget.repository.fetchSubFolderList(folder.vodId);
    if (mounted) {
      setState(() {
        _vodList = subList;
        _isLoading = false;
      });
    }
  }

  /// 面包屑回退上级目录
  Future<void> _popFolder() async {
    if (_folderHistory.isEmpty) return;

    setState(() {
      _folderHistory.removeLast();
      _isLoading = true;
    });

    if (_folderHistory.isNotEmpty) {
      final parentFolder = _folderHistory.last;
      final subList = await widget.repository.fetchSubFolderList(parentFolder.vodId);
      if (mounted) {
        setState(() {
          _vodList = subList;
          _isLoading = false;
        });
      }
    } else {
      if (_selectedCategory == null) {
        final homeVods = await widget.repository.fetchHomeVods();
        if (mounted) {
          setState(() {
            _vodList = homeVods;
            _isLoading = false;
          });
        }
      } else {
        await _loadCategoryVods(_selectedCategory!.typeId, _page);
      }
    }
  }

  /// 弹出站点切换面板
  void _showSitePickerSheet() {
    final sites = widget.repository.sites;
    final active = widget.repository.activeSite;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz, color: Color(0xFFE5A00D)),
                  const SizedBox(width: 8),
                  Text(
                    '选择点播数据源 (${sites.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: ListView.builder(
                itemCount: sites.length,
                itemBuilder: (context, idx) {
                  final s = sites[idx];
                  final isCurrent = s.key == active?.key;
                  return TvFocusable(
                    onPressed: () async {
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

  /// 推送解析弹窗
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('🚀 正在调用 push_agent 站点处理推送链接...'),
                    duration: Duration(seconds: 2),
                  ),
                );
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('⚠️ push_agent 解析链接未返回有效播放集，尝试直接进入播放器...'),
                        duration: Duration(seconds: 2),
                      ),
                    );
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
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181A22),
        elevation: 0,
        titleSpacing: 12,
        title: InkWell(
          onTap: _showSitePickerSheet,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.movie_filter, color: Color(0xFFE5A00D), size: 20),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    activeSite?.name ?? '选择点播源',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down, color: Colors.white70),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: '全网搜索',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SearchView(repository: widget.repository)),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.terminal, color: Colors.greenAccent),
            tooltip: '查看 QJS 日志',
            onPressed: () => ExecutionLogDialog.show(context, widget.repository.jsEngine),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: '刷新数据',
            onPressed: _loadSiteAndData,
          ),
        ],
      ),
      body: _isChangingSite
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
          : Column(
              children: [
                _buildCategoryTabBar(),
                if (_folderHistory.isNotEmpty) _buildFolderBreadcrumb(),
                if (_showFilterPanel && currentFilters != null && currentFilters.isNotEmpty)
                  _buildFilterPanel(currentFilters),
                Expanded(
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
                                  childAspectRatio: 0.68,
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
          if (currentFilters != null && currentFilters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: FloatingActionButton.small(
                heroTag: 'filterBtn',
                onPressed: () => setState(() => _showFilterPanel = !_showFilterPanel),
                tooltip: '多维筛选',
                backgroundColor: _showFilterPanel ? const Color(0xFFE5A00D) : const Color(0xFF262832),
                child: Icon(Icons.filter_list, color: _showFilterPanel ? Colors.black : Colors.white),
              ),
            ),
          FloatingActionButton(
            heroTag: 'pushBtn',
            backgroundColor: const Color(0xFFE5A00D),
            onPressed: _showPushDialog,
            tooltip: '推送链接',
            child: const Icon(Icons.rocket_launch, color: Colors.black),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTabBar() {
    final hasHome = _hasHomeVod;
    final totalCount = hasHome ? _categories.length + 1 : _categories.length;

    return Container(
      height: 46,
      color: const Color(0xFF14161E),
      child: ListView.builder(
        controller: _tabScrollController,
        scrollDirection: Axis.horizontal,
        itemCount: totalCount,
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
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
              margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 6.0),
              padding: const EdgeInsets.symmetric(horizontal: 14.0),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFE5A00D) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                title,
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white70,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13,
                ),
              ),
            ),
          );
        },
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
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.inbox, size: 48, color: Colors.grey),
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

  Widget _buildVodCard(VodItem vod) {
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
              ),
            ),
          );
        }
      },
      child: Card(
        color: const Color(0xFF1C1E26),
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Stack(
          children: [
            Positioned.fill(
              child: vod.vodPic.isNotEmpty
                  ? Image.network(
                      vod.vodPic,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: const Color(0xFF262832),
                        child: Icon(vod.isFolder ? Icons.folder : Icons.movie, size: 40, color: Colors.grey),
                      ),
                    )
                  : Container(
                      color: const Color(0xFF262832),
                      child: Icon(vod.isFolder ? Icons.folder : Icons.movie, size: 40, color: Colors.grey),
                    ),
            ),
            if (vod.isFolder)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder, size: 12, color: Color(0xFFE5A00D)),
                      SizedBox(width: 2),
                      Text('目录', style: TextStyle(color: Color(0xFFE5A00D), fontSize: 9, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Color(0xDD000000)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
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
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    if ((vod.vodRemarks ).isNotEmpty && !vod.isFolder)
                      Text(
                        vod.vodRemarks,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}