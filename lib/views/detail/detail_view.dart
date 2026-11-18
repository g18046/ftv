import '../../services/pip_and_media_session_service.dart';
import '../../services/history_favorite_service.dart';
import '../../services/theme_service.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/legacy.dart';
import '../widgets/realtime_battery_time.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import '../../models/vod_model.dart';
import '../../models/danmaku_model.dart';
import '../../models/subtitle_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/danmaku_service.dart';
import '../../services/local_http_server.dart';
import '../../services/iso_parser_service.dart';
import '../../services/app_logger.dart';
import '../../global/storage_bridge.dart';
import '../widgets/danmaku_view.dart';

import 'widgets/bar_slider_thumb_shape.dart';
import 'widgets/danmaku_dialogs.dart';
import 'widgets/detail_info_sections.dart';
import 'widgets/episode_download_sheet.dart';
import 'widgets/episode_list_sheet.dart';
import 'widgets/player_track_dialogs.dart';
import 'widgets/subtitle_settings_dialog.dart';
class DetailView extends StatefulWidget {
  final SiteRepository repository;
  final String vodId;
  final VodItem? vodItem;

  const DetailView({
    super.key,
    required this.repository,
    required this.vodId,
    this.vodItem,
  });

  @override
  State<DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<DetailView> with WidgetsBindingObserver {
  bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool _isTopHovered = false;
  VodItem? _vodDetail;
  bool _isLoading = true;
  int _selectedSourceIndex = 0;
  bool _isReversedOrder = false;

  Player? _player;
  VideoController? _videoController;
  VideoPlayerController? _exoController;
  VoidCallback? _exoListener;
  bool _exoCompletedTriggered = false;
  bool get _isExoActive => _playerCoreName == 'EXO' && Platform.isAndroid;
  bool _isPlayerLoading = false;
  bool _isBuffering = false;
  String _networkSpeedStr = '0 KB/s';
  Timer? _speedTimer;
  int _lastRxBytes = -1;
  DateTime _lastRxTime = DateTime.now();
  StreamSubscription? _bufferingSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _errorSub;
  Timer? _reconnectTimer;
  int _autoReconnectCount = 0;
  Duration? _pendingSeekAfterRefresh;
  Duration _lastValidPosition = Duration.zero;
  String? _playErrorMsg;
  String? _targetSiteKey;
  bool _isAutoSwitchingSite = false;
  final Set<String> _failedSiteKeys = {};
  int _lastSavedHistorySec = -1;
  String _currentEpisodeName = '';
  String _currentPlayUrl = '';
  Map<String, String> _currentHeaders = {};

  bool _isPlaying = false;
  bool _isLocked = false;
  bool _showOverlay = true;
  bool _isLandscape = false;
  bool _isFullscreen = false;
  double _playbackRate = 1.0;
  BoxFit _videoFit = BoxFit.contain;
  double? _customAspectRatio;
  String _fitName = '原始';
  bool _showRightFitDrawer = false;
  final GlobalKey _speedButtonKey = GlobalKey();
  final GlobalKey _fitButtonKey = GlobalKey();
  bool _isFavorited = false;
  bool _isLooping = false;
  String _playerCoreName = 'MPV';
  bool _isHardwareDecode = true; // 硬解 / 软解
  String _dvCorrectionMode = '自动校色'; // 杜比视界校色模式: 自动校色、原生直通、色彩反转校正
  String _bgPlayMode = '开启'; // 后台播放: 关闭、开启、画中画；默认仅后台续播、不自动进画中画，严格以设置页为准
  String _simPlayMode = '开启'; // 同时播放: 开启、关闭
  String _userAgentOption = '系统默认';
  String _bufferTimeOption = '1 倍';
  String _renderModeOption = 'Surface';
  String _linePlayOption = '全自动';
  String _tunnelModeOption = '关闭';
  String _aacPriorityOption = '关闭';

  // 视频分辨率与画质/音效标志
  int? _videoWidth;
  int? _videoHeight;
  int _isoParseSeq = 0;
  String? _badgeResolution;
  String? _badgeHdr;
  String? _badgeAudio;
  String? _badgeIso;
  bool _hasAttemptedDvExoFallback = false;
  String _lastBadgeLogKey = '';

  // 片头片尾跳过秒数 (按当前视频维度独立记忆，不同剧集共享)
  int _skipIntroSeconds = 0;
  int _skipOutroSeconds = 0;
  bool _hasSkippedIntro = false;
  bool _hasSkippedOutro = false;

  static const List<Map<String, dynamic>> _fitOptions = [
    {
      'name': '原始 (适应)',
      'fit': BoxFit.contain,
      'aspectRatio': null,
      'desc': '保持原片宽高比，黑边居中补齐'
    },
    {
      'name': '居中裁切',
      'fit': BoxFit.cover,
      'aspectRatio': null,
      'desc': '裁剪多余黑边，满屏视觉充盈'
    },
    {
      'name': '拉伸铺满',
      'fit': BoxFit.fill,
      'aspectRatio': null,
      'desc': '不留黑边，拉伸画面铺满全屏'
    },
    {
      'name': '16:9 (宽屏)',
      'fit': BoxFit.fill,
      'aspectRatio': 16.0 / 9.0,
      'desc': '强制按 16:9 黄金宽屏比例显示'
    },
    {
      'name': '4:3 (普屏)',
      'fit': BoxFit.fill,
      'aspectRatio': 4.0 / 3.0,
      'desc': '强制按 4:3 经典老剧比例显示'
    },
  ];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;

  Timer? _overlayHideTimer;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _widthSub;
  StreamSubscription? _heightSub;
  StreamSubscription? _trackSub;
  StreamSubscription? _tracksSub;
  StreamSubscription? _danmakuRefreshSub;
  StreamSubscription? _subtitleRefreshSub;

  bool _showGestureHud = false;
  bool _isSeekGestureHud = false;
  IconData _gestureHudIcon = Icons.volume_up;
  String _gestureHudText = '';
  Timer? _gestureHudTimer;

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

  double _seekTargetSeconds = 0.0;
  double _videoScale = 1.0;
  double _baseVideoScale = 1.0;
  bool _isPinching = false;
  double _dragStartX = 0.0;
  double _dragStartY = 0.0;
  bool _isDraggingSeek = false;
  bool _isDraggingLeft = false;
  bool _isDraggingRight = false;
  String _panMode = 'none';

  bool _showRightEpisodeDrawer = false;

  // 弹幕引擎
  final DanmakuService _danmakuService = DanmakuService();
  final ThemeService _themeService = ThemeService();
  final ScrollController _sourceScrollController = ScrollController();
  DanmakuConfig _danmakuConfig = DanmakuConfig();
  SubtitleConfig _subtitleConfig = SubtitleConfig();
  List<DanmakuItem> _danmakus = [];
  bool _isDanmakuLoading = false;
  int? _matchedLogVarEpisodeId;
  String? _matchedAnimeTitle;
  List<LogVarAnimeSource> _cachedAnimeSources = [];
  String _lastDanmakuSearchQuery = '';
  String? _matchedEpisodeTitle;
  String? _matchedDanmakuUrl;
  String _longPressSpeedOption = '3.0x';
  bool _isLongPressingSpeed = false;
  double _preLongPressSpeed = 1.0;

  List<VodItem> _quickSearchResults = [];
  bool _isQuickSearching = false;

  final FocusNode _playerFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final isDesktopInit = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (!isDesktopInit) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _loadPlayerPreferences();
    HistoryFavoriteService().init().then((_) {
      if (mounted && widget.vodId.isNotEmpty) {
        setState(() {
          _isFavorited = HistoryFavoriteService().isFavorite(widget.vodId);
        });
      }
    });
    _initDanmakuConfig();
    _themeService.accentColorNotifier.addListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.addListener(_onThemeChanged);
    PipAndMediaSessionService().isInPipNotifier.addListener(_onPipChanged);
    _listenLocalHttpServerEvents();
    PipAndMediaSessionService().setCallbacks(
      onPlay: _kernelPlay,
      onPause: _kernelPause,
      onPlayPause: _kernelPlayOrPause,
      onNext: _playNextEpisode,
      onPrevious: _playPreviousEpisode,
      onSeekTo: (sec) => _kernelSeek(Duration(seconds: sec)),
    );
    _loadDetailAndAutoPlay();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PipAndMediaSessionService().clear();
    _resetOrientationAndSystemUi();
    _savePlaybackHistory();
    _overlayHideTimer?.cancel();
    AppLogger.hideGlobalDebugFabNotifier.value = false;
    _gestureHudTimer?.cancel();
    if (Platform.isAndroid && _brightnessAdjusted) {
      const MethodChannel('com.example.ftv/downloader')
          .invokeMethod('setScreenBrightness', {'brightness': -1.0})
          .catchError((_) {});
    }
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _completedSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _trackSub?.cancel();
    _tracksSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    _errorSub?.cancel();
    _reconnectTimer?.cancel();
    _speedTimer?.cancel();
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    PipAndMediaSessionService().isInPipNotifier.removeListener(_onPipChanged);
    _sourceScrollController.dispose();
    _danmakuRefreshSub?.cancel();
    _subtitleRefreshSub?.cancel();
    _playerFocusNode.dispose();
    _disposeExoController();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _initDanmakuConfig() async {
    final conf = await _danmakuService.initConfig();
    print('⚙️ [DANMAKU] 配置加载完成: enabled=${conf.enabled}, server="${conf.serverUrl}"');
    if (mounted) {
      setState(() => _danmakuConfig = conf);
    }
  }

  void _listenLocalHttpServerEvents() {
    _danmakuRefreshSub =
        LocalHttpServer().onDanmakuRefresh.listen((pathOrUrl) async {
      print('🔔 收到 JS 源强行刷新弹幕指令: $pathOrUrl');
      final items = await _danmakuService.fetchDanmakuFromUrl(pathOrUrl);
      if (mounted && items.isNotEmpty) {
        setState(() {
          _danmakus = items;
        });
        _showHud(Icons.comment, '💬 JS 源已成功注入 ${items.length} 条弹幕');
      }
    });

    _subtitleRefreshSub =
        LocalHttpServer().onSubtitleRefresh.listen((pathOrUrl) async {
      print('🔔 收到 JS 源强行刷新字幕指令: $pathOrUrl');
      final clean = pathOrUrl.trim();
      if (clean.isEmpty) return;
      if (!_isExoActive && _player != null) {
        try {
          await _player!.setSubtitleTrack(SubtitleTrack.uri(clean));
        } catch (_) {}
      }
      if (mounted) {
        _showHud(Icons.subtitles, '已加载推送字幕: ${clean.split('/').last}');
      }
    });
  }

  String _getVodSkipKey() {
    final raw = (_vodDetail?.vodName.trim().isNotEmpty == true)
        ? _vodDetail!.vodName.trim()
        : (widget.vodItem?.vodName.trim().isNotEmpty == true
            ? widget.vodItem!.vodName.trim()
            : widget.vodId);
    return raw.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5_-]'), '_');
  }

