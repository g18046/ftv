import 'dart:io';

/// 全局 HTTP 代理适配器：自动读取 Windows 系统代理（注册表 Internet Settings）及环境变量代理
class FtvHttpOverrides extends HttpOverrides {
  static String? _cachedWindowsProxy;
  static String? get currentProxy => _cachedWindowsProxy;
  static DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> refreshSystemProxy() async {
    if (!Platform.isWindows) return;
    try {
      final enableRes = await Process.run(
        'reg',
        [
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
          '/v',
          'ProxyEnable',
        ],
        runInShell: false,
      );
      final enableOut = enableRes.stdout.toString();
      if (!enableOut.contains('0x1')) {
        _cachedWindowsProxy = null;
        _lastCheck = DateTime.now();
        return;
      }

      final srvRes = await Process.run(
        'reg',
        [
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
          '/v',
          'ProxyServer',
        ],
        runInShell: false,
      );
      final srvOut = srvRes.stdout.toString();
      final match = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)').firstMatch(srvOut);
      var raw = match?.group(1)?.trim() ?? '';
      if (raw.isEmpty) {
        _cachedWindowsProxy = null;
        _lastCheck = DateTime.now();
        return;
      }

      // 兼容 "http=127.0.0.1:7890;https=127.0.0.1:7890" 或 "127.0.0.1:7890"
      if (raw.contains('=')) {
        final parts = raw.split(';');
        String? picked;
        for (final p in parts) {
          final kv = p.split('=');
          if (kv.length == 2) {
            final k = kv[0].trim().toLowerCase();
            final v = kv[1].trim();
            if (k == 'https' || k == 'http') {
              picked = v;
              if (k == 'https') break;
            }
          }
        }
        raw = picked ?? parts.first.split('=').last.trim();
      }
      raw = raw.replaceFirst(RegExp(r'^https?://'), '').trim();
      final nextProxy = raw.isNotEmpty ? raw : null;
      if (nextProxy != _cachedWindowsProxy && nextProxy != null) {
        print('🌐 [Proxy] 已应用 Windows 系统代理: $nextProxy');
      }
      _cachedWindowsProxy = nextProxy;
      _lastCheck = DateTime.now();
    } catch (_) {}
  }

  static bool _isLocalHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '::1' ||
        h.startsWith('192.168.') ||
        h.startsWith('10.');
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (_, __, ___) => true;
    client.findProxy = (Uri uri) {
      if (_isLocalHost(uri.host)) return 'DIRECT';

      // 1. 优先环境变量
      final env = Platform.environment['HTTPS_PROXY'] ??
          Platform.environment['https_proxy'] ??
          Platform.environment['HTTP_PROXY'] ??
          Platform.environment['http_proxy'];
      if (env != null && env.trim().isNotEmpty) {
        final cleaned = env
            .trim()
            .replaceFirst(RegExp(r'^https?://'), '')
            .replaceAll('/', '');
        if (cleaned.isNotEmpty) return 'PROXY $cleaned; DIRECT';
      }

      // 2. Windows 系统代理（每 15 秒异步刷新一次）
      if (Platform.isWindows) {
        if (DateTime.now().difference(_lastCheck).inSeconds > 15) {
          _lastCheck = DateTime.now();
          refreshSystemProxy();
        }
        if (_cachedWindowsProxy != null && _cachedWindowsProxy!.isNotEmpty) {
          return 'PROXY $_cachedWindowsProxy; DIRECT';
        }
      }

      return HttpClient.findProxyFromEnvironment(uri);
    };
    return client;
  }
}
