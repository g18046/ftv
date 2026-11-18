import 'package:flutter/material.dart';
import '../../global/storage_bridge.dart';
import '../../models/subtitle_model.dart';
import '../../services/danmaku_service.dart';
import '../../services/pip_and_media_session_service.dart';
import '../../services/theme_service.dart';
import '../detail/widgets/subtitle_settings_dialog.dart';

/// 播放设置子页 (严格复刻参考图 4)
class PlaybackSettingsPage extends StatefulWidget {
  final ThemeService themeService;

  const PlaybackSettingsPage({super.key, required this.themeService});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  String core = 'MPV';
  String decode = '硬解';
  String render = 'Surface';
  String scale = '原始';
  String subtitleStyle = '自定义';
  String danmakuLoad = '开启';
  SubtitleConfig _subtitleConfig = SubtitleConfig();
  final DanmakuService _danmakuService = DanmakuService();
  String simPlay = '开启';
  String bgPlay = '开启'; // 默认退后台继续播放声音、不进画中画，由用户在此显式选择
  String linePlay = '全自动';
  String tunnelMode = '关闭';
  String aacPriority = '关闭';
  String bufferTime = '1 倍';
  String userAgent = '系统默认';
  String longPressSpeed = '3.0x'; // 默认长按 3 倍速播放

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final dmConf = await _danmakuService.initConfig();
      danmakuLoad = dmConf.enabled ? '开启' : '关闭';
      _subtitleConfig = await SubtitleConfig.load();
      subtitleStyle = '${_subtitleConfig.fontSize.toInt()}pt';

      final savedCore = await StorageBridge.getValue('player_core');
      if (savedCore != null && savedCore.isNotEmpty) core = savedCore;

      final savedDecode = await StorageBridge.getValue('player_decode');
      if (savedDecode != null && savedDecode.isNotEmpty) decode = savedDecode;

      final savedRender = await StorageBridge.getValue('player_render');
      if (savedRender != null && savedRender.isNotEmpty) render = savedRender;

      final savedScale = await StorageBridge.getValue('player_scale');
      if (savedScale != null && savedScale.isNotEmpty) scale = savedScale;

      final savedLine = await StorageBridge.getValue('player_line_play');
      if (savedLine != null && savedLine.isNotEmpty) linePlay = savedLine;

      final savedTunnel = await StorageBridge.getValue('player_tunnel_mode');
      if (savedTunnel != null && savedTunnel.isNotEmpty) tunnelMode = savedTunnel;

      final savedAac = await StorageBridge.getValue('player_aac_priority');
      if (savedAac != null && savedAac.isNotEmpty) aacPriority = savedAac;

      final savedBg = await StorageBridge.getValue('player_bg_play');
      if (savedBg != null && savedBg.isNotEmpty) bgPlay = savedBg;

      final savedSim = await StorageBridge.getValue('player_sim_play');
      if (savedSim != null && savedSim.isNotEmpty) simPlay = savedSim;

      final savedUa = await StorageBridge.getValue('player_ua');
      if (savedUa != null && savedUa.isNotEmpty) userAgent = savedUa;

      final savedBuffer = await StorageBridge.getValue('player_buffer_time');
      if (savedBuffer != null && savedBuffer.isNotEmpty) bufferTime = savedBuffer;

