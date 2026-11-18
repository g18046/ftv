import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/vod_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/theme_service.dart';
import '../detail/detail_view.dart';
import 'widgets/vod_card.dart';

/// 文件夹多层浏览子路由页面（支持系统 Back 手势逐层返回）
class VodFolderPage extends StatefulWidget {
  final SiteRepository repository;
  final VodItem folder;
  final ThemeService themeService;

  const VodFolderPage({
    super.key,
    required this.repository,
    required this.folder,
    required this.themeService,
  });

  @override
  State<VodFolderPage> createState() => _VodFolderPageState();
}

class _VodFolderPageState extends State<VodFolderPage> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  List<VodItem> _items = [];

  @override
  void initState() {
    super.initState();
    _loadFolder();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFolder() async {
    setState(() => _isLoading = true);
    try {
      final list = await widget.repository
          .fetchSubFolderList(widget.folder.vodId)
          .timeout(const Duration(seconds: 8), onTimeout: () => []);
      if (mounted) {
        setState(() {
          _items = list;
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

    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.escape): const DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) => Navigator.maybePop(context),
          ),
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            decoration: BoxDecoration(
              gradient: widget.themeService.currentGradient,
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            widget.folder.vodName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
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
                                onRefresh: _loadFolder,
                                child: GridView.builder(
                                  controller: _scrollController,
                                  padding: EdgeInsets.all(
                                    (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                                        ? 16.0
                                        : 12.0,
                                  ),
                                  gridDelegate: (Platform.isWindows ||
                                          Platform.isLinux ||
                                          Platform.isMacOS)
                                      ? const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 205,
                                          childAspectRatio: 0.66,
                                          crossAxisSpacing: 14,
                                          mainAxisSpacing: 14,
                                        )
                                      : SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: crossAxisCount,
                                          childAspectRatio: 0.62,
                                          crossAxisSpacing: 10,
                                          mainAxisSpacing: 10,
                                        ),
                                  itemCount: _items.length,
                                  itemBuilder: (context, index) {
                                    final vod = _items[index];
                                    return VodCard(
                                      vod: vod,
                                      onTap: () {
                                        if (vod.isFolder) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => VodFolderPage(
                                                repository: widget.repository,
                                                folder: vod,
                                                themeService: widget.themeService,
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
                                      },
                                    );
                                  },
                                ),
                              ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
