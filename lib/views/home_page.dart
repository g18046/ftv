import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/legacy.dart';
import '../global/storage_bridge.dart';
import '../repositories/site_repository.dart';
import '../services/theme_service.dart';
import 'live/live_view.dart';
import 'settings/settings_view.dart';
import 'vod/vod_view.dart';

/// OK影视主框架页
/// 采用点播、直播、设置三大核心顶级导航
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener {
  final SiteRepository _repository = SiteRepository();
  final ThemeService _themeService = ThemeService();
  int _navIndex = 0; // 0: 点播, 2: 设置 (1 为直通横屏直播入口)
  bool _isInitLoading = true;
  String _statusText = '正在加载点播配置与初始化 JS 引擎...';
  DateTime? _lastBackPressedTime;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _themeService.init();
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    if (isDesktop) windowManager.addListener(this);
    _repository.toastNotifier.addListener(_onToastMessage);
    _repository.configVersionNotifier.addListener(_onThemeChanged);
    _restoreLastTab();
    _initApp();
  }

  @override
  void dispose() {
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    if (isDesktop) windowManager.removeListener(this);
    _repository.toastNotifier.removeListener(_onToastMessage);
    _repository.configVersionNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _onDesktopWindowChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void onWindowMaximize() => _onDesktopWindowChanged();
  @override
  void onWindowUnmaximize() => _onDesktopWindowChanged();
  @override
  void onWindowRestore() => _onDesktopWindowChanged();
  @override
  void onWindowResized() => _onDesktopWindowChanged();

  Future<void> _restoreLastTab() async {
    try {
      final saved = await StorageBridge.getValue('app_last_tab');
      final idx = int.tryParse(saved ?? '');
      if (idx != null && (idx == 0 || idx == 2) && mounted) {
        setState(() => _navIndex = idx);
      }
    } catch (_) {}
  }

  Future<void> _saveLastTab(int index) async {
    try {
      await StorageBridge.setValue('app_last_tab', index.toString());
    } catch (_) {}
  }

  void _onToastMessage() {
    final msg = _repository.toastNotifier.value;
    if (msg != null && msg.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _initApp() async {
    try {
      await _doInitApp().timeout(
        const Duration(milliseconds: 3500),
        onTimeout: () {
          debugPrint('⏱️ 应用启动加载超时 (3.5s 阈值已到)，平滑进入主页面');
        },
      );
    } catch (e) {
      debugPrint('应用初始化配置捕获异常: $e');
    } finally {
      if (mounted) {
        setState(() => _isInitLoading = false);
      }
    }
  }

  Future<void> _doInitApp() async {
    final activeConfig = await _repository.configService.getActiveConfig();

    if (activeConfig != null && activeConfig.urlOrPath.isNotEmpty) {
      if (mounted) {
        setState(() => _statusText = '正在恢复上次配置 [${activeConfig.name}]...');
      }
      debugPrint('🚀 发现历史激活配置，优先恢复: ${activeConfig.name} (${activeConfig.urlOrPath})');
      await _repository.loadConfig(
        activeConfig.urlOrPath,
        activeConfig.name,
        activeConfig.type,
      ).timeout(
        const Duration(milliseconds: 3000),
        onTimeout: () => [],
      );
    }
  }

  void _handleBackPress() {
    if (_navIndex == 0 && VodView.tryPopNestedFolder()) {
      return;
    }
    final now = DateTime.now();
    if (_lastBackPressedTime == null ||
        now.difference(_lastBackPressedTime!) > const Duration(seconds: 2)) {
      _lastBackPressedTime = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('再按一次返回键退出 OK 影视'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      SystemNavigator.pop();
    }
  }

  Future<void> _openFullscreenLive() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveView(repository: _repository),
      ),
    );

    if (mounted) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Widget _buildBottomTabItem(
      int index, IconData unselectedIcon, IconData selectedIcon) {
    final isSelected = _navIndex == index;

    return InkWell(
      onTap: () {
        if (index == 1) {
          _openFullscreenLive();
          return;
        }
        setState(() => _navIndex = index);
        _saveLastTab(index);
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: isSelected
            ? const EdgeInsets.symmetric(horizontal: 22, vertical: 6)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFC8ECE2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(
          isSelected ? selectedIcon : unselectedIcon,
          color: isSelected ? const Color(0xFF1B483F) : Colors.white,
          size: 26,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitLoading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: BoxDecoration(gradient: _themeService.currentGradient),
          child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFFE5A00D)),
                    const SizedBox(height: 20),
                    Text(
                      _statusText,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '首次启动可随时在 [设置] 页面导入本地 JS 离线包或输入远程配置',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
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

    final pages = [
      VodView(repository: _repository),
      SettingsView(repository: _repository),
    ];

    final int selectedPageIndex = _navIndex == 2 ? 1 : 0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: BoxDecoration(gradient: _themeService.currentGradient),
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: selectedPageIndex,
                  children: pages,
                ),
              ),
              Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
                child: SafeArea(
                  top: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildBottomTabItem(
                          0, Icons.movie_creation_outlined, Icons.movie_creation),
                      if (_repository.lives.isNotEmpty)
                        _buildBottomTabItem(
                            1, Icons.play_arrow_outlined, Icons.play_arrow),
                      _buildBottomTabItem(
                          2, Icons.settings_outlined, Icons.settings),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
