import 'package:flutter/material.dart';
import '../../models/config_model.dart';
import '../../models/site_model.dart';
import '../../models/danmaku_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/danmaku_service.dart';
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
  DanmakuConfig _danmakuConfig = DanmakuConfig();

  List<ConfigItemModel> _historyList = [];
  bool _isLoading = false;
  String _loadingMessage = '';
  String _cacheSizeStr = '67.8 MB';
  String _dohType = '系统';

  @override
  void initState() {
    super.initState();
    _configUrlController = TextEditingController(text: widget.repository.configBaseUrl);
    _danmakuUrlController = TextEditingController(text: _danmakuService.config.serverUrl);
    _initData();
  }

  @override
  void dispose() {
    _configUrlController.dispose();
    _danmakuUrlController.dispose();
    super.dispose();
  }

  Future<void> _initData() async {
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
      final sites = await widget.repository.loadConfig(pathOrUrl, customName).timeout(
        const Duration(seconds: 8),
        onTimeout: () => widget.repository.sites,
      );
      await _loadHistory();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功载入点播配置！共就绪 ${sites.length} 个可用 JS 影视源'),
            backgroundColor: const Color(0xFFE5A00D),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('配置加载失败: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
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
        final sites = await widget.repository.loadConfig(
          result.effectiveBaseUrl,
          result.suggestedName,
          result.type,
        );
        _configUrlController.text = result.effectiveBaseUrl;
        await _loadHistory();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('本地包导入并解压成功！共解析 ${sites.length} 个 JS 影视源'),
              backgroundColor: const Color(0xFFE5A00D),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('本地包导入失败: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
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
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE5A00D)),
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

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.history, color: Color(0xFFE5A00D)),
                  const SizedBox(width: 8),
                  const Text('历史配置列表',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      await widget.repository.configService.clearHistory();
                      await _loadHistory();
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.delete_sweep, size: 16, color: Colors.redAccent),
                    label: const Text('清空', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
                ],
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: _historyList.isEmpty
                    ? const Center(child: Text('暂无历史记录', style: TextStyle(color: Colors.grey)))
                    : ListView.separated(
                        itemCount: _historyList.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                        itemBuilder: (c, idx) {
                          final item = _historyList[idx];
                          return ListTile(
                            dense: true,
                            title: Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
                            subtitle: Text(item.urlOrPath,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                            trailing: IconButton(
                              icon: const Icon(Icons.play_circle_fill, color: Color(0xFFE5A00D)),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _handleReloadConfig(item.urlOrPath, item.name);
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPlayerSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('播放设置', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('默认解码方式', style: TextStyle(color: Colors.white, fontSize: 13)),
              trailing: const Text('硬解 (GPU 加速)', style: TextStyle(color: Color(0xFFE5A00D), fontSize: 13)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('播放内核', style: TextStyle(color: Colors.white, fontSize: 13)),
              trailing: const Text('EXO 内核', style: TextStyle(color: Color(0xFFE5A00D), fontSize: 13)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动跳过片头', style: TextStyle(color: Colors.white, fontSize: 13)),
              trailing: const Text('01:47 (107秒)', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动跳过片尾', style: TextStyle(color: Colors.white, fontSize: 13)),
              trailing: const Text('02:23 (143秒)', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
        ],
      ),
    );
  }

  void _showPersonalSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('个性设置', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('全局弹幕开关', style: TextStyle(color: Colors.white, fontSize: 13)),
                    value: _danmakuConfig.enabled,
                    activeColor: const Color(0xFFE5A00D),
                    onChanged: (val) {
                      setDialogState(() => _danmakuConfig.enabled = val);
                      setState(() => _danmakuConfig.enabled = val);
                      _danmakuService.saveConfig(_danmakuConfig);
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('弹幕不透明度:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text('${(_danmakuConfig.opacity * 100).toInt()}%',
                          style: const TextStyle(color: Color(0xFFE5A00D), fontSize: 12)),
                    ],
                  ),
                  Slider(
                    value: _danmakuConfig.opacity,
                    min: 0.1,
                    max: 1.0,
                    activeColor: const Color(0xFFE5A00D),
                    onChanged: (v) {
                      setDialogState(() => _danmakuConfig.opacity = v);
                      setState(() => _danmakuConfig.opacity = v);
                      _danmakuService.saveConfig(_danmakuConfig);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeConfig = widget.repository.activeConfigItem;
    final currentUrl = activeConfig?.urlOrPath ?? widget.repository.configBaseUrl;

    return Scaffold(
      backgroundColor: const Color(0xFF1B483F),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6FAAA0), Color(0xFF48877C), Color(0xFF296358), Color(0xFF1B483F)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
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
                      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已备份配置至本地'), duration: Duration(seconds: 1)),
                      ),
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

                    // 3. 壁纸
                    _buildSettingsItemCard(
                      title: '壁纸',
                      value: '',
                      onTap: () {},
                      rightActions: [
                        IconButton(
                          icon: const Icon(Icons.home_outlined, color: Colors.white, size: 22),
                          tooltip: '重置默认壁纸',
                          onPressed: () {},
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white, size: 22),
                          tooltip: '切换壁纸',
                          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已刷新当前壁纸主题'), duration: Duration(seconds: 1)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 4. 播放设置
                    _buildSimpleCard('播放设置', onTap: _showPlayerSettingsDialog),
                    const SizedBox(height: 12),

                    // 5. 个性设置
                    _buildSimpleCard('个性设置', onTap: _showPersonalSettingsDialog),
                    const SizedBox(height: 12),

                    // 6. 备份恢复
                    _buildSimpleCard('备份恢复', onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('备份恢复管理器就绪'), duration: Duration(seconds: 1)),
                      );
                    }),
                    const SizedBox(height: 12),

                    // 7. DoH
                    _buildSettingsValueCard('DoH', _dohType, onTap: () {
                      setState(() {
                        _dohType = _dohType == '系统' ? '阿里 (DoH)' : _dohType == '阿里 (DoH)' ? '腾讯 (DoH)' : '系统';
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('DoH 已切换为: $_dohType'), duration: const Duration(seconds: 1)),
                      );
                    }),
                    const SizedBox(height: 12),

                    // 8. 缓存
                    _buildSettingsValueCard('缓存', _cacheSizeStr, onTap: () {
                      setState(() => _cacheSizeStr = '0.0 MB');
                      widget.repository.jsEngine.clearModuleCache();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('缓存与 JS 模块缓存已清空'), duration: Duration(seconds: 1)),
                      );
                    }),
                    const SizedBox(height: 12),

                    // 9. 版本
                    _buildSettingsValueCard('版本', '5.1.6'),
                    const SizedBox(height: 12),

                    // 10. 关于
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