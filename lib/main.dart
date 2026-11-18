import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/legacy.dart';
import 'services/app_logger.dart';
import 'services/proxy_service.dart';
import 'services/js_engine_service.dart';
import 'views/widgets/execution_log_dialog.dart';
import 'services/local_http_server.dart';
import 'services/pip_and_media_session_service.dart';
import 'global/storage_bridge.dart';
import 'views/home_page.dart';
import 'views/widgets/desktop_title_bar.dart';

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await AppLogger.init();
      HttpOverrides.global = FtvHttpOverrides();
      await FtvHttpOverrides.refreshSystemProxy();

  // 手机端默认竖屏模式
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      await windowManager.ensureInitialized();
      WindowOptions windowOptions = const WindowOptions(
        size: Size(1280, 750),
        minimumSize: Size(800, 500),
        center: true,
        backgroundColor: Color(0xFF101216),
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden, // 隐藏原生边框，无缝融入自定义顶栏
        title: 'FTV 影视',
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.setResizable(true);
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e) {
      debugPrint('WindowManager 初始化提示: $e');
    }
  }

  try {
    // 启动本地 NanoHTTPD 服务器 (默认端口 9978)
    await LocalHttpServer().start();
  } catch (e) {
    debugPrint('LocalHttpServer 启动捕获异常: $e');
  }

  try {
    // 初始化 media_kit 跨平台原生高性能播放器内核
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('MediaKit 初始化捕获异常: $e');
  }

  try {
    // 严格按持久化设置初始化系统级自动画中画（默认退后台仅播放声音，不进画中画）
    await StorageBridge.init();
    final bgPlay = await StorageBridge.getValue('player_bg_play');
    final isPip = bgPlay == '画中画';
    await PipAndMediaSessionService().enableAutoPip(
      enabled: isPip,
      keepOnResume: isPip,
    );
  } catch (_) {}

      runApp(const FtvApp());
    },
    (error, stack) {
      AppLogger.writeLine('[UncaughtError] $error\n$stack');
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        AppLogger.writeLine(line);
        parent.print(zone, line);
      },
    ),
  );
}

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

class FtvApp extends StatelessWidget {
  const FtvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        LogicalKeySet(LogicalKeyboardKey.enter): const ActivateIntent(),
        LogicalKeySet(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
      },
      child: MaterialApp(
        navigatorKey: _rootNavigatorKey,
        title: 'FTV 影视',
        restorationScopeId: 'ftv_root',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF101216),
          canvasColor: const Color(0xFF101216),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFE5A00D), // OK影视琥珀金主题色
            secondary: Color(0xFFE5A00D),
            surface: Color(0xFF181A22),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF181A22),
            elevation: 0,
            iconTheme: IconThemeData(color: Colors.white),
            titleTextStyle: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          cardColor: const Color(0xFF1C1E26),
        ),
        builder: (context, child) {
          final Widget base = (Platform.isWindows || Platform.isLinux || Platform.isMacOS) && child != null
              ? DragToResizeArea(
                  child: Column(
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: AppLogger.hideGlobalDebugFabNotifier,
                        builder: (_, hide, _) => hide
                            ? const SizedBox.shrink()
                            : const DesktopTitleBar(title: 'FTV 影视'),
                      ),
                      Expanded(child: child),
                    ],
                  ),
                )
              : (child ?? const SizedBox.shrink());
          return Stack(
            children: [
              base,
              _GlobalDebugLogFab(navigatorKey: _rootNavigatorKey),
            ],
          );
        },
        home: const HomePage(),
      ),
    );
  }
}


class _GlobalDebugLogFab extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  const _GlobalDebugLogFab({required this.navigatorKey});

  @override
  State<_GlobalDebugLogFab> createState() => _GlobalDebugLogFabState();
}

class _GlobalDebugLogFabState extends State<_GlobalDebugLogFab> {
  double _right = 14.0;
  double _bottom = 148.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppLogger.debugModeNotifier,
        AppLogger.hideGlobalDebugFabNotifier,
        PipAndMediaSessionService().isInPipNotifier,
      ]),
      builder: (context, _) {
        final visible = AppLogger.debugModeNotifier.value &&
            !AppLogger.hideGlobalDebugFabNotifier.value &&
            !PipAndMediaSessionService().isInPipNotifier.value;
        if (!visible) return const SizedBox.shrink();

        final size = MediaQuery.of(context).size;
        final maxRight = (size.width - 52).clamp(8.0, double.infinity);
        final maxBottom = (size.height - 96).clamp(8.0, double.infinity);

        return Positioned(
          right: _right.clamp(8.0, maxRight),
          bottom: _bottom.clamp(16.0, maxBottom),
          child: GestureDetector(
            onPanUpdate: (d) {
              setState(() {
                _right = (_right - d.delta.dx).clamp(8.0, maxRight);
                _bottom = (_bottom - d.delta.dy).clamp(16.0, maxBottom);
              });
            },
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onLongPress: () async {
                  await AppLogger.setWebDebugEnabled(false);
                },
                onTap: () {
                  final navCtx = widget.navigatorKey.currentContext;
                  if (navCtx != null) {
                    ExecutionLogDialog.show(
                      navCtx,
                      JsEngineService.currentInstance ?? JsEngineService(),
                    );
                  }
                },
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.greenAccent.withValues(alpha: 0.7),
                      width: 1.3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.terminal,
                    color: Colors.greenAccent,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
