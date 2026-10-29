import 'package:flutter/material.dart';
import '../../models/config_model.dart';
import '../../models/site_model.dart';
import '../../models/danmaku_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/danmaku_service.dart';
import '../../services/theme_service.dart';
import '../../global/storage_bridge.dart';
import '../widgets/tv_focusable.dart';

class SettingsView extends StatefulWidget {
  final SiteRepository repository;

  const SettingsView({super.key, required this.repository});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
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

  @override
  void initState() {
    super.initState();
    _configUrlController = TextEditingController(text: widget.repository.configBaseUrl);
    _danmakuUrlController = TextEditingController(text: _danmakuService.config.serverUrl);
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
    _initData();
  }

  @override
  void dispose() {
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

  Future<void> _pickLocalPackageZip() async {
    setState(() {
      _isLoading = true;
      _loadingMessage = '正在选择并解压本地包...';
    });

    try {
      final result = await widget.repository.configService.pickAndLoadConfig();
      if (result != null) {
        await widget.repository.loadConfig(
          result.effectiveBaseUrl,
          result.suggestedName,
          result.type,
        );
        _configUrlController.text = result.effectiveBaseUrl;
        await _loadHistory();
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showConfigEditDialog({required String title, required String currentUrl, required Function(String) onSave}) {
    final controller = TextEditingController(text: currentUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            hintText: '输入 http:// 或 file:// 路径',
            hintStyle: TextStyle(color: Colors.grey),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _themeService.accentColor),
            onPressed: () {
              Navigator.pop(ctx);
              onSave(controller.text.trim());
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
        decoration: BoxDecoration(
          gradient: _themeService.currentGradient,
        ),
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
                      tooltip: '导入本地离线包 (.zip)',
                      onPressed: _pickLocalPackageZip,
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
                      value: currentUrl.isNotEmpty ? currentUrl : 'file://Download/config.json',
                      onTap: () => _showConfigEditDialog(
                        title: '编辑点播配置地址',
                        currentUrl: currentUrl,
                        onSave: (url) => _handleReloadConfig(url),
                      ),
                      rightActions: [
                        IconButton(
                          icon: const Icon(Icons.home_outlined, color: Colors.white, size: 22),
                          tooltip: '重置为默认',
                          onPressed: () => _handleReloadConfig('D:/code/ok影视js源/my/src/config.json'),
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
                      value: currentUrl.isNotEmpty ? currentUrl : 'file://Download/config.json',
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

                    // 10. 版本
                    _buildSettingsValueCard('版本', '5.1.6'),
                    const SizedBox(height: 12),

                    // 11. 关于
                    _buildSettingsValueCard('关于', 'mobile-arm64_v8a'),
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

/// 播放设置子页 (严格复刻参考图 4)
class PlaybackSettingsPage extends StatefulWidget {
  final ThemeService themeService;

  const PlaybackSettingsPage({super.key, required this.themeService});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  String core = 'EXO';
  String decode = '硬解';
  String render = 'Surface';
  String scale = '原始';
  String subtitleStyle = '预设';
  String danmakuLoad = '开启';
  String simPlay = '开启';
  String bgPlay = '画中画';
  String linePlay = '全自动';
  String tunnelMode = '关闭';
  String aacPriority = '关闭';
  String bufferTime = '15 倍';
  String userAgent = '系统默认';

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final savedBg = await StorageBridge.getValue('player_bg_play');
      if (savedBg != null && savedBg.isNotEmpty) bgPlay = savedBg;

      final savedSim = await StorageBridge.getValue('player_sim_play');
      if (savedSim != null && savedSim.isNotEmpty) simPlay = savedSim;

      final savedUa = await StorageBridge.getValue('player_ua');
      if (savedUa != null && savedUa.isNotEmpty) userAgent = savedUa;

      final savedBuffer = await StorageBridge.getValue('player_buffer_time');
      if (savedBuffer != null && savedBuffer.isNotEmpty) bufferTime = savedBuffer;

      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _showBgPlayDialog() {
    final options = ['画中画 (默认)', '开启', '关闭'];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('后台播放设置', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((opt) {
            final isSel = bgPlay == opt || (bgPlay == '画中画' && opt.contains('画中画'));
            return ListTile(
              title: Text(opt, style: TextStyle(color: isSel ? widget.themeService.accentColor : Colors.white)),
              trailing: isSel ? Icon(Icons.check, color: widget.themeService.accentColor) : null,
              onTap: () async {
                final clean = opt.replaceAll(' (默认)', '');
                setState(() => bgPlay = clean);
                await StorageBridge.setValue('player_bg_play', clean);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showUaDialog() {
    final presets = [
      {'name': '系统默认', 'ua': '系统默认'},
      {'name': '移动端 (Android)', 'ua': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120.0 Mobile'},
      {'name': '电视端 (FongMi TV)', 'ua': 'okhttp/4.9.0'},
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('User-Agent 设置', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: presets.map((item) {
            final isSel = userAgent == item['name'];
            return ListTile(
              title: Text(item['name']!, style: TextStyle(color: isSel ? widget.themeService.accentColor : Colors.white)),
              subtitle: Text(item['ua']!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 11)),
              trailing: isSel ? Icon(Icons.check, color: widget.themeService.accentColor) : null,
              onTap: () async {
                setState(() => userAgent = item['name']!);
                await StorageBridge.setValue('player_ua', item['name']!);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showBufferTimeDialog() {
    final options = ['5 倍', '10 倍', '15 倍 (默认)', '20 倍', '30 倍'];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('缓冲时间设置', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((opt) {
            final isSel = bufferTime == opt || (bufferTime == '15 倍' && opt.contains('默认'));
            return ListTile(
              title: Text(opt, style: TextStyle(color: isSel ? widget.themeService.accentColor : Colors.white)),
              trailing: isSel ? Icon(Icons.check, color: widget.themeService.accentColor) : null,
              onTap: () async {
                final clean = opt.replaceAll(' (默认)', '');
                setState(() => bufferTime = clean);
                await StorageBridge.setValue('player_buffer_time', clean);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(gradient: widget.themeService.currentGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    const Text('播放设置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    _buildItem('播放核心', core, () => setState(() => core = core == 'EXO' ? 'MPV' : 'EXO')),
                    _buildItem('解码方式', decode, () => setState(() => decode = decode == '硬解' ? '软解' : '硬解')),
                    _buildItem('渲染方式', render, () => setState(() => render = render == 'Surface' ? 'Texture' : 'Surface')),
                    _buildItem('缩放比例', scale, () => setState(() => scale = scale == '原始' ? '16:9' : scale == '16:9' ? '4:3' : '原始')),
                    _buildItem('字幕样式', subtitleStyle, () {}),
                    _buildItem('弹幕加载', danmakuLoad, () => setState(() => danmakuLoad = danmakuLoad == '开启' ? '关闭' : '开启')),
                    _buildItem('同时播放', simPlay, () async {
                      final next = simPlay == '开启' ? '关闭' : '开启';
                      setState(() => simPlay = next);
                      await StorageBridge.setValue('player_sim_play', next);
                    }),
                    _buildItem('后台播放', bgPlay, _showBgPlayDialog),
                    _buildItem('User-Agent', userAgent, _showUaDialog),
                    _buildItem('线路播放', linePlay, () => setState(() => linePlay = linePlay == '全自动' ? '优先低延迟' : '全自动')),
                    _buildItem('隧道模式', tunnelMode, () => setState(() => tunnelMode = tunnelMode == '关闭' ? '开启' : '关闭')),
                    _buildItem('AAC优先', aacPriority, () => setState(() => aacPriority = aacPriority == '关闭' ? '开启' : '关闭')),
                    _buildItem('缓冲时间', bufferTime, _showBufferTimeDialog),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(String title, String val, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0x66336B61),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
        trailing: Text(val, style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
    );
  }
}

/// 个性设置子页 (严格复刻参考图 5)
class PersonalSettingsPage extends StatefulWidget {
  final ThemeService themeService;

  const PersonalSettingsPage({super.key, required this.themeService});

  @override
  State<PersonalSettingsPage> createState() => _PersonalSettingsPageState();
}

class _PersonalSettingsPageState extends State<PersonalSettingsPage> {
  String picSize = '大';
  String playRate = '1.00';
  String longPressRate = '3.00';
  String incognito = '关闭';
  String multiSearch = '关闭';
  String showSource = '开启';
  String sourceSearch = '开启';
  String aiAdBlock = '开启';
  String localDownload = '关闭';
  String lang = '简体中文';
  String debugMode = '开启';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(gradient: widget.themeService.currentGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    const Text('个性设置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    _buildItem('图片尺寸', picSize, () => setState(() => picSize = picSize == '大' ? '中' : '大')),
                    _buildItem('播放倍速', playRate, () => setState(() => playRate = playRate == '1.00' ? '1.25' : '1.00')),
                    _buildItem('长按倍速', longPressRate, () => setState(() => longPressRate = longPressRate == '3.00' ? '2.00' : '3.00')),
                    _buildItem('无痕模式', incognito, () => setState(() => incognito = incognito == '关闭' ? '开启' : '关闭')),
                    _buildItem('聚合搜索', multiSearch, () => setState(() => multiSearch = multiSearch == '关闭' ? '开启' : '关闭')),
                    _buildItem('显示站源', showSource, () => setState(() => showSource = showSource == '开启' ? '关闭' : '开启')),
                    _buildItem('站源搜索', sourceSearch, () => setState(() => sourceSearch = sourceSearch == '开启' ? '关闭' : '开启')),
                    _buildItem('AI去广告', aiAdBlock, () => setState(() => aiAdBlock = aiAdBlock == '开启' ? '关闭' : '开启')),
                    _buildItem('内置下载', localDownload, () => setState(() => localDownload = localDownload == '关闭' ? '开启' : '关闭')),
                    _buildItem('语言设置', lang, () {}),
                    _buildItem('调试模式', debugMode, () => setState(() => debugMode = debugMode == '开启' ? '关闭' : '开启')),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0x66336B61),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        onTap: () {},
                        title: const Text('重置App', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(String title, String val, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0x66336B61),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
        trailing: Text(val, style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
    );
  }
}

/// 备份恢复子页 (严格复刻参考图 6)
class BackupRestorePage extends StatefulWidget {
  final ThemeService themeService;

  const BackupRestorePage({super.key, required this.themeService});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  String mode = '手动';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(gradient: widget.themeService.currentGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    const Text('备份恢复', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0x66336B61),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        onTap: () => setState(() => mode = mode == '手动' ? '自动' : '手动'),
                        title: const Text('备份模式', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                        trailing: Text(mode, style: const TextStyle(color: Colors.white, fontSize: 15)),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0x66336B61),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        onTap: () {},
                        title: const Text('恢复', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0x66336B61),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        onTap: () {},
                        title: const Text('备份', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}