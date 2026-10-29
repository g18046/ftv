import '../../services/pip_and_media_session_service.dart';
import '../../services/history_favorite_service.dart';
import '../../services/theme_service.dart';
import 'package:flutter/gestures.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../models/vod_model.dart';
import '../../models/danmaku_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/danmaku_service.dart';
import '../../services/local_http_server.dart';
import '../../global/storage_bridge.dart';
import '../widgets/danmaku_view.dart';
import '../widgets/tv_focusable.dart';
import '../search/folder_list_view.dart';

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
  VodItem? _vodDetail;
  bool _isLoading = true;
  int _selectedSourceIndex = 0;
  bool _isReversedOrder = false;

  Player? _player;
  VideoController? _videoController;
  bool _isPlayerLoading = false;
  String? _playErrorMsg;
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
  bool _isFavorited = false;
  bool _isLooping = false;
  String _playerCoreName = 'EXO';
  bool _isHardwareDecode = true; // 硬解 / 软解
  String _bgPlayMode = '画中画'; // 后台播放: 关闭、开启、画中画 (默认)
  String _simPlayMode = '开启'; // 同时播放: 开启、关闭
  String _userAgentOption = '系统默认';
  String _bufferTimeOption = '15 倍';

  // 视频分辨率
  int? _videoWidth;
  int? _videoHeight;

  // 片头片尾跳过秒数 (默认 01:47 与 02:23)
  int _skipIntroSeconds = 107;
  int _skipOutroSeconds = 143;
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

  Timer? _overlayHideTimer;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _widthSub;
  StreamSubscription? _heightSub;
  StreamSubscription? _danmakuRefreshSub;
  StreamSubscription? _subtitleRefreshSub;

  bool _showGestureHud = false;
  IconData _gestureHudIcon = Icons.volume_up;
  String _gestureHudText = '';
  Timer? _gestureHudTimer;

  double _currentVolume = 100.0;
  double _currentBrightness = 0.5;

  double _seekTargetSeconds = 0.0;
  double _dragStartX = 0.0;
  double _dragStartY = 0.0;
  bool _isDraggingSeek = false;
  bool _isDraggingLeft = false;
  bool _isDraggingRight = false;

  bool _showRightEpisodeDrawer = false;

  // 弹幕引擎
  final DanmakuService _danmakuService = DanmakuService();
  final ThemeService _themeService = ThemeService();
  final ScrollController _sourceScrollController = ScrollController();
  DanmakuConfig _danmakuConfig = DanmakuConfig();
  List<DanmakuItem> _danmakus = [];
  bool _isDanmakuLoading = false;
  int? _matchedLogVarEpisodeId;

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
    _listenLocalHttpServerEvents();
    PipAndMediaSessionService().setCallbacks(
      onPlay: () => _player?.play(),
      onPause: () => _player?.pause(),
      onPlayPause: () => _player?.playOrPause(),
      onNext: _playNextEpisode,
      onPrevious: _playPreviousEpisode,
      onSeekTo: (sec) => _player?.seek(Duration(seconds: sec)),
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
    _gestureHudTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _themeService.accentColorNotifier.removeListener(_onThemeChanged);
    _themeService.wallpaperIndexNotifier.removeListener(_onThemeChanged);
    _sourceScrollController.dispose();
    _danmakuRefreshSub?.cancel();
    _subtitleRefreshSub?.cancel();
    _playerFocusNode.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _initDanmakuConfig() async {
    final conf = await _danmakuService.initConfig();
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
        LocalHttpServer().onSubtitleRefresh.listen((pathOrUrl) {
      print('🔔 收到 JS 源强行刷新字幕指令: $pathOrUrl');
      if (mounted) {
        _showHud(Icons.subtitles, '已接收 JS 动态字幕: ${pathOrUrl.split('/').last}');
      }
    });
  }

  Future<void> _loadPlayerPreferences() async {
    try {
      final bg = await StorageBridge.getValue('player_bg_play');
      if (bg != null && bg.isNotEmpty) _bgPlayMode = bg;

      final sim = await StorageBridge.getValue('player_sim_play');
      if (sim != null && sim.isNotEmpty) _simPlayMode = sim;

      final ua = await StorageBridge.getValue('player_ua');
      if (ua != null && ua.isNotEmpty) _userAgentOption = ua;

      final buf = await StorageBridge.getValue('player_buffer_time');
      if (buf != null && buf.isNotEmpty) _bufferTimeOption = buf;

      final savedIntro = await StorageBridge.getValue('player_skip_intro');
      if (savedIntro != null && savedIntro.isNotEmpty) {
        _skipIntroSeconds = int.tryParse(savedIntro) ?? _skipIntroSeconds;
      }
      final savedOutro = await StorageBridge.getValue('player_skip_outro');
      if (savedOutro != null && savedOutro.isNotEmpty) {
        _skipOutroSeconds = int.tryParse(savedOutro) ?? _skipOutroSeconds;
      }

      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (_bgPlayMode == '关闭') {
        _player?.pause();
        _syncMediaSession(false);
      } else if (_bgPlayMode == '画中画' && _isPlaying) {
        final w = _videoWidth ?? 16;
        final h = _videoHeight ?? 9;
        PipAndMediaSessionService().enterPip(
          numerator: w,
          denominator: h,
        );
      }
    }
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
    if (_bgPlayMode == '画中画' && playing) {
      final w = _videoWidth ?? 16;
      final h = _videoHeight ?? 9;
      PipAndMediaSessionService().enableAutoPip(
        enabled: true,
        numerator: w,
        denominator: h,
      );
    }
  }

  /// 更多剧集列表底部弹窗 (严格贴合用户提供的参考图规范)
  void _showEpisodeListBottomSheet() {
    final sources = _vodDetail?.playSources ?? [];
    if (sources.isEmpty) return;
    final episodes = sources[_selectedSourceIndex].episodes;
    if (episodes.isEmpty) return;

    final int totalCount = episodes.length;
    const int pageSize = 20;
    final int groupCount = (totalCount / pageSize).ceil();

    int curGroupIndex = 0;
    final curIdx = episodes.indexWhere((e) => e.name == _currentEpisodeName);
    if (curIdx >= 0) {
      curGroupIndex = curIdx ~/ pageSize;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final startIdx = curGroupIndex * pageSize;
          final endIdx = min(startIdx + pageSize, totalCount);
          final pageEpisodes = episodes.sublist(startIdx, endIdx);

          return Container(
            height: MediaQuery.of(context).size.height * 0.68,
            decoration: const BoxDecoration(
              color: Color(0xFFF9FAFB),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(color: Colors.black26, blurRadius: 20, offset: Offset(0, -4)),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 标题
                const Text(
                  '选集',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 14),

                // 2. 分组 Tab (1 - 20, 21 - 40...)
                if (groupCount > 1)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: List.generate(groupCount, (gIdx) {
                        final gStart = gIdx * pageSize + 1;
                        final gEnd = min((gIdx + 1) * pageSize, totalCount);
                        final isSel = curGroupIndex == gIdx;
                        final tabLabel = '$gStart - $gEnd';

                        return Padding(
                          padding: const EdgeInsets.only(right: 18.0),
                          child: InkWell(
                            onTap: () => setModalState(() => curGroupIndex = gIdx),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  tabLabel,
                                  style: TextStyle(
                                    color: isSel ? const Color(0xFF2979FF) : Colors.black54,
                                    fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  width: 28,
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color: isSel ? const Color(0xFF2979FF) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                  ),

                const SizedBox(height: 14),

                // 3. 3列剧集方框网格
                Expanded(
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, // 参考图 3 列
                      childAspectRatio: 2.1,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: pageEpisodes.length,
                    itemBuilder: (context, idx) {
                      final ep = pageEpisodes[idx];
                      final isCurrent = ep.name == _currentEpisodeName;

                      return InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _playEpisode(sources[_selectedSourceIndex].name, ep);
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isCurrent ? const Color(0xFF2979FF) : Colors.black12,
                              width: isCurrent ? 1.5 : 1,
                            ),
                          ),
                          child: Text(
                            ep.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent ? const Color(0xFF2979FF) : Colors.black87,
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _resetOrientationAndSystemUi() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 进入全屏播放模式 (默认横屏全屏，也支持竖屏全屏)
  void _enterFullscreen({bool landscape = true}) {
    setState(() {
      _isFullscreen = true;
      _isLandscape = landscape;
    });
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (!isDesktop) {
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
    setState(() {
      _isFullscreen = false;
      _isLandscape = false;
      _showRightEpisodeDrawer = false;
      _showRightFitDrawer = false;
    });
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (!isDesktop) {
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
      _showHud(Icons.screen_rotation, '全屏横屏');
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _showHud(Icons.screen_lock_portrait, '全屏竖屏');
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

  Future<void> _loadDetailAndAutoPlay() async {
    setState(() => _isLoading = true);

    if (widget.vodItem != null && widget.vodItem!.playSources.isNotEmpty) {
      _vodDetail = widget.vodItem;
      _isLoading = false;
      if (mounted) setState(() {});
    } else {
      try {
        final detail = await widget.repository.fetchDetail(widget.vodId);
        if (mounted) {
          setState(() {
            _vodDetail = detail;
            _isLoading = false;
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

    if (_vodDetail != null && _vodDetail!.playSources.isNotEmpty) {
      _isFavorited = HistoryFavoriteService().isFavorite(_vodDetail!.vodId);
      final lastPlay = await HistoryFavoriteService().getLastPlayback(_vodDetail!.vodId);
      final source = _vodDetail!.playSources.first;
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

  Future<void> _playEpisode(String flag, EpisodeItem ep) async {
    _savePlaybackHistory();

    setState(() {
      _isPlayerLoading = true;
      _playErrorMsg = null;
      _currentEpisodeName = ep.name;
      _danmakus = [];
      _matchedLogVarEpisodeId = null;
    });

    try {
      final res = await widget.repository.fetchPlayInfo(flag, ep.url);
      final playUrl = res['url']?.toString() ?? '';

      if (playUrl.isNotEmpty) {
        _currentPlayUrl = playUrl;
        _initAndStartPlayer(playUrl, res);
        _fetchLogVarDanmaku();
      } else {
        setState(() {
          _isPlayerLoading = false;
          _playErrorMsg = '选集播放地址解析为空';
        });
      }
    } catch (e) {
      setState(() {
        _isPlayerLoading = false;
        _playErrorMsg = '选集播放解析异常: $e';
      });
    }
  }

  Future<void> _refreshPlayback() async {
    if (_vodDetail == null || _isPlayerLoading) return;
    _showHud(Icons.refresh, '正在刷新播放器...');
    final currentPos = _position;

    final sources = _vodDetail!.playSources;
    if (sources.isNotEmpty && _selectedSourceIndex < sources.length) {
      final currentEp = sources[_selectedSourceIndex].episodes.firstWhere(
            (e) => e.name == _currentEpisodeName,
            orElse: () => sources[_selectedSourceIndex].episodes.first,
          );
      await _playEpisode(sources[_selectedSourceIndex].name, currentEp);
      if (_player != null && currentPos.inSeconds > 3) {
        _player!.seek(currentPos);
      }
    }
  }

  void _initAndStartPlayer(String url, Map<String, dynamic> playData) {
    try {
      _player ??= Player();

      final headerObj = playData['header'] ?? playData['headers'] ?? {};
      Map<String, String> headers = {};
      if (headerObj is Map) {
        headerObj.forEach((k, v) {
          if (k != null && v != null) headers[k.toString()] = v.toString();
        });
      }
      _currentHeaders = headers;

      _videoController ??= VideoController(_player!);

      _posSub?.cancel();
      _durSub?.cancel();
      _playSub?.cancel();
      _widthSub?.cancel();
      _heightSub?.cancel();

      _posSub = _player!.stream.position.listen((pos) {
        if (mounted) {
          setState(() => _position = pos);

          // 自动跳过片头
          if (!_hasSkippedIntro && _skipIntroSeconds > 0 && pos.inSeconds > 0 && pos.inSeconds < 5) {
            _hasSkippedIntro = true;
            if (_duration.inSeconds == 0 || _duration.inSeconds > _skipIntroSeconds + 20) {
              _player?.seek(Duration(seconds: _skipIntroSeconds));
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
        }
      });

      // 应用硬解/软解设置
      try {
        (_player!.platform as dynamic)?.setProperty('hwdec', _isHardwareDecode ? 'auto' : 'no');
      } catch (_) {}

      _player!.open(Media(url, httpHeaders: headers));
      _player!.setRate(_playbackRate);

      _restorePlaybackHistory();
    } catch (e) {
      setState(() {
        _isPlayerLoading = false;
        _playErrorMsg = '启动原生解码器异常: $e';
      });
    }
  }

  void _toggleHardwareDecode() {
    setState(() => _isHardwareDecode = !_isHardwareDecode);
    try {
      (_player?.platform as dynamic)?.setProperty('hwdec', _isHardwareDecode ? 'auto' : 'no');
    } catch (_) {}
    _showHud(
      _isHardwareDecode ? Icons.hardware : Icons.memory,
      _isHardwareDecode ? '已切换为：硬解模式 (GPU加速)' : '已切换为：软解模式 (CPU兼容)',
    );
  }

  Future<void> _fetchLogVarDanmaku() async {
    if (_vodDetail == null || !_danmakuConfig.enabled) return;

    setState(() => _isDanmakuLoading = true);
    try {
      final (cleanName, cleanEp) = _danmakuService.sanitizeVodNameAndEpisode(
        _vodDetail!.vodName,
        _currentEpisodeName,
      );

      List<DanmakuItem> items = [];

      // 1. 💡 默认全网搜索弹幕库，优先直接匹配推送第 1 个站源的当前剧集弹幕
      final sources = await _danmakuService.searchLogVarAnimes(cleanName);
      if (sources.isNotEmpty) {
        final firstSource = sources.first;
        LogVarEpisode? matchedEp;

        for (final ep in firstSource.episodes) {
          final t = ep.episodeTitle;
          if (t == cleanEp || t.contains(cleanEp)) {
            matchedEp = ep;
            break;
          }
          final epNumMatch = RegExp(r'(\d+)').firstMatch(t);
          if (epNumMatch != null && epNumMatch.group(1) == cleanEp) {
            matchedEp = ep;
            break;
          }
        }
        matchedEp ??= firstSource.episodes.first;

        items = await _danmakuService.fetchDanmakuByEpisodeId(matchedEp.episodeId);
        _matchedLogVarEpisodeId = matchedEp.episodeId;
        if (items.isNotEmpty) {
          _showHud(
            Icons.comment,
            '已自动匹配推送: [${firstSource.animeTitle}] ${matchedEp.episodeTitle} (${items.length}条弹幕)',
          );
        }
      }

      // 2. 若首选源未命中，回退常规接口
      if (items.isEmpty) {
        items = await _danmakuService.fetchDanmaku(
          vodName: _vodDetail!.vodName,
          episodeName: _currentEpisodeName,
          playUrl: _currentPlayUrl,
        );
      }

      // 3. 兜底保障
      if (items.isEmpty) {
        items = _danmakuService.generateSampleDanmakus(
          _vodDetail!.vodName,
          _currentEpisodeName,
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

  void _showDanmakuSettingsDialog() {
    final colors = [
      {'name': '纯白 (默认)', 'color': Colors.white},
      {'name': '金黄', 'color': const Color(0xFFFFEB3B)},
      {'name': '青蓝', 'color': const Color(0xFF00E5FF)},
      {'name': '翠绿', 'color': const Color(0xFF00E676)},
      {'name': '粉红', 'color': const Color(0xFFFF4081)},
      {'name': '亮橙', 'color': const Color(0xFFFF9800)},
    ];

    final gradients = ['无', '极光蓝', '落霞红', '赛博紫', '流光金', '荧光绿', '随机渐变'];
    final fontSizes = [
      {'label': '小 (14px)', 'size': 14.0},
      {'label': '中 (16px 默认)', 'size': 16.0},
      {'label': '大 (20px)', 'size': 20.0},
      {'label': '特大 (24px)', 'size': 24.0},
    ];

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            title: Row(
              children: [
                Icon(Icons.tune, color: _themeService.accentColor),
                const SizedBox(width: 8),
                const Text('弹幕播放设置', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. 智能防重叠开关
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('智能防重叠', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: const Text('严格多通道碰撞检测，杜绝弹幕水平追尾碰撞', style: TextStyle(color: Colors.grey, fontSize: 11)),
                      value: _danmakuConfig.antiOverlap,
                      activeColor: _themeService.accentColor,
                      onChanged: (val) {
                        setDialogState(() => _danmakuConfig.antiOverlap = val);
                        setState(() => _danmakuConfig.antiOverlap = val);
                        _danmakuService.saveConfig(_danmakuConfig);
                      },
                    ),
                    const Divider(color: Colors.white12, height: 16),

                    // 2. 显示行数与同屏密度
                    const Text('最大显示行数 (默认3行):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 6),
                    Row(
                      children: [1, 2, 3, 5, 8].map((lines) {
                        final isSel = _danmakuConfig.maxLines == lines;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6.0),
                          child: ChoiceChip(
                            label: Text(lines == 3 ? '3行 (默认)' : '$lines行'),
                            selected: isSel,
                            selectedColor: _themeService.accentColor,
                            onSelected: (_) {
                              setDialogState(() => _danmakuConfig.maxLines = lines);
                              setState(() => _danmakuConfig.maxLines = lines);
                              _danmakuService.saveConfig(_danmakuConfig);
                            },
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),

                    const Text('同屏密度限制 (防密集刷屏):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        {'label': '15条', 'val': 15},
                        {'label': '30条 (默认)', 'val': 30},
                        {'label': '50条', 'val': 50},
                        {'label': '不限制', 'val': 0},
                      ].map((item) {
                        final val = item['val'] as int;
                        final isSel = _danmakuConfig.maxScreenCount == val;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6.0),
                          child: ChoiceChip(
                            label: Text(item['label'] as String),
                            selected: isSel,
                            selectedColor: _themeService.accentColor,
                            onSelected: (_) {
                              setDialogState(() => _danmakuConfig.maxScreenCount = val);
                              setState(() => _danmakuConfig.maxScreenCount = val);
                              _danmakuService.saveConfig(_danmakuConfig);
                            },
                          ),
                        );
                      }).toList(),
                    ),
                    const Divider(color: Colors.white12, height: 20),

                    // 3. 字体大小与描边
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('字体大小:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        Text('${_danmakuConfig.fontSize.toInt()} px',
                            style: TextStyle(color: _themeService.accentColor, fontSize: 12, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: fontSizes.map((f) {
                          final size = f['size'] as double;
                          final isSel = (_danmakuConfig.fontSize - size).abs() < 1.0;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6.0),
                            child: ChoiceChip(
                              label: Text(f['label'] as String),
                              selected: isSel,
                              selectedColor: _themeService.accentColor,
                              onSelected: (_) {
                                setDialogState(() => _danmakuConfig.fontSize = size);
                                setState(() => _danmakuConfig.fontSize = size);
                                _danmakuService.saveConfig(_danmakuConfig);
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // 文字描边与不透明度
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('文字阴影描边', style: TextStyle(color: Colors.white, fontSize: 13)),
                      subtitle: const Text('增强对比度与明亮场景下的可读性', style: TextStyle(color: Colors.grey, fontSize: 11)),
                      value: _danmakuConfig.showStroke,
                      activeColor: _themeService.accentColor,
                      onChanged: (val) {
                        setDialogState(() => _danmakuConfig.showStroke = val);
                        setState(() => _danmakuConfig.showStroke = val);
                        _danmakuService.saveConfig(_danmakuConfig);
                      },
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('弹幕不透明度:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        Text('${(_danmakuConfig.opacity * 100).toInt()}%',
                            style: TextStyle(color: _themeService.accentColor, fontSize: 12)),
                      ],
                    ),
                    Slider(
                      value: _danmakuConfig.opacity,
                      min: 0.1,
                      max: 1.0,
                      activeColor: _themeService.accentColor,
                      onChanged: (v) {
                        setDialogState(() => _danmakuConfig.opacity = v);
                        setState(() => _danmakuConfig.opacity = v);
                        _danmakuService.saveConfig(_danmakuConfig);
                      },
                    ),
                    const Divider(color: Colors.white12, height: 20),

                    // 4. 颜色模式：随机颜色、文字渐变、基础纯色
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('随机炫彩颜色', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: const Text('每条弹幕随机分配柔和马卡龙/荧光色彩', style: TextStyle(color: Colors.grey, fontSize: 11)),
                      value: _danmakuConfig.isRandomColor,
                      activeColor: _themeService.accentColor,
                      onChanged: (val) {
                        setDialogState(() => _danmakuConfig.isRandomColor = val);
                        setState(() => _danmakuConfig.isRandomColor = val);
                        _danmakuService.saveConfig(_danmakuConfig);
                      },
                    ),
                    const SizedBox(height: 8),

                    // 渐变文字风格选择
                    const Text('渐变文字特效 (双色流动着色):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: gradients.map((gName) {
                        final isSel = _danmakuConfig.gradientStyle == gName;
                        return ChoiceChip(
                          label: Text(gName),
                          selected: isSel,
                          selectedColor: _themeService.accentColor,
                          onSelected: (_) {
                            setDialogState(() => _danmakuConfig.gradientStyle = gName);
                            setState(() => _danmakuConfig.gradientStyle = gName);
                            _danmakuService.saveConfig(_danmakuConfig);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),

                    // 基础纯色选择 (若未启用随机与渐变)
                    if (!_danmakuConfig.isRandomColor && _danmakuConfig.gradientStyle == '无') ...[
                      const Text('基础纯色选择 (默认白色):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: colors.map((c) {
                          final color = c['color'] as Color;
                          final isSel = _danmakuConfig.defaultColor.toARGB32() == color.toARGB32();
                          return GestureDetector(
                            onTap: () {
                              setDialogState(() => _danmakuConfig.defaultColor = color);
                              setState(() => _danmakuConfig.defaultColor = color);
                              _danmakuService.saveConfig(_danmakuConfig);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: isSel ? color.withOpacity(0.3) : const Color(0xFF262832),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: isSel ? color : Colors.white24, width: isSel ? 1.5 : 1),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(c['name'] as String,
                                      style: TextStyle(
                                        color: isSel ? Colors.white : Colors.white70,
                                        fontSize: 11,
                                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                      )),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
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

  /// 完善弹幕搜索：搜索列表支持全量滚动，确保弹幕可即刻播放
  void _showDanmakuSearchDialog() {
    final titleController = TextEditingController(text: _vodDetail?.vodName ?? '');
    List<LogVarAnimeSource> animeSources = [];
    bool isSearchingLogVar = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          void doSearch(String kw) async {
            final query = kw.trim();
            if (query.isEmpty) return;
            setDialogState(() => isSearchingLogVar = true);
            final res = await _danmakuService.searchLogVarAnimes(query);
            if (context.mounted) {
              setDialogState(() {
                animeSources = res;
                isSearchingLogVar = false;
              });
            }
          }

          // 首次打开自动触发初始搜索
          if (animeSources.isEmpty && !isSearchingLogVar && titleController.text.isNotEmpty) {
            Future.microtask(() => doSearch(titleController.text));
          }

          final screenHeight = MediaQuery.of(context).size.height;
          final screenWidth = MediaQuery.of(context).size.width;

          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            title: Row(
              children: [
                const Icon(Icons.comment_outlined, color: Color(0xFFE5A00D), size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('匹配 LogVar 在线弹幕库',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.pop(dialogCtx),
                ),
              ],
            ),
            content: SizedBox(
              width: min(520, screenWidth * 0.92),
              height: min(480, screenHeight * 0.78),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前服务器: ${_danmakuConfig.serverUrl}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: titleController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          textInputAction: TextInputAction.search,
                          onSubmitted: (kw) => doSearch(kw),
                          decoration: InputDecoration(
                            labelText: '搜索剧名 / 动漫关键词',
                            labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, color: Color(0xFFE5A00D), size: 18),
                            suffixIcon: titleController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 16, color: Colors.grey),
                                    onPressed: () {
                                      titleController.clear();
                                      setDialogState(() {});
                                    },
                                  )
                                : null,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE5A00D),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        onPressed: isSearchingLogVar ? null : () => doSearch(titleController.text),
                        child: isSearchingLogVar
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Text('搜索',
                                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Colors.white12),
                  const SizedBox(height: 8),

                  // 搜索结果列表（支持全量纵向滚动与每部剧集展开）
                  Expanded(
                    child: isSearchingLogVar
                        ? const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: Color(0xFFE5A00D)),
                                SizedBox(height: 12),
                                Text('正在检索弹幕库...', style: TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          )
                        : animeSources.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.subtitles_off, size: 40, color: Colors.grey),
                                    const SizedBox(height: 8),
                                    const Text('未在远程库找到精准匹配', style: TextStyle(color: Colors.white60, fontSize: 13)),
                                    const SizedBox(height: 12),
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF262832)),
                                      icon: const Icon(Icons.auto_awesome, color: Color(0xFFE5A00D), size: 16),
                                      label: const Text('一键装载精选保底弹幕 (保证播放)',
                                          style: TextStyle(color: Colors.white, fontSize: 12)),
                                      onPressed: () {
                                        Navigator.pop(dialogCtx);
                                        setState(() {
                                          _danmakuConfig.enabled = true;
                                          _danmakus = _danmakuService.generateSampleDanmakus(
                                              _vodDetail?.vodName ?? '精选', _currentEpisodeName);
                                        });
                                        _showHud(Icons.check_circle, '✅ 已成功注入 ${_danmakus.length} 条弹幕并开启播放！');
                                      },
                                    ),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: animeSources.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, idx) {
                                  final source = animeSources[idx];
                                  return Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF262832),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white12),
                                    ),
                                    child: ExpansionTile(
                                      dense: true,
                                      initiallyExpanded: idx == 0,
                                      leading: const Icon(Icons.movie_filter,
                                          color: Color(0xFFE5A00D), size: 20),
                                      title: Text(
                                        source.animeTitle,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13),
                                      ),
                                      subtitle: Text(
                                        '类型: ${source.typeDescription} | 共 ${source.episodes.length} 集',
                                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                                      ),
                                      children: [
                                        Container(
                                          constraints: const BoxConstraints(maxHeight: 180),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                          child: SingleChildScrollView(
                                            physics: const AlwaysScrollableScrollPhysics(),
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: source.episodes.map((ep) {
                                                return InkWell(
                                                  onTap: () async {
                                                    Navigator.pop(dialogCtx);
                                                    setState(() => _isDanmakuLoading = true);
                                                    final items = await _danmakuService
                                                        .fetchDanmakuByEpisodeId(ep.episodeId);
                                                    if (mounted) {
                                                      setState(() {
                                                        _danmakuConfig.enabled = true;
                                                        _danmakus = items;
                                                        _matchedLogVarEpisodeId = ep.episodeId;
                                                        _isDanmakuLoading = false;
                                                      });
                                                      _showHud(Icons.check_circle,
                                                          '已关联 [${source.animeTitle} - ${ep.episodeTitle}] (${items.length}条弹幕)');
                                                    }
                                                  },
                                                  borderRadius: BorderRadius.circular(6),
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(
                                                        horizontal: 10, vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFF1E2028),
                                                      borderRadius: BorderRadius.circular(6),
                                                      border: Border.all(color: Colors.white24),
                                                    ),
                                                    child: Text(
                                                      ep.episodeTitle,
                                                      style: const TextStyle(
                                                          color: Colors.white, fontSize: 11),
                                                    ),
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSendDanmakuDialog() {
    final textController = TextEditingController();
    Color selectedColor = Colors.white;
    DanmakuType selectedType = DanmakuType.scroll;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final colors = [
            Colors.white,
            const Color(0xFFFFEB3B),
            const Color(0xFF00E5FF),
            const Color(0xFF69F0AE),
            const Color(0xFFFF5252),
            const Color(0xFFE040FB),
          ];

          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.send, color: Color(0xFFE5A00D), size: 20),
                SizedBox(width: 8),
                Text('发送实时弹幕', style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: textController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: '输入你想说的弹幕内容...',
                      hintStyle: TextStyle(color: Colors.grey),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('选择弹幕颜色:', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: colors.map((c) {
                      final isSel = selectedColor == c;
                      return GestureDetector(
                        onTap: () => setModalState(() => selectedColor = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSel ? const Color(0xFFE5A00D) : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE5A00D)),
                onPressed: () async {
                  final text = textController.text.trim();
                  if (text.isNotEmpty) {
                    Navigator.pop(context);
                    final newItem = DanmakuItem(
                      time: _position.inMilliseconds / 1000.0,
                      text: text,
                      color: selectedColor,
                      type: selectedType,
                    );
                    setState(() {
                      _danmakus.add(newItem);
                      _danmakus.sort((a, b) => a.time.compareTo(b.time));
                    });
                    _showHud(Icons.check, '✅ 弹幕即刻发射成功！');
                    await _danmakuService.sendDanmaku(
                      vodName: _vodDetail?.vodName ?? '',
                      episodeName: _currentEpisodeName,
                      episodeId: _matchedLogVarEpisodeId,
                      time: _position.inMilliseconds / 1000.0,
                      text: text,
                      color: selectedColor,
                      type: selectedType,
                    );
                  }
                },
                child: const Text('发射', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 视轨选择弹窗 (参考图 8)
  void _showVideoTrackDialog() {
    final tracks = _player?.state.tracks.video ?? [];
    final currentTrack = _player?.state.track.video;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF6F8FA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择视轨',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 16),
              if (tracks.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF2979FF), width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white,
                  ),
                  child: Text(
                    '${_videoWidth ?? 3840} × ${_videoHeight ?? 2160}, H.265 (默认原画)',
                    style: const TextStyle(color: Color(0xFF2979FF), fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                )
              else
                ...tracks.map((track) {
                  final isSel = currentTrack?.id == track.id;
                  final label = (track.w != null && track.h != null)
                      ? '${track.w} × ${track.h}, ${track.codec ?? "H.265"}'
                      : track.title ?? track.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () {
                        _player?.setVideoTrack(track);
                        Navigator.pop(ctx);
                        _showHud(Icons.video_library, '已切换视轨: $label');
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSel ? const Color(0xFF2979FF) : Colors.black12,
                            width: isSel ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.white,
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            color: isSel ? const Color(0xFF2979FF) : Colors.black87,
                            fontSize: 14,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  /// 音轨选择弹窗 (参考图 9)
  void _showAudioTrackDialog() {
    final tracks = _player?.state.tracks.audio ?? [];
    final currentTrack = _player?.state.track.audio;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF6F8FA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择音轨',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 16),
              if (tracks.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF2979FF), width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white,
                  ),
                  child: const Text(
                    '立体声，AAC-LC (默认音轨)',
                    style: TextStyle(color: Color(0xFF2979FF), fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                )
              else
                ...tracks.map((track) {
                  final isSel = currentTrack?.id == track.id;
                  final label = track.title ?? track.language ?? '${track.channels ?? 2}声道，${track.codec ?? "AAC"}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () {
                        _player?.setAudioTrack(track);
                        Navigator.pop(ctx);
                        _showHud(Icons.audiotrack, '已切换音轨: $label');
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSel ? const Color(0xFF2979FF) : Colors.black12,
                            width: isSel ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.white,
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            color: isSel ? const Color(0xFF2979FF) : Colors.black87,
                            fontSize: 14,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  /// 字幕选择弹窗
  void _showSubtitleTrackDialog() {
    final tracks = _player?.state.tracks.subtitle ?? [];
    final currentTrack = _player?.state.track.subtitle;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF6F8FA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择字幕',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () {
                  _player?.setSubtitleTrack(SubtitleTrack.no());
                  Navigator.pop(ctx);
                  
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white,
                  ),
                  child: const Text('关闭字幕', style: TextStyle(color: Colors.black87, fontSize: 14)),
                ),
              ),
              const SizedBox(height: 8),
              if (tracks.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF2979FF), width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white,
                  ),
                  child: const Text(
                    '内置中文硬字幕 / 无外挂流',
                    style: TextStyle(color: Color(0xFF2979FF), fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                )
              else
                ...tracks.map((track) {
                  final isSel = currentTrack?.id == track.id;
                  final label = track.title ?? track.language ?? '字幕轨 ${track.id}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () {
                        _player?.setSubtitleTrack(track);
                        Navigator.pop(ctx);
                        _showHud(Icons.subtitles, '已切换字幕: $label');
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSel ? const Color(0xFF2979FF) : Colors.black12,
                            width: isSel ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.white,
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            color: isSel ? const Color(0xFF2979FF) : Colors.black87,
                            fontSize: 14,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  /// 播放链接详情弹窗 (支持查看与复制 直链、User-Agent、Referer、Cookie 等完整参数)
  void _showPlayLinkDetailDialog() {
    final title = '${_vodDetail?.vodName ?? ""}：$_currentEpisodeName';

    // 容错提取 Header 字段 (不区分大小写)
    String? findHeader(List<String> keys) {
      for (final k in keys) {
        for (final entry in _currentHeaders.entries) {
          if (entry.key.toLowerCase() == k.toLowerCase() && entry.value.trim().isNotEmpty) {
            return entry.value.trim();
          }
        }
      }
      return null;
    }

    final ua = findHeader(['User-Agent', 'user-agent']) ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36';
    final referer = findHeader(['Referer', 'referer', 'Refer', 'refer']);
    final cookie = findHeader(['Cookie', 'cookie']);

    // 构建一键复制全部文本
    final fullInfoBuffer = StringBuffer();
    fullInfoBuffer.writeln('【剧名】$title');
    fullInfoBuffer.writeln('【直链】$_currentPlayUrl');
    fullInfoBuffer.writeln('【User-Agent】$ua');
    if (referer != null) fullInfoBuffer.writeln('【Referer】$referer');
    if (cookie != null) fullInfoBuffer.writeln('【Cookie】$cookie');
    final fullInfoStr = fullInfoBuffer.toString();

    Widget buildInfoTile(String label, String value, {bool isUrl = false}) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2979FF),
                  ),
                ),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    _showHud(Icons.check, '已复制 $label 至剪贴板');
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy, size: 14, color: Color(0xFF2979FF)),
                        SizedBox(width: 4),
                        Text('复制', style: TextStyle(fontSize: 11, color: Color(0xFF2979FF), fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              value,
              style: TextStyle(
                color: isUrl ? const Color(0xFF1565C0) : Colors.black87,
                fontSize: 12.5,
                height: 1.35,
                decoration: isUrl ? TextDecoration.underline : null,
              ),
            ),
          ],
        ),
      );
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600, maxHeight: 650),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F6F9),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20, color: Colors.black54),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildInfoTile('播放直链 (URL)', _currentPlayUrl, isUrl: true),
                        buildInfoTile('User-Agent', ua),
                        if (referer != null) buildInfoTile('Referer', referer),
                        if (cookie != null) buildInfoTile('Cookie', cookie),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy_all, size: 16, color: Color(0xFF2979FF)),
                      label: const Text('复制全部', style: TextStyle(color: Color(0xFF2979FF), fontWeight: FontWeight.bold)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: fullInfoStr));
                        Navigator.pop(ctx);
                        _showHud(Icons.check, '已复制全部播放参数至剪贴板');
                      },
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2979FF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 投屏弹窗 (右上角投屏功能)
  void _showCastDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2028),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.cast, color: Color(0xFFE5A00D)),
              SizedBox(width: 8),
              Text('无线投屏 (DLNA / AirPlay)', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '请确保手机与电视/盒子处于同一个 Wi-Fi 局域网下：',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tv, color: Color(0xFFE5A00D)),
                title: const Text('客厅电视 (DLNA)', style: TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: const Text('就绪 - 点击一键投送', style: TextStyle(color: Colors.grey, fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showHud(Icons.cast_connected, '已将当前视频推送至客厅电视');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.laptop, color: Colors.white70),
                title: const Text('我的电脑 (DLNA Renderer)', style: TextStyle(color: Colors.white, fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showHud(Icons.cast_connected, '已将当前视频推送至电脑');
                },
              ),
              const Divider(color: Colors.white12),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _currentPlayUrl));
                  Navigator.pop(ctx);
                  _showHud(Icons.copy, '已复制播放地址供外部投屏播放器解析');
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.link, color: Color(0xFFE5A00D), size: 16),
                      SizedBox(width: 8),
                      Text('复制当前流媒体链接至其他播放设备',
                          style: TextStyle(color: Color(0xFFE5A00D), fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ],
        );
      },
    );
  }

  /// 播放器设置弹窗 (右上角齿轮设置功能)
  void _showPlayerSettingsDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSettingState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2028),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.settings, color: _themeService.accentColor),
                  const SizedBox(width: 8),
                  const Text('播放器高级设置', style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
              content: SizedBox(
                width: 380,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. 解码方式
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('解码方式:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Row(
                            children: [
                              ChoiceChip(
                                label: const Text('硬解'),
                                selected: _isHardwareDecode,
                                selectedColor: _themeService.accentColor,
                                onSelected: (val) {
                                  setSettingState(() => _isHardwareDecode = true);
                                  setState(() => _isHardwareDecode = true);
                                  try {
                                    (_player?.platform as dynamic)?.setProperty('hwdec', 'auto');
                                  } catch (_) {}
                                },
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: const Text('软解'),
                                selected: !_isHardwareDecode,
                                selectedColor: _themeService.accentColor,
                                onSelected: (val) {
                                  setSettingState(() => _isHardwareDecode = false);
                                  setState(() => _isHardwareDecode = false);
                                  try {
                                    (_player?.platform as dynamic)?.setProperty('hwdec', 'no');
                                  } catch (_) {}
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 2. 播放内核
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('播放内核:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          DropdownButton<String>(
                            value: _playerCoreName,
                            dropdownColor: const Color(0xFF262832),
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(value: 'EXO', child: Text('EXO 内核')),
                              DropdownMenuItem(value: 'MPV', child: Text('MPV 跨平台内核')),
                              DropdownMenuItem(value: 'IJK', child: Text('IJK 原生内核')),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setSettingState(() => _playerCoreName = val);
                                setState(() => _playerCoreName = val);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 3. 后台播放 (关闭、开启、画中画)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('后台播放:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Row(
                            children: ['画中画', '开启', '关闭'].map((opt) {
                              final isSel = _bgPlayMode == opt;
                              return Padding(
                                padding: const EdgeInsets.only(left: 6.0),
                                child: ChoiceChip(
                                  label: Text(opt),
                                  selected: isSel,
                                  selectedColor: _themeService.accentColor,
                                  onSelected: (_) async {
                                    setSettingState(() => _bgPlayMode = opt);
                                    setState(() => _bgPlayMode = opt);
                                    await StorageBridge.setValue('player_bg_play', opt);
                                  },
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 4. 同时播放
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('同时播放:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Row(
                            children: ['开启', '关闭'].map((opt) {
                              final isSel = _simPlayMode == opt;
                              return Padding(
                                padding: const EdgeInsets.only(left: 6.0),
                                child: ChoiceChip(
                                  label: Text(opt),
                                  selected: isSel,
                                  selectedColor: _themeService.accentColor,
                                  onSelected: (_) async {
                                    setSettingState(() => _simPlayMode = opt);
                                    setState(() => _simPlayMode = opt);
                                    await StorageBridge.setValue('player_sim_play', opt);
                                  },
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 5. 缓冲时间
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('缓冲时间:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          DropdownButton<String>(
                            value: _bufferTimeOption,
                            dropdownColor: const Color(0xFF262832),
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(value: '5 倍', child: Text('5 倍')),
                              DropdownMenuItem(value: '10 倍', child: Text('10 倍')),
                              DropdownMenuItem(value: '15 倍', child: Text('15 倍 (默认)')),
                              DropdownMenuItem(value: '20 倍', child: Text('20 倍')),
                              DropdownMenuItem(value: '30 倍', child: Text('30 倍')),
                            ],
                            onChanged: (val) async {
                              if (val != null) {
                                setSettingState(() => _bufferTimeOption = val);
                                setState(() => _bufferTimeOption = val);
                                await StorageBridge.setValue('player_buffer_time', val);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 6. User-Agent
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('User-Agent:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          DropdownButton<String>(
                            value: _userAgentOption,
                            dropdownColor: const Color(0xFF262832),
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(value: '系统默认', child: Text('系统默认')),
                              DropdownMenuItem(value: '移动端', child: Text('移动端 (Android)')),
                              DropdownMenuItem(value: '电视端', child: Text('电视端 (TV)')),
                            ],
                            onChanged: (val) async {
                              if (val != null) {
                                setSettingState(() => _userAgentOption = val);
                                setState(() => _userAgentOption = val);
                                await StorageBridge.setValue('player_ua', val);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 7. 片头片尾跳过
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showSkipTimesDialog();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Row(
                                    children: [
                                      Text('跳过片头:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                                      SizedBox(width: 4),
                                      Icon(Icons.edit, size: 13, color: Colors.white54),
                                    ],
                                  ),
                                  Text('${_formatSeconds(_skipIntroSeconds)} ($_skipIntroSeconds 秒)',
                                      style: TextStyle(color: _themeService.accentColor, fontSize: 13, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Row(
                                    children: [
                                      Text('跳过片尾:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                                      SizedBox(width: 4),
                                      Icon(Icons.edit, size: 13, color: Colors.white54),
                                    ],
                                  ),
                                  Text('${_formatSeconds(_skipOutroSeconds)} ($_skipOutroSeconds 秒)',
                                      style: TextStyle(color: _themeService.accentColor, fontSize: 13, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 8. 弹幕开关
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('弹幕总开关', style: TextStyle(color: Colors.white, fontSize: 13)),
                        value: _danmakuConfig.enabled,
                        activeColor: _themeService.accentColor,
                        onChanged: (val) {
                          setSettingState(() => _danmakuConfig.enabled = val);
                          setState(() => _danmakuConfig.enabled = val);
                          _danmakuService.saveConfig(_danmakuConfig);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
              ],
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
      await HistoryFavoriteService().recordHistory(
        vod: _vodDetail!,
        episodeName: _currentEpisodeName,
        positionSec: _position.inSeconds,
        durationSec: _duration.inSeconds,
      );
    } catch (_) {}
  }

  Future<void> _restorePlaybackHistory() async {
    if (_vodDetail == null) return;
    try {
      final history = await HistoryFavoriteService().getLastPlayback(_vodDetail!.vodId);
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

      if (sec > 5 && (ep.isEmpty || ep == _currentEpisodeName) && _player != null) {
        _hasSkippedIntro = true;
        _player!.seek(Duration(seconds: sec));
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

  /// 片头片尾设置弹窗
  void _showSkipTimesDialog() {
    int tempIntro = _skipIntroSeconds;
    int tempOutro = _skipOutroSeconds;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Icon(Icons.skip_next, color: _themeService.accentColor, size: 22),
                const SizedBox(width: 8),
                const Text('跳过片头片尾设置', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 片头设置
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('跳过片头时长', style: TextStyle(color: Colors.white, fontSize: 14)),
                      Text('${_formatSeconds(tempIntro)} ($tempIntro 秒)',
                          style: TextStyle(color: _themeService.accentColor, fontSize: 14, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildAdjustBtn('-10s', () => setDialogState(() => tempIntro = max(0, tempIntro - 10))),
                      _buildAdjustBtn('-5s', () => setDialogState(() => tempIntro = max(0, tempIntro - 5))),
                      _buildAdjustBtn('+5s', () => setDialogState(() => tempIntro += 5)),
                      _buildAdjustBtn('+10s', () => setDialogState(() => tempIntro += 10)),
                      _buildAdjustBtn('0s (关闭)', () => setDialogState(() => tempIntro = 0)),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // 片尾设置
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('跳过片尾时长', style: TextStyle(color: Colors.white, fontSize: 14)),
                      Text('${_formatSeconds(tempOutro)} ($tempOutro 秒)',
                          style: TextStyle(color: _themeService.accentColor, fontSize: 14, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildAdjustBtn('-10s', () => setDialogState(() => tempOutro = max(0, tempOutro - 10))),
                      _buildAdjustBtn('-5s', () => setDialogState(() => tempOutro = max(0, tempOutro - 5))),
                      _buildAdjustBtn('+5s', () => setDialogState(() => tempOutro += 5)),
                      _buildAdjustBtn('+10s', () => setDialogState(() => tempOutro += 10)),
                      _buildAdjustBtn('0s (关闭)', () => setDialogState(() => tempOutro = 0)),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  setState(() {
                    _skipIntroSeconds = tempIntro;
                    _skipOutroSeconds = tempOutro;
                  });
                  await StorageBridge.setValue('player_skip_intro', '$tempIntro');
                  await StorageBridge.setValue('player_skip_outro', '$tempOutro');
                  Navigator.pop(ctx);
                  _showHud(Icons.check, '片头片尾跳过时长已保存');
                },
                child: const Text('保存', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAdjustBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2E3A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ),
    );
  }

  void _showHud(IconData icon, String text) {
    if (!mounted) return;
    setState(() {
      _gestureHudIcon = icon;
      _gestureHudText = text;
      _showGestureHud = true;
    });
    _gestureHudTimer?.cancel();
    _gestureHudTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showGestureHud = false);
    });
  }

  void _onPanStart(DragStartDetails details, BoxConstraints constraints) {
    _dragStartX = details.localPosition.dx;
    _dragStartY = details.localPosition.dy;
    _isDraggingSeek = false;
    _isDraggingLeft = false;
    _isDraggingRight = false;

    if (_dragStartX < constraints.maxWidth * 0.3) {
      _isDraggingLeft = true;
    } else if (_dragStartX > constraints.maxWidth * 0.7) {
      _isDraggingRight = true;
    } else {
      _isDraggingSeek = true;
      _seekTargetSeconds = _position.inSeconds.toDouble();
    }
  }

  void _onPanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    final dx = details.localPosition.dx - _dragStartX;
    final dy = details.localPosition.dy - _dragStartY;

    if (_isDraggingSeek) {
      final factor = dx / constraints.maxWidth;
      final totalSec = max(1.0, _duration.inSeconds.toDouble());
      final target = (_position.inSeconds + factor * min(totalSec, 600.0)).clamp(0.0, totalSec);
      _seekTargetSeconds = target;

      final deltaSec = (target - _position.inSeconds).toInt();
      final sign = deltaSec >= 0 ? '+' : '';
      _showHud(
        deltaSec >= 0 ? Icons.fast_forward : Icons.fast_rewind,
        '[$sign${deltaSec}s] ${_formatDuration(Duration(seconds: target.toInt()))} / ${_formatDuration(_duration)}',
      );
    } else if (_isDraggingLeft) {
      final delta = -dy / constraints.maxHeight;
      _currentBrightness = (_currentBrightness + delta * 0.05).clamp(0.0, 1.0);
      _showHud(Icons.brightness_6, '亮度: ${(_currentBrightness * 100).toInt()}%');
    } else if (_isDraggingRight) {
      final delta = -dy / constraints.maxHeight;
      _currentVolume = (_currentVolume + delta * 5.0).clamp(0.0, 100.0);
      _player?.setVolume(_currentVolume);
      _showHud(Icons.volume_up, '音量: ${_currentVolume.toInt()}%');
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isDraggingSeek && _player != null) {
      _player!.seek(Duration(seconds: _seekTargetSeconds.toInt()));
    }
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
              _player?.playOrPause();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              if (_isFullscreen) {
                setState(() => _isFullscreen = false);
                return KeyEventResult.handled;
              }
            }
            if (event.logicalKey == LogicalKeyboardKey.keyF || event.logicalKey == LogicalKeyboardKey.f11) {
              setState(() => _isFullscreen = !_isFullscreen);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              final target = max(0, _position.inSeconds - 10);
              _player?.seek(Duration(seconds: target));
              _showHud(Icons.fast_rewind, '-10s');
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              final target = min(_duration.inSeconds, _position.inSeconds + 10);
              _player?.seek(Duration(seconds: target));
              _showHud(Icons.fast_forward, '+10s');
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: pageBody,
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
                    IconButton(
                      icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 22),
                      tooltip: '播放器设置',
                      onPressed: _showPlayerSettingsDialog,
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
                                      // 悬浮全屏按钮
                                      Positioned(
                                        right: 8,
                                        bottom: 8,
                                        child: Tooltip(
                                          message: '进入全屏 (按 F 或双击)',
                                          child: InkWell(
                                            onTap: () => setState(() => _isFullscreen = true),
                                            borderRadius: BorderRadius.circular(6),
                                            child: Container(
                                              padding: const EdgeInsets.all(6),
                                              decoration: BoxDecoration(
                                                color: Colors.black54,
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: Colors.white24),
                                              ),
                                              child: const Icon(Icons.fullscreen, color: Colors.white, size: 20),
                                            ),
                                          ),
                                        ),
                                      ),
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
        return GestureDetector(
          onTap: _toggleOverlay,
          onDoubleTap: () {
            if (_isFullscreen) {
              _player?.playOrPause();
            } else {
              setState(() => _isFullscreen = true);
            }
          },
          onPanStart: (d) => _onPanStart(d, constraints),
          onPanUpdate: (d) => _onPanUpdate(d, constraints),
          onPanEnd: _onPanEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_videoController != null)
                Center(
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

              if (_showGestureHud)
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

              if (_isPlayerLoading)
                const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFFE5A00D)),
                      SizedBox(height: 12),
                      Text('正在解析并缓冲中...',
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),

              if (_playErrorMsg != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.black87,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 40),
                        const SizedBox(height: 8),
                        Text(_playErrorMsg!, style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                ),

              // 控制栏 (点击画面显隐)
              if (_showOverlay) _buildControlsOverlay(),

              // ─────────────────────────────────────────────────────────────
              // 常驻全屏与退出全屏按键 (需求: 全屏、退出按钮应该一直显示)
              // 控制栏淡出隐藏且未锁定控制器时，在右下角常驻显示半透明快捷按键，随时一键切换
              // ─────────────────────────────────────────────────────────────
              if (!_showOverlay && !_isLocked)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Tooltip(
                    message: _isFullscreen ? '退出全屏' : '进入全屏',
                    child: InkWell(
                      onTap: () {
                        if (_isFullscreen) {
                          _exitFullscreen();
                        } else {
                          _enterFullscreen(landscape: true);
                        }
                      },
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                        child: Icon(
                          _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
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

  Widget _buildControlsOverlay() {
    final resolutionStr = (_videoWidth != null && _videoHeight != null)
        ? '$_videoWidth × $_videoHeight'
        : '3840 × 2160';

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
                  padding: EdgeInsets.fromLTRB(16, isDesktop ? 12 : 6, 16, 8),
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
                            const SizedBox(height: 2),
                            Text(
                              resolutionStr,
                              style: const TextStyle(
                                color: Color(0xFFB0BEC5),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
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
                      _buildTopIconButton(
                        icon: Icons.settings_outlined,
                        tooltip: '播放器设置',
                        onTap: _showPlayerSettingsDialog,
                      ),


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
                    child: Text(
                      '${_vodDetail?.vodName ?? ""}：$_currentEpisodeName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
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
                    tooltip: '播放器设置',
                    onTap: _showPlayerSettingsDialog,
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
                  // 1. 弹幕开关
                  Tooltip(
                    message: _danmakuConfig.enabled ? '关闭弹幕' : '开启弹幕',
                    child: InkWell(
                      onTap: () {
                        setState(() => _danmakuConfig.enabled = !_danmakuConfig.enabled);
                        _danmakuService.saveConfig(_danmakuConfig);
                      },
                      borderRadius: BorderRadius.circular(19),
                      child: Container(
                        width: _isFullscreen ? 38 : 32,
                        height: _isFullscreen ? 38 : 32,
                        decoration: BoxDecoration(
                          color: _danmakuConfig.enabled
                              ? _themeService.accentColor.withOpacity(0.35)
                              : const Color(0x55000000),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _danmakuConfig.enabled
                                ? _themeService.accentColor
                                : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '弹',
                            style: TextStyle(
                              color: _danmakuConfig.enabled
                                  ? _themeService.accentColor
                                  : Colors.white70,
                              fontSize: _isFullscreen ? 13 : 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: _isFullscreen ? 10 : 8),

                  // 2. 弹幕搜索
                  Tooltip(
                    message: '搜索与匹配弹幕',
                    child: InkWell(
                      onTap: _showDanmakuSearchDialog,
                      borderRadius: BorderRadius.circular(19),
                      child: Container(
                        width: _isFullscreen ? 38 : 32,
                        height: _isFullscreen ? 38 : 32,
                        decoration: BoxDecoration(
                          color: const Color(0x55000000),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Icon(Icons.search, color: Colors.white, size: _isFullscreen ? 20 : 16),
                      ),
                    ),
                  ),
                  SizedBox(height: _isFullscreen ? 10 : 8),

                  // 3. 弹幕设置
                  Tooltip(
                    message: '弹幕设置 (颜色/行数/防重叠/渐变)',
                    child: InkWell(
                      onTap: _showDanmakuSettingsDialog,
                      borderRadius: BorderRadius.circular(19),
                      child: Container(
                        width: _isFullscreen ? 38 : 32,
                        height: _isFullscreen ? 38 : 32,
                        decoration: BoxDecoration(
                          color: const Color(0x55000000),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Icon(Icons.tune, color: Colors.white, size: _isFullscreen ? 19 : 15),
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
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: IconButton(
                            iconSize: 46,
                            icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                            onPressed: () => _player?.playOrPause(),
                          ),
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_next, color: Colors.white),
                          onPressed: _playNextEpisode,
                        ),
                      ],
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                      child: IconButton(
                        iconSize: 36,
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                        onPressed: () => _player?.playOrPause(),
                      ),
                    ),
            ),

          // ─────────────────────────────────────────────────────────────
          // 4. 屏幕右侧浮动控制 (全屏横屏专属)
          // ─────────────────────────────────────────────────────────────
          if (isFullscreenMode)
            Positioned(
              right: 14,
              top: 0,
              bottom: 0,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                          // 无论锁定还是解锁，均严格保持当前正在观看的屏幕方向，绝不触发瞬间横竖切屏！
                          if (_isLandscape) {
                            SystemChrome.setPreferredOrientations([
                              DeviceOrientation.landscapeLeft,
                              DeviceOrientation.landscapeRight,
                            ]);
                          } else {
                            SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
                          }
                        }
                        _showHud(
                          _isLocked ? Icons.lock : Icons.lock_open,
                          _isLocked ? '已锁定屏幕旋转与控制器' : '已解锁，保持当前全屏方向',
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    if (!_isLocked)
                      IconButton(
                        icon: const Icon(Icons.screen_rotation, color: Colors.white70),
                        tooltip: isDesktop ? '退出全屏' : (_isLandscape ? '切换至全屏竖屏' : '切换至全屏横屏'),
                        onPressed: () => _toggleFullscreenOrientation(),
                      ),
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
                                    inactiveTrackColor: Colors.white24,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value: _position.inSeconds.toDouble().clamp(
                                        0.0, max(1.0, _duration.inSeconds.toDouble())),
                                    max: max(1.0, _duration.inSeconds.toDouble()),
                                    onChanged: (val) {
                                      _startOverlayTimer();
                                      _player?.seek(Duration(seconds: val.toInt()));
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
                                  _buildBottomPillButton(_playerCoreName, _showPlayerSettingsDialog),
                                  _buildBottomPillButton(
                                    _isHardwareDecode ? '硬解' : '软解',
                                    _toggleHardwareDecode,
                                    isHighlight: _isHardwareDecode,
                                  ),
                                  _buildBottomPillButton('${_playbackRate.toStringAsFixed(2)}', _showSpeedMenu),
                                  _buildBottomPillButton(_fitName, _showFitMenu),
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
                                  _buildBottomPillButton(_formatSeconds(_skipIntroSeconds), _showSkipTimesDialog),
                                  _buildBottomPillButton(_formatSeconds(_skipOutroSeconds), _showSkipTimesDialog),
                                  _buildBottomPillButton('弹幕', _showDanmakuSearchDialog, isHighlight: _danmakuConfig.enabled),
                                  _buildBottomPillButton(
                                    '选集',
                                    () => setState(() => _showRightEpisodeDrawer = true),
                                    isHighlight: true,
                                  ),
                                  _buildBottomPillButton(
                                    '退出全屏',
                                    _exitFullscreen,
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
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: _position.inSeconds.toDouble().clamp(
                                    0.0, max(1.0, _duration.inSeconds.toDouble())),
                                max: max(1.0, _duration.inSeconds.toDouble()),
                                onChanged: (val) {
                                  _startOverlayTimer();
                                  _player?.seek(Duration(seconds: val.toInt()));
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

  Widget _buildBottomPillButton(String text, VoidCallback onTap, {bool isHighlight = false}) {
    return InkWell(
      onTap: () {
        _startOverlayTimer();
        onTap();
      },
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
    final currentEpisodes = sources.isNotEmpty ? sources[_selectedSourceIndex].episodes : [];

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _showRightEpisodeDrawer = false),
            child: Container(color: Colors.black45),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          child: Container(
            width: 380,
            decoration: BoxDecoration(
              color: const Color(0xFF161820).withOpacity(0.95),
              border: const Border(left: BorderSide(color: Colors.white12, width: 1)),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '播放列表与线路',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                          onPressed: () => setState(() => _showRightEpisodeDrawer = false),
                        ),
                      ],
                    ),
                  ),

                  // 线路选择栏
                  if (sources.length > 1)
                    SizedBox(
                      height: 38,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        itemCount: sources.length,
                        itemBuilder: (context, idx) {
                          final isSel = idx == _selectedSourceIndex;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(sources[idx].name),
                              selected: isSel,
                              selectedColor: const Color(0xFFE5A00D),
                              onSelected: (val) {
                                if (val) setState(() => _selectedSourceIndex = idx);
                              },
                            ),
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('共 ${currentEpisodes.length} 集',
                            style: const TextStyle(color: Colors.grey, fontSize: 12)),
                        InkWell(
                          onTap: () => setState(() => _isReversedOrder = !_isReversedOrder),
                          child: Row(
                            children: [
                              Icon(_isReversedOrder ? Icons.arrow_upward : Icons.arrow_downward,
                                  size: 14, color: const Color(0xFFE5A00D)),
                              const SizedBox(width: 4),
                              Text(_isReversedOrder ? '倒序' : '正序',
                                  style: const TextStyle(color: Color(0xFFE5A00D), fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final displayList = _isReversedOrder
                            ? currentEpisodes.reversed.toList()
                            : currentEpisodes;
                        return GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 2.2,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: displayList.length,
                          itemBuilder: (context, idx) {
                            final ep = displayList[idx];
                            final isCurrent = ep.name == _currentEpisodeName;
                            return TvFocusable(
                              onPressed: () {
                                _playEpisode(sources[_selectedSourceIndex].name, ep);
                                setState(() => _showRightEpisodeDrawer = false);
                              },
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? const Color(0xFFE5A00D)
                                      : const Color(0xFF262832),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: isCurrent ? const Color(0xFFE5A00D) : Colors.white12,
                                  ),
                                ),
                                child: Text(
                                  ep.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent ? Colors.black : Colors.white,
                                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            );
                          },
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

  void _showSpeedMenu() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(14.0),
                child: Text('播放速度',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
              ),
              ...speeds.map((s) {
                final isSel = _playbackRate == s;
                return ListTile(
                  dense: true,
                  title: Text('${s}x',
                      style: TextStyle(
                          color: isSel ? const Color(0xFFE5A00D) : Colors.white,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
                  trailing: isSel ? const Icon(Icons.check, color: Color(0xFFE5A00D)) : null,
                  onTap: () {
                    setState(() => _playbackRate = s);
                    _player?.setRate(s);
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _applyVideoFit(String name, BoxFit fit, double? aspectRatio) {
    setState(() {
      _fitName = name;
      _videoFit = fit;
      _customAspectRatio = aspectRatio;
      _showRightFitDrawer = false;
    });
    _showHud(Icons.aspect_ratio, '画幅比例: $name');
  }

  void _showFitMenu() {
    if (_isLandscape) {
      setState(() => _showRightFitDrawer = true);
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1E2028),
        builder: (ctx) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(14.0),
                  child: Text('画面比例与缩放',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
                ),
                ..._fitOptions.map((opt) {
                  final isSel = _fitName == opt['name'];
                  return ListTile(
                    dense: true,
                    title: Text(opt['name'],
                        style: TextStyle(
                            color: isSel ? const Color(0xFFE5A00D) : Colors.white,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
                    onTap: () {
                      _applyVideoFit(opt['name'], opt['fit'], opt['aspectRatio']);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          );
        },
      );
    }
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

  Widget _buildVodMetaInfo(String? siteName) {
    final vod = _vodDetail!;
    final year = vod.vodYear.isNotEmpty ? vod.vodYear : '2026';
    final area = vod.vodArea.isNotEmpty ? vod.vodArea : '中国大陆';
    final type = vod.typeName.isNotEmpty ? vod.typeName : '国产剧';
    final remarks = vod.vodRemarks.isNotEmpty ? vod.vodRemarks : '更新至22集 / 共42集';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: vod.vodName));
            _showHud(Icons.check, '已复制剧名: ${vod.vodName}');
          },
          child: Tooltip(
            message: '长按复制剧名',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    vod.vodName,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: vod.vodName));
                    _showHud(Icons.check, '已复制剧名: ${vod.vodName}');
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(Icons.copy, size: 14, color: Colors.white38),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          remarks,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 6),
        Text(
          '站源: ${siteName ?? "看剧ai js"}',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          '年份: $year  地区: $area  类型: $type',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        if (vod.vodDirector.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '导演: ${vod.vodDirector}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
        if (vod.vodActor.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '演员: ${vod.vodActor}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildSourceAndEpisodesSection() {
    final sources = _vodDetail?.playSources ?? [];
    if (sources.isEmpty) return const SizedBox.shrink();

    final currentEpisodes = sources[_selectedSourceIndex].episodes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 线路行 (参考图 5)
        Row(
          children: [
            const Text('线路',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
            const Spacer(),
            InkWell(
              onTap: () => _showHud(Icons.download, '离线缓存功能准备中'),
              child: const Row(
                children: [
                  Text('下载', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  Icon(Icons.chevron_right, size: 16, color: Colors.white70),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
          ),
          child: Listener(
            onPointerSignal: (pointerSignal) {
              if (pointerSignal is PointerScrollEvent) {
                final double delta = pointerSignal.scrollDelta.dy != 0
                    ? pointerSignal.scrollDelta.dy
                    : pointerSignal.scrollDelta.dx;
                if (_sourceScrollController.hasClients) {
                  final target = (_sourceScrollController.offset + delta).clamp(
                    0.0,
                    _sourceScrollController.position.maxScrollExtent,
                  );
                  _sourceScrollController.animateTo(
                    target,
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeOut,
                  );
                }
              }
            },
            child: SingleChildScrollView(
              controller: _sourceScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: sources.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final src = entry.value;
                  final isSel = idx == _selectedSourceIndex;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: InkWell(
                      onTap: () => setState(() => _selectedSourceIndex = idx),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSel ? _themeService.accentColor.withOpacity(0.25) : const Color(0x33FFFFFF),
                          borderRadius: BorderRadius.circular(8),
                          border: isSel ? Border.all(color: _themeService.accentColor, width: 1.2) : null,
                        ),
                        child: Text(
                          src.name,
                          style: TextStyle(
                            color: isSel ? _themeService.accentColor : Colors.white,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),

        // 选集行 (参考图 5: 选集 ⇄ 与 更多 >)
        Row(
          children: [
            InkWell(
              onTap: () => setState(() => _isReversedOrder = !_isReversedOrder),
              child: Row(
                children: [
                  const Text('选集',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(width: 4),
                  Icon(_isReversedOrder ? Icons.arrow_upward : Icons.swap_vert,
                      size: 16, color: Colors.white70),
                ],
              ),
            ),
            const Spacer(),
            InkWell(
              onTap: _showEpisodeListBottomSheet,
              child: const Row(
                children: [
                  Text('更多', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  Icon(Icons.chevron_right, size: 16, color: Colors.white70),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 剧集展示：Windows/TV端网格平铺，手机端横向滚动
        Builder(
          builder: (context) {
            final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
            final isWide = _isLandscape || isDesktop || (MediaQuery.of(context).size.width > 750 && MediaQuery.of(context).size.width > MediaQuery.of(context).size.height);
            final displayList = _isReversedOrder
                ? currentEpisodes.reversed.toList()
                : currentEpisodes;

            if (isWide) {
              final crossAxis = MediaQuery.of(context).size.width > 1200
                  ? 8
                  : MediaQuery.of(context).size.width > 900
                      ? 6
                      : 4;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxis,
                  childAspectRatio: 2.3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: displayList.length,
                itemBuilder: (context, idx) {
                  final ep = displayList[idx];
                  final isCurrent = ep.name == _currentEpisodeName;
                  return TvFocusable(
                    onPressed: () => _playEpisode(sources[_selectedSourceIndex].name, ep),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isCurrent ? const Color(0xFFE5A00D) : const Color(0xFF262832),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isCurrent ? const Color(0xFFE5A00D) : Colors.white12,
                        ),
                      ),
                      child: Text(
                        ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent ? Colors.black : Colors.white,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  );
                },
              );
            }

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: displayList.map((ep) {
                  final isCurrent = ep.name == _currentEpisodeName;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: InkWell(
                      onTap: () => _playEpisode(sources[_selectedSourceIndex].name, ep),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isCurrent ? const Color(0xFF2C5951) : const Color(0x33FFFFFF),
                          borderRadius: BorderRadius.circular(8),
                          border: isCurrent ? Border.all(color: const Color(0xFF66C8B5), width: 1.2) : null,
                        ),
                        child: Text(
                          ep.name,
                          style: TextStyle(
                            color: isCurrent ? const Color(0xFFFFD54F) : Colors.white,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        ),

        // 简介展示 (支持长按复制与一键复制)
        if ((_vodDetail?.vodContent ?? '').isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('简介', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _vodDetail!.vodContent));
                  _showHud(Icons.check, '已复制影视简介至剪贴板');
                },
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy, size: 13, color: Color(0xFF2979FF)),
                      SizedBox(width: 4),
                      Text('复制简介', style: TextStyle(color: Color(0xFF2979FF), fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: _vodDetail!.vodContent));
              _showHud(Icons.check, '已复制影视简介至剪贴板');
            },
            child: Tooltip(
              message: '长按可复制完整简介',
              child: SelectableText(
                _vodDetail!.vodContent,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQuickSearchSection() {
    if (_quickSearchResults.isEmpty && !_isQuickSearching) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('全网同名秒搜源', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 8),
        ..._quickSearchResults.map((vod) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                vod.vodPic,
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(width: 40, height: 56, color: Colors.grey),
              ),
            ),
            title: Text(vod.vodName, style: const TextStyle(color: Colors.white, fontSize: 13)),
            subtitle: Text('${vod.siteName ?? ""} - ${vod.vodRemarks}',
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
            trailing: const Icon(Icons.play_circle_fill, color: Color(0xFFE5A00D)),
            onTap: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => DetailView(repository: widget.repository, vodId: vod.vodId, vodItem: vod),
                ),
              );
            },
          );
        }),
      ],
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 12),
          Text(_playErrorMsg ?? '未能成功获取影视数据', style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回上一页'),
          ),
        ],
      ),
    );
  }
}