      final savedSpeed = await StorageBridge.getValue('player_long_press_speed');
      if (savedSpeed != null && savedSpeed.isNotEmpty) longPressSpeed = savedSpeed;

      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _showBgPlayDialog() {
    final options = ['开启', '关闭', '画中画'];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('后台播放设置', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((opt) {
            final isSel = bgPlay == opt;
            return ListTile(
              title: Text(opt, style: TextStyle(color: isSel ? widget.themeService.accentColor : Colors.white)),
              trailing: isSel ? Icon(Icons.check, color: widget.themeService.accentColor) : null,
              onTap: () async {
                setState(() => bgPlay = opt);
                await StorageBridge.setValue('player_bg_play', opt);
                // 立即同步系统级「上划自动进入画中画」，关闭时撤销残留开关
                await PipAndMediaSessionService().enableAutoPip(
                  enabled: opt == '画中画',
                  numerator: 16,
                  denominator: 9,
                  keepOnResume: opt == '画中画',
                );
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

  void _showLongPressSpeedDialog() {
    final options = ['2.0x', '2.5x', '3.0x (默认)', '4.0x', '5.0x', '关闭'];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('长按倍速设置', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((opt) {
            final isSel = longPressSpeed == opt || (longPressSpeed == '3.0x' && opt.contains('默认'));
            return ListTile(
              title: Text(opt, style: TextStyle(color: isSel ? widget.themeService.accentColor : Colors.white)),
              trailing: isSel ? Icon(Icons.check, color: widget.themeService.accentColor) : null,
              onTap: () async {
                final clean = opt.replaceAll(' (默认)', '');
                setState(() => longPressSpeed = clean);
                await StorageBridge.setValue('player_long_press_speed', clean);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showBufferTimeDialog() {
    double currentVal = 1.0;
    final match = RegExp(r'(\d+)').firstMatch(bufferTime);
    if (match != null) {
      currentVal = double.tryParse(match.group(1)!) ?? 1.0;
    }
    currentVal = currentVal.clamp(1.0, 30.0);

    showDialog(
      context: context,
      builder: (ctx) {
        double tempVal = currentVal;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFEBEAEF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: const Text(
                '缓冲时间',
                style: TextStyle(
                  color: Color(0xFF1E1E1E),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 12.0,
                        activeTrackColor: const Color(0xFF1E88E5),
                        inactiveTrackColor: const Color(0xFFD6E4F0),
                        thumbColor: const Color(0xFF1E88E5),
                        overlayColor: Colors.transparent,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10.0),
                        trackShape: const RoundedRectSliderTrackShape(),
                      ),
                      child: Slider(
                        value: tempVal,
                        min: 1.0,
                        max: 30.0,
                        divisions: 29,
                        onChanged: (val) {
                          setDialogState(() => tempVal = val);
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${tempVal.toInt()} 倍 (预缓存约 ${tempVal.toInt() * 4}MB / ${tempVal.toInt() * 5}秒)',
                      style: const TextStyle(color: Color(0xFF555555), fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(color: Color(0xFF1E88E5), fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: () async {
                    final clean = '${tempVal.toInt()} 倍';
                    setState(() => bufferTime = clean);
                    await StorageBridge.setValue('player_buffer_time', clean);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确定', style: TextStyle(color: Color(0xFF1E88E5), fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
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
                    _buildItem('播放核心', core, () async {
                      final next = core == 'MPV' ? 'EXO' : 'MPV';
                      setState(() => core = next);
                      await StorageBridge.setValue('player_core', next);
                    }),
                    _buildItem('解码方式', decode, () async {
                      final next = decode == '硬解' ? '软解' : '硬解';
                      setState(() => decode = next);
                      await StorageBridge.setValue('player_decode', next);
                    }),
                    _buildItem('渲染方式', render, () async {
                      final next = render == 'Surface' ? 'Texture' : 'Surface';
                      setState(() => render = next);
                      await StorageBridge.setValue('player_render', next);
                    }),
                    _buildItem('缩放比例', scale, () async {
                      const scales = ['原始', '16:9', '4:3', '填充', '裁剪'];
                      final idx = scales.indexOf(scale);
                      final next = scales[(idx + 1) % scales.length];
                      setState(() => scale = next);
                      await StorageBridge.setValue('player_scale', next);
                    }),
                    _buildItem('字幕样式', subtitleStyle, () {
                      showSubtitleSettingsDialog(
                        context: context,
                        subtitleConfig: _subtitleConfig,
                        themeService: widget.themeService,
                        onStateChanged: () {
                          if (mounted) {
                            setState(() => subtitleStyle = '${_subtitleConfig.fontSize.toInt()}pt');
                          }
                        },
                      );
                    }),
                    _buildItem('弹幕加载', danmakuLoad, () async {
                      final nextEnabled = danmakuLoad != '开启';
                      setState(() => danmakuLoad = nextEnabled ? '开启' : '关闭');
                      _danmakuService.config.enabled = nextEnabled;
                      await _danmakuService.saveConfig(_danmakuService.config);
                    }),
                    _buildItem('同时播放', simPlay, () async {
                      final next = simPlay == '开启' ? '关闭' : '开启';
                      setState(() => simPlay = next);
                      await StorageBridge.setValue('player_sim_play', next);
                    }),
                    _buildItem('后台播放', bgPlay, _showBgPlayDialog),
                    _buildItem('User-Agent', userAgent, _showUaDialog),
                    _buildItem('线路播放', linePlay, () async {
                      final next = linePlay == '全自动' ? '优先低延迟' : '全自动';
                      setState(() => linePlay = next);
                      await StorageBridge.setValue('player_line_play', next);
                    }),
                    _buildItem('隧道模式', tunnelMode, () async {
                      final next = tunnelMode == '关闭' ? '开启' : '关闭';
                      setState(() => tunnelMode = next);
                      await StorageBridge.setValue('player_tunnel_mode', next);
                    }),
                    _buildItem('AAC优先', aacPriority, () async {
                      final next = aacPriority == '关闭' ? '开启' : '关闭';
                      setState(() => aacPriority = next);
                      await StorageBridge.setValue('player_aac_priority', next);
                    }),
                    _buildItem('长按倍速', longPressSpeed, _showLongPressSpeedDialog),
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

