import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../global/storage_bridge.dart';
import '../../models/live_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/live_service.dart';
import '../../services/pip_and_media_session_service.dart';
import '../../services/app_logger.dart';
import '../detail/widgets/player_track_dialogs.dart';
import '../widgets/tv_focusable.dart';

/// 电视直播播放器视图（对齐点播播放器体验：支持全功能控制栏、换台/换源面板、画中画、软硬解、音视轨、手势调节与断网重连）
class LiveView extends StatefulWidget {
  final SiteRepository repository;

  const LiveView({super.key, required this.repository});

  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  Player? _player;
  VideoController? _videoController;

  List<LiveGroup> _groups = [];
  bool _isLoading = true;
  String? _errorMsg;
  String? _playErrorMsg;

  int _selectedGroupIndex = 0;
  int _selectedChannelIndex = 0;
  int _selectedLineIndex = 0;

  bool _showChannelList = false;
  bool _showOverlay = false;
  bool _showOsd = false;
  bool _isPlaying = true;
  bool _isLocked = false;
  bool _isBuffering = false;
  bool _isHardwareDecode = true;

  String _fitName = '原始';
  BoxFit _videoFit = BoxFit.contain;
  double? _customAspectRatio;
  double _videoScale = 1.0;
  double _baseVideoScale = 1.0;
  bool _isPinching = false;

  int? _videoWidth;
  int? _videoHeight;
  String _currentPlayUrl = '';

  double _currentVolume = 100.0;
  double _currentBrightness = 0.5;
  double _dragStartBrightness = 0.5;
  double _dragStartVolume = 100.0;
  bool _brightnessAdjusted = false;

  void _applyBrightness(double value) {
    _brightnessAdjusted = true;
    if (Platform.isAndroid) {
      const MethodChannel('com.example.ftv/downloader')
          .invokeMethod('setScreenBrightness', {'brightness': value})
          .catchError((_) {});
    }
  }
  double _dragStartX = 0.0;
  double _dragStartY = 0.0;
  String _panMode = 'none';

  bool _showGestureHud = false;
  IconData _gestureHudIcon = Icons.info_outline;
  String _gestureHudText = '';
  Timer? _gestureHudTimer;

  String _networkSpeedStr = '0 KB/s';
  Timer? _speedTimer;
  int _lastRxBytes = -1;
  DateTime _lastRxTime = DateTime.now();

  StreamSubscription? _bufferingSub;
  StreamSubscription? _playSub;
  StreamSubscription? _widthSub;
  StreamSubscription? _heightSub;
  StreamSubscription? _errorSub;

  Timer? _osdTimer;
  Timer? _overlayTimer;
  Timer? _reconnectTimer;

  final FocusNode _pageFocusNode = FocusNode();

  static const List<Map<String, dynamic>> _fitOptions = [
    {'label': '原始', 'fit': BoxFit.contain, 'aspectRatio': null},
    {'label': '裁剪', 'fit': BoxFit.cover, 'aspectRatio': null},
    {'label': '填充', 'fit': BoxFit.fill, 'aspectRatio': null},
    {'label': '16:9', 'fit': BoxFit.fill, 'aspectRatio': 16.0 / 9.0},
    {'label': '4:3', 'fit': BoxFit.fill, 'aspectRatio': 4.0 / 3.0},
  ];

  LiveChannel? get _currentChannel {
    if (_groups.isEmpty || _selectedGroupIndex >= _groups.length) return null;
    final group = _groups[_selectedGroupIndex];
    if (group.channels.isEmpty || _selectedChannelIndex >= group.channels.length) return null;
    return group.channels[_selectedChannelIndex];
  }

  @override
  void initState() {
    super.initState();
    AppLogger.hideGlobalDebugFabNotifier.value = true;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    PipAndMediaSessionService().isInPipNotifier.addListener(_onPipChanged);
    _loadPrefsAndInit();
  }

  Future<void> _loadPrefsAndInit() async {
    try {
      final dec = await StorageBridge.getValue('player_decode');
      if (dec != null && dec.isNotEmpty) {
        _isHardwareDecode = dec != '软解';
      }
    } catch (_) {}
    _initPlayer();
    _loadLiveChannels();
  }

