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
  bool _isTestingDanmaku = false;

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
      _loadingMessage = '正在解析与装载点播配置...';
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

  Future<void> _saveDanmakuSettings() async {
    final text = _danmakuUrlController.text.trim();
    _danmakuConfig.serverUrl = text.isEmpty ? DanmakuConfig.defaultServerUrl : text;
    _danmakuUrlController.text = _danmakuConfig.serverUrl;
    await _danmakuService.saveConfig(_danmakuConfig);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('弹幕配置已保存！'),
          backgroundColor: Color(0xFFE5A00D),
        ),
      );
    }
  }

  Future<void> _testDanmakuServer() async {
    setState(() => _isTestingDanmaku = true);
    final url = _danmakuUrlController.text.trim();
    final ok = await _danmakuService.testConnection(url);
    if (mounted) {
      setState(() => _isTestingDanmaku = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '✅ 弹幕服务器连接正常！' : '❌ 无法连接到该弹幕服务器'),
          backgroundColor: ok ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _resetDanmakuServerToDefault() {
    _danmakuUrlController.text = DanmakuConfig.defaultServerUrl;
    _saveDanmakuSettings();
  }

  @override
  Widget build(BuildContext context) {
    final activeSite = widget.repository.activeSite;
    final activeConfig = widget.repository.activeConfigItem;

    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181A22),
        title: const Text('设置', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFFE5A00D)),
            tooltip: '重新加载当前源',
            onPressed: _isLoading ? null : () => _handleReloadConfig(),
          ),
        ],
      ),
      body: _isLoading
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFFE5A00D)),
            const SizedBox(height: 16),
            Text(_loadingMessage, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
      )
          : ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildCurrentConfigCard(activeSite, activeConfig),
          const SizedBox(height: 16),
          _buildConfigImportCard(),
          const SizedBox(height: 16),
          if (_historyList.isNotEmpty) ...[
            _buildHistoryConfigCard(),
            const SizedBox(height: 16),
          ],
          _buildDanmakuSettingsCard(),
          const SizedBox(height: 16),
          _buildStorageCleanupCard(),
        ],
      ),
    );
  }

  Widget _buildCurrentConfigCard(SiteModel? activeSite, ConfigItemModel? activeConfig) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF181A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5A00D).withOpacity(0.4), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Color(0xFFE5A00D), size: 20),
              const SizedBox(width: 8),
              Text(
                activeConfig?.name ?? '当前激活点播源',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFFE5A00D)),
              ),
              const Spacer(),
              if (activeConfig != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5A00D),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    activeConfig.typeLabel,
                    style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          const Divider(height: 18, color: Colors.white12),
          SelectableText(
            '地址: ${widget.repository.configBaseUrl.isEmpty ? "未配置" : widget.repository.configBaseUrl}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '已就绪 JS 站源: ${widget.repository.sites.length} 个',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '当前主站: ${activeSite?.name ?? "未选择"}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Color(0xFFE5A00D)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConfigImportCard() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF181A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.link, size: 20, color: Color(0xFFE5A00D)),
              SizedBox(width: 8),
              Text('配置源管理', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _configUrlController,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              labelText: '配置链接 / 本地绝对路径',
              hintText: 'http://... 或 file:///...',
              prefixIcon: const Icon(Icons.edit_note, color: Color(0xFFE5A00D)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                onPressed: () => _configUrlController.clear(),
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TvFocusable(
                  onPressed: _isLoading ? null : _pickLocalPackageZip,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE5A00D),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _isLoading ? null : _pickLocalPackageZip,
                    icon: const Icon(Icons.folder_zip, color: Colors.black, size: 18),
                    label: const Text('导入本地包 (.zip)', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TvFocusable(
                  onPressed: _isLoading ? null : () => _handleReloadConfig(),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF262832),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _isLoading ? null : () => _handleReloadConfig(),
                    icon: const Icon(Icons.play_circle_outline, color: Color(0xFFE5A00D), size: 18),
                    label: const Text('加载此配置', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryConfigCard() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF181A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 20, color: Color(0xFFE5A00D)),
              const SizedBox(width: 8),
              const Text('历史配置源', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await widget.repository.configService.clearHistory();
                  await _loadHistory();
                },
                icon: const Icon(Icons.delete_sweep, size: 16, color: Colors.redAccent),
                label: const Text('清空历史', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _historyList.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
            itemBuilder: (context, idx) {
              final item = _historyList[idx];
              final isCurrent = item.isActive || item.urlOrPath == widget.repository.configBaseUrl;

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                leading: CircleAvatar(
                  backgroundColor: isCurrent ? const Color(0xFFE5A00D) : const Color(0xFF262832),
                  child: Icon(
                    item.type == ConfigType.localFile ? Icons.folder : Icons.cloud,
                    color: isCurrent ? Colors.black : Colors.white70,
                    size: 18,
                  ),
                ),
                title: Text(
                  item.name,
                  style: TextStyle(
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    color: isCurrent ? const Color(0xFFE5A00D) : Colors.white,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  item.urlOrPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
                onTap: () => _handleReloadConfig(item.urlOrPath, item.name),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 4. LogVar 弹幕配置专区
  Widget _buildDanmakuSettingsCard() {
    final areas = [
      {'label': '¼ 屏', 'val': 0.25},
      {'label': '半 屏', 'val': 0.5},
      {'label': '¾ 屏', 'val': 0.75},
      {'label': '满 屏', 'val': 1.0},
    ];

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF181A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.subtitles, size: 20, color: Color(0xFFE5A00D)),
              const SizedBox(width: 8),
              const Text('弹幕设置 (LogVar)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
              const Spacer(),
              Switch(
                value: _danmakuConfig.enabled,
                activeColor: const Color(0xFFE5A00D),
                onChanged: (val) {
                  setState(() => _danmakuConfig.enabled = val);
                  _saveDanmakuSettings();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _danmakuUrlController,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'LogVar 弹幕服务器',
              hintText: DanmakuConfig.defaultServerUrl,
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _resetDanmakuServerToDefault,
                    child: const Text('恢复默认', style: TextStyle(color: Colors.grey, fontSize: 11)),
                  ),
                  IconButton(
                    icon: _isTestingDanmaku
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.speed, color: Color(0xFFE5A00D), size: 18),
                    tooltip: '测试服务器连接',
                    onPressed: _isTestingDanmaku ? null : _testDanmakuServer,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // 显示区域选择
          Row(
            children: [
              const Text('显示区域: ', style: TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: areas.map((a) {
                    final isSel = (_danmakuConfig.displayArea - (a['val'] as double)).abs() < 0.05;
                    return ChoiceChip(
                      selected: isSel,
                      selectedColor: const Color(0xFFE5A00D),
                      label: Text(
                        a['label'] as String,
                        style: TextStyle(
                          color: isSel ? Colors.black : Colors.white70,
                          fontSize: 11,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onSelected: (val) {
                        if (val) {
                          setState(() => _danmakuConfig.displayArea = a['val'] as double);
                          _saveDanmakuSettings();
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('不透明度: ${(_danmakuConfig.opacity * 100).toInt()}%', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    Slider(
                      value: _danmakuConfig.opacity,
                      min: 0.1,
                      max: 1.0,
                      activeColor: const Color(0xFFE5A00D),
                      onChanged: (v) {
                        setState(() => _danmakuConfig.opacity = v);
                        _saveDanmakuSettings();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('字号大小: ${_danmakuConfig.fontSize.toInt()} px', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    Slider(
                      value: _danmakuConfig.fontSize,
                      min: 12,
                      max: 32,
                      activeColor: const Color(0xFFE5A00D),
                      onChanged: (v) {
                        setState(() => _danmakuConfig.fontSize = v);
                        _saveDanmakuSettings();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('滚动速度: ${_danmakuConfig.speed.toStringAsFixed(1)} 秒', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    Slider(
                      value: _danmakuConfig.speed,
                      min: 3.0,
                      max: 12.0,
                      activeColor: const Color(0xFFE5A00D),
                      onChanged: (v) {
                        setState(() => _danmakuConfig.speed = v);
                        _saveDanmakuSettings();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    const Text('文字描边加黑: ', style: TextStyle(fontSize: 12, color: Colors.white70)),
                    Switch(
                      value: _danmakuConfig.showStroke,
                      activeColor: const Color(0xFFE5A00D),
                      onChanged: (v) {
                        setState(() => _danmakuConfig.showStroke = v);
                        _saveDanmakuSettings();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStorageCleanupCard() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF181A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cleaning_services, size: 20, color: Color(0xFFE5A00D)),
              SizedBox(width: 8),
              Text('通用与存储', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TvFocusable(
                  onPressed: () async {
                    await StorageBridge.init();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ 缓存数据已成功清理'), backgroundColor: Color(0xFFE5A00D)),
                      );
                    }
                  },
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      await StorageBridge.init();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('✅ 缓存数据已成功清理'), backgroundColor: Color(0xFFE5A00D)),
                        );
                      }
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('清理播放缓存与存储'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              'FTV (OK 影视 / FongMi 原生规范) v1.0.0',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}