  Future<void> _loadVodSkipTimes() async {
    try {
      final key = _getVodSkipKey();
      final savedIntro = await StorageBridge.getValue('player_skip_intro_$key');
      final savedOutro = await StorageBridge.getValue('player_skip_outro_$key');
      if (mounted) {
        setState(() {
          _skipIntroSeconds = int.tryParse(savedIntro ?? '') ?? 0;
          _skipOutroSeconds = int.tryParse(savedOutro ?? '') ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadPlayerPreferences() async {
    try {
      _subtitleConfig = await SubtitleConfig.load();
      final bg = await StorageBridge.getValue('player_bg_play');
      if (bg != null && bg.isNotEmpty) _bgPlayMode = bg;

      final sim = await StorageBridge.getValue('player_sim_play');
      if (sim != null && sim.isNotEmpty) _simPlayMode = sim;

      final ua = await StorageBridge.getValue('player_ua');
      if (ua != null && ua.isNotEmpty) _userAgentOption = ua;

      final buf = await StorageBridge.getValue('player_buffer_time');
      if (buf != null && buf.isNotEmpty) _bufferTimeOption = buf;

      final core = await StorageBridge.getValue('player_core');
      if (core != null && (core == 'MPV' || (core == 'EXO' && Platform.isAndroid))) {
        _playerCoreName = core;
      }

      final dec = await StorageBridge.getValue('player_decode');
      if (dec != null && dec.isNotEmpty) _isHardwareDecode = (dec != '软解');

      final ren = await StorageBridge.getValue('player_render');
      if (ren != null && ren.isNotEmpty) _renderModeOption = ren;

      final scl = await StorageBridge.getValue('player_scale');
      if (scl != null && scl.isNotEmpty) {
        const mapName = {
          '原始': '原始 (适应)',
          '16:9': '16:9 (宽屏)',
          '4:3': '4:3 (普屏)',
          '填充': '拉伸铺满',
          '裁剪': '居中裁切',
        };
        final targetName = mapName[scl] ?? scl;
        final opt = _fitOptions.firstWhere(
          (o) => o['name'] == targetName,
          orElse: () => _fitOptions.first,
        );
        _fitName = opt['name'];
        _videoFit = opt['fit'];
        _customAspectRatio = opt['aspectRatio'];
      }

      final line = await StorageBridge.getValue('player_line_play');
      if (line != null && line.isNotEmpty) _linePlayOption = line;

      final tunnel = await StorageBridge.getValue('player_tunnel_mode');
      if (tunnel != null && tunnel.isNotEmpty) _tunnelModeOption = tunnel;

      final aac = await StorageBridge.getValue('player_aac_priority');
      if (aac != null && aac.isNotEmpty) _aacPriorityOption = aac;

      await _loadVodSkipTimes();

      final savedSpeed = await StorageBridge.getValue('player_long_press_speed');
      if (savedSpeed != null && savedSpeed.isNotEmpty) {
        _longPressSpeedOption = savedSpeed;
      }

      // 偏好读取完成后同步缓冲倍数与系统级自动画中画开关
      _applyBufferSettings(_bufferTimeOption);
      _syncAutoPip();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // 从画中画 / 后台回到前台：重新读取设置页最新的后台播放开关，避免沿用旧状态
      _refreshBgPlayMode();
      return;
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _syncAutoPip();
      if (_bgPlayMode == '关闭') {
        _kernelPause();
        _syncMediaSession(false);
      } else if (_bgPlayMode == '画中画' && _isPlaying) {
        PipAndMediaSessionService().enterPip(
          numerator: _videoWidth ?? 16,
          denominator: _videoHeight ?? 9,
        );
      }
    }
  }

  /// 依据设置页开关同步系统级「上划自动进入画中画」(Android 12+ setAutoEnterEnabled)
  /// 关闭 / 开启(仅后台音频) 时必须显式下发 false，否则系统开关会一直残留生效
  void _syncAutoPip([bool? overridePlaying]) {
    final playing = overridePlaying ?? _isPlaying;
    final enabled = _bgPlayMode == '画中画' && playing;
    PipAndMediaSessionService().enableAutoPip(
      enabled: enabled,
      numerator: _videoWidth ?? 16,
      denominator: _videoHeight ?? 9,
      keepOnResume: enabled,
    );
  }

  /// 回到前台时刷新后台播放模式（设置页与播放器内设置弹窗共用 player_bg_play）
  Future<void> _refreshBgPlayMode() async {
    try {
      final bg = await StorageBridge.getValue('player_bg_play');
      final next = (bg != null && bg.isNotEmpty) ? bg : '开启';
      if (mounted && next != _bgPlayMode) {
        setState(() => _bgPlayMode = next);
      }
      _syncAutoPip();
    } catch (_) {}
  }

  void _syncMediaSession([bool? overridePlaying]) {
    if (_vodDetail == null) return;
    final playing = overridePlaying ?? _isPlaying;
    PipAndMediaSessionService().updateMediaSession(
      title: _vodDetail!.vodName,
      episode: _currentEpisodeName,
      coverUrl: _vodDetail!.vodPic,
      isPlaying: playing,
      positionSec: _position.inSeconds,
      durationSec: _duration.inSeconds,
    );
    _syncAutoPip(playing);
  }

  /// 更多剧集列表底部弹窗 (严格贴合用户提供的参考图规范)
  void _showEpisodeDownloadSheet() => showEpisodeDownloadSheet(
        context: context,
        vodDetail: _vodDetail,
        selectedSourceIndex: _selectedSourceIndex,
        currentEpisodeName: _currentEpisodeName,
        currentPlayUrl: _currentPlayUrl,
        currentHeaders: _currentHeaders,
        targetSiteKey: _targetSiteKey,
        repository: widget.repository,
        themeService: _themeService,
        onPlayLocalFile: (localPath, epName) {
          setState(() {
            _currentEpisodeName = epName;
            _playErrorMsg = null;
          });
          _initAndStartPlayer(localPath, {});
          _showHud(Icons.offline_pin, '正在播放本地缓存: $epName');
        },
        onShowHud: _showHud,
      );

  void _showEpisodeListBottomSheet() => showEpisodeListBottomSheet(
        context: context,
        vodDetail: _vodDetail,
        selectedSourceIndex: _selectedSourceIndex,
        currentEpisodeName: _currentEpisodeName,
        isReversedOrder: _isReversedOrder,
        onPlayEpisode: _playEpisode,
      );

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _onPipChanged() {
    if (!mounted) return;
    final inPip = PipAndMediaSessionService().isInPipNotifier.value;
    setState(() {
      if (inPip) _showOverlay = false;
    });
  }

  void _resetOrientationAndSystemUi() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 进入全屏播放模式 (默认横屏全屏，也支持竖屏全屏)
  void _enterFullscreen({bool landscape = true}) {
    AppLogger.hideGlobalDebugFabNotifier.value = true;
    setState(() {
      _isFullscreen = true;
      _isLandscape = landscape;
    });
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) {
      windowManager.setFullScreen(true).then((_) {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
      }).catchError((_) {});
    } else if (!isDesktop) {
      if (landscape) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ));
    }
    _startOverlayTimer();
  }

  /// 退出全屏播放，退回竖屏详情小屏
  void _exitFullscreen() {
    AppLogger.hideGlobalDebugFabNotifier.value = false;
    setState(() {
      _isFullscreen = false;
      _isLandscape = false;
      _showRightEpisodeDrawer = false;
      _showRightFitDrawer = false;
    });
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) {
      windowManager.setFullScreen(false).then((_) {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
      }).catchError((_) {});
    } else if (!isDesktop) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted && !_isFullscreen && !_isLocked) {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
      });
    }
    _startOverlayTimer();
  }

  /// 全屏模式下的旋转：在全屏横屏与全屏竖屏之间切换，绝不退回详情小屏！
  void _toggleFullscreenOrientation([bool? toLandscape]) {
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) {
      setState(() => _isFullscreen = !_isFullscreen);
      AppLogger.hideGlobalDebugFabNotifier.value = _isFullscreen;
      return;
    }

    final isDeviceLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final currentIsLand = _isLandscape || isDeviceLandscape;
    final targetLand = toLandscape ?? !currentIsLand;

    setState(() {
      _isLandscape = targetLand;
      _isFullscreen = true; // 牢牢保持全屏模式，绝不退回详情小屏！
    });

    if (targetLand) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _toggleOrientation({bool? forceLandscape, bool? forcePortrait}) {
    if (_isFullscreen) {
      if (forceLandscape == true) {
        _toggleFullscreenOrientation(true);
      } else if (forcePortrait == true) {
        _toggleFullscreenOrientation(false);
      } else {
        _toggleFullscreenOrientation();
      }
    } else {
      if (forceLandscape == true) {
        _enterFullscreen(landscape: true);
      } else if (forcePortrait == true) {
        _exitFullscreen();
      } else {
        _enterFullscreen(landscape: true);
      }
    }
  }

  void _toggleOverlay() {
    if (_isLocked) {
      setState(() => _showOverlay = !_showOverlay);
      if (_showOverlay) _startOverlayTimer();
      return;
    }
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) {
      _startOverlayTimer();
    } else {
      _overlayHideTimer?.cancel();
    }
  }

  void _startOverlayTimer() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying && !_isLocked && !_showRightEpisodeDrawer && !_showRightFitDrawer) {
        setState(() => _showOverlay = false);
      }
    });
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    } else {
      final m = d.inMinutes.toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }
  }

  String _formatSeconds(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String? _resolveTargetSiteKey() {
    final itemKey = widget.vodItem?.siteKey;
    if (itemKey != null && itemKey.isNotEmpty) return itemKey;
    final itemName = widget.vodItem?.siteName;
    if (itemName != null && itemName.isNotEmpty) {
      for (final s in widget.repository.sites) {
        if (s.name == itemName) return s.key;
      }
    }
    return widget.repository.activeSite?.key;
  }

  String _resolveTargetSiteName() {
    final itemName = _vodDetail?.siteName ?? widget.vodItem?.siteName;
    if (itemName != null && itemName.isNotEmpty) return itemName;
    if (_targetSiteKey != null && _targetSiteKey!.isNotEmpty) {
      for (final s in widget.repository.sites) {
        if (s.key == _targetSiteKey) return s.name;
      }
    }
    return widget.repository.activeSite?.name ?? '';
  }

  Future<void> _loadDetailAndAutoPlay() async {
    _targetSiteKey ??= _resolveTargetSiteKey();
    setState(() => _isLoading = true);

    if (widget.vodItem != null && widget.vodItem!.playSources.isNotEmpty) {
      _vodDetail = widget.vodItem;
      _isLoading = false;
      if (mounted) setState(() {});
    } else {
      try {
        final detail = await widget.repository.fetchDetail(widget.vodId, siteKey: _targetSiteKey);
        if (mounted) {
          setState(() {
            _vodDetail = detail;
            _isLoading = false;
            if (detail == null && widget.repository.lastDetailMsg != null) {
              _playErrorMsg = widget.repository.lastDetailMsg;
            }
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _playErrorMsg = '拉取影视详情异常: $e';
          });
        }
        return;
      }
    }

    if (_vodDetail != null) {
      await _loadVodSkipTimes();
    }
    if (_vodDetail != null && _vodDetail!.playSources.isNotEmpty) {
      _isFavorited = HistoryFavoriteService().isFavorite(_vodDetail!.vodId);
      final lastPlay = await HistoryFavoriteService().getLastPlayback(
        _vodDetail!.vodId,
        siteKey: _targetSiteKey,
      );
      int targetSourceIdx = 0;
      if (lastPlay != null && lastPlay['sourceName'] != null) {
        final savedSource = lastPlay['sourceName'].toString();
        if (savedSource.isNotEmpty) {
          final foundIdx = _vodDetail!.playSources.indexWhere((s) => s.name == savedSource);
          if (foundIdx >= 0) targetSourceIdx = foundIdx;
        }
      }
      if (mounted && _selectedSourceIndex != targetSourceIdx) {
        setState(() => _selectedSourceIndex = targetSourceIdx);
      }
      final source = _vodDetail!.playSources[targetSourceIdx];
      if (source.episodes.isNotEmpty) {
        EpisodeItem targetEp = source.episodes.first;
        if (lastPlay != null && lastPlay['episodeName'] != null) {
          final savedEpName = lastPlay['episodeName'].toString();
          targetEp = source.episodes.firstWhere(
            (e) => e.name == savedEpName,
            orElse: () => source.episodes.first,
          );
        }
        _playEpisode(source.name, targetEp);
      }
    }
  }


  Future<void> _tryAutoSwitchChangeableSite() async {
    if (_isAutoSwitchingSite || !mounted) return;
    final vodName = (_vodDetail?.vodName ?? '').trim();
    if (vodName.isEmpty) return;

    final curKey = _targetSiteKey ?? widget.repository.activeSite?.key ?? '';
    if (curKey.isNotEmpty) _failedSiteKeys.add(curKey);

    final candidates = widget.repository.sites.where((s) {
      if (s.key.isEmpty || s.key == 'push_agent') return false;
      if (_failedSiteKeys.contains(s.key)) return false;
      if (s.changeable == 0) return false;
      if (s.searchable == 0) return false;
      return true;
    }).toList();

    if (candidates.isEmpty) return;

    _isAutoSwitchingSite = true;
    _showHud(Icons.sync, '播放失败，正在自动切换支持换源的站点...');

    try {
      for (final site in candidates) {
        if (!mounted) return;
        _failedSiteKeys.add(site.key);
        try {
          final results = await widget.repository.searchVodOnSite(site, vodName);
          if (results.isEmpty) continue;
          final matched = results.firstWhere(
            (r) => r.vodName.trim() == vodName,
            orElse: () => results.first,
          );
          final detail = await widget.repository
              .fetchDetail(matched.vodId, siteKey: site.key);
          if (detail == null || detail.playSources.isEmpty) continue;

          final src = detail.playSources.first;
          if (src.episodes.isEmpty) continue;

          // 尽量匹配当前剧集名称，找不到则按同序号/第一集
          EpisodeItem targetEp = src.episodes.first;
          if (_currentEpisodeName.isNotEmpty) {
            final epMatch = src.episodes.where((e) => e.name == _currentEpisodeName);
            if (epMatch.isNotEmpty) {
              targetEp = epMatch.first;
            }
          }

          if (!mounted) return;
          setState(() {
            _targetSiteKey = site.key;
            _vodDetail = detail;
            _selectedSourceIndex = 0;
            _playErrorMsg = null;
          });
          _showHud(Icons.check_circle_outline, '已自动换源至: ${site.name}');
          await _playEpisode(src.name, targetEp);
          return;
        } catch (_) {}
      }
    } finally {
      _isAutoSwitchingSite = false;
    }
  }

  Future<void> _playEpisode(String flag, EpisodeItem ep) async {
    final isSwitchingEpisode = _currentEpisodeName.isNotEmpty && _currentEpisodeName != ep.name;
    if (_currentEpisodeName.isNotEmpty) {
      await _savePlaybackHistory();
    }

    setState(() {
      _isPlayerLoading = true;
      _playErrorMsg = null;
      _currentEpisodeName = ep.name;
      _position = Duration.zero;
      _duration = Duration.zero;
      _bufferedPosition = Duration.zero;
      _lastValidPosition = Duration.zero;
      _hasSkippedIntro = false;
      _hasSkippedOutro = false;
      _lastSavedHistorySec = -1;
      _videoWidth = null;
      _videoHeight = null;
      _badgeResolution = null;
      _badgeHdr = null;
      _badgeAudio = null;
      _badgeIso = null;
      _hasAttemptedDvExoFallback = false;
      _lastBadgeLogKey = '';
      _danmakus = [];
      _matchedLogVarEpisodeId = null;
    });

    final isLocalMedia = flag == '本地缓存' ||
        ep.url.startsWith('file://') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(ep.url);
    if (isLocalMedia) {
      final localUri = ep.url.startsWith('file://') ? ep.url : Uri.file(ep.url).toString();
      _currentPlayUrl = localUri;
      _initAndStartPlayer(localUri, {}, restoreHistory: !isSwitchingEpisode);
      _fetchLogVarDanmaku();
      return;
    }

    try {
      final res = await widget.repository.fetchPlayInfo(flag, ep.url, siteKey: _targetSiteKey);
      final playUrl = res['url']?.toString() ?? '';
      final playMsg = res['msg']?.toString().trim() ?? '';

      if (playUrl.isNotEmpty) {
        _currentPlayUrl = playUrl;
        _initAndStartPlayer(playUrl, res, restoreHistory: !isSwitchingEpisode);
        _fetchLogVarDanmaku();
      } else {
        setState(() {
          _isPlayerLoading = false;
          _playErrorMsg = playMsg.isNotEmpty ? playMsg : '选集播放地址解析为空';
        });
        _tryAutoSwitchChangeableSite();
      }
    } catch (e) {
      setState(() {
        _isPlayerLoading = false;
        _playErrorMsg = '选集播放解析异常: $e';
      });
    }
  }

  Future<void> _refreshPlayback({Duration? resumePosition}) async {
    if (_vodDetail == null) return;
    _reconnectTimer?.cancel();
    final targetPos = resumePosition ?? (_position.inSeconds > 1 ? _position : _lastValidPosition);
    if (targetPos.inSeconds > 1) {
      _pendingSeekAfterRefresh = targetPos;
    }

    final sources = _vodDetail!.playSources;
    if (sources.isNotEmpty && _selectedSourceIndex < sources.length) {
      final currentEp = sources[_selectedSourceIndex].episodes.firstWhere(
            (e) => e.name == _currentEpisodeName,
            orElse: () => sources[_selectedSourceIndex].episodes.first,
          );
      await _playEpisode(sources[_selectedSourceIndex].name, currentEp);
    }
  }

  void _scheduleAutoReconnect(Duration savedPos) {
    if (_reconnectTimer?.isActive == true ||
        !_currentPlayUrl.startsWith('http') ||
        _autoReconnectCount >= 2) {
      return;
    }
    int attempts = 0;
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      attempts++;
      if (!mounted || _vodDetail == null || _playErrorMsg == null) {
        t.cancel();
        return;
      }
      if (attempts > 30) {
        t.cancel();
        return;
      }
      try {
        final uri = Uri.tryParse(_currentPlayUrl);
        final host = (uri != null && uri.host.isNotEmpty) ? uri.host : '223.5.5.5';
        final addrs = await InternetAddress.lookup(host).timeout(const Duration(seconds: 2));
        if (addrs.isNotEmpty && mounted) {
          t.cancel();
          _autoReconnectCount++;
          debugPrint('🔄 [播放器] 检测到网络已恢复，自动重连继续播放 (位置: ${savedPos.inSeconds}s)');
          await _refreshPlayback(resumePosition: savedPos);
        }
      } catch (_) {}
    });
  }

  void _applyBufferSettings(String bufferOption) {
    if (_player == null) return;
    try {
      final platform = _player!.platform as dynamic;
      int multiplier = 1;
      final match = RegExp(r'(\d+)').firstMatch(bufferOption);
      if (match != null) {
        multiplier = int.tryParse(match.group(1)!) ?? 1;
      }
      multiplier = multiplier.clamp(1, 30);

      final cacheSecs = (multiplier * 15).clamp(15, 300);
      final cacheBytes =
          (multiplier * 16 * 1024 * 1024).clamp(16 * 1024 * 1024, 320 * 1024 * 1024);
      final streamBufBytes =
          (multiplier * 1024 * 1024).clamp(2 * 1024 * 1024, 16 * 1024 * 1024);

      platform?.setProperty('cache', 'yes');
      platform?.setProperty('cache-on-disk', 'no');
      platform?.setProperty('demuxer-max-bytes', cacheBytes.toString());
      platform?.setProperty('demuxer-max-back-bytes', (cacheBytes ~/ 2).toString());
      platform?.setProperty('demuxer-readahead-secs', cacheSecs.toString());
      platform?.setProperty('stream-buffer-size', streamBufBytes.toString());
      platform?.setProperty(
        'demuxer-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,http_persistent=1',
      );
      platform?.setProperty('hls-bitrate', 'max');
      platform?.setProperty('hr-seek', 'yes');
      platform?.setProperty('hr-seek-framedrop', 'yes');
      platform?.setProperty('vd-lavc-threads', '0');
      if (_linePlayOption == '优先低延迟') {
        platform?.setProperty('cache-pause-wait', '0.2');
      } else {
        platform?.setProperty('cache-pause-wait', '1');
      }
      if (_aacPriorityOption == '开启') {
        platform?.setProperty('alang', 'chi,zh,en');
        platform?.setProperty('ad-lavc-downmix', 'yes');
      }
      if (_tunnelModeOption == '开启') {
        platform?.setProperty('audio-spdif', 'ac3,eac3,dts,truehd');
      }
    } catch (_) {}
  }

  void _disposeExoController() {
    final c = _exoController;
    _exoController = null;
    if (c != null) {
      if (_exoListener != null) {
        c.removeListener(_exoListener!);
        _exoListener = null;
      }
      c.dispose();
    }
  }

  void _kernelPlay() {
    if (_isExoActive) {
      _exoController?.play();
    } else {
      _player?.play();
    }
  }

  void _kernelPause() {
    if (_isExoActive) {
      _exoController?.pause();
    } else {
      _player?.pause();
    }
  }

  void _kernelPlayOrPause() {
    if (_isExoActive) {
      final c = _exoController;
      if (c != null && c.value.isInitialized) {
        if (c.value.isPlaying) {
          c.pause();
        } else {
          c.play();
        }
      }
    } else {
      _player?.playOrPause();
    }
  }

  Future<void> _kernelSeek(Duration target) async {
    if (_isExoActive) {
      await _exoController?.seekTo(target);
    } else {
      await _player?.seek(target);
    }
  }

  void _kernelSetRate(double rate) {
    if (_isExoActive) {
      _exoController?.setPlaybackSpeed(rate);
    } else {
      _player?.setRate(rate);
    }
  }

  void _kernelSetVolume(double vol) {
    if (_isExoActive) {
      _exoController?.setVolume((vol / 100.0).clamp(0.0, 1.0));
    } else {
      _player?.setVolume(vol);
    }
  }

  Future<void> _initAndStartExoPlayer(String url, Map<String, String> headers, {bool restoreHistory = true}) async {
    _player?.pause();
    _disposeExoController();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _completedSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    _errorSub?.cancel();
    _speedTimer?.cancel();
    _bufferedPosition = Duration.zero;
    _exoCompletedTriggered = false;

    print('🎬 [PLAYER-EXO] 启动 ExoPlayer: url=$url, headers=${headers.keys.toList()}');
    try {
      final VideoPlayerController controller =
          (url.startsWith('http://') || url.startsWith('https://'))
              ? VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: headers)
              : VideoPlayerController.file(
                  File(url.startsWith('file://') ? Uri.parse(url).toFilePath() : url),
                );

      _exoController = controller;
      _exoListener = () {
        if (!mounted || _exoController != controller) return;
        final val = controller.value;
        if (val.position.inSeconds > 0) _lastValidPosition = val.position;

        final bufEnd = val.buffered.isNotEmpty ? val.buffered.last.end : Duration.zero;
        final w = val.size.width.toInt();
        final h = val.size.height.toInt();

        setState(() {
          _position = val.position;
          _duration = val.duration;
          _isPlaying = val.isPlaying;
          _isBuffering = val.isBuffering;
          if (val.isInitialized && _isPlayerLoading) {
            print('🎬 [PLAYER-EXO] 初始化完成: ${w}x${h}, duration=${val.duration.inSeconds}s');
            Future.microtask(() => _detectMediaBadges(isExo: true));
          }
          if (val.isInitialized) _isPlayerLoading = false;
          _bufferedPosition = bufEnd;
          if (w > 0) _videoWidth = w;
          if (h > 0) _videoHeight = h;
        });

        if (val.position.inSeconds > 0 &&
            val.position.inSeconds % 5 == 0 &&
            val.position.inSeconds != _lastSavedHistorySec) {
          _lastSavedHistorySec = val.position.inSeconds;
          _savePlaybackHistory();
        }

        if (val.hasError && _playErrorMsg == null) {
          print('❌ [PLAYER-EXO] 播放异常: ${val.errorDescription}');
          final savedPos = _position.inSeconds > 1 ? _position : _lastValidPosition;
          setState(() {
            _isPlayerLoading = false;
            _playErrorMsg = 'EXO 播放异常，等待网络恢复后自动续播...\n${val.errorDescription ?? ""}';
          });
          _scheduleAutoReconnect(savedPos);
        }

        if (val.isInitialized &&
            val.duration > Duration.zero &&
            !val.isPlaying &&
            val.position >= val.duration - const Duration(milliseconds: 400) &&
            !_exoCompletedTriggered) {
          _exoCompletedTriggered = true;
          _handlePlaybackCompleted();
        }
      };
      controller.addListener(_exoListener!);

      _lastRxBytes = -1;
      _lastRxTime = DateTime.now();
      const speedChannel = MethodChannel('com.example.ftv/downloader');
      _speedTimer = Timer.periodic(const Duration(milliseconds: 800), (t) async {
        if (!mounted || _exoController != controller) {
          t.cancel();
          return;
        }
        if (_isPlayerLoading || _isBuffering) {
          double bps = 0;
          try {
            final curRx = await speedChannel.invokeMethod<int>('getUidRxBytes') ?? 0;
            final now = DateTime.now();
            if (curRx > 0 && _lastRxBytes > 0 && curRx >= _lastRxBytes) {
              final elapsedSec = now.difference(_lastRxTime).inMilliseconds / 1000.0;
              if (elapsedSec > 0.1) bps = (curRx - _lastRxBytes) / elapsedSec;
            }
            if (curRx > 0) {
              _lastRxBytes = curRx;
              _lastRxTime = now;
            }
          } catch (_) {}
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

      await controller.initialize();
      if (!mounted || _exoController != controller) return;
      await controller.setPlaybackSpeed(_playbackRate);
      await controller.setVolume((_currentVolume / 100.0).clamp(0.0, 1.0));
      await controller.play();

      if (_pendingSeekAfterRefresh != null) {
        final seekTarget = _pendingSeekAfterRefresh!;
        _pendingSeekAfterRefresh = null;
        if (seekTarget.inSeconds > 1) {
          await controller.seekTo(seekTarget);
        }
      } else if (restoreHistory) {
        await _restorePlaybackHistory();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPlayerLoading = false;
          _playErrorMsg = 'EXO 内核加载失败: $e';
        });
      }
    }
  }

  Future<void> _initAndStartPlayer(String url, Map<String, dynamic> playData, {bool restoreHistory = true}) async {
    try {
      dynamic headerObj = playData['header'] ?? playData['headers'] ?? {};
      if (headerObj is String && headerObj.trim().startsWith('{')) {
        try {
          headerObj = jsonDecode(headerObj.trim());
        } catch (_) {}
      }
      final Map<String, String> headers = {};
      if (headerObj is Map) {
        headerObj.forEach((k, v) {
          if (k != null && v != null) {
            final cleanKey = k.toString().replaceAll(RegExp(r'[\r\n]'), '').trim();
            final cleanVal = v.toString().replaceAll(RegExp(r'[\r\n]'), '').trim();
            if (cleanKey.isNotEmpty) headers[cleanKey] = cleanVal;
          }
        });
      }
      _currentHeaders = headers;

      final isIso = IsoParserService.isIsoPathOrUrl(url, episodeName: _currentEpisodeName);
      String effectiveUrl = url;
      Map<String, String> effectiveHeaders = headers;

      if (mounted) {
        setState(() {
          _badgeResolution = null;
          _badgeHdr = null;
          _badgeAudio = null;
          _badgeIso = isIso ? 'ISO' : null;
          _lastBadgeLogKey = '';
        });
      }

      if (isIso) {
        final parseToken = ++_isoParseSeq;
        print('💿 [PLAYER-ISO] 检测到 ISO 镜像，开始解析 UDF/ISO9660 目录结构: $url');
        final isoResult = await IsoParserService.parse(url, headers: headers);
        if (!mounted || parseToken != _isoParseSeq) return;
        if (isoResult != null) {
          final virtualUrl = LocalHttpServer().registerIsoStreamProxy(
            isoResult.primaryEntry,
            url,
            headers,
            discType: isoResult.discType,
          );
          final discLabel = isoResult.discType == 'BDMV'
              ? '蓝光ISO'
              : (isoResult.discType == 'DVD' ? 'DVD ISO' : 'ISO');
          final sizeMb = (isoResult.primaryEntry.totalSize / (1024 * 1024)).toStringAsFixed(1);
          print('💿 [PLAYER-ISO] 解析成功: 类型=$discLabel, 主视频=${isoResult.primaryEntry.name}, 大小=${sizeMb}MB, 分片=${isoResult.primaryEntry.extents.length}');
          effectiveUrl = virtualUrl;
          effectiveHeaders = {};
          if (mounted) setState(() => _badgeIso = discLabel);
        } else {
          print('⚠️ [PLAYER-ISO] UDF/ISO9660 解析未命中，回退直连尝试: $url');
        }
      }

      if (_isExoActive && !isIso) {
        _initAndStartExoPlayer(effectiveUrl, effectiveHeaders, restoreHistory: restoreHistory);
        Future.microtask(() => _detectMediaBadges(isExo: true));
        return;
      }
      if (isIso && _isExoActive) {
        print('💿 [PLAYER-ISO] ISO 镜像自动使用 MPV 内核解码播放');
      }
      _disposeExoController();
      _player ??= Player();
      debugPrint('🎬 [播放器] 准备打开流: $effectiveUrl | headers: $effectiveHeaders');

      _videoController ??= VideoController(
        _player!,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: _renderModeOption != 'Texture',
        ),
      );

      _posSub?.cancel();
      _durSub?.cancel();
      _playSub?.cancel();
      _widthSub?.cancel();
      _heightSub?.cancel();
      _trackSub?.cancel();
      _tracksSub?.cancel();
      _bufferingSub?.cancel();
      _bufferSub?.cancel();
      _bufferedPosition = Duration.zero;
      _errorSub?.cancel();
      _reconnectTimer?.cancel();
      _speedTimer?.cancel();

      _bufferingSub = _player!.stream.buffering.listen((buffering) {
        if (mounted && _isBuffering != buffering) {
          setState(() => _isBuffering = buffering);
        }
      });

      _bufferSub = _player!.stream.buffer.listen((buf) {
        if (mounted && (buf - _bufferedPosition).abs().inMilliseconds >= 300) {
          setState(() => _bufferedPosition = buf);
        }
      });

      _lastRxBytes = -1;
      _lastRxTime = DateTime.now();
      const speedChannel = MethodChannel('com.example.ftv/downloader');

      _speedTimer = Timer.periodic(const Duration(milliseconds: 800), (t) async {
        if (!mounted || _player == null) {
          t.cancel();
          return;
        }
        if (_isPlayerLoading || _isBuffering) {
          double bps = 0;
          try {
            final res = await (_player!.platform as dynamic)?.getProperty('demuxer-cache-speed');
            if (res != null) {
              bps = double.tryParse(res.toString()) ?? 0;
            }
          } catch (_) {}

          if (bps <= 0) {
            try {
              final stateRes = await (_player!.platform as dynamic)?.getProperty('demuxer-cache-state');
              if (stateRes != null) {
                final parsed = stateRes is Map ? stateRes : jsonDecode(stateRes.toString());
                if (parsed is Map) {
                  final rawRate = parsed['raw-input-rate'] ?? parsed['cache-speed'];
                  if (rawRate != null) {
                    bps = double.tryParse(rawRate.toString()) ?? 0;
                  }
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
                  if (bps <= 0 || sysBps > bps) {
                    bps = sysBps;
                  }
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

      _posSub = _player!.stream.position.listen((pos) {
        if (pos.inSeconds > 0) _lastValidPosition = pos;
        if (mounted) {
          setState(() => _position = pos);

          if (pos.inSeconds > 0 &&
              pos.inSeconds % 5 == 0 &&
              pos.inSeconds != _lastSavedHistorySec) {
            _lastSavedHistorySec = pos.inSeconds;
            _savePlaybackHistory();
          }

          // 自动跳过片头
          if (!_hasSkippedIntro && _skipIntroSeconds > 0 && pos.inSeconds > 0 && pos.inSeconds < 5) {
            _hasSkippedIntro = true;
            if (_duration.inSeconds == 0 || _duration.inSeconds > _skipIntroSeconds + 20) {
              _kernelSeek(Duration(seconds: _skipIntroSeconds));
              _showHud(Icons.fast_forward, '已自动跳过片头 ${_formatSeconds(_skipIntroSeconds)}');
            }
          }

          // 自动跳过片尾并连播下一集
          if (!_hasSkippedOutro && _skipOutroSeconds > 0 && _duration.inSeconds > _skipOutroSeconds + 20) {
            if (pos.inSeconds >= _duration.inSeconds - _skipOutroSeconds) {
              _hasSkippedOutro = true;
              _showHud(Icons.skip_next, '片尾已自动跳过，正在播放下一集');
              _playNextEpisode();
            }
          }

          // 定期记录播放进度 (每 10 秒记录一次)
          if (pos.inSeconds > 0 && pos.inSeconds % 10 == 0) {
            _savePlaybackHistory();
          }
        }
      });

      _durSub = _player!.stream.duration.listen((dur) {
        if (mounted) setState(() => _duration = dur);
      });

      _completedSub?.cancel();
      _completedSub = _player!.stream.completed.listen((completed) {
        if (mounted && completed) {
          _handlePlaybackCompleted();
        }
      });

      _playSub = _player!.stream.playing.listen((playing) {
        if (mounted) {
          setState(() {
            _isPlaying = playing;
            _isPlayerLoading = false;
          });
          _syncMediaSession(playing);
          if (playing) _startOverlayTimer();
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
          _detectMediaBadges();
        }
      });

      _trackSub = _player!.stream.track.listen((_) {
        _detectMediaBadges();
      });

      _tracksSub = _player!.stream.tracks.listen((_) {
        _detectMediaBadges();
      });

      // 应用硬解/软解设置、杜比校正与本地预缓存优化
      try {
        final platform = _player!.platform as dynamic;
        final isIsoStream = _badgeIso != null || url.contains('/iso_stream/');

        // 💡 如果是 ISO 蓝光 M2TS 流，Android MediaCodec 硬解易产生 Codec 初始化失败 (Could not open codec) 导致黑屏无画面
        // 使用 auto-safe 能更平滑回退软解/兼容解码
        platform?.setProperty('hwdec', _isHardwareDecode ? (isIsoStream ? 'auto-safe' : (Platform.isAndroid ? 'mediacodec,auto' : 'auto')) : 'no');

        if (isIsoStream) {
          // 💡 对 ISO / M2TS 传输流配置专门的 probesize、seekable 与缓冲区，解决 ISO 无法快进和定位卡死问题
          platform?.setProperty('demuxer-lavf-o', 'probesize=20000000,analyzeduration=20000000');
          platform?.setProperty('demuxer-seekable', 'yes');
          platform?.setProperty('demuxer-max-bytes', '157286400'); // 150MB 预读缓冲区
          platform?.setProperty('demuxer-max-back-bytes', '52428800'); // 50MB 后退快进缓冲区
          platform?.setProperty('hr-seek', 'yes');
        }

        final ua = headers['User-Agent'] ?? headers['user-agent'];
        if (ua != null && ua.isNotEmpty) {
          platform?.setProperty('user-agent', ua);
        }
        final ref = headers['Referer'] ?? headers['referer'];
        if (ref != null && ref.isNotEmpty) {
          platform?.setProperty('referrer', ref);
        }
        
        // 1. 应用用户配置的缓冲倍数与流媒体加速参数
        _applyBufferSettings(_bufferTimeOption);

        // 2. 深度优化杜比视界与 HDR 色彩映射
        _applyDvHdrProperties(platform);
      } catch (_) {}

      _errorSub = _player!.stream.error.listen((err) {
        debugPrint('⚠️ [media_kit 事件] $err (url: $url)');
        if (!mounted || err.isEmpty) return;
        final lower = err.toLowerCase();
        // 缓冲、缓存、字幕、音频输出或非致命解码告警不应直接报错打断播放，等待即可
        final isNonFatal = lower.contains('buffer') ||
            lower.contains('cache') ||
            lower.contains('seek') ||
            lower.contains('subtitle') ||
            lower.contains('ass') ||
            lower.contains('audiotrack') ||
            lower.contains('wasapi') ||
            lower.contains('alsa') ||
            lower.contains('swscale') ||
            lower.contains('deprecated') ||
            lower.contains('discarding') ||
            lower.contains('corrupt') ||
            lower.contains('non-existing') ||
            lower.contains('no frame');
        final isFatalOpen = lower.contains('failed to open') ||
            lower.contains('unrecognized') ||
            lower.contains('403') ||
            lower.contains('404') ||
            lower.contains('401') ||
            lower.contains('protocol not found');
        if (isNonFatal || ((_isBuffering || _isPlayerLoading || _isPlaying) && !isFatalOpen)) {
          return;
        }
        final savedPos = _position.inSeconds > 1 ? _position : _lastValidPosition;
        setState(() {
          _isPlayerLoading = false;
          _playErrorMsg = '网络异常或播放中断，等待恢复后自动续播...\n$err';
        });
        _scheduleAutoReconnect(savedPos);
        _tryAutoSwitchChangeableSite();
      });

      // 直连播放：User-Agent / Referer 已通过 mpv 原生属性设置，httpHeaders 保留其余头（避免 UA 含逗号被 mpv 拆分）
      final Map<String, String> mpvHeaders = Map<String, String>.from(effectiveHeaders)
        ..removeWhere((k, _) => k.toLowerCase() == 'user-agent' || k.toLowerCase() == 'referer');
      try {
        (_player!.platform as dynamic)?.setProperty(
          'hwdec',
          _isHardwareDecode ? (Platform.isAndroid ? 'mediacodec,auto' : 'auto') : 'no',
        );
      } catch (_) {}
      print('🎬 [PLAYER-MPV] 启动 MediaKit: hwdec=$_isHardwareDecode, rate=$_playbackRate, url=$effectiveUrl, headers=${mpvHeaders.keys.toList()}');
      _player!.open(Media(effectiveUrl, httpHeaders: mpvHeaders));
      _player!.setRate(_playbackRate);
      Future.delayed(const Duration(milliseconds: 800), _syncActualHardwareDecode);

      if (_pendingSeekAfterRefresh != null) {
        final seekTarget = _pendingSeekAfterRefresh!;
        _pendingSeekAfterRefresh = null;
        _seekAfterReady(seekTarget);
      } else if (restoreHistory) {
        _restorePlaybackHistory();
      }
    } catch (e) {
      setState(() {
        _isPlayerLoading = false;
        _playErrorMsg = '启动原生解码器异常: $e';
      });
    }
  }

  Future<void> _syncActualHardwareDecode() async {
    if (!mounted || _player == null) return;
    try {
      final res = await (_player!.platform as dynamic)?.getProperty('hwdec-current');
      final hw = res?.toString().trim().toLowerCase() ?? '';
      if (hw.isNotEmpty) {
        final actualIsHw = hw != 'no' && hw != 'none';
        final audioCnt = _player!.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').length;
        final subCnt = _player!.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').length;
        print('🎬 [PLAYER-MPV] 解码就绪: hwdec=$hw, 分辨率=${_videoWidth}x${_videoHeight}, 音轨=$audioCnt, 字幕=$subCnt');
        if (mounted && actualIsHw != _isHardwareDecode) {
          setState(() => _isHardwareDecode = actualIsHw);
        }
      }
      await _detectMediaBadges();
    } catch (_) {}
  }

  void _applyDvHdrProperties(dynamic platform) {
    if (platform == null) return;
    try {
      platform.setProperty('tone-mapping', 'spline');
      platform.setProperty('tone-mapping-mode', 'auto');
      platform.setProperty('gamut-mapping-mode', 'perceptual');
      platform.setProperty('target-colorspace-hint', 'no');
      platform.setProperty('hdr-compute-peak', 'yes');
    } catch (_) {}
  }

  Future<void> _detectMediaBadges({bool isExo = false}) async {
    if (!mounted) return;
    String? resBadge;
    final w = _videoWidth ?? 0;
    final h = _videoHeight ?? 0;
    if (w >= 3600 || h >= 2000) {
      resBadge = '4K';
    } else if (w >= 2400 || h >= 1350) {
      resBadge = '2K';
    } else if (w >= 1800 || h >= 1000) {
      resBadge = '1080P';
    } else if (w >= 1200 || h >= 680) {
      resBadge = '720P';
    }

    String? hdrBadge;
    String? audioBadge;
    final hintText = '${_currentEpisodeName} ${_currentPlayUrl} ${_vodDetail?.vodName ?? ""}'.toLowerCase();

    if (!isExo && _player != null) {
      try {
        final platform = _player!.platform as dynamic;
        final colormatrix = (await platform?.getProperty('video-params/colormatrix'))?.toString().toLowerCase() ?? '';
        final gamma = (await platform?.getProperty('video-params/gamma'))?.toString().toLowerCase() ?? '';
        final primaries = (await platform?.getProperty('video-params/primaries'))?.toString().toLowerCase() ?? '';
        final sigPeakStr = (await platform?.getProperty('video-params/sig-peak'))?.toString() ?? '';
        final sigPeak = double.tryParse(sigPeakStr) ?? 0.0;
        final audioCodecProp = (await platform?.getProperty('audio-codec-name'))?.toString().toLowerCase() ?? '';

        final vTrack = _player!.state.track.video;
        final vTrackInfo = '${vTrack.codec ?? ""} ${vTrack.title ?? ""}'.toLowerCase();
        final aTrack = _player!.state.track.audio;
        final aTrackInfo = '${aTrack.codec ?? ""} ${aTrack.title ?? ""} $audioCodecProp'.toLowerCase();

        final isDvVideo = colormatrix.contains('dolbyvision') ||
            colormatrix.contains('iptpqc2') ||
            primaries.contains('dolbyvision') ||
            gamma.contains('dolbyvision') ||
            vTrackInfo.contains('dvhe') ||
            vTrackInfo.contains('dvh1') ||
            vTrackInfo.contains('dovi') ||
            vTrackInfo.contains('dolby vision') ||
            RegExp(r'(^|[.\s_\[(])(dv|dovi)([.\s_\])]|$)|dolby.?vision|杜比视界').hasMatch(hintText);

        // Android 上若检测到杜比视界 Profile 5 (IPTPQc2)，vo=libmpv 易偏紫绿，自动无缝接管至 ExoPlayer 原生硬解
        if (Platform.isAndroid &&
            isDvVideo &&
            !_hasAttemptedDvExoFallback &&
            _badgeIso == null &&
            _currentPlayUrl.isNotEmpty) {
          _hasAttemptedDvExoFallback = true;
          final resumePos = _position.inSeconds > 1 ? _position : _lastValidPosition;
          if (resumePos.inSeconds > 1) _pendingSeekAfterRefresh = resumePos;
          debugPrint('🎨 [DV-AUTO] 检测到杜比视界，Android 自动切换 ExoPlayer 原生硬解以修复偏紫');
          _showHud(Icons.hdr_on, '已自动切换 ExoPlayer 原生解码杜比视界');
          _initAndStartExoPlayer(_currentPlayUrl, _currentHeaders, restoreHistory: true);
          return;
        }

        // 若依然运行在 MPV 内核下且为 DV 视频，在「自动校色」下强制应用色域映射 format=colormatrix=bt.709 转换 IPT 色彩空间
        if (isDvVideo && _dvCorrectionMode == '自动校色') {
          try {
            platform?.setProperty('tone-mapping', 'reinhard');
            platform?.setProperty('target-colorspace-hint', 'no');
            platform?.setProperty('vf', 'format=colormatrix=bt.709');
          } catch (_) {}
        }

        if (isDvVideo) {
          hdrBadge = '杜比视界';
        } else if (gamma.contains('pq') || gamma.contains('smpte2084')) {
          hdrBadge = (hintText.contains('hdr10+') || hintText.contains('hdr10plus')) ? 'HDR10+' : 'HDR10';
        } else if (gamma.contains('hlg') || gamma.contains('arib-std-b67')) {
          hdrBadge = 'HLG';
        } else if (primaries.contains('bt.2020') || colormatrix.contains('bt.2020') || sigPeak > 1.2) {
          hdrBadge = 'HDR';
        }

        if (aTrackInfo.contains('atmos') || (aTrackInfo.contains('truehd') && aTrackInfo.contains('atmos'))) {
          audioBadge = '全景声';
        } else if (aTrackInfo.contains('truehd')) {
          audioBadge = '杜比TrueHD';
        } else if (aTrackInfo.contains('eac3') || aTrackInfo.contains('ec-3') || aTrackInfo.contains('e-ac-3')) {
          audioBadge = '杜比DD+';
        } else if (aTrackInfo.contains('ac3') || aTrackInfo.contains('ac-3')) {
          audioBadge = '杜比AC3';
        } else if (aTrackInfo.contains('dts-hd') || aTrackInfo.contains('dtshd')) {
          audioBadge = 'DTS-HD';
        } else if (aTrackInfo.contains('dts') || aTrackInfo.contains('dca')) {
          audioBadge = 'DTS';
        }
      } catch (_) {}
    }

    // 元数据/文件名兜底识别 (适用于 EXO 内核或流未携带完整 tag 时)
    if (hdrBadge == null) {
      if (RegExp(r'(^|[.\s_\-\[\(])(dv|dovi|dvhe|dvh1)([.\s_\-\]\)]|$)|dolby.?vision|杜比视界').hasMatch(hintText)) {
        hdrBadge = '杜比视界';
      } else if (hintText.contains('hdr10+') || hintText.contains('hdr10plus')) {
        hdrBadge = 'HDR10+';
      } else if (hintText.contains('hdr10')) {
        hdrBadge = 'HDR10';
      } else if (RegExp(r'(^|[.\s_\-\[\(])hlg([.\s_\-\]\)]|$)').hasMatch(hintText)) {
        hdrBadge = 'HLG';
      } else if (RegExp(r'(^|[.\s_\-\[\(])hdr([.\s_\-\]\)]|$)').hasMatch(hintText)) {
        hdrBadge = 'HDR';
      }
    }
    if (audioBadge == null) {
      if (hintText.contains('atmos') || hintText.contains('全景声')) {
        audioBadge = '全景声';
      } else if (hintText.contains('truehd')) {
        audioBadge = '杜比TrueHD';
      } else if (hintText.contains('ddp') || hintText.contains('dd+') || hintText.contains('eac3')) {
        audioBadge = '杜比DD+';
      } else if (hintText.contains('ac3') || hintText.contains('dd5.1')) {
        audioBadge = '杜比AC3';
      } else if (hintText.contains('dts-hd') || hintText.contains('dtshd')) {
        audioBadge = 'DTS-HD';
      } else if (RegExp(r'(^|[.\s_\-\[\(])dts([.\s_\-\]\)]|$)').hasMatch(hintText)) {
        audioBadge = 'DTS';
      }
    }

    final logKey = '${resBadge ?? ""}|${hdrBadge ?? ""}|${audioBadge ?? ""}|${_badgeIso ?? ""}';
    if (logKey != '|||' && logKey != _lastBadgeLogKey) {
      _lastBadgeLogKey = logKey;
      final activeBadges = [
        if (_badgeIso != null) _badgeIso!,
        if (resBadge != null) resBadge,
        if (hdrBadge != null) hdrBadge,
        if (audioBadge != null) audioBadge,
      ];
      print('✨ [MEDIA-BADGE] 标志点亮: ${activeBadges.join(" · ")}');
    }

    if (mounted &&
        (_badgeResolution != resBadge ||
            _badgeHdr != hdrBadge ||
            _badgeAudio != audioBadge)) {
      setState(() {
        _badgeResolution = resBadge;
        _badgeHdr = hdrBadge;
        _badgeAudio = audioBadge;
      });
    }
  }

  void _toggleHardwareDecode() {
    final targetHw = !_isHardwareDecode;
    setState(() => _isHardwareDecode = targetHw);
    try {
      (_player?.platform as dynamic)?.setProperty(
        'hwdec',
        targetHw ? (Platform.isAndroid ? 'mediacodec,auto' : 'auto') : 'no',
      );
      Future.delayed(const Duration(milliseconds: 500), _syncActualHardwareDecode);
    } catch (_) {}
  }

  Future<void> _launchExternalPlayer() async {
    if (_currentPlayUrl.isEmpty) {
      _showHud(Icons.info_outline, '暂无有效播放地址');
      return;
    }
    _kernelPause();
    String launchUrl = _currentPlayUrl;
    if (_currentHeaders.isNotEmpty &&
        (_currentPlayUrl.startsWith('http://') || _currentPlayUrl.startsWith('https://'))) {
      await LocalHttpServer().start();
      final vodName = (_vodDetail?.vodName ?? '').trim();
      final epName = _currentEpisodeName.trim();
      final streamTitle = epName.isNotEmpty && vodName.isNotEmpty
          ? '$vodName - $epName'
          : (vodName.isNotEmpty ? vodName : epName);
      launchUrl = LocalHttpServer().registerStreamProxy(
        _currentPlayUrl,
        _currentHeaders,
        title: streamTitle,
      );
    }
    if (Platform.isAndroid) {
      try {
        final ok = await const MethodChannel('com.example.ftv/downloader')
            .invokeMethod<bool>('launchExternalPlayer', {
          'url': launchUrl,
          'title': '${_vodDetail?.vodName ?? ""} $_currentEpisodeName'.trim(),
          'headers': _currentHeaders,
        });
        if (ok != true) {
          _showHud(Icons.error_outline, '未找到可用的外部播放器');
        }
      } catch (e) {
        _showHud(Icons.error_outline, '外调播放器失败: $e');
      }
    } else if (Platform.isWindows) {
      await _showWindowsExternalPlayerDialog(launchUrl);
    }
  }

  Future<void> _showWindowsExternalPlayerDialog(String launchUrl) async {
    final savedCustom = await StorageBridge.getValue('win_custom_player_path') ?? '';
    final candidates = <Map<String, String>>[];

    final potPaths = [
      r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini.exe',
      r'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe',
    ];
    for (final p in potPaths) {
      if (await File(p).exists()) {
        candidates.add({'name': 'PotPlayer', 'path': p});
        break;
      }
    }

    final vlcPaths = [
      r'C:\Program Files\VideoLAN\VLC\vlc.exe',
      r'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe',
    ];
    for (final p in vlcPaths) {
      if (await File(p).exists()) {
        candidates.add({'name': 'VLC Media Player', 'path': p});
        break;
      }
    }

    if (savedCustom.isNotEmpty && await File(savedCustom).exists()) {
      final base = savedCustom.split(Platform.pathSeparator).last;
      candidates.add({'name': '自定义 ($base)', 'path': savedCustom});
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('选择 Windows 外部播放器', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...candidates.map((item) => ListTile(
                    leading: const Icon(Icons.play_circle_outline, color: Colors.white70),
                    title: Text(item['name']!, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: Text(item['path']!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      try {
                        await Process.start(item['path']!, [launchUrl], mode: ProcessStartMode.detached);
                      } catch (e) {
                        _showHud(Icons.error_outline, '启动播放器失败: $e');
                      }
                    },
                  )),
              ListTile(
                leading: const Icon(Icons.folder_open, color: Colors.amber),
                title: const Text('手动选择播放器 (.exe)...', style: TextStyle(color: Colors.white, fontSize: 14)),
                onTap: () async {
                  final picked = await FilePicker.pickFile(
                    type: FileType.custom,
                    allowedExtensions: ['exe'],
                  );
                  final exePath = picked?.path;
                  if (exePath != null && exePath.isNotEmpty) {
                    await StorageBridge.setValue('win_custom_player_path', exePath);
                    if (ctx.mounted) Navigator.pop(ctx);
                    try {
                      await Process.start(exePath, [launchUrl], mode: ProcessStartMode.detached);
                    } catch (e) {
                      _showHud(Icons.error_outline, '启动播放器失败: $e');
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_browser, color: Colors.white70),
                title: const Text('使用系统默认方式打开', style: TextStyle(color: Colors.white, fontSize: 14)),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Process.start('cmd', ['/c', 'start', '', launchUrl], mode: ProcessStartMode.detached);
                  } catch (e) {
                    _showHud(Icons.error_outline, '启动失败: $e');
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  void _showPlayerCoreSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1.0,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            decoration: const BoxDecoration(
              color: Color(0xFFF6F7F9),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '播放核心',
                          style: TextStyle(
                            color: Color(0xFF222222),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.ios_share_outlined, color: Color(0xFF333333), size: 22),
                          tooltip: '外调播放器',
                          onPressed: () {
                            Navigator.pop(ctx);
                            _launchExternalPlayer();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () async {
                        final changed = _playerCoreName != 'MPV';
                        setState(() => _playerCoreName = 'MPV');
                        await StorageBridge.setValue('player_core', 'MPV');
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (changed && _currentPlayUrl.isNotEmpty) {
                          _pendingSeekAfterRefresh = _position.inSeconds > 1 ? _position : _lastValidPosition;
                          _initAndStartPlayer(_currentPlayUrl, {'header': _currentHeaders});
                        }
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _playerCoreName == 'MPV' ? const Color(0xFF2196F3) : const Color(0xFFBDBDBD),
                            width: 1.2,
                          ),
                        ),
                        child: Text(
                          'MPV (${_isHardwareDecode ? "硬解" : "软解"})',
                          style: TextStyle(
                            color: _playerCoreName == 'MPV' ? const Color(0xFF2196F3) : const Color(0xFF222222),
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (Platform.isAndroid) ...[
                      const SizedBox(height: 10),
                      InkWell(
                        onTap: () async {
                          final changed = _playerCoreName != 'EXO';
                          setState(() => _playerCoreName = 'EXO');
                          await StorageBridge.setValue('player_core', 'EXO');
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (changed && _currentPlayUrl.isNotEmpty) {
                            _pendingSeekAfterRefresh = _position.inSeconds > 1 ? _position : _lastValidPosition;
                            _initAndStartPlayer(_currentPlayUrl, {'header': _currentHeaders});
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _playerCoreName == 'EXO' ? const Color(0xFF2196F3) : const Color(0xFFBDBDBD),
                              width: 1.2,
                            ),
                          ),
                          child: Text(
                            'EXO (Android 原生)',
                            style: TextStyle(
                              color: _playerCoreName == 'EXO' ? const Color(0xFF2196F3) : const Color(0xFF222222),
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _launchExternalPlayer();
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFBDBDBD), width: 1.0),
                        ),
                        child: const Text(
                          '外调播放器',
                          style: TextStyle(
                            color: Color(0xFF222222),
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _fetchLogVarDanmaku() async {
    print('🎬 [DANMAKU] 自动拉取触发: vod="${_vodDetail?.vodName}", ep="$_currentEpisodeName", enabled=${_danmakuConfig.enabled}, server="${_danmakuService.config.serverUrl}"');
    if (_vodDetail == null) return;
    if (!_danmakuConfig.enabled) {
      print('⏸️ [DANMAKU] 弹幕开关处于关闭状态，跳过自动拉取');
      return;
    }

    setState(() => _isDanmakuLoading = true);
    try {
      final (cleanName, cleanEp) = _danmakuService.sanitizeVodNameAndEpisode(
        _vodDetail!.vodName,
        _currentEpisodeName,
      );

      List<DanmakuItem> items = [];

      // 1. 💡 优先复用已缓存/已选定的弹幕源（切集时无缝切换下一集），否则按剧名智能优选主站源
      List<LogVarAnimeSource> sources =
          (_cachedAnimeSources.isNotEmpty && _lastDanmakuSearchQuery == cleanName)
              ? _cachedAnimeSources
              : await _danmakuService.searchLogVarAnimes(cleanName);
      _lastDanmakuSearchQuery = cleanName;
      _cachedAnimeSources = sources;
      if (sources.isNotEmpty) {
        LogVarAnimeSource? targetSource;
        if (_matchedAnimeTitle != null && _matchedAnimeTitle!.isNotEmpty) {
          final idx = sources.indexWhere((s) => s.animeTitle == _matchedAnimeTitle);
          if (idx >= 0) targetSource = sources[idx];
        }
        targetSource ??= _danmakuService.pickBestSource(
          sources,
          _vodDetail!.vodName,
          cleanName,
          cleanEp,
        );

        LogVarEpisode? matchedEp;
        final targetEpInt = int.tryParse(cleanEp);
        for (final ep in targetSource.episodes) {
          final t = ep.episodeTitle.trim();
          if (t == cleanEp) {
            matchedEp = ep;
            break;
          }
          final epNumMatch = RegExp(r'(\d+)').firstMatch(t);
          if (epNumMatch != null) {
            final epInt = int.tryParse(epNumMatch.group(1)!);
            if ((targetEpInt != null && epInt == targetEpInt) || epNumMatch.group(1) == cleanEp) {
              matchedEp = ep;
              break;
            }
          }
        }
        matchedEp ??= targetSource.episodes.first;

        items = await _danmakuService.fetchDanmakuByEpisodeId(matchedEp.episodeId);
        _matchedLogVarEpisodeId = matchedEp.episodeId;
        _matchedAnimeTitle = targetSource.animeTitle;
        _matchedEpisodeTitle = matchedEp.episodeTitle;
        _matchedDanmakuUrl = '${LocalHttpServer().baseUrl}/danmu?box_id=${targetSource.animeTitle}_ep${matchedEp.episodeTitle}_${targetSource.animeTitle}(${targetSource.typeDescription}).xml';
        if (items.isNotEmpty) {
          final epOrderIdx = targetSource.episodes.indexOf(matchedEp);
          final epOrderLabel = '第${epOrderIdx >= 0 ? epOrderIdx + 1 : 1}集';
          _showHud(
            Icons.comment,
            '${targetSource.animeTitle} $epOrderLabel ${items.length}条',
          );
        }
      }

      if (sources.isEmpty) {
        print('⚠️ [DANMAKU] 搜索弹幕源为空 (cleanName="$cleanName")，尝试回退常规接口');
      }

      // 2. 若首选源未命中，回退常规接口
      if (items.isEmpty) {
        items = await _danmakuService.fetchDanmaku(
          vodName: _vodDetail!.vodName,
          episodeName: _currentEpisodeName,
          playUrl: _currentPlayUrl,
        );
      }



      if (mounted) {
        setState(() {
          _danmakuConfig.enabled = true;
          _danmakus = items;
          _isDanmakuLoading = false;
        });
        // 💡 减少 toast 提示：静默无缝注入弹幕，不弹出骚扰 toast
      }
    } catch (e) {
      if (mounted) setState(() => _isDanmakuLoading = false);
    }
  }

  void _showDanmakuSettingsDialog() => showDanmakuSettingsDialog(
        context: context,
        danmakuConfig: _danmakuConfig,
        danmakuService: _danmakuService,
        onStateChanged: () => setState(() {}),
      );

  void _showDanmakuSearchDialog() => showDanmakuSearchDialog(
        context: context,
        vodDetail: _vodDetail,
        currentEpisodeName: _currentEpisodeName,
        danmakuConfig: _danmakuConfig,
        danmakuService: _danmakuService,
        matchedAnimeTitle: _matchedAnimeTitle,
        matchedEpisodeTitle: _matchedEpisodeTitle,
        matchedLogVarEpisodeId: _matchedLogVarEpisodeId,
        initialSources: _cachedAnimeSources,
        initialQuery: _lastDanmakuSearchQuery,
        onCacheSearchSources: (q, sources) {
          _lastDanmakuSearchQuery = q;
          _cachedAnimeSources = sources;
        },
        isHostMounted: () => mounted,
        onApplyDanmaku: (items, animeTitle, episodeTitle, matchedUrl, epId) {
          setState(() {
            _danmakus = items;
            _danmakuConfig.enabled = true;
            _matchedAnimeTitle = animeTitle;
            _matchedEpisodeTitle = episodeTitle;
            _matchedDanmakuUrl = matchedUrl;
            _matchedLogVarEpisodeId = epId;
          });
        },
        onShowHud: _showHud,
      );

  void _showMatchedDanmakuDialog() => showMatchedDanmakuDialog(
        context: context,
        vodDetail: _vodDetail,
        currentEpisodeName: _currentEpisodeName,
        danmakuConfig: _danmakuConfig,
        danmakuService: _danmakuService,
        danmakus: _danmakus,
        matchedDanmakuUrl: _matchedDanmakuUrl,
        onLoadLocalDanmaku: (items, path) => setState(() {
          _danmakus = items;
          _danmakuConfig.enabled = true;
          _matchedDanmakuUrl = path;
        }),
        onToggleDanmakuEnabled: () => setState(() {}),
        onClearDanmakus: () => setState(() {
          _danmakus = [];
          _matchedDanmakuUrl = null;
        }),
        onOpenSearch: _showDanmakuSearchDialog,
        onShowHud: _showHud,
      );

  void _showSendDanmakuDialog() => showSendDanmakuDialog(
        context: context,
        vodDetail: _vodDetail,
        currentEpisodeName: _currentEpisodeName,
        matchedLogVarEpisodeId: _matchedLogVarEpisodeId,
        position: _position,
        danmakuService: _danmakuService,
        onAddLocalDanmaku: (newItem) {
          setState(() {
            _danmakus.add(newItem);
            _danmakus.sort((a, b) => a.time.compareTo(b.time));
          });
        },
        onShowHud: _showHud,
      );

  void _showVideoTrackDialog() => showVideoTrackDialog(
        context: context,
        player: _player,
        videoWidth: _videoWidth,
        videoHeight: _videoHeight,
        onShowHud: _showHud,
      );

  void _showAudioTrackDialog() => showAudioTrackDialog(
        context: context,
        player: _player,
        onShowHud: _showHud,
      );

  void _showSubtitleSettingsDialog() => showSubtitleSettingsDialog(
        context: context,
        subtitleConfig: _subtitleConfig,
        themeService: _themeService,
        onStateChanged: () => setState(() {}),
      );

  SubtitleViewConfiguration _buildSubtitleViewConfig() {
    final color = Color(_subtitleConfig.colorValue)
        .withValues(alpha: _subtitleConfig.opacity);
    return SubtitleViewConfiguration(
      textAlign: TextAlign.center,
      style: TextStyle(
        height: 1.25,
        fontSize: _subtitleConfig.fontSize,
        color: color,
        fontWeight: FontWeight.w500,
        backgroundColor: _subtitleConfig.showBackground
            ? Colors.black.withValues(alpha: 0.55 * _subtitleConfig.opacity)
            : Colors.transparent,
        shadows: _subtitleConfig.showBackground
            ? null
            : [
                Shadow(
                  color: Colors.black.withValues(alpha: 0.9 * _subtitleConfig.opacity),
                  blurRadius: 4,
                  offset: const Offset(1, 1),
                ),
                Shadow(
                  color: Colors.black.withValues(alpha: 0.7 * _subtitleConfig.opacity),
                  blurRadius: 8,
                  offset: const Offset(0, 0),
                ),
              ],
      ),
      padding: EdgeInsets.fromLTRB(24.0, 4.0, 24.0, _subtitleConfig.bottomPadding.clamp(16.0, 160.0)),
    );
  }

  void _showSubtitleTrackDialog() => showSubtitleTrackDialog(
        context: context,
        player: _player,
        isMounted: mounted,
        onOpenSubtitleSettings: _showSubtitleSettingsDialog,
        onShowHud: _showHud,
      );

  Future<void> _showPlayLinkDetailDialog() async {
    String? proxyUrl;
    if (_currentPlayUrl.startsWith('http://') || _currentPlayUrl.startsWith('https://')) {
      await LocalHttpServer().start();
      final vodName = (_vodDetail?.vodName ?? '').trim();
      final epName = _currentEpisodeName.trim();
      final streamTitle = epName.isNotEmpty && vodName.isNotEmpty
          ? '$vodName - $epName'
          : (vodName.isNotEmpty ? vodName : epName);
      proxyUrl = LocalHttpServer().registerStreamProxy(
        _currentPlayUrl,
        _currentHeaders,
        title: streamTitle,
      );
    }
    if (!mounted) return;
    print('📋 [PLAY-INFO] 播放信息: title=${_vodDetail?.vodName}, ep=$_currentEpisodeName, res=${_videoWidth}x${_videoHeight}, url=$_currentPlayUrl, proxy=$proxyUrl, headers=${_currentHeaders.keys.toList()}');
    showPlayLinkDetailDialog(
      context: context,
      vodDetail: _vodDetail,
      currentEpisodeName: _currentEpisodeName,
      currentPlayUrl: _currentPlayUrl,
      proxyPlayUrl: proxyUrl,
      currentHeaders: _currentHeaders,
      videoWidth: _videoWidth,
      videoHeight: _videoHeight,
      onShowHud: _showHud,
    );
  }

  Future<void> _showCastDialog() async {
    String? proxyUrl;
    if (_currentPlayUrl.startsWith('http://') ||
        _currentPlayUrl.startsWith('https://')) {
      await LocalHttpServer().start();
      final vodName = (_vodDetail?.vodName ?? '').trim();
      final epName = _currentEpisodeName.trim();
      final streamTitle = epName.isNotEmpty && vodName.isNotEmpty
          ? '$vodName - $epName'
          : (vodName.isNotEmpty ? vodName : epName);
      proxyUrl = LocalHttpServer().registerStreamProxy(
        _currentPlayUrl,
        _currentHeaders,
        title: streamTitle,
      );
    }
    if (!mounted) return;
    showCastDialog(
      context: context,
      currentPlayUrl: _currentPlayUrl,
      proxyPlayUrl: proxyUrl,
      vodDetail: _vodDetail,
      currentEpisodeName: _currentEpisodeName,
      onShowHud: _showHud,
    );
  }

  void _showPortraitPlayerControlsSheet() {
    final fitLabels = [
      {'label': '原始', 'name': '原始 (适应)'},
      {'label': '16:9', 'name': '16:9 (宽屏)'},
      {'label': '4:3', 'name': '4:3 (普屏)'},
      {'label': '填充', 'name': '拉伸铺满'},
      {'label': '裁剪', 'name': '居中裁切'},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            Widget buildChip({
              required String text,
              bool selected = false,
              required VoidCallback onTap,
              VoidCallback? onLongPress,
            }) {
              final accent = _themeService.accentColor;
              return InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? accent.withOpacity(0.12) : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? accent : const Color(0xFF9E9E9E),
                      width: 1.0,
                    ),
                  ),
                  child: Text(
                    text,
                    style: TextStyle(
                      color: selected ? accent : const Color(0xFF333333),
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }

            Widget buildSectionTitle(String title, {Widget? trailing}) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFF222222),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (trailing != null) trailing,
                  ],
                ),
              );
            }

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.72,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFFF6F7F9),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. 倍速
                      buildSectionTitle(
                        '倍速',
                        trailing: Text(
                          '${_playbackRate.toStringAsFixed(2)}x',
                          style: TextStyle(
                            color: _themeService.accentColor,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 16,
                          activeTrackColor: const Color(0xFF1E88E5),
                          inactiveTrackColor: const Color(0xFFE3EEF9),
                          thumbColor: const Color(0xFF1E88E5),
                          thumbShape: const BarSliderThumbShape(width: 4, height: 26),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                        ),
                        child: Slider(
                          value: _playbackRate.clamp(0.25, 5.0),
                          min: 0.25,
                          max: 5.0,
                          divisions: 19,
                          onChanged: (val) {
                            final rounded = (val * 4).round() / 4.0;
                            setSheetState(() {});
                            setState(() => _playbackRate = rounded);
                            _kernelSetRate(rounded);
                          },
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 2. 缩放
                      buildSectionTitle('缩放'),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: fitLabels.map((item) {
                          final optName = item['name']!;
                          final isSel = _fitName == optName;
                          return buildChip(
                            text: item['label']!,
                            selected: isSel,
                            onTap: () {
                              final opt = _fitOptions.firstWhere(
                                (o) => o['name'] == optName,
                                orElse: () => _fitOptions.first,
                              );
                              _applyVideoFit(
                                opt['name'],
                                opt['fit'],
                                opt['aspectRatio'],
                              );
                              setSheetState(() {});
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // 3. 播放
                      buildSectionTitle('播放'),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          buildChip(
                            text: _playerCoreName,
                            selected: true,
                            onTap: () {
                              Navigator.pop(ctx);
                              _showPlayerCoreSheet();
                            },
                          ),
                          buildChip(
                            text: _isHardwareDecode ? '硬解' : '软解',
                            selected: _isHardwareDecode,
                            onTap: () {
                              _toggleHardwareDecode();
                              setSheetState(() {});
                            },
                          ),
                          buildChip(
                            text: _skipIntroSeconds > 0
                                ? '片头 ${_formatSeconds(_skipIntroSeconds)}'
                                : '片头',
                            selected: _skipIntroSeconds > 0,
                            onTap: () async {
                              final sec = _position.inSeconds;
                              setState(() => _skipIntroSeconds = sec);
                              setSheetState(() {});
                              await StorageBridge.setValue(
                                'player_skip_intro_${_getVodSkipKey()}',
                                sec.toString(),
                              );
                              _showHud(Icons.fast_forward, '已设置跳过片头 ${_formatSeconds(sec)}');
                            },
                            onLongPress: () async {
                              setState(() => _skipIntroSeconds = 0);
                              setSheetState(() {});
                              await StorageBridge.setValue(
                                'player_skip_intro_${_getVodSkipKey()}',
                                '0',
                              );
                              _showHud(Icons.restore, '已重置跳过片头');
                            },
                          ),
                          buildChip(
                            text: _skipOutroSeconds > 0
                                ? '片尾 ${_formatSeconds(_skipOutroSeconds)}'
                                : '片尾',
                            selected: _skipOutroSeconds > 0,
                            onTap: () async {
                              if (_duration.inSeconds <= 0) {
                                _showHud(Icons.info_outline, '暂未获取到视频总时长');
                                return;
                              }
                              final sec = (_duration.inSeconds - _position.inSeconds)
                                  .clamp(0, _duration.inSeconds);
                              setState(() => _skipOutroSeconds = sec);
                              setSheetState(() {});
                              await StorageBridge.setValue(
                                'player_skip_outro_${_getVodSkipKey()}',
                                sec.toString(),
                              );
                              _showHud(Icons.skip_next, '已设置跳过片尾 ${_formatSeconds(sec)}');
                            },
                            onLongPress: () async {
                              setState(() => _skipOutroSeconds = 0);
                              setSheetState(() {});
                              await StorageBridge.setValue(
                                'player_skip_outro_${_getVodSkipKey()}',
                                '0',
                              );
                              _showHud(Icons.restore, '已重置跳过片尾');
                            },
                          ),
                          buildChip(
                            text: '刷新',
                            onTap: () {
                              Navigator.pop(ctx);
                              _refreshPlayback();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 4. 轨道
                      buildSectionTitle('轨道'),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          buildChip(
                            text: '字幕',
                            onTap: () {
                              Navigator.pop(ctx);
                              _showSubtitleTrackDialog();
                            },
                          ),
                          buildChip(
                            text: '音轨',
                            onTap: () {
                              Navigator.pop(ctx);
                              _showAudioTrackDialog();
                            },
                          ),
                          buildChip(
                            text: '视轨',
                            onTap: () {
                              Navigator.pop(ctx);
                              _showVideoTrackDialog();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 5. 其它
                      buildSectionTitle('其它'),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          buildChip(
                            text: '弹幕',
                            selected: _danmakuConfig.enabled,
                            onTap: () {
                              Navigator.pop(ctx);
                              _showMatchedDanmakuDialog();
                            },
                            onLongPress: () {
                              Navigator.pop(ctx);
                              _showDanmakuSettingsDialog();
                            },
                          ),
                          buildChip(
                            text: _isLooping ? '循环' : '顺序',
                            selected: _isLooping,
                            onTap: () {
                              setState(() => _isLooping = !_isLooping);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _savePlaybackHistory() async {
    if (_vodDetail == null || _currentPlayUrl.isEmpty) return;
    try {
      await StorageBridge.setValue(
        'history_${_vodDetail!.vodId}',
        '${_position.inSeconds}|$_currentEpisodeName',
      );
      final currentSourceName = (_vodDetail!.playSources.isNotEmpty &&
              _selectedSourceIndex < _vodDetail!.playSources.length)
          ? _vodDetail!.playSources[_selectedSourceIndex].name
          : '';
      await HistoryFavoriteService().recordHistory(
        vod: _vodDetail!,
        episodeName: _currentEpisodeName,
        positionSec: _position.inSeconds,
        durationSec: _duration.inSeconds,
        sourceName: currentSourceName,
        siteKey: _targetSiteKey,
        siteName: _resolveTargetSiteName(),
      );
    } catch (_) {}
  }

  Future<void> _seekAfterReady(Duration target) async {
    if (target.inSeconds <= 1 || _player == null) return;
    for (int i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted || _player == null) return;
      if (_duration.inSeconds > target.inSeconds) {
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted || _player == null) return;
        await _kernelSeek(target);
        debugPrint('🔄 [刷新/重连] 精确续播至 ${target.inSeconds}s');
        return;
      }
    }
  }

  Future<void> _restorePlaybackHistory() async {
    if (_vodDetail == null) return;
    try {
      final history = await HistoryFavoriteService().getLastPlayback(
        _vodDetail!.vodId,
        siteKey: _targetSiteKey,
      );
      int sec = 0;
      String ep = '';
      if (history != null) {
        sec = (history['positionSec'] as num?)?.toInt() ?? 0;
        ep = history['episodeName']?.toString() ?? '';
      } else {
        final val = await StorageBridge.getValue('history_${_vodDetail!.vodId}');
        if (val != null && val.contains('|')) {
          final parts = val.split('|');
          sec = int.tryParse(parts[0]) ?? 0;
          ep = parts.length > 1 ? parts[1] : '';
        }
      }

      if (sec > 5 && ep.isNotEmpty && ep == _currentEpisodeName && (_isExoActive ? _exoController != null : _player != null)) {
        _hasSkippedIntro = true;
        if (_duration == Duration.zero) {
          if (_isExoActive) {
            for (int i = 0; i < 20; i++) {
              if (_exoController?.value.isInitialized == true &&
                  (_exoController?.value.duration ?? Duration.zero) > Duration.zero) {
                break;
              }
              await Future.delayed(const Duration(milliseconds: 250));
            }
          } else {
            try {
              await _player!.stream.duration
                  .firstWhere((d) => d > Duration.zero)
                  .timeout(const Duration(seconds: 10));
            } catch (_) {}
          }
        }
        // 等待解码器与解复用器完全就绪后再执行 seek，避免开播瞬间被重置
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted || (_isExoActive ? _exoController == null : _player == null)) return;
        debugPrint('⏪ [历史恢复] 跳转到 ${sec}s (剧集: $_currentEpisodeName)');
        await _kernelSeek(Duration(seconds: sec));
        _showHud(Icons.restore, '已恢复上次播放进度: ${_formatDuration(Duration(seconds: sec))}');
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    if (_vodDetail == null) return;
    final isFav = await HistoryFavoriteService().toggleFavorite(_vodDetail!);
    setState(() => _isFavorited = isFav);
    _showHud(
      isFav ? Icons.star : Icons.star_border,
      isFav ? '已添加至我的收藏' : '已取消收藏',
    );
  }

  void _onLongPressStart() {
    if (_isLocked || _longPressSpeedOption == '关闭') return;
    if ((_isExoActive ? _exoController == null : _player == null) || !_isPlaying) return;
    final speedVal = double.tryParse(_longPressSpeedOption.replaceAll(RegExp(r'[xX倍\s]'), '')) ?? 3.0;
    _preLongPressSpeed = _playbackRate;
    _isLongPressingSpeed = true;
    _kernelSetRate(speedVal);
    setState(() {});
  }

  void _onLongPressEnd() {
    if (_isLongPressingSpeed) {
      _isLongPressingSpeed = false;
      _kernelSetRate(_preLongPressSpeed);
      setState(() {});
    }
  }

  void _showHud(
    IconData icon,
    String text, {
    bool isSeek = false,
    Duration duration = const Duration(milliseconds: 1500),
  }) {
    if (!mounted) return;
    setState(() {
      _gestureHudIcon = icon;
      _gestureHudText = text;
      _isSeekGestureHud = isSeek;
      _showGestureHud = true;
    });
    _gestureHudTimer?.cancel();
    _gestureHudTimer = Timer(duration, () {
      if (mounted) {
        setState(() {
          _showGestureHud = false;
          _isSeekGestureHud = false;
        });
      }
    });
  }

  void _onScaleStart(ScaleStartDetails details, BoxConstraints constraints) {
    if (details.pointerCount >= 2 && _isFullscreen && !_isLocked) {
      _isPinching = true;
      _baseVideoScale = _videoScale;
      _panMode = 'none';
      _startOverlayTimer();
      return;
    }
    _isPinching = false;
    _dragStartX = details.localFocalPoint.dx;
    _dragStartY = details.localFocalPoint.dy;
    _panMode = 'none';
    _isDraggingSeek = false;
    _isDraggingLeft = false;
    _isDraggingRight = false;
    _seekTargetSeconds = _position.inSeconds.toDouble();
    _dragStartBrightness = _currentBrightness;
    _dragStartVolume = _currentVolume;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, BoxConstraints constraints) {
    if (details.pointerCount >= 2) {
      if (_isFullscreen && !_isLocked) {
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
    if (_isPinching || _isLongPressingSpeed) return;

    final dx = details.localFocalPoint.dx - _dragStartX;
    final dy = details.localFocalPoint.dy - _dragStartY;

    // 动态意图仲裁：即便在左右侧区域，若水平位移大于垂直位移，依然优先支持水平快进/快退！
    if (_panMode == 'none') {
      if (dx.abs() > 8 || dy.abs() > 8) {
        if (dx.abs() >= dy.abs()) {
          _panMode = 'seek';
          _isDraggingSeek = true;
        } else {
          if (_dragStartX < constraints.maxWidth * 0.5) {
            _panMode = 'brightness';
            _isDraggingLeft = true;
          } else {
            _panMode = 'volume';
            _isDraggingRight = true;
          }
        }
      } else {
        return;
      }
    }

    if (_panMode == 'seek' || _isDraggingSeek) {
      final factor = dx / constraints.maxWidth;
      final totalSec = max(1.0, _duration.inSeconds.toDouble());
      final target = (_position.inSeconds + factor * min(totalSec, 600.0)).clamp(0.0, totalSec);
      _seekTargetSeconds = target;

      final deltaSec = (target - _position.inSeconds).toInt();
      _showHud(
        deltaSec >= 0 ? Icons.fast_forward : Icons.fast_rewind,
        _formatDuration(Duration(seconds: target.toInt())),
        isSeek: true,
        duration: const Duration(milliseconds: 700),
      );
    } else if (_panMode == 'brightness' || _isDraggingLeft) {
      final delta = -dy / constraints.maxHeight;
      setState(() {
        _currentBrightness = (_dragStartBrightness + delta * 1.2).clamp(0.01, 1.0);
      });
      _applyBrightness(_currentBrightness);
      _showHud(Icons.brightness_6, '亮度: ${(_currentBrightness * 100).toInt()}%');
    } else if (_panMode == 'volume' || _isDraggingRight) {
      final delta = -dy / constraints.maxHeight;
      _currentVolume = (_dragStartVolume + delta * 120.0).clamp(0.0, 100.0);
      _kernelSetVolume(_currentVolume);
      _showHud(Icons.volume_up, '音量: ${_currentVolume.toInt()}%');
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_isPinching) {
      _isPinching = false;
      return;
    }
    if ((_panMode == 'seek' || _isDraggingSeek) && _player != null) {
      _kernelSeek(Duration(seconds: _seekTargetSeconds.toInt()));
    }
    _panMode = 'none';
    _isDraggingSeek = false;
    _isDraggingLeft = false;
    _isDraggingRight = false;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final isDeviceLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final isMobileLandscape = !isDesktop && (_isLandscape || isDeviceLandscape);

    Widget pageBody;
    if (_isLoading) {
      pageBody = const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color(0xFFE5A00D))),
      );
    } else if (_vodDetail == null) {
      pageBody = Scaffold(
        backgroundColor: Colors.black,
        body: _buildErrorView(),
      );
    } else if (isDesktop) {
      // 大屏/桌面模式 (Windows/TV)：窗口模式为两栏布局，全屏模式为沉浸播放器
      if (_isFullscreen) {
        pageBody = Scaffold(
          backgroundColor: Colors.black,
          body: _buildLandscapePlayer(),
        );
      } else {
        pageBody = _buildDesktopTvLayout();
      }
    } else if (PipAndMediaSessionService().isInPipNotifier.value) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildVideoPlayerArea(),
      );
    } else {
      // 手机移动端：全屏状态展示沉浸全屏播放器 (支持全屏横屏与全屏竖屏)；非全屏展示竖屏详情小屏
      if (_isFullscreen) {
        pageBody = Scaffold(
          backgroundColor: Colors.black,
          body: _buildLandscapePlayer(),
        );
      } else {
        pageBody = Scaffold(
          backgroundColor: Colors.black,
          body: _buildPortraitLayout(),
        );
      }
    }

    final mainWidget = PopScope(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isFullscreen) {
          _exitFullscreen();
        }
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.space) {
              _kernelPlayOrPause();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              if (_isFullscreen) {
                setState(() => _isFullscreen = false);
                AppLogger.hideGlobalDebugFabNotifier.value = false;
                return KeyEventResult.handled;
              }
            }
            if (event.logicalKey == LogicalKeyboardKey.keyF || event.logicalKey == LogicalKeyboardKey.f11) {
              setState(() => _isFullscreen = !_isFullscreen);
              AppLogger.hideGlobalDebugFabNotifier.value = _isFullscreen;
      AppLogger.hideGlobalDebugFabNotifier.value = _isFullscreen;
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              final target = max(0, _position.inSeconds - 10);
              _kernelSeek(Duration(seconds: target));
              _showHud(Icons.fast_rewind, '-10s');
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              final target = min(_duration.inSeconds, _position.inSeconds + 10);
              _kernelSeek(Duration(seconds: target));
              _showHud(Icons.fast_forward, '+10s');
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          onHover: (event) {
            if (isDesktop) {
              final nearTop = event.localPosition.dy < 48;
              if (nearTop != _isTopHovered) {
                setState(() => _isTopHovered = nearTop);
              }
            }
          },
          onExit: (_) {
            if (isDesktop && _isTopHovered) {
              setState(() => _isTopHovered = false);
            }
          },
          child: pageBody,
        ),
      ),
    );

    return mainWidget;
  }

  /// Windows / TV 端专属窗口详情布局：左上角播放器，右上角详情，下方展示线路与剧集列表
  Widget _buildDesktopTvLayout() {
    final activeSite = widget.repository.activeSite;

    return Scaffold(
      backgroundColor: const Color(0xFF101D1A),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _themeService.currentGradient.colors,
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // 顶栏操作区
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(
                          color: Color(0x33000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _vodDetail?.vodName ?? '影视详情',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        _isFavorited ? Icons.star : Icons.star_border,
                        color: _isFavorited ? const Color(0xFFE5A00D) : Colors.white,
                        size: 22,
                      ),
                      tooltip: '收藏',
                      onPressed: _toggleFavorite,
                    ),
                  ],
                ),
              ),

              // 主视口：左上角播放器 + 右上角详情，下方线路与选集
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final playerWidth = min(620.0, constraints.maxWidth * 0.54);
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 1. 左上角播放器
                            SizedBox(
                              width: playerWidth,
                              child: AspectRatio(
                                aspectRatio: 16 / 9,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Stack(
                                    children: [
                                      _buildVideoPlayerArea(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 18),
                            // 2. 右上方影视元数据详情
                            Expanded(
                              child: _buildVodMetaInfo(activeSite?.name),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                    const Divider(color: Colors.white12),
                    const SizedBox(height: 8),

                    // 3. 下方线路与剧集选择
                    _buildSourceAndEpisodesSection(),
                    const SizedBox(height: 18),
                    _buildQuickSearchSection(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    final activeSite = widget.repository.activeSite;

    return SafeArea(
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildVideoPlayerArea(),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _themeService.currentGradient.colors,
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
                children: [
                  _buildVodMetaInfo(activeSite?.name),
                  const SizedBox(height: 12),
                  _buildSourceAndEpisodesSection(),
                  const SizedBox(height: 16),
                  _buildQuickSearchSection(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapePlayer() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildVideoPlayerArea(),
        if (_showRightEpisodeDrawer) _buildLandscapeRightDrawer(),
        if (_showRightFitDrawer) _buildLandscapeFitDrawer(),
      ],
    );
  }

  Widget _buildVideoPlayerArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          fit: StackFit.expand,
          children: [
            if (_isExoActive && _exoController != null && _exoController!.value.isInitialized)
              Center(
                child: Transform.scale(
                  scale: _isFullscreen ? _videoScale : 1.0,
                  child: SizedBox.expand(
                    child: FittedBox(
                      fit: _videoFit,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: _customAspectRatio != null
                            ? 1000.0
                            : (_exoController!.value.size.width > 0 ? _exoController!.value.size.width : 1280.0),
                        height: _customAspectRatio != null
                            ? (1000.0 / _customAspectRatio!)
                            : (_exoController!.value.size.height > 0 ? _exoController!.value.size.height : 720.0),
                        child: VideoPlayer(_exoController!),
                      ),
                    ),
                  ),
                ),
              )
            else if (!_isExoActive && _videoController != null)
              Center(
                child: Transform.scale(
                  scale: _isFullscreen ? _videoScale : 1.0,
                  child: _customAspectRatio != null
                      ? AspectRatio(
                          aspectRatio: _customAspectRatio!,
                          child: Video(
                            controller: _videoController!,
                            fit: _videoFit,
                            controls: NoVideoControls,
                            subtitleViewConfiguration: _buildSubtitleViewConfig(),
                          ),
                        )
                      : Video(
                          controller: _videoController!,
                          fit: _videoFit,
                          controls: NoVideoControls,
                          subtitleViewConfiguration: _buildSubtitleViewConfig(),
                        ),
                ),
              )
            else
              Container(color: Colors.black),

            DanmakuView(
              danmakus: _danmakus,
              currentPosition: _position,
              isPlaying: _isPlaying,
              config: _danmakuConfig,
              playbackRate: _playbackRate,
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
                      const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 52),
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

            // 统一手势层：置于视频与弹幕之上，并包裹控制栏浮层；无论控件是否显示，未锁定时均可滑动调节亮度/音量/快进快退
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleOverlay,
                onDoubleTap: () {
                  if (_isLocked) return;
                  if (_isFullscreen) {
                    _kernelPlayOrPause();
                  } else {
                    _enterFullscreen();
                  }
                },
                onScaleStart: (d) {
                  if (!_isLocked) _onScaleStart(d, constraints);
                },
                onScaleUpdate: (d) {
                  if (!_isLocked) _onScaleUpdate(d, constraints);
                },
                onScaleEnd: (d) {
                  if (!_isLocked) _onScaleEnd(d);
                },
                onLongPressStart: (_) => _onLongPressStart(),
                onLongPressEnd: (_) => _onLongPressEnd(),
                onLongPressCancel: () => _onLongPressEnd(),
                child: _showOverlay
                    ? _buildControlsOverlay()
                    : const ColoredBox(color: Colors.transparent),
              ),
            ),



              // 长按倍速顶部居中指示器
              if (_isLongPressingSpeed)
                Positioned(
                  top: _isFullscreen ? 28 : 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE5A00D), width: 1.2),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.fast_forward, color: Color(0xFFE5A00D), size: 18),
                          const SizedBox(width: 6),
                          Text(
                            '$_longPressSpeedOption 倍速播放中',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              if (_showGestureHud && _isSeekGestureHud)
                Positioned(
                  top: _isFullscreen ? 22 : 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2B2F36).withOpacity(0.82),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_gestureHudIcon, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            _gestureHudText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              if (_showGestureHud && !_isSeekGestureHud)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE5A00D), width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_gestureHudIcon, color: const Color(0xFFE5A00D), size: 28),
                        const SizedBox(width: 12),
                        Text(
                          _gestureHudText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // 视频加载与缓冲指示器 (控制栏隐藏或锁屏时居中展示；控制栏显示时环绕在居中播放按钮外圈)
              if ((_isPlayerLoading || _isBuffering) && (!_showOverlay || _isLocked))
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
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.5,
                          shadows: [
                            Shadow(
                              offset: Offset(0, 1),
                              blurRadius: 4,
                              color: Colors.black87,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),



            ],
          );
      },
    );
  }


  Widget _buildCenterPlayButton({required double iconSize, required bool isBuffering}) {
    final btnSize = iconSize + 18;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: btnSize,
          height: btnSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: btnSize,
                height: btnSize,
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: isBuffering ? null : Border.all(color: Colors.white24),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: iconSize,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                  onPressed: _kernelPlayOrPause,
                ),
              ),
              if (isBuffering)
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
        if (isBuffering)
          Positioned(
            top: btnSize + 8,
            child: Text(
              _networkSpeedStr,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                letterSpacing: 0.5,
                shadows: [
                  Shadow(offset: Offset(0, 1), blurRadius: 4, color: Colors.black87),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTopIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Color(0x33000000),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
        ),
      ),
    );
  }

  Widget _buildMediaBadgePill(String label, List<Color> colors, {Color borderColor = Colors.white24, bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 6, vertical: compact ? 1 : 1.5),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor, width: 0.7),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 9 : 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.3,
          height: 1.15,
        ),
      ),
    );
  }

  Widget _buildMediaBadgeRow({required String resolutionStr, bool compact = false}) {
    return Wrap(
      spacing: compact ? 4 : 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_badgeIso != null)
          _buildMediaBadgePill(
            _badgeIso!,
            const [Color(0xFF3949AB), Color(0xFF5C6BC0)],
            borderColor: const Color(0xFF9FA8DA),
            compact: compact,
          ),
        if (_badgeHdr != null)
          _buildMediaBadgePill(
            _badgeHdr!,
            _badgeHdr == '杜比视界'
                ? const [Color(0xFF6A1B9A), Color(0xFFE5A00D)]
                : const [Color(0xFFE65100), Color(0xFFFF9800)],
            borderColor: _badgeHdr == '杜比视界' ? const Color(0xFFFFD54F) : const Color(0xFFFFCC80),
            compact: compact,
          ),
        if (_badgeResolution != null)
          _buildMediaBadgePill(
            _badgeResolution!,
            const [Color(0xFF0277BD), Color(0xFF29B6F6)],
            borderColor: const Color(0xFF81D4FA),
            compact: compact,
          ),
        if (_badgeAudio != null)
          _buildMediaBadgePill(
            _badgeAudio!,
            const [Color(0xFF00695C), Color(0xFF26A69A)],
            borderColor: const Color(0xFF80CBC4),
            compact: compact,
          ),
        if (resolutionStr.isNotEmpty)
          Text(
            resolutionStr,
            style: TextStyle(
              color: const Color(0xFFB0BEC5),
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );
  }

  Widget _buildControlsOverlay() {
    if (PipAndMediaSessionService().isInPipNotifier.value) {
      return const SizedBox.shrink();
    }
    final resolutionStr = (_videoWidth != null && _videoHeight != null && _videoWidth! > 0 && _videoHeight! > 0)
        ? '$_videoWidth × $_videoHeight'
        : '';

    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final isFullscreenMode = _isFullscreen;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.black87,
            Colors.transparent,
            Colors.transparent,
            Colors.black87,
          ],
          stops: isFullscreenMode ? const [0.0, 0.22, 0.75, 1.0] : const [0.0, 0.35, 0.65, 1.0],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        children: [
          // ─────────────────────────────────────────────────────────────
          // 1. 顶部操作栏 (横全屏展示完整详情与电量；竖屏小窗展示极简单行，避免视觉挤压)
          // ─────────────────────────────────────────────────────────────
          if (isFullscreenMode)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () {
                          if (_isFullscreen) {
                            _exitFullscreen();
                          } else {
                            Navigator.pop(context);
                          }
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: Color(0x33000000),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${_vodDetail?.vodName ?? ""}：$_currentEpisodeName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                letterSpacing: 0.3,
                              ),
                            ),
                            if (resolutionStr.isNotEmpty || _badgeHdr != null || _badgeAudio != null || _badgeIso != null) ...[
                              const SizedBox(height: 3),
                              _buildMediaBadgeRow(resolutionStr: resolutionStr, compact: false),
                            ],
                          ],
                        ),
                      ),

                      _buildTopIconButton(
                        icon: Icons.cast,
                        tooltip: '投屏',
                        onTap: _showCastDialog,
                      ),
                      _buildTopIconButton(
                        icon: Icons.info_outline,
                        tooltip: '播放链接详情',
                        onTap: _showPlayLinkDetailDialog,
                      ),
                      _buildTopIconButton(
                        icon: _isFavorited ? Icons.star : Icons.star_border,
                        tooltip: '收藏',
                        color: _isFavorited ? const Color(0xFFE5A00D) : Colors.white,
                        onTap: _toggleFavorite,
                      ),
                      const SizedBox(width: 6),
                      const RealtimeBatteryTimeWidget(),


                    ],
                  ),
                ),
              ),
            )
          else
            // 竖屏小窗精简顶栏 (返回 + 剧名 + 极简设置，高度收敛，绝不侵占画面)
            Positioned(
              top: 6,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Color(0x33000000),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${_vodDetail?.vodName ?? ""}：$_currentEpisodeName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        if (resolutionStr.isNotEmpty || _badgeHdr != null || _badgeAudio != null || _badgeIso != null) ...[
                          const SizedBox(height: 2),
                          _buildMediaBadgeRow(resolutionStr: resolutionStr, compact: true),
                        ],
                      ],
                    ),
                  ),
                  _buildTopIconButton(
                    icon: Icons.info_outline,
                    tooltip: '播放详情',
                    onTap: _showPlayLinkDetailDialog,
                  ),
                  _buildTopIconButton(
                    icon: Icons.cast,
                    tooltip: '投屏',
                    onTap: _showCastDialog,
                  ),
                  _buildTopIconButton(
                    icon: Icons.settings_outlined,
                    tooltip: '播放控件设置',
                    onTap: _showPortraitPlayerControlsSheet,
                  ),
                ],
              ),
            ),

          // ─────────────────────────────────────────────────────────────
          // 2. 屏幕左侧：弹幕 3 按钮 (全屏与竖屏小屏均展示；横屏全屏向右偏移避开摄像头挖孔)
          // ─────────────────────────────────────────────────────────────
          Positioned(
            left: (_isFullscreen && _isLandscape)
                ? max(48.0, MediaQuery.of(context).padding.left + 16.0)
                : 10.0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. 弹幕开关（电视框+弹+角标，对齐参考图）
                  Tooltip(
                    message: _danmakuConfig.enabled ? '关闭弹幕' : '开启弹幕',
                    child: InkWell(
                      onTap: () {
                        setState(() => _danmakuConfig.enabled = !_danmakuConfig.enabled);
                        _danmakuService.saveConfig(_danmakuConfig);
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: SizedBox(
                          width: _isFullscreen ? 30 : 26,
                          height: _isFullscreen ? 28 : 24,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Center(
                                child: Icon(
                                  Icons.tv,
                                  color: _danmakuConfig.enabled ? Colors.white : Colors.white54,
                                  size: _isFullscreen ? 28 : 24,
                                ),
                              ),
                              Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 3),
                                  child: Text(
                                    '弹',
                                    style: TextStyle(
                                      color: _danmakuConfig.enabled ? Colors.white : Colors.white54,
                                      fontSize: _isFullscreen ? 10 : 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: -1,
                                bottom: -1,
                                child: Container(
                                  padding: const EdgeInsets.all(1),
                                  decoration: const BoxDecoration(
                                    color: Colors.black87,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    _danmakuConfig.enabled ? Icons.check_circle : Icons.cancel,
                                    color: _danmakuConfig.enabled ? Colors.white : Colors.white54,
                                    size: _isFullscreen ? 12 : 10,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: _isFullscreen ? 12 : 8),

                  // 2. 弹幕设置（电视框+弹+齿轮，对齐参考图）
                  Tooltip(
                    message: '弹幕设置',
                    child: InkWell(
                      onTap: _showDanmakuSettingsDialog,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: SizedBox(
                          width: _isFullscreen ? 30 : 26,
                          height: _isFullscreen ? 28 : 24,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Center(
                                child: Icon(
                                  Icons.tv,
                                  color: Colors.white,
                                  size: _isFullscreen ? 28 : 24,
                                ),
                              ),
                              Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 3),
                                  child: Text(
                                    '弹',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: _isFullscreen ? 10 : 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: -1,
                                bottom: -1,
                                child: Container(
                                  padding: const EdgeInsets.all(1),
                                  decoration: const BoxDecoration(
                                    color: Colors.black87,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.settings,
                                    color: Colors.white,
                                    size: _isFullscreen ? 12 : 10,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: _isFullscreen ? 12 : 8),

                  // 3. 弹幕搜索
                  Tooltip(
                    message: '搜索与匹配弹幕',
                    child: InkWell(
                      onTap: _showDanmakuSearchDialog,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.search,
                          color: Colors.white,
                          size: _isFullscreen ? 25 : 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ─────────────────────────────────────────────────────────────
          // 3. 屏幕中心控制 (全屏模式显示上一集、播放/暂停、下一集；竖屏小窗仅居中单一精致播放按钮，绝不重叠)
          // ─────────────────────────────────────────────────────────────
          if (!_isLocked)
            Center(
              child: isFullscreenMode
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_previous, color: Colors.white),
                          onPressed: _playPreviousEpisode,
                        ),
                        const SizedBox(width: 24),
                        _buildCenterPlayButton(
                          iconSize: 46,
                          isBuffering: _isPlayerLoading || _isBuffering,
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_next, color: Colors.white),
                          onPressed: _playNextEpisode,
                        ),
                      ],
                    )
                  : _buildCenterPlayButton(
                      iconSize: 36,
                      isBuffering: _isPlayerLoading || _isBuffering,
                    ),
            ),

          // ─────────────────────────────────────────────────────────────
          // 4. 屏幕右侧浮动控制 (全屏含锁屏/旋转/画中画；竖屏小窗含画中画入口)
          // ─────────────────────────────────────────────────────────────
          if (isFullscreenMode || Platform.isAndroid)
            Positioned(
              right: isFullscreenMode ? 14 : 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isFullscreenMode) ...[
                      IconButton(
                        icon: Icon(
                          _isLocked ? Icons.lock : Icons.lock_open,
                          color: _isLocked ? const Color(0xFFE5A00D) : Colors.white70,
                        ),
                        tooltip: _isLocked ? '点击解锁' : '点击锁定',
                        onPressed: () {
                          setState(() => _isLocked = !_isLocked);
                          final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
                          if (!isDesktop) {
                            if (_isLandscape) {
                              SystemChrome.setPreferredOrientations([
                                DeviceOrientation.landscapeLeft,
                                DeviceOrientation.landscapeRight,
                              ]);
                            } else {
                              SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
                            }
                          }
                        },
                      ),
                      if (!_isLocked) ...[
                        const SizedBox(height: 8),
                        IconButton(
                          icon: const Icon(Icons.screen_rotation, color: Colors.white70),
                          tooltip: isDesktop ? '退出全屏' : (_isLandscape ? '切换至全屏竖屏' : '切换至全屏横屏'),
                          onPressed: () => _toggleFullscreenOrientation(),
                        ),
                      ],
                    ],
                    if (Platform.isAndroid && !isFullscreenMode && !_isLocked) ...[
                      IconButton(
                        icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white, size: 24),
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

          // ─────────────────────────────────────────────────────────────
          // 5. 底部控制栏与进度条 (竖屏小窗严格单行平铺，绝无重叠；横屏展示全功能底栏)
          // ─────────────────────────────────────────────────────────────
          if (!_isLocked)
            Positioned(
              left: isFullscreenMode ? 16 : 8,
              right: isFullscreenMode ? 16 : 8,
              bottom: isFullscreenMode ? 12 : 4,
              child: SafeArea(
                top: false,
                bottom: isFullscreenMode,
                child: isFullscreenMode
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 横屏全屏进度条
                          Row(
                            children: [
                              Text(_formatDuration(_position),
                                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3.5,
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                                    activeTrackColor: _themeService.accentColor,
                                    secondaryActiveTrackColor: Colors.white54,
                                    inactiveTrackColor: Colors.white24,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value: _position.inSeconds.toDouble().clamp(
                                        0.0, max(1.0, _duration.inSeconds.toDouble())),
                                    secondaryTrackValue: _bufferedPosition.inSeconds.toDouble().clamp(
                                        0.0, max(1.0, _duration.inSeconds.toDouble())),
                                    max: max(1.0, _duration.inSeconds.toDouble()),
                                    onChanged: (val) {
                                      _startOverlayTimer();
                                      _kernelSeek(Duration(seconds: val.toInt()));
                                    },
                                  ),
                                ),
                              ),
                              Text(_formatDuration(_duration),
                                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),

                          // 横屏全屏功能胶囊行
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildBottomPillButton(_playerCoreName, _showPlayerCoreSheet),
                                  _buildBottomPillButton(
                                    _isHardwareDecode ? '硬解' : '软解',
                                    _toggleHardwareDecode,
                                    isHighlight: _isHardwareDecode,
                                  ),
                                  _buildBottomPillButton(
  _playbackRate.toStringAsFixed(2),
  _cycleNextSpeed,
  buttonKey: _speedButtonKey,
  onLongPress: _showSpeedMenu,
),
                                  _buildBottomPillButton(
  _fitName,
  _cycleNextFit,
  buttonKey: _fitButtonKey,
  onLongPress: _showFitMenu,
),
                                  _buildBottomPillButton('刷新', _refreshPlayback),
                                  _buildBottomPillButton(
                                    _isLooping ? '循环' : '顺序',
                                    () => setState(() => _isLooping = !_isLooping),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildBottomPillButton('字幕', _showSubtitleTrackDialog),
                                  _buildBottomPillButton('音轨', _showAudioTrackDialog),
                                  _buildBottomPillButton('视轨', _showVideoTrackDialog),
                                  _buildBottomPillButton(
                                    _formatSeconds(_skipIntroSeconds),
                                    () async {
                                      final sec = _position.inSeconds;
                                      setState(() => _skipIntroSeconds = sec);
                                      await StorageBridge.setValue('player_skip_intro_${_getVodSkipKey()}', sec.toString());
                                      _showHud(Icons.fast_forward, '已设置跳过片头 ${_formatSeconds(sec)}');
                                    },
                                    onLongPress: () async {
                                      setState(() => _skipIntroSeconds = 0);
                                      await StorageBridge.setValue('player_skip_intro_${_getVodSkipKey()}', '0');
                                      _showHud(Icons.restore, '已重置跳过片头');
                                    },
                                  ),
                                  _buildBottomPillButton(
                                    _formatSeconds(_skipOutroSeconds),
                                    () async {
                                      if (_duration.inSeconds <= 0) {
                                        _showHud(Icons.info_outline, '暂未获取到视频总时长');
                                        return;
                                      }
                                      final sec = (_duration.inSeconds - _position.inSeconds).clamp(0, _duration.inSeconds);
                                      setState(() => _skipOutroSeconds = sec);
                                      await StorageBridge.setValue('player_skip_outro_${_getVodSkipKey()}', sec.toString());
                                      _showHud(Icons.skip_next, '已设置跳过片尾 ${_formatSeconds(sec)}');
                                    },
                                    onLongPress: () async {
                                      setState(() => _skipOutroSeconds = 0);
                                      await StorageBridge.setValue('player_skip_outro_${_getVodSkipKey()}', '0');
                                      _showHud(Icons.restore, '已重置跳过片尾');
                                    },
                                  ),
                                  _buildBottomPillButton(
                                    '弹幕',
                                    _showMatchedDanmakuDialog,
                                    onLongPress: _showDanmakuSearchDialog,
                                    isHighlight: _danmakuConfig.enabled,
                                  ),
                                  _buildBottomPillButton(
                                    '选集',
                                    () => setState(() => _showRightEpisodeDrawer = true),
                                    isHighlight: true,
                                  ),
                                  
                                ],
                              ),
                            ],
                          ),
                        ],
                      )
                    : // 竖屏小窗单行紧凑布局：播放/暂停 + 时间 + 进度条 + 总时长 + 旋转按键 (彻底避免组件遮挡与重叠)
                    Row(
                        children: [
                          InkWell(
                            onTap: () => _player?.playOrPause(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                              child: Icon(
                                _isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                          Text(
                            _formatDuration(_position),
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2.8,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.0),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
                                activeTrackColor: _themeService.accentColor,
                                secondaryActiveTrackColor: Colors.white54,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: _position.inSeconds.toDouble().clamp(
                                    0.0, max(1.0, _duration.inSeconds.toDouble())),
                                secondaryTrackValue: _bufferedPosition.inSeconds.toDouble().clamp(
                                    0.0, max(1.0, _duration.inSeconds.toDouble())),
                                max: max(1.0, _duration.inSeconds.toDouble()),
                                onChanged: (val) {
                                  _startOverlayTimer();
                                  _kernelSeek(Duration(seconds: val.toInt()));
                                },
                              ),
                            ),
                          ),
                          Text(
                            _formatDuration(_duration),
                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message: '进入全屏',
                            child: InkWell(
                              onTap: () => _enterFullscreen(landscape: true),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                child: Icon(
                                  Icons.fullscreen,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomPillButton(String text, VoidCallback onTap, {Key? buttonKey, VoidCallback? onLongPress, bool isHighlight = false}) {
    return InkWell(
      key: buttonKey,
      onTap: () {
        _startOverlayTimer();
        onTap();
      },
      onLongPress: onLongPress != null ? () {
        _startOverlayTimer();
        onLongPress();
      } : null,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Text(
          text,
          style: TextStyle(
            color: isHighlight ? _themeService.accentColor : Colors.white,
            fontSize: 12.5,
            fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  void _playPreviousEpisode() {
    final sources = _vodDetail?.playSources ?? [];
    if (sources.isEmpty) return;
    final episodes = sources[_selectedSourceIndex].episodes;
    final curIndex = episodes.indexWhere((e) => e.name == _currentEpisodeName);
    if (curIndex > 0) {
      _playEpisode(sources[_selectedSourceIndex].name, episodes[curIndex - 1]);
    } else {
      _showHud(Icons.info, '已经是第一集了');
    }
  }

  /// 播放完成自动连播/循环逻辑处理 (响应 stream.completed 或片尾跳过)
  void _handlePlaybackCompleted() {
    if (_isLooping) {
      _hasSkippedIntro = false;
      _hasSkippedOutro = false;
      _kernelSeek(Duration.zero);
      _kernelPlay();
      _showHud(Icons.replay, '单集循环：重新开始播放');
    } else {
      _showHud(Icons.skip_next, '本集播放完毕，为您顺序播放下一集');
      _playNextEpisode();
    }
  }

  void _playNextEpisode() {
    final sources = _vodDetail?.playSources ?? [];
    if (sources.isEmpty) return;
    final episodes = sources[_selectedSourceIndex].episodes;
    final curIndex = episodes.indexWhere((e) => e.name == _currentEpisodeName);
    if (curIndex >= 0 && curIndex < episodes.length - 1) {
      _playEpisode(sources[_selectedSourceIndex].name, episodes[curIndex + 1]);
    } else {
      _showHud(Icons.info, '已经是最后一集了');
    }
  }

  Widget _buildLandscapeRightDrawer() {
    final sources = _vodDetail?.playSources ?? [];
    final currentEpisodes = sources.isNotEmpty && _selectedSourceIndex < sources.length
        ? sources[_selectedSourceIndex].episodes
        : <EpisodeItem>[];

    final displayList = _isReversedOrder
        ? currentEpisodes.reversed.toList()
        : currentEpisodes;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _showRightEpisodeDrawer = false),
            child: Container(color: Colors.transparent),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          child: Container(
            width: 240,
            decoration: const BoxDecoration(
              color: Colors.white, // 严格按图 3 纯白背景
              borderRadius: BorderRadius.horizontal(left: Radius.circular(20)),
              boxShadow: [
                BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(-3, 0)),
              ],
            ),
            child: SafeArea(
              left: false,
              child: Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                      itemCount: displayList.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, idx) {
                        final ep = displayList[idx];
                        final isCurrent = ep.name == _currentEpisodeName;

                        return InkWell(
                          onTap: () {
                            _playEpisode(sources[_selectedSourceIndex].name, ep);
                            setState(() => _showRightEpisodeDrawer = false);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFDCDCDC), // 浅灰描边
                                width: 1.2,
                              ),
                            ),
                            child: Text(
                              ep.name,
                              style: TextStyle(
                                color: isCurrent ? const Color(0xFF2196F3) : const Color(0xFF333333), // 当前集蓝字，其他暗黑字
                                fontSize: 15,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              ),
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
  }

  static const List<double> _speedCycleList = [1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 0.25, 0.5, 0.75];

  void _cycleNextSpeed() {
    int curIndex = _speedCycleList.indexWhere((s) => (s - _playbackRate).abs() < 0.05);
    int nextIndex = (curIndex + 1) % _speedCycleList.length;
    double nextSpeed = _speedCycleList[nextIndex];
    setState(() => _playbackRate = nextSpeed);
    _kernelSetRate(nextSpeed);
  }

  void _cycleNextFit() {
    int curIndex = _fitOptions.indexWhere((opt) => opt['name'] == _fitName);
    int nextIndex = (curIndex + 1) % _fitOptions.length;
    final nextOpt = _fitOptions[nextIndex];
    _applyVideoFit(nextOpt['name'], nextOpt['fit'], nextOpt['aspectRatio']);
  }

  void _showAnchoredPopupMenu<T>({
    required GlobalKey anchorKey,
    required String title,
    required List<({String label, T value, bool isSelected})> items,
    required void Function(T) onSelected,
    double width = 148,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;

    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenSize = MediaQuery.of(context).size;
    final left = (pos.dx + size.width / 2 - width / 2).clamp(12.0, screenSize.width - width - 12.0);
    final bottom = screenSize.height - pos.dy + 8.0;
    final maxHeight = (pos.dy - 24.0).clamp(120.0, 320.0);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (entry.mounted) entry.remove();
              },
            ),
          ),
          Positioned(
            left: left,
            bottom: bottom,
            width: width,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: const Color(0xF21E2028),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.45),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        title,
                        style: const TextStyle(color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white10),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: items.map((item) {
                            return InkWell(
                              onTap: () {
                                if (entry.mounted) entry.remove();
                                onSelected(item.value);
                              },
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                color: item.isSelected ? const Color(0xFFE5A00D).withOpacity(0.16) : Colors.transparent,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.label,
                                        style: TextStyle(
                                          color: item.isSelected ? const Color(0xFFE5A00D) : Colors.white,
                                          fontSize: 13,
                                          fontWeight: item.isSelected ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                    if (item.isSelected)
                                      const Icon(Icons.check, size: 15, color: Color(0xFFE5A00D)),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
  }

  void _showSpeedMenu() {
    final speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0];
    _showAnchoredPopupMenu<double>(
      anchorKey: _speedButtonKey,
      title: '播放速度',
      width: 132,
      items: speeds
          .map((s) => (label: '${s}x', value: s, isSelected: _playbackRate == s))
          .toList(),
      onSelected: (s) {
        print('⚡ [PLAYER] 切换倍速: ${s}x');
        setState(() => _playbackRate = s);
        _kernelSetRate(s);
        _showHud(Icons.speed, '倍速 ${s}x');
      },
    );
  }

  void _applyVideoFit(String name, BoxFit fit, double? aspectRatio) {
    print('🖼️ [PLAYER] 切换画面比例: $name');
    setState(() {
      _fitName = name;
      _videoFit = fit;
      _customAspectRatio = aspectRatio;
      _showRightFitDrawer = false;
    });
  }

  void _showFitMenu() {
    _showAnchoredPopupMenu<Map<String, dynamic>>(
      anchorKey: _fitButtonKey,
      title: '画面尺寸',
      width: 152,
      items: _fitOptions
          .map((opt) => (label: opt['name'] as String, value: opt, isSelected: _fitName == opt['name']))
          .toList(),
      onSelected: (opt) {
        _applyVideoFit(opt['name'], opt['fit'], opt['aspectRatio']);
        _showHud(Icons.aspect_ratio, '画面: ${opt['name']}');
      },
    );
  }

  Widget _buildLandscapeFitDrawer() {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _showRightFitDrawer = false),
            child: Container(color: Colors.black45),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          child: Container(
            width: 300,
            color: const Color(0xFF181A22).withOpacity(0.95),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Text('画面比例',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _fitOptions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, idx) {
                        final opt = _fitOptions[idx];
                        final isSel = _fitName == opt['name'];
                        return ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tileColor: isSel ? const Color(0xFFE5A00D).withOpacity(0.2) : Colors.transparent,
                          title: Text(opt['name'],
                              style: TextStyle(
                                  color: isSel ? const Color(0xFFE5A00D) : Colors.white,
                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
                          onTap: () => _applyVideoFit(opt['name'], opt['fit'], opt['aspectRatio']),
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
  }

  Widget _buildVodMetaInfo(String? siteName) => buildDetailVodMetaInfo(
        context: context,
        vodDetail: _vodDetail,
        siteName: siteName,
        vodRemarks: widget.vodItem?.vodRemarks,
        onShowHud: _showHud,
      );

  Widget _buildSourceAndEpisodesSection() => buildDetailSourceAndEpisodesSection(
        context: context,
        vodDetail: _vodDetail,
        selectedSourceIndex: _selectedSourceIndex,
        currentEpisodeName: _currentEpisodeName,
        isReversedOrder: _isReversedOrder,
        isLandscape: _isLandscape,
        sourceScrollController: _sourceScrollController,
        themeService: _themeService,
        onSelectSource: (idx) => setState(() => _selectedSourceIndex = idx),
        onToggleOrder: () => setState(() => _isReversedOrder = !_isReversedOrder),
        onPlayEpisode: _playEpisode,
        onShowEpisodeSheet: _showEpisodeListBottomSheet,
        onOpenDownloadSheet: _showEpisodeDownloadSheet,
        onShowHud: _showHud,
      );

  Widget _buildQuickSearchSection() => buildDetailQuickSearchSection(
        context: context,
        isQuickSearching: _isQuickSearching,
        quickSearchResults: _quickSearchResults,
        repository: widget.repository,
      );

  Widget _buildErrorView() => buildDetailErrorView(
        context: context,
        errorMsg: _playErrorMsg ?? '未能成功获取影视数据',
        onRetry: _loadDetailAndAutoPlay,
      );
}