  @override
  void dispose() {
    AppLogger.hideGlobalDebugFabNotifier.value = false;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _osdTimer?.cancel();
    _overlayTimer?.cancel();
    _gestureHudTimer?.cancel();
    if (Platform.isAndroid && _brightnessAdjusted) {
      const MethodChannel('com.example.ftv/downloader')
          .invokeMethod('setScreenBrightness', {'brightness': -1.0})
          .catchError((_) {});
    }
    _reconnectTimer?.cancel();
    _pageFocusNode.dispose();
    _bufferingSub?.cancel();
    _playSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _errorSub?.cancel();
    _speedTimer?.cancel();
    PipAndMediaSessionService().isInPipNotifier.removeListener(_onPipChanged);
    _player?.dispose();
    super.dispose();
  }

  void _initPlayer() {
    _player = Player();
    _videoController = VideoController(_player!);

    try {
      final platform = _player!.platform as dynamic;
      platform?.setProperty(
        'hwdec',
        _isHardwareDecode ? (Platform.isAndroid ? 'mediacodec,mediacodec-copy,auto' : 'auto') : 'no',
      );
      platform?.setProperty('cache', 'yes');
      platform?.setProperty('cache-on-disk', 'no');
      platform?.setProperty(
        'demuxer-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,http_persistent=1',
      );
      platform?.setProperty('vd-lavc-threads', '0');
    } catch (_) {}

    _bufferingSub = _player!.stream.buffering.listen((buffering) {
      if (mounted && _isBuffering != buffering) {
        setState(() => _isBuffering = buffering);
      }
    });

    _playSub = _player!.stream.playing.listen((playing) {
      if (mounted && _isPlaying != playing) {
        setState(() => _isPlaying = playing);
      }
    });

    _widthSub = _player!.stream.width.listen((w) {
      if (mounted && w != null && w > 0) {
        setState(() => _videoWidth = w);
      }
    });

    _heightSub = _player!.stream.height.listen((h) {
      if (mounted && h != null && h > 0) {
        setState(() => _videoHeight = h);
      }
    });

    _errorSub = _player!.stream.error.listen((err) {
      if (!mounted || err.isEmpty) return;
      final lower = err.toLowerCase();
      final isNonFatal = lower.contains('buffer') ||
          lower.contains('cache') ||
          lower.contains('seek') ||
          lower.contains('subtitle') ||
          lower.contains('audiotrack') ||
          lower.contains('wasapi') ||
          lower.contains('swscale') ||
          lower.contains('deprecated') ||
          lower.contains('corrupt') ||
          lower.contains('no frame');
      final isFatalOpen = lower.contains('failed to open') ||
          lower.contains('403') ||
          lower.contains('404') ||
          lower.contains('401');
      if (isNonFatal || ((_isBuffering || _isPlaying) && !isFatalOpen)) {
        return;
      }
      setState(() => _playErrorMsg = '直播加载失败，网络恢复后自动重连...\n$err');
      _scheduleAutoReconnect();
    });

    _lastRxBytes = -1;
    _lastRxTime = DateTime.now();
    const speedChannel = MethodChannel('com.example.ftv/downloader');

    _speedTimer = Timer.periodic(const Duration(milliseconds: 800), (t) async {
      if (!mounted || _player == null) {
        t.cancel();
        return;
      }
      if (_isBuffering) {
        double bps = 0;
        try {
          final res = await (_player!.platform as dynamic)?.getProperty('demuxer-cache-speed');
          if (res != null) bps = double.tryParse(res.toString()) ?? 0;
        } catch (_) {}

        if (bps <= 0) {
          try {
            final stateRes = await (_player!.platform as dynamic)?.getProperty('demuxer-cache-state');
            if (stateRes != null) {
              final parsed = stateRes is Map ? stateRes : jsonDecode(stateRes.toString());
              if (parsed is Map) {
                final rawRate = parsed['raw-input-rate'] ?? parsed['cache-speed'];
                if (rawRate != null) bps = double.tryParse(rawRate.toString()) ?? 0;
              }
            }
          } catch (_) {}
        }

        if (Platform.isAndroid) {
          try {
            final curRx = await speedChannel.invokeMethod<int>('getUidRxBytes') ?? 0;
            final now = DateTime.now();
            if (curRx > 0 && _lastRxBytes > 0 && curRx >= _lastRxBytes) {
              final elapsedSec = now.difference(_lastRxTime).inMilliseconds / 1000.0;
              if (elapsedSec > 0.1) {
                final sysBps = (curRx - _lastRxBytes) / elapsedSec;
                if (bps <= 0 || sysBps > bps) bps = sysBps;
              }
            }
            if (curRx > 0) {
              _lastRxBytes = curRx;
              _lastRxTime = now;
            }
          } catch (_) {}
        }

        final speedStr = bps >= 1024 * 1024
            ? '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s'
            : bps > 0
                ? '${(bps / 1024).toInt()} KB/s'
                : '0 KB/s';
        if (mounted && _networkSpeedStr != speedStr) {
          setState(() => _networkSpeedStr = speedStr);
        }
      } else {
        _lastRxBytes = -1;
      }
    });
  }

