import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../repositories/site_repository.dart';
import 'vod/vod_view.dart';
import 'live/live_view.dart';
import 'settings/settings_view.dart';

/// OK影视主框架页
/// 采用点播、直播、设置三大核心顶级导航
/// 遵循移动端交互设计：应用主框架默认保持竖屏，点击“直播”时才全屏横屏进入专属播放页
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SiteRepository _repository = SiteRepository();
  int _navIndex = 0; // 0: 点播, 2: 设置 (1 为直通横屏直播入口)
  bool _isInitLoading = true;
  String _statusText = '正在加载点播配置与初始化 JS 引擎...';
  DateTime? _lastBackPressedTime;

  @override
  void initState() {
    super.initState();
    // 手机应用主界面默认保持竖屏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _repository.toastNotifier.addListener(_onToastMessage);
    _initApp();
  }

  @override
  void dispose() {
    _repository.toastNotifier.removeListener(_onToastMessage);
    super.dispose();
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
      // 启动超时全局保护：最多限时 3.5 秒。超时也强制平滑进入主页面，绝不卡屏阻断！
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
        onTimeout: () {
          print('⚠️ 恢复上次点播配置超时，跳过');
          return [];
        },
      );
      if (sites.isNotEmpty) return;
    }

    // 2. 尝试探测主力本地 JS 源目录 D:/code/ok影视js源/my/src 与 D:/code/ok影视js源/my
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

  /// 点击“直播”导航时，以原生全屏横屏模式进入 LiveView
  Future<void> _openFullscreenLive() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveView(repository: _repository),
      ),
    );

    // 退出直播后恢复手机竖屏模式
    if (mounted) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF101216),
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
                style: TextStyle(color: Colors.grey, fontSize: 12),
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

    // 导航索引转换 (0: 点播, 1: 直播路由跳转, 2: 设置映射至内部 pages[1])
    final int selectedPageIndex = _navIndex == 2 ? 1 : 0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF101216),
        body: IndexedStack(
          index: selectedPageIndex,
          children: pages,
        ),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF161820),
            border: Border(top: BorderSide(color: Colors.white12, width: 0.8)),
          ),
          child: NavigationBar(
            backgroundColor: const Color(0xFF161820),
            indicatorColor: const Color(0xFFE5A00D).withValues(alpha: 0.2),
            selectedIndex: _navIndex,
            onDestinationSelected: (index) {
              if (index == 1) {
                // 点击直播：全屏横屏进入
                _openFullscreenLive();
                return;
              }
              setState(() => _navIndex = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.movie_outlined, color: Colors.white70),
                selectedIcon: Icon(Icons.movie, color: Color(0xFFE5A00D)),
                label: '点播',
              ),
              NavigationDestination(
                icon: Icon(Icons.live_tv_outlined, color: Colors.white70),
                selectedIcon: Icon(Icons.live_tv, color: Color(0xFFE5A00D)),
                label: '直播',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined, color: Colors.white70),
                selectedIcon: Icon(Icons.settings, color: Color(0xFFE5A00D)),
                label: '设置',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
