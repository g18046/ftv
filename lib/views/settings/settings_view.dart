import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/config_model.dart';
import '../../models/danmaku_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/danmaku_service.dart';
import '../../services/theme_service.dart';
import '../../services/app_logger.dart';
import '../../global/app_version.dart';
import '../../services/local_http_server.dart';

import 'playback_settings_page.dart';
import 'personal_settings_page.dart';
import 'backup_restore_page.dart';
class SettingsView extends StatefulWidget {
  final SiteRepository repository;

  const SettingsView({super.key, required this.repository});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

enum _PendingPickerAction { file, directory, editFile }

class _SettingsViewState extends State<SettingsView> with WidgetsBindingObserver {
  _PendingPickerAction? _pendingPickerAction;
  Future<void> Function()? _pendingEditPickCallback;
  late final TextEditingController _configUrlController;
  late final TextEditingController _danmakuUrlController;

  final DanmakuService _danmakuService = DanmakuService();
  final ThemeService _themeService = ThemeService();
  DanmakuConfig _danmakuConfig = DanmakuConfig();

  List<ConfigItemModel> _historyList = [];
  bool _isLoading = false;
  String _loadingMessage = '';
  String _cacheSizeStr = '64.9 MB';
  String _dohType = '系统';
  String _appVersion = AppVersion.version;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configUrlController = TextEditingController(text: widget.repository.configBaseUrl);
    _danmakuUrlController = TextEditingController(text: _danmakuService.config.serverUrl);
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
    _initData();
    _loadAppVersion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingPickerAction != null) {
      final action = _pendingPickerAction!;
      _pendingPickerAction = null;
      Future.delayed(const Duration(milliseconds: 150), () async {
        final granted = await widget.repository.configService.hasAndroidAllFilesAccess();
        if (!mounted) return;
        if (granted) {
          if (action == _PendingPickerAction.file) {
            await _pickLocalConfigFile();
          } else if (action == _PendingPickerAction.directory) {
            await _pickLocalDirectory();
          } else if (action == _PendingPickerAction.editFile &&
              _pendingEditPickCallback != null) {
            final cb = _pendingEditPickCallback!;
            _pendingEditPickCallback = null;
            await cb();
          }
        } else {
          _pendingEditPickCallback = null;
          _showSnack('未授予所有文件访问权限，无法直接读取本地目录中的 js/lib 文件');
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    _configUrlController.dispose();
    _danmakuUrlController.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initData() async {
    await _themeService.init();
    final conf = await _danmakuService.initConfig();
    _danmakuUrlController.text = conf.serverUrl;
    if (mounted) {
      setState(() => _danmakuConfig = conf);
    }
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    final list = await widget.repository.configService.loadHistory();
    if (mounted) {
      setState(() => _historyList = list);
    }
  }

  Future<void> _handleReloadConfig([String? customPath, String? customName]) async {
    final pathOrUrl = customPath ?? _configUrlController.text.trim();
    if (pathOrUrl.isEmpty) return;

    setState(() {
      _isLoading = true;
      _loadingMessage = '正在装载并编译点播配置...';
      _configUrlController.text = pathOrUrl;
    });

    try {
      await widget.repository.loadConfig(pathOrUrl, customName).timeout(
        const Duration(seconds: 8),
        onTimeout: () => widget.repository.sites,
      );
      await _loadHistory();
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _applyPickedResult(ConfigLoadResult result) async {
    final sites = await widget.repository.applyLoadedConfig(
      result,
      customName: result.suggestedName,
      type: result.type,
    );
    _configUrlController.text = result.effectiveBaseUrl;
    await _loadHistory();
    if (mounted) setState(() {});
    _showSnack('已加载配置「${result.suggestedName}」，共 ${sites.length} 个 JS 站源');
  }

  Future<void> _pickLocalConfigFile() async {
    if (Platform.isAndroid) {
      final hasAccess = await widget.repository.configService.hasAndroidAllFilesAccess();
      if (!hasAccess) {
        _pendingPickerAction = _PendingPickerAction.file;
        _showSnack('请先授予“所有文件访问权限”，授权后返回将自动打开文件选择');
        await widget.repository.configService.requestAndroidAllFilesAccess();
        return;
      }
    }
    setState(() {
      _isLoading = true;
      _loadingMessage = '正在读取并解析本地配置文件...';
    });

    try {
      final result = await widget.repository.configService.pickAndLoadConfig();
      if (result != null) {
        await _applyPickedResult(result);
      }
    } catch (e) {
      _showSnack('导入本地配置文件失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _pickLocalDirectory() async {
    if (Platform.isAndroid) {
      final hasAccess = await widget.repository.configService.hasAndroidAllFilesAccess();
      if (!hasAccess) {
        _pendingPickerAction = _PendingPickerAction.directory;
        _showSnack('请先授予“所有文件访问权限”，授权后返回将自动打开文件夹选择');
        await widget.repository.configService.requestAndroidAllFilesAccess();
        return;
      }
    }
    setState(() {
      _isLoading = true;
      _loadingMessage = '正在扫描并解析本地配置文件夹...';
    });

    try {
      final result = await widget.repository.configService.pickAndLoadDirectory();
      if (result != null) {
        await _applyPickedResult(result);
      }
    } catch (e) {
      _showSnack('导入本地配置文件夹失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showLocalImportOptions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('导入本地配置', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined, color: Color(0xFF2979FF)),
              title: const Text('选择本地配置文件', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('支持 .json / .zip / .txt (安卓/Windows)', style: TextStyle(color: Colors.grey, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _pickLocalConfigFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open, color: Color(0xFFE5A00D)),
              title: const Text('选择本地配置文件夹', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('直接加载硬盘或存储中的源码目录', style: TextStyle(color: Colors.grey, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _pickLocalDirectory();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showConfigEditDialog({required String title, required String currentUrl, required Function(String) onSave}) {
    final controller = TextEditingController(text: currentUrl);
    ConfigLoadResult? pickedResult;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: '输入 http:// 或本地文件路径',
                hintStyle: const TextStyle(color: Colors.grey),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.insert_drive_file_outlined, color: Color(0xFF2979FF)),
                  tooltip: '选择本地配置文件 (.json/.zip/.txt)',
                  onPressed: () async {
                    Future<void> runEditPick() async {
                      try {
                        final result = await widget.repository.configService.pickAndLoadConfig();
                        if (result != null) {
                          pickedResult = result;
                          controller.text = result.effectiveBaseUrl;
                        }
                      } catch (e) {
                        _showSnack('选择配置文件失败: $e');
                      }
                    }

                    if (Platform.isAndroid) {
                      final hasAccess = await widget.repository.configService.hasAndroidAllFilesAccess();
                      if (!hasAccess) {
                        _pendingPickerAction = _PendingPickerAction.editFile;
                        _pendingEditPickCallback = runEditPick;
                        _showSnack('请先授予“所有文件访问权限”，授权后返回将自动打开文件选择');
                        await widget.repository.configService.requestAndroidAllFilesAccess();
                        return;
                      }
                    }
                    await runEditPick();
                  },
                ),
              ),
            ),

          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _themeService.accentColor),
            onPressed: () async {
              final inputText = controller.text.trim();
              Navigator.pop(ctx);
              if (pickedResult != null && pickedResult!.effectiveBaseUrl == inputText) {
                await _applyPickedResult(pickedResult!);
              } else {
                onSave(inputText);
              }
            },
            child: const Text('保存', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// 历史配置弹窗 (严格贴合参考图 7 浮窗卡片)
  void _showHistorySheet() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
          decoration: BoxDecoration(
            color: const Color(0xFFEBECEF),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_historyList.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('暂无历史配置', style: TextStyle(color: Colors.black54, fontSize: 14)),
                )
              else
                ..._historyList.take(5).map((item) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(ctx);
                              _handleReloadConfig(item.urlOrPath, item.name);
                            },
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.black26),
                              ),
                              child: Text(
                                item.urlOrPath,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.black54, size: 22),
                          onPressed: () async {
                            await widget.repository.configService.removeHistory(item.id);
                            await _loadHistory();
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  void _showThemeColorDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('配置按钮主题色',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: ThemeService.presetColors.map((item) {
              final color = item['color'] as Color;
              final name = item['name'] as String;
              final isSel = _themeService.accentColor.toARGB32() == color.toARGB32();

              return InkWell(
                onTap: () {
                  _themeService.setAccentColor(color);
                  Navigator.pop(ctx);
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSel ? color.withOpacity(0.25) : const Color(0xFF262832),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isSel ? color : Colors.white24, width: isSel ? 1.5 : 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(name,
                          style: TextStyle(
                            color: isSel ? Colors.white : Colors.white70,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12,
                          )),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeConfig = widget.repository.activeConfigItem;
    final currentUrl = activeConfig?.urlOrPath ?? widget.repository.configBaseUrl;
    final currentWpName = ThemeService.presetWallpapers[_themeService.wallpaperIndex]['name'] as String;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 顶栏 (参考图 2: 左侧标题“设置”，右侧导出 [↑] 与导入 [↓])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Text(
                      '设置',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.file_upload_outlined, color: Colors.white, size: 24),
                      tooltip: '备份与导出',
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: const Icon(Icons.file_download_outlined, color: Colors.white, size: 24),
                      tooltip: '导入本地配置文件',
                      onPressed: _pickLocalConfigFile,
                    ),
                  ],
                ),
              ),

              // 设置项卡片列表 (严格贴合参考图 2)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    // 1. 点播源
                    _buildSettingsItemCard(
                      title: '点播',
                      value: currentUrl.isNotEmpty ? currentUrl : '未配置点播源，请点击导入',
                      onTap: () => _showConfigEditDialog(
                        title: '编辑点播配置地址',
                        currentUrl: currentUrl,
                        onSave: (url) => _handleReloadConfig(url),
                      ),
                      rightActions: [
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white, size: 22),
                          tooltip: '重载当前配置',
                          onPressed: () => _handleReloadConfig(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.history, color: Colors.white, size: 22),
                          tooltip: '历史配置',
                          onPressed: _showHistorySheet,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 2. 直播源
                    _buildSettingsItemCard(
                      title: '直播',
                      value: currentUrl.isNotEmpty ? currentUrl : '未配置点播源，请点击导入',
                      onTap: () => _showConfigEditDialog(
                        title: '编辑直播配置地址',
                        currentUrl: currentUrl,
                        onSave: (url) => _handleReloadConfig(url),
                      ),
                      rightActions: [
                        IconButton(
                          icon: const Icon(Icons.home_outlined, color: Colors.white, size: 22),
                          tooltip: '重置为默认',
                          onPressed: () => _handleReloadConfig(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.history, color: Colors.white, size: 22),
                          tooltip: '历史配置',
                          onPressed: _showHistorySheet,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 3. 壁纸 (点击右侧房子图标循环切换默认渐变壁纸)
                    _buildSettingsItemCard(
                      title: '壁纸',
                      value: currentWpName,
                      onTap: () => _themeService.nextWallpaper(),
                      rightActions: [
                        IconButton(
                          icon: const Icon(Icons.home_outlined, color: Colors.white, size: 22),
                          tooltip: '切换默认渐变壁纸',
                          onPressed: () => _themeService.nextWallpaper(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white, size: 22),
                          tooltip: '切换下一套壁纸',
                          onPressed: () => _themeService.nextWallpaper(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 4. 播放设置 (参考图 4)
                    _buildSimpleCard(
                      '播放设置',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlaybackSettingsPage(themeService: _themeService),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),

                    // 5. 个性设置 (参考图 5)
                    _buildSettingsItemCard(
                      title: '弹幕服务',
                      value: _maskDanmakuUrl(_danmakuConfig.serverUrl),
                      onTap: _showDanmakuServerDialog,
                      rightActions: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, color: Colors.white70, size: 20),
                          tooltip: '修改弹幕服务地址',
                          onPressed: _showDanmakuServerDialog,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    _buildSettingsItemCard(
                      title: '网页调试日志',
                      value: AppLogger.webDebugEnabled
                          ? '${LocalHttpServer().baseUrl}/logs'
                          : '已关闭（开启后可通过局域网浏览器查看实时日志）',
                      onTap: () async {
                        final next = !AppLogger.webDebugEnabled;
                        if (next) await LocalHttpServer().start();
                        await AppLogger.setWebDebugEnabled(next);
                        if (mounted) setState(() {});
                      },
                      rightActions: [
                        if (AppLogger.webDebugEnabled)
                          IconButton(
                            icon: const Icon(Icons.open_in_browser, color: Colors.white70, size: 20),
                            tooltip: '在浏览器中打开日志',
                            onPressed: () async {
                              await LocalHttpServer().start();
                              final url = '${LocalHttpServer().baseUrl}/logs';
                              try {
                                if (Platform.isWindows) {
                                  await Process.start('cmd', ['/c', 'start', '', url]);
                                } else if (Platform.isMacOS) {
                                  await Process.start('open', [url]);
                                } else if (Platform.isLinux) {
                                  await Process.start('xdg-open', [url]);
                                } else if (Platform.isAndroid) {
                                  await const MethodChannel('com.example.ftv/downloader')
                                      .invokeMethod('openInBrowser', {'url': url});
                                }
                              } catch (e) {
                                if (mounted) _showSnack('打开浏览器失败: $e');
                              }
                            },
                          ),
                        if (AppLogger.webDebugEnabled)
                          IconButton(
                            icon: const Icon(Icons.copy, color: Colors.white70, size: 19),
                            tooltip: '复制日志链接',
                            onPressed: () {
                              final url = '${LocalHttpServer().baseUrl}/logs';
                              Clipboard.setData(ClipboardData(text: url));
                              _showSnack('已复制调试日志地址: $url');
                            },
                          ),
                        Switch(
                          value: AppLogger.webDebugEnabled,
                          activeColor: _themeService.accentColor,
                          onChanged: (val) async {
                            if (val) await LocalHttpServer().start();
                            await AppLogger.setWebDebugEnabled(val);
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    _buildSimpleCard(
                      '个性设置',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PersonalSettingsPage(themeService: _themeService),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),

                    // 6. 备份恢复 (参考图 6)
                    _buildSimpleCard(
                      '备份恢复',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BackupRestorePage(themeService: _themeService),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),

                    // 7. 主题颜色配置
                    _buildSettingsValueCard(
                      '主题颜色',
                      ThemeService.presetColors.firstWhere(
                        (e) => (e['color'] as Color).toARGB32() == _themeService.accentColor.toARGB32(),
                        orElse: () => {'name': '自定义'},
                      )['name'],
                      onTap: _showThemeColorDialog,
                    ),
                    const SizedBox(height: 12),

                    // 8. DoH
                    _buildSettingsValueCard('DoH', _dohType, onTap: () {
                      setState(() {
                        _dohType = _dohType == '系统' ? '阿里 (DoH)' : _dohType == '阿里 (DoH)' ? '腾讯 (DoH)' : '系统';
                      });
                    }),
                    const SizedBox(height: 12),

                    // 9. 缓存
                    _buildSettingsValueCard('缓存', _cacheSizeStr, onTap: () {
                      setState(() => _cacheSizeStr = '0.0 MB');
                      widget.repository.jsEngine.clearModuleCache();
                    }),
                    const SizedBox(height: 12),

                    // 10. 版本 (跟随包版本/AppVersion，点击查看更新说明)
                    _buildSettingsItemCard(
                      title: '版本',
                      value: 'v$_appVersion (点击查看更新说明)',
                      onTap: _showChangelogDialog,
                    ),
                    const SizedBox(height: 12),

                    // 11. 关于
                    _buildSettingsValueCard(
                      '关于',
                      Platform.isWindows ? 'windows-x64' : 'mobile-arm64_v8a',
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _maskDanmakuUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '未配置';
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      if (trimmed.length <= 8) return '***';
      return '${trimmed.substring(0, 4)}***${trimmed.substring(trimmed.length - 2)}';
    }
    final host = uri.host;
    final maskedHost = host.length <= 4
        ? '***'
        : '${host.substring(0, 2)}***${host.substring(host.length - 3)}';
    final hasExtra = uri.hasPort || (uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery;
    final scheme = uri.scheme.isNotEmpty ? '${uri.scheme}://' : '';
    return '$scheme$maskedHost${hasExtra ? "/****" : ""}';
  }


  Future<void> _loadAppVersion() async {
    if (Platform.isAndroid) {
      try {
        final v = await const MethodChannel('com.example.ftv/downloader')
            .invokeMethod<String>('getAppVersion');
        if (v != null && v.trim().isNotEmpty && mounted) {
          setState(() => _appVersion = v.trim());
        }
      } catch (_) {}
    }
  }

  void _showChangelogDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.new_releases_outlined, color: Color(0xFFE5A00D), size: 22),
            SizedBox(width: 8),
            Text(
              '版本更新说明',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: AppVersion.changelog.map((item) {
                final ver = item['version']?.toString() ?? '';
                final date = item['date']?.toString() ?? '';
                final notes = (item['notes'] as List?) ?? const [];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5A00D).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFE5A00D), width: 0.8),
                            ),
                            child: Text(
                              'v$ver',
                              style: const TextStyle(
                                color: Color(0xFFE5A00D),
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            date,
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...notes.map(
                        (n) => Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('• ', style: TextStyle(color: Color(0xFFE5A00D), fontSize: 13)),
                              Expanded(
                                child: Text(
                                  n.toString(),
                                  style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('关闭', style: TextStyle(color: _themeService.accentColor)),
          ),
        ],
      ),
    );
  }

  void _showDanmakuServerDialog() {
    _danmakuUrlController.text = _danmakuConfig.serverUrl;
    bool isTesting = false;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2028),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('弹幕服务地址', style: TextStyle(color: Colors.white, fontSize: 16)),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _danmakuUrlController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '请输入弹幕服务地址 (如 https://dm.example.com)',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFF262832),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () {
                            _danmakuUrlController.clear();
                          },
                          child: const Text('恢复默认', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ),
                        TextButton.icon(
                          onPressed: isTesting
                              ? null
                              : () async {
                                  setDialogState(() => isTesting = true);
                                  final ok = await _danmakuService.testConnection(_danmakuUrlController.text);
                                  if (dCtx.mounted) {
                                    setDialogState(() => isTesting = false);
                                  }
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(ok ? '✅ 弹幕服务连接成功' : '❌ 无法连接到该弹幕服务'),
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                          icon: isTesting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                                )
                              : const Icon(Icons.network_check, size: 16, color: Colors.white70),
                          label: const Text('测试连接', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(color: Colors.white54)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _themeService.accentColor,
                    foregroundColor: _themeService.accentColor.computeLuminance() > 0.6 ? Colors.black : Colors.white,
                  ),
                  onPressed: () async {
                    final raw = _danmakuUrlController.text.trim().replaceAll(RegExp(r'/+$'), '');
                    final nextUrl = raw;
                    _danmakuConfig.serverUrl = nextUrl;
                    await _danmakuService.saveConfig(_danmakuConfig);
                    if (mounted) {
                      setState(() {});
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text('已保存弹幕服务地址'),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSettingsItemCard({
    required String title,
    required String value,
    required VoidCallback onTap,
    List<Widget> rightActions = const [],
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x66336B61),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        onTap: onTap,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
        subtitle: value.isNotEmpty
            ? Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              )
            : null,
        trailing: rightActions.isNotEmpty
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: rightActions,
              )
            : null,
      ),
    );
  }

  Widget _buildSimpleCard(String title, {required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x66336B61),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        onTap: onTap,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
      ),
    );
  }

  Widget _buildSettingsValueCard(String title, String value, {VoidCallback? onTap}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x66336B61),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        onTap: onTap,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
        trailing: Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }
}