  void _scheduleAutoReconnect() {
    if (_reconnectTimer?.isActive == true || _currentPlayUrl.isEmpty) return;
    int attempts = 0;
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      attempts++;
      if (!mounted || _playErrorMsg == null || attempts > 30) {
        t.cancel();
        return;
      }
      try {
        final uri = Uri.tryParse(_currentPlayUrl);
        final host = (uri != null && uri.host.isNotEmpty) ? uri.host : '223.5.5.5';
        final addrs = await InternetAddress.lookup(host).timeout(const Duration(seconds: 2));
        if (addrs.isNotEmpty && mounted) {
          t.cancel();
          _playCurrentChannel();
        }
      } catch (_) {}
    });
  }

  Future<void> _loadLiveChannels() async {
    setState(() => _isLoading = true);
    try {
      final groups = await widget.repository.fetchLives();
      if (groups.isNotEmpty) {
        setState(() {
          _groups = groups;
          _isLoading = false;
          _selectedGroupIndex = 0;
          _selectedChannelIndex = 0;
          _selectedLineIndex = 0;
        });
        _playCurrentChannel();
      } else {
        setState(() {
          _isLoading = false;
          _errorMsg = '未检索到可用的直播频道列表';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMsg = '加载直播数据异常: $e';
      });
    }
  }

  void _playCurrentChannel() {
    final channel = _currentChannel;
    if (channel == null || channel.urls.isEmpty) return;

    _reconnectTimer?.cancel();
    final rawUrl = channel.urls[_selectedLineIndex % channel.urls.length];
    final cleanUrl = LiveService.sanitizeStreamUrl(rawUrl);
    _currentPlayUrl = cleanUrl;
    setState(() {
      _playErrorMsg = null;
      _isBuffering = true;
    });
    print('📺 正在播放直播: [${channel.name}] 线路 ${_selectedLineIndex + 1} -> $cleanUrl');

    try {
      _player?.open(Media(cleanUrl));
      _showOsdBriefly();
    } catch (e) {
      print('播放直播流发生错误: $e');
    }
  }

  void _onPipChanged() {
    if (!mounted) return;
    if (PipAndMediaSessionService().isInPipNotifier.value) {
      setState(() {
        _showOverlay = false;
        _showOsd = false;
        _showChannelList = false;
      });
    } else {
      setState(() {});
    }
  }

  void _showOsdBriefly() {
    _osdTimer?.cancel();
    setState(() => _showOsd = true);
    _osdTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showOsd = false);
    });
  }

  void _startOverlayTimer() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _showOverlay) {
        setState(() => _showOverlay = false);
      }
    });
  }

  void _toggleOverlay() {
    if (_showChannelList) {
      setState(() => _showChannelList = false);
      return;
    }
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _startOverlayTimer();
  }

  void _showHud(IconData icon, String text) {
    _gestureHudTimer?.cancel();
    setState(() {
      _gestureHudIcon = icon;
      _gestureHudText = text;
      _showGestureHud = true;
    });
    _gestureHudTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _showGestureHud = false);
    });
  }

  void _toggleHardwareDecode() {
    final targetHw = !_isHardwareDecode;
    setState(() => _isHardwareDecode = targetHw);
    try {
      (_player?.platform as dynamic)?.setProperty(
        'hwdec',
        targetHw ? (Platform.isAndroid ? 'mediacodec,mediacodec-copy,auto' : 'auto') : 'no',
      );
    } catch (_) {}
    _showHud(Icons.memory, targetHw ? '已切换至硬解' : '已切换至软解');
  }

  void _cycleNextFit() {
    final curIdx = _fitOptions.indexWhere((o) => o['label'] == _fitName);
    final next = _fitOptions[(curIdx + 1) % _fitOptions.length];
    setState(() {
      _fitName = next['label'] as String;
      _videoFit = next['fit'] as BoxFit;
      _customAspectRatio = next['aspectRatio'] as double?;
    });
    _showHud(Icons.aspect_ratio, '画面比例: $_fitName');
    _startOverlayTimer();
  }

  void _showLinePickerDialog() {
    final channel = _currentChannel;
    if (channel == null || channel.urls.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFFF3EFF6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 340, maxHeight: 360),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: channel.urls.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, idx) {
                final isSel = idx == (_selectedLineIndex % channel.urls.length);
                return InkWell(
                  onTap: () {
                    setState(() => _selectedLineIndex = idx);
                    Navigator.pop(ctx);
                    _playCurrentChannel();
                  },
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isSel ? const Color(0xFF1E88E5) : const Color(0xFF888888),
                        width: 1.1,
                      ),
                    ),
                    child: Text(
                      '线路 ${idx + 1}',
                      style: TextStyle(
                        color: isSel ? const Color(0xFF1E88E5) : const Color(0xFF222222),
                        fontSize: 15,
                        fontWeight: isSel ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _switchChannel(int delta) {
    if (_groups.isEmpty) return;
    final currentGroup = _groups[_selectedGroupIndex];
    if (currentGroup.channels.isEmpty) return;

    int nextIndex = _selectedChannelIndex + delta;
    if (nextIndex < 0) {
      int prevGroup = _selectedGroupIndex - 1;
      if (prevGroup < 0) prevGroup = _groups.length - 1;
      setState(() {
        _selectedGroupIndex = prevGroup;
        _selectedChannelIndex = _groups[prevGroup].channels.length - 1;
        _selectedLineIndex = 0;
      });
    } else if (nextIndex >= currentGroup.channels.length) {
      int nextGroup = (_selectedGroupIndex + 1) % _groups.length;
      setState(() {
        _selectedGroupIndex = nextGroup;
        _selectedChannelIndex = 0;
        _selectedLineIndex = 0;
      });
    } else {
      setState(() {
        _selectedChannelIndex = nextIndex;
        _selectedLineIndex = 0;
      });
    }
    _playCurrentChannel();
  }

  void _switchLine(int delta) {
    final channel = _currentChannel;
    if (channel == null || channel.urls.isEmpty) return;
    setState(() {
      _selectedLineIndex = (_selectedLineIndex + delta) % channel.urls.length;
      if (_selectedLineIndex < 0) _selectedLineIndex += channel.urls.length;
    });
    _playCurrentChannel();
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (details.pointerCount >= 2 && !_isLocked) {
      _isPinching = true;
      _baseVideoScale = _videoScale;
      _panMode = 'none';
    _dragStartBrightness = _currentBrightness;
    _dragStartVolume = _currentVolume;
      return;
    }
    _isPinching = false;
    _dragStartX = details.localFocalPoint.dx;
    _dragStartY = details.localFocalPoint.dy;
    _panMode = 'none';
  }

  void _onScaleUpdate(ScaleUpdateDetails details, BoxConstraints constraints) {
    if (details.pointerCount >= 2) {
      if (!_isLocked) {
        if (!_isPinching) {
          _isPinching = true;
          _baseVideoScale = _videoScale;
          _panMode = 'none';
        }
        setState(() {
          _videoScale = (_baseVideoScale * details.scale).clamp(0.7, 4.0);
        });
      }
      return;
    }
    if (_isPinching) return;

    final dx = details.localFocalPoint.dx - _dragStartX;
    final dy = details.localFocalPoint.dy - _dragStartY;

    if (_panMode == 'none') {
      if (dx.abs() > 10 || dy.abs() > 10) {
        if (dy.abs() > dx.abs()) {
          _panMode = _dragStartX < constraints.maxWidth * 0.5 ? 'brightness' : 'volume';
        } else {
          _panMode = 'channel';
        }
      } else {
        return;
      }
    }

    if (_panMode == 'brightness') {
      final delta = -dy / constraints.maxHeight;
      setState(() {
        _currentBrightness = (_dragStartBrightness + delta * 1.2).clamp(0.01, 1.0);
      });
      _applyBrightness(_currentBrightness);
      _showHud(Icons.brightness_6, '亮度: ${(_currentBrightness * 100).toInt()}%');
    } else if (_panMode == 'volume') {
      final delta = -dy / constraints.maxHeight;
      _currentVolume = (_dragStartVolume + delta * 120.0).clamp(0.0, 100.0);
      _player?.setVolume(_currentVolume);
      _showHud(Icons.volume_up, '音量: ${_currentVolume.toInt()}%');
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _isPinching = false;
    _panMode = 'none';
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_showChannelList) {
      if (event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.backspace) {
        setState(() => _showChannelList = false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _switchChannel(1);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _switchLine(-1);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _switchLine(1);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      setState(() => _showChannelList = !_showChannelList);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Widget _buildBottomPill(String text, VoidCallback onTap, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: () {
          _startOverlayTimer();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            text,
            style: TextStyle(
              color: highlight ? const Color(0xFFE5A00D) : Colors.white,
              fontSize: 13.5,
              fontWeight: highlight ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    if (PipAndMediaSessionService().isInPipNotifier.value) {
      return const SizedBox.shrink();
    }
    final channel = _currentChannel;
    final resText = (_videoWidth != null && _videoHeight != null)
        ? '$_videoWidth x $_videoHeight'
        : '直播流';
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.black87, Colors.transparent, Colors.transparent, Colors.black87],
          stops: [0.0, 0.22, 0.75, 1.0],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        children: [
          // 1. 顶部栏：返回 + 频道名/分辨率 + 投屏/详情/时间
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(20),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            channel?.name ?? '电视直播',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            resText,
                            style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cast, color: Colors.white, size: 20),
                      tooltip: '投屏',
                      onPressed: () => showCastDialog(
                        context: context,
                        currentPlayUrl: _currentPlayUrl,
                        vodDetail: null,
                        currentEpisodeName: channel?.name ?? '直播',
                        onShowHud: _showHud,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.info_outline, color: Colors.white, size: 20),
                      tooltip: '直播流详情',
                      onPressed: () => showPlayLinkDetailDialog(
                        context: context,
                        vodDetail: null,
                        currentEpisodeName: channel?.name ?? '直播',
                        currentPlayUrl: _currentPlayUrl,
                        currentHeaders: const {},
                        videoWidth: _videoWidth,
                        videoHeight: _videoHeight,
                        onShowHud: _showHud,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        timeStr,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 2. 中心播放控制：上一台 / 播放暂停 / 下一台
          if (!_isLocked)
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    iconSize: 36,
                    icon: const Icon(Icons.skip_previous, color: Colors.white),
                    onPressed: () => _switchChannel(-1),
                  ),
                  const SizedBox(width: 28),
                  Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                                border: _isBuffering ? null : Border.all(color: Colors.white24),
                              ),
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                iconSize: 46,
                                icon: Icon(
                                  _isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
                                ),
                                onPressed: () => _player?.playOrPause(),
                              ),
                            ),
                            if (_isBuffering)
                              const Positioned.fill(
                                child: IgnorePointer(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_isBuffering)
                        Positioned(
                          top: 72,
                          child: Text(
                            _networkSpeedStr,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              shadows: [Shadow(offset: Offset(0, 1), blurRadius: 4, color: Colors.black87)],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 28),
                  IconButton(
                    iconSize: 36,
                    icon: const Icon(Icons.skip_next, color: Colors.white),
                    onPressed: () => _switchChannel(1),
                  ),
                ],
              ),
            ),

          // 3. 右侧控制：锁定 + 进入画中画
          Positioned(
            right: 16,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      _isLocked ? Icons.lock : Icons.lock_open,
                      color: _isLocked ? const Color(0xFFE5A00D) : Colors.white,
                    ),
                    tooltip: _isLocked ? '点击解锁' : '点击锁定',
                    onPressed: () {
                      setState(() => _isLocked = !_isLocked);
                      _startOverlayTimer();
                    },
                  ),
                  if (Platform.isAndroid && !_isLocked) ...[
                    const SizedBox(height: 10),
                    IconButton(
                      icon: const Icon(Icons.picture_in_picture_alt_outlined, color: Colors.white, size: 22),
                      tooltip: '进入画中画',
                      onPressed: () {
                        PipAndMediaSessionService().enterPip(
                          numerator: (_videoWidth != null && _videoWidth! > 0) ? _videoWidth! : 16,
                          denominator: (_videoHeight != null && _videoHeight! > 0) ? _videoHeight! : 9,
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),

          // 4. 底部功能胶囊栏
          if (!_isLocked)
            Positioned(
              left: 16,
              right: 16,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildBottomPill('频道', () {
                          setState(() {
                            _showOverlay = false;
                            _showChannelList = true;
                          });
                        }),
                        _buildBottomPill('MPV', () {}),
                        _buildBottomPill(
                          _isHardwareDecode ? '硬解' : '软解',
                          _toggleHardwareDecode,
                          highlight: _isHardwareDecode,
                        ),
                        _buildBottomPill(_fitName, _cycleNextFit),
                        _buildBottomPill(
                          '线路 ${(_selectedLineIndex % max(1, channel?.urls.length ?? 1)) + 1}',
                          _showLinePickerDialog,
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildBottomPill('刷新', _playCurrentChannel),
                        _buildBottomPill('音轨', () => showAudioTrackDialog(
                          context: context,
                          player: _player,
                          onShowHud: _showHud,
                        )),
                        _buildBottomPill('视轨', () => showVideoTrackDialog(
                          context: context,
                          player: _player,
                          videoWidth: _videoWidth,
                          videoHeight: _videoHeight,
                          onShowHud: _showHud,
                        )),
                        _buildBottomPill('换台', () {
                          setState(() {
                            _showOverlay = false;
                            _showChannelList = true;
                          });
                        }, highlight: true),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFE5A00D)),
              const SizedBox(height: 16),
              const Text('正在加载电视频道列表...', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back, color: Colors.grey),
                label: const Text('返回', style: TextStyle(color: Colors.grey)),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMsg != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.live_tv_outlined, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_errorMsg!, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    onPressed: _loadLiveChannels,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      },
      child: Focus(
        focusNode: _pageFocusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (_videoController != null)
                    Center(
                      child: Transform.scale(
                        scale: _videoScale,
                        child: _customAspectRatio != null
                            ? AspectRatio(
                                aspectRatio: _customAspectRatio!,
                                child: Video(
                                  controller: _videoController!,
                                  fit: _videoFit,
                                  controls: NoVideoControls,
                                ),
                              )
                            : Video(
                                controller: _videoController!,
                                fit: _videoFit,
                                controls: NoVideoControls,
                              ),
                      ),
                    ),

                  if (_playErrorMsg != null)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 48),
                            const SizedBox(height: 10),
                            Text(
                              _playErrorMsg!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 13.5),
                            ),
                          ],
                        ),
                      ),
                    ),

                  if (!Platform.isAndroid && _brightnessAdjusted)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withOpacity(
                            ((1.0 - _currentBrightness) * 0.72).clamp(0.0, 0.72),
                          ),
                        ),
                      ),
                    ),

                  // 统一手势层（包裹控制栏，控件显隐时均支持亮度/音量调节）
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        if (_isLocked) {
                          _toggleOverlay();
                          return;
                        }
                        if (_showChannelList) {
                          setState(() => _showChannelList = false);
                          return;
                        }
                        if (details.localPosition.dx < constraints.maxWidth * 0.5) {
                          setState(() {
                            _showChannelList = true;
                            _showOverlay = false;
                          });
                          _overlayTimer?.cancel();
                        } else {
                          _toggleOverlay();
                        }
                      },
                      onDoubleTap: () {
                        if (!_isLocked) _player?.playOrPause();
                      },
                      onScaleStart: (d) {
                        if (!_isLocked) _onScaleStart(d);
                      },
                      onScaleUpdate: (d) {
                        if (!_isLocked) _onScaleUpdate(d, constraints);
                      },
                      onScaleEnd: (d) {
                        if (!_isLocked) _onScaleEnd(d);
                      },
                      child: _showOverlay
                          ? _buildControlsOverlay()
                          : const ColoredBox(color: Colors.transparent),
                    ),
                  ),

                  if (_isBuffering && _playErrorMsg == null && (!_showOverlay || _isLocked))
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _networkSpeedStr,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              shadows: [Shadow(offset: Offset(0, 1), blurRadius: 4, color: Colors.black87)],
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (_showGestureHud)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5A00D), width: 1.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_gestureHudIcon, color: const Color(0xFFE5A00D), size: 24),
                            const SizedBox(width: 10),
                            Text(
                              _gestureHudText,
                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 换台 OSD 提示条
                  if (_showOsd && _currentChannel != null)
                    Positioned(
                      top: 24,
                      right: 24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.85),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE5A00D), width: 1.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE5A00D),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${_selectedChannelIndex + 1}'.padLeft(2, '0'),
                                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _currentChannel!.name,
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white38),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '线路 ${_selectedLineIndex + 1}/${_currentChannel!.urls.length}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 频道抽屉面板
                  if (_showChannelList)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 380,
                      child: GestureDetector(
                        onTap: () {},
                        child: Container(
                          color: const Color(0xEE12141C),
                          child: Row(
                            children: [
                              Container(
                                width: 120,
                                color: Colors.black38,
                                child: ListView.builder(
                                  itemCount: _groups.length,
                                  itemBuilder: (context, idx) {
                                    final grp = _groups[idx];
                                    final isSel = idx == _selectedGroupIndex;
                                    return TvFocusable(
                                      onPressed: () {
                                        setState(() {
                                          _selectedGroupIndex = idx;
                                          _selectedChannelIndex = 0;
                                          _selectedLineIndex = 0;
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
                                        color: isSel ? const Color(0xFFE5A00D).withOpacity(0.2) : Colors.transparent,
                                        child: Text(
                                          grp.name,
                                          style: TextStyle(
                                            color: isSel ? const Color(0xFFE5A00D) : Colors.white70,
                                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: _groups[_selectedGroupIndex].channels.length,
                                  itemBuilder: (context, idx) {
                                    final ch = _groups[_selectedGroupIndex].channels[idx];
                                    final isCurrent = idx == _selectedChannelIndex;
                                    return TvFocusable(
                                      onPressed: () {
                                        setState(() {
                                          _selectedChannelIndex = idx;
                                          _selectedLineIndex = 0;
                                          _showChannelList = false;
                                        });
                                        _playCurrentChannel();
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: isCurrent ? const Color(0xFFE5A00D).withOpacity(0.18) : Colors.white10,
                                          borderRadius: BorderRadius.circular(6),
                                          border: isCurrent
                                              ? Border.all(color: const Color(0xFFE5A00D), width: 1.2)
                                              : null,
                                        ),
                                        child: Row(
                                          children: [
                                            Text(
                                              '${idx + 1}'.padLeft(2, '0'),
                                              style: TextStyle(
                                                color: isCurrent ? const Color(0xFFE5A00D) : Colors.grey,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                ch.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isCurrent ? Colors.white : Colors.white70,
                                                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                                ),
                                              ),
                                            ),
                                            if (ch.urls.length > 1)
                                              Text(
                                                '${ch.urls.length}线',
                                                style: const TextStyle(color: Colors.white38, fontSize: 10),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
