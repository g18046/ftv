import '../services/theme_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../repositories/site_repository.dart';
import 'vod/vod_view.dart';
import 'live/live_view.dart';
import 'settings/settings_view.dart';

/// OK影视主框架页
/// 采用点播、直播、设置三大核心顶级导航
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SiteRepository _repository = SiteRepository();
  final ThemeService _themeService = ThemeService();
  int _navIndex = 0; // 0: 点播, 2: 设置 (1 为直通横屏直播入口)
  bool _isInitLoading = true;
  String _statusText = '正在加载点播配置与初始化 JS 引擎...';
  DateTime? _lastBackPressedTime;

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

    _repository.toastNotifier.addListener(_onToastMessage);
    _initApp();
  }

  @override
  void dispose() {
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    _repository.toastNotifier.removeListener(_onToastMessage);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
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
          print('⏱️ 应用启动加载超时 (3.5s 阈值已到)，平滑进入主页面');
        },
      );
    } catch (e) {
      print('应用初始化配置捕获异常: $e');
    } finally {
      if (mounted) {
        setState(() => _isInitLoading = false);
      }
    }
  }

  Future<void> _doInitApp() async {
    // 1. 优先读取持久化配置历史：恢复上次的点播源配置
    final activeConfig = await _repository.configService.getActiveConfig();

    if (activeConfig != null && activeConfig.urlOrPath.isNotEmpty) {
      if (mounted) {
        setState(() => _statusText = '正在恢复上次配置 [${activeConfig.name}]...');
      }
      print('🚀 发现历史激活配置，优先恢复: ${activeConfig.name} (${activeConfig.urlOrPath})');
      final sites = await _repository.loadConfig(
        activeConfig.urlOrPath,
        activeConfig.name,
        activeConfig.type,
      ).timeout(
        const Duration(milliseconds: 3000),
        onTimeout: () => [],
      );
      if (sites.isNotEmpty) return;
    }

    // 2. 尝试探测主力本地 JS 源目录
    final userLocalCandidates = [
      'D:/code/ok影视js源/my/src',
      'D:/code/ok影视js源/my/src/config.json',
      'D:/code/ok影视js源/my',
      'D:/code/ok影视js源/my/config.json',
    ];
    for (final userPath in userLocalCandidates) {
      if (await Directory(userPath).exists() || await File(userPath).exists()) {
        if (mounted) {
          setState(() => _statusText = '正在加载本地 JS 源: $userPath ...');
        }
        final sites = await _repository.loadConfig(userPath, '我的本地JS源').timeout(
          const Duration(milliseconds: 2500),
          onTimeout: () => [],
        );
        if (sites.isNotEmpty) return;
      }
    }

    // 3. 首次启动探测本地项目内置测试源
    final localBuiltinCandidates = [
      '测试源/src/config.json',
      'D:/code/ftv/测试源/src/config.json',
    ];

    for (final p in localBuiltinCandidates) {
      if (await File(p).exists()) {
        if (mounted) {
          setState(() => _statusText = '正在加载项目内置测试源...');
        }
        final sites = await _repository.loadConfig(p, '项目内置测试源').timeout(
          const Duration(milliseconds: 2000),
          onTimeout: () => [],
        );
        if (sites.isNotEmpty) return;
      }
    }

    // 4. 局域网测试源兜底
    if (mounted) {
      setState(() => _statusText = '正在探测测试源 (:5000)...');
    }
    await _repository.loadConfig('http://192.168.5.4:5000/src/config.json').timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () async => [],
    );
  }

  void _handleBackPress() {
    final now = DateTime.now();
    if (_lastBackPressedTime == null || now.difference(_lastBackPressedTime!) > const Duration(seconds: 2)) {
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

  Widget _buildBottomTabItem(int index, IconData unselectedIcon, IconData selectedIcon) {
    final isSelected = _navIndex == index;

    return InkWell(
      onTap: () {
        if (index == 1) {
          _openFullscreenLive();
          return;
        }
        setState(() => _navIndex = index);
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
        backgroundColor: const Color(0xFF1B483F),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Color(0xFFE5A00D)),
              const SizedBox(height: 20),
              Text(
                _statusText,
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 8),
              const Text(
                '首次启动可随时在 [设置] 页面导入本地 JS 离线包或输入远程配置',
                style: TextStyle(color: Colors.white70, fontSize: 12),
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
        backgroundColor: const Color(0xFF1B483F),
        body: IndexedStack(
          index: selectedPageIndex,
          children: pages,
        ),
        // OK影视标志性底部导航栏 (参考图 1 & 2: 极简胶囊高亮 Pill 指示器)
        bottomNavigationBar: Container(
          color: const Color(0xFF1B483F),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
          child: SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBottomTabItem(0, Icons.movie_creation_outlined, Icons.movie_creation),
                _buildBottomTabItem(1, Icons.play_arrow_outlined, Icons.play_arrow),
                _buildBottomTabItem(2, Icons.settings_outlined, Icons.settings),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
