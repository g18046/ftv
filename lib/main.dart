import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'services/local_http_server.dart';
import 'views/home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 手机端默认竖屏模式
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  try {
    // 启动本地 NanoHTTPD 服务器 (默认端口 9978)
    await LocalHttpServer().start();
  } catch (e) {
    print('LocalHttpServer 启动捕获异常: $e');
  }

  try {
    // 初始化 media_kit 跨平台原生高性能播放器内核
    MediaKit.ensureInitialized();
  } catch (e) {
    print('MediaKit 初始化捕获异常: $e');
  }
  runApp(const FtvApp());
}

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
        title: 'FTV 影视',
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
            titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          cardColor: const Color(0xFF1C1E26),
        ),
        home: const HomePage(),
      ),
    );
  }
}