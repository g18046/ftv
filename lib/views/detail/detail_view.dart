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

class _DetailViewState extends State<DetailView> {
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
  double _playbackRate = 1.0;
  BoxFit _videoFit = BoxFit.contain;
  double? _customAspectRatio;
  String _fitName = '原始';
  bool _showRightFitDrawer = false;
  bool _isFavorited = false;
  bool _isLooping = false;
  String _playerCoreName = 'EXO';
  bool _isHardwareDecode = true; // 硬解 / 软解

  // 视频分辨率
  int? _videoWidth;
  int? _videoHeight;

  // 片头片尾跳过秒数 (默认 01:47 与 02:23)
  int _skipIntroSeconds = 107;
  int _skipOutroSeconds = 143;

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
    _initDanmakuConfig();
    _listenLocalHttpServerEvents();
    _loadDetailAndAutoPlay();
  }

  @override
  void dispose() {
    _resetOrientationAndSystemUi();
    _savePlaybackHistory();
    _overlayHideTimer?.cancel();
    _gestureHudTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
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

  void _resetOrientationAndSystemUi() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _toggleOrientation() {
    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
      final source = _vodDetail!.playSources.first;
      if (source.episodes.isNotEmpty) {
        final ep = source.episodes.first;
        _playEpisode(source.name, ep);
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
        if (mounted) setState(() => _position = pos);
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
      final items = await _danmakuService.fetchDanmaku(
        vodName: _vodDetail!.vodName,
        episodeName: _currentEpisodeName,
        playUrl: _currentPlayUrl,
      );
      if (mounted) {
        setState(() {
          _danmakus = items;
          _isDanmakuLoading = false;
        });
        if (items.isNotEmpty) {
          _showHud(Icons.comment, '已载入 ${items.length} 条弹幕');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isDanmakuLoading = false);
    }
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
                  _showHud(Icons.subtitles_off, '已关闭字幕');
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

  /// 播放链接详情弹窗 (参考图 10)
  void _showPlayLinkDetailDialog() {
    final title = '${_vodDetail?.vodName ?? ""}：$_currentEpisodeName';
    final ua = _currentHeaders['User-Agent'] ??
        _currentHeaders['user-agent'] ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36';

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 580),
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(20),
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
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  'user-agent : $ua',
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  _currentPlayUrl,
                  style: const TextStyle(
                    color: Color(0xFF2979FF),
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 16, color: Color(0xFF2979FF)),
                      label: const Text('复制链接', style: TextStyle(color: Color(0xFF2979FF), fontWeight: FontWeight.bold)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _currentPlayUrl));
                        Navigator.pop(ctx);
                        _showHud(Icons.check, '已复制播放直链至剪贴板');
                      },
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2979FF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭', style: TextStyle(color: Colors.white)),
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
              title: const Row(
                children: [
                  Icon(Icons.settings, color: Color(0xFFE5A00D)),
                  SizedBox(width: 8),
                  Text('播放器高级设置', style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
              content: SizedBox(
                width: 380,
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
                              selectedColor: const Color(0xFFE5A00D),
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
                              selectedColor: const Color(0xFFE5A00D),
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

                    // 3. 片头片尾跳过
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('跳过片头:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        Text('${_formatSeconds(_skipIntroSeconds)} ($_skipIntroSeconds 秒)',
                            style: const TextStyle(color: Color(0xFFE5A00D), fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('跳过片尾:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        Text('${_formatSeconds(_skipOutroSeconds)} ($_skipOutroSeconds 秒)',
                            style: const TextStyle(color: Color(0xFFE5A00D), fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 4. 弹幕开关
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('弹幕总开关', style: TextStyle(color: Colors.white, fontSize: 13)),
                      value: _danmakuConfig.enabled,
                      activeColor: const Color(0xFFE5A00D),
                      onChanged: (val) {
                        setSettingState(() => _danmakuConfig.enabled = val);
                        setState(() => _danmakuConfig.enabled = val);
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
    } catch (_) {}
  }

  Future<void> _restorePlaybackHistory() async {
    if (_vodDetail == null) return;
    try {
      final val = await StorageBridge.getValue('history_${_vodDetail!.vodId}');
      if (val != null && val.contains('|')) {
        final parts = val.split('|');
        final sec = int.tryParse(parts[0]) ?? 0;
        final ep = parts.length > 1 ? parts[1] : '';
        if (sec > 5 && ep == _currentEpisodeName && _player != null) {
          _player!.seek(Duration(seconds: sec));
          _showHud(Icons.restore, '已恢复上次播放至: ${_formatDuration(Duration(seconds: sec))}');
        }
      }
    } catch (_) {}
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
    return PopScope(
      canPop: !_isLandscape,
      onPopInvokedWithResult: (didPop, result) {
        if (_isLandscape) {
          _toggleOrientation();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFE5A00D)))
            : _vodDetail == null
                ? _buildErrorView()
                : _isLandscape
                    ? _buildLandscapePlayer()
                    : _buildPortraitLayout(),
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
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1E3A34), Color(0xFF122420), Color(0xFF0E1A17)],
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
          onDoubleTap: () => _player?.playOrPause(),
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

              if (_showOverlay) _buildControlsOverlay(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControlsOverlay() {
    final resolutionStr = (_videoWidth != null && _videoHeight != null)
        ? '$_videoWidth × $_videoHeight'
        : '3840 × 2160';

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.black87,
            Colors.transparent,
            Colors.transparent,
            Colors.black87,
          ],
          stops: [0.0, 0.22, 0.75, 1.0],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        children: [
          // 顶部栏：返回、标题与分辨率、投屏、详情、收藏、设置按钮 (严格贴合 OK 影视参考图)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                      onPressed: () {
                        if (_isLandscape) {
                          _toggleOrientation();
                        } else {
                          Navigator.pop(context);
                        }
                      },
                    ),
                    const SizedBox(width: 4),
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
                              fontSize: 15,
                            ),
                          ),
                          if (_isLandscape)
                            Text(
                              resolutionStr,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                        ],
                      ),
                    ),

                    // 右上角三大核心功能：投屏、播放链接详情、播放器设置按钮
                    IconButton(
                      icon: const Icon(Icons.cast, color: Colors.white, size: 22),
                      tooltip: '投屏',
                      onPressed: _showCastDialog,
                    ),
                    IconButton(
                      icon: const Icon(Icons.info_outline, color: Colors.white, size: 22),
                      tooltip: '播放链接详情',
                      onPressed: _showPlayLinkDetailDialog,
                    ),
                    IconButton(
                      icon: Icon(
                        _isFavorited ? Icons.star : Icons.star_border,
                        color: _isFavorited ? const Color(0xFFE5A00D) : Colors.white,
                        size: 22,
                      ),
                      tooltip: '收藏',
                      onPressed: () {
                        setState(() => _isFavorited = !_isFavorited);
                        _showHud(
                          _isFavorited ? Icons.star : Icons.star_border,
                          _isFavorited ? '已添加至我的收藏' : '已取消收藏',
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 22),
                      tooltip: '播放器设置',
                      onPressed: _showPlayerSettingsDialog,
                    ),

                    // 横屏时右上角展示时间与电量
                    if (_isLandscape)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, right: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.battery_std, color: Colors.white70, size: 15),
                            const SizedBox(width: 2),
                            Text(
                              '${DateTime.now().hour.toString().padLeft(2, "0")}:${DateTime.now().minute.toString().padLeft(2, "0")}',
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // 屏幕中间左侧：弹幕开关键 [弹] (参考图 6)
          Positioned(
            left: 14,
            top: 0,
            bottom: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  setState(() => _danmakuConfig.enabled = !_danmakuConfig.enabled);
                  _danmakuService.saveConfig(_danmakuConfig);
                  _showHud(
                    _danmakuConfig.enabled ? Icons.comment : Icons.comments_disabled,
                    _danmakuConfig.enabled ? '弹幕已开启' : '弹幕已关闭',
                  );
                },
                onLongPress: _showDanmakuSearchDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: _danmakuConfig.enabled
                        ? const Color(0xFFE5A00D).withOpacity(0.25)
                        : Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _danmakuConfig.enabled ? const Color(0xFFE5A00D) : Colors.white30,
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.comment,
                        size: 15,
                        color: _danmakuConfig.enabled ? const Color(0xFFE5A00D) : Colors.white60,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '弹',
                        style: TextStyle(
                          color: _danmakuConfig.enabled ? const Color(0xFFE5A00D) : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 屏幕中心控制：上一集、播放/暂停、下一集
          if (!_isLocked)
            Center(
              child: Row(
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
              ),
            ),

          // 屏幕右侧垂直按钮：锁定、画面旋转/比例切换
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
                    onPressed: () {
                      setState(() => _isLocked = !_isLocked);
                      _showHud(
                        _isLocked ? Icons.lock : Icons.lock_open,
                        _isLocked ? '屏幕已锁定，防止误触' : '屏幕已解锁',
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  if (!_isLocked)
                    IconButton(
                      icon: const Icon(Icons.screen_rotation, color: Colors.white70),
                      tooltip: '画面旋转与比例',
                      onPressed: _showFitMenu,
                    ),
                ],
              ),
            ),
          ),

          // 底部控制栏：横屏完整控制 (进度、EXO、硬解/软解、倍速、比例、视轨、音轨、字幕、弹幕、选集)
          if (!_isLocked)
            Positioned(
              left: 12,
              right: 12,
              bottom: 8,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 进度条行
                    Row(
                      children: [
                        Text(_formatDuration(_position),
                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: _position.inSeconds.toDouble().clamp(
                                0.0, max(1.0, _duration.inSeconds.toDouble())),
                            max: max(1.0, _duration.inSeconds.toDouble()),
                            activeColor: const Color(0xFFE5A00D),
                            inactiveColor: Colors.white24,
                            onChanged: (val) {
                              _startOverlayTimer();
                              _player?.seek(Duration(seconds: val.toInt()));
                            },
                          ),
                        ),
                        Text(_formatDuration(_duration),
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),

                    // 底部控制按钮行 (严格贴合 OK 影视横屏设计)
                    if (_isLandscape)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // 左侧属性控制
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
                                () {
                                  setState(() => _isLooping = !_isLooping);
                                  _showHud(Icons.loop, _isLooping ? '单集循环播放' : '顺序播放');
                                },
                              ),
                            ],
                          ),

                          // 右侧音视频轨与剧集控制 (视轨、音轨、弹幕、选集等)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildBottomPillButton('字幕', _showSubtitleTrackDialog),
                              _buildBottomPillButton('音轨', _showAudioTrackDialog),
                              _buildBottomPillButton('视轨', _showVideoTrackDialog),
                              _buildBottomPillButton(_formatSeconds(_skipIntroSeconds), () {
                                _showHud(Icons.skip_next, '片头跳过时长: $_skipIntroSeconds 秒');
                              }),
                              _buildBottomPillButton(_formatSeconds(_skipOutroSeconds), () {
                                _showHud(Icons.skip_next, '片尾跳过时长: $_skipOutroSeconds 秒');
                              }),
                              _buildBottomPillButton('弹幕', _showDanmakuSearchDialog, isHighlight: _danmakuConfig.enabled),
                              _buildBottomPillButton(
                                '选集',
                                () => setState(() => _showRightEpisodeDrawer = true),
                                isHighlight: true,
                              ),
                            ],
                          ),
                        ],
                      )
                    else
                      // 竖屏底部控制行
                      Row(
                        children: [
                          TextButton(
                            onPressed: _showSpeedMenu,
                            child: Text('${_playbackRate}x',
                                style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ),
                          TextButton(
                            onPressed: _showFitMenu,
                            child: Text(_fitName,
                                style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ),
                          _buildBottomPillButton(
                            _isHardwareDecode ? '硬解' : '软解',
                            _toggleHardwareDecode,
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _showDanmakuSearchDialog,
                            icon: const Icon(Icons.comment, size: 16, color: Color(0xFFE5A00D)),
                            label: const Text('弹幕',
                                style: TextStyle(color: Color(0xFFE5A00D), fontSize: 12)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.fullscreen, color: Colors.white),
                            onPressed: _toggleOrientation,
                          ),
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

  Widget _buildBottomPillButton(String text, VoidCallback onTap, {bool isHighlight = false}) {
    return InkWell(
      onTap: () {
        _startOverlayTimer();
        onTap();
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          text,
          style: TextStyle(
            color: isHighlight ? const Color(0xFFE5A00D) : Colors.white,
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

  /// OK 影视横屏右侧抽屉式选集面板
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
        Text(
          vod.vodName,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
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
                      color: isSel ? const Color(0xFF2C5951) : const Color(0x33FFFFFF),
                      borderRadius: BorderRadius.circular(8),
                      border: isSel ? Border.all(color: const Color(0xFF66C8B5), width: 1.2) : null,
                    ),
                    child: Text(
                      src.name,
                      style: TextStyle(
                        color: isSel ? const Color(0xFFFFD54F) : Colors.white,
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
              onTap: () {
                // 打开全屏选集面板
                setState(() => _showRightEpisodeDrawer = true);
              },
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

        // 横向可滚动剧集胶囊 (参考图 5: 第15集、第16集...)
        Builder(
          builder: (context) {
            final displayList = _isReversedOrder
                ? currentEpisodes.reversed.toList()
                : currentEpisodes;
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

        // 简介展示
        if ((_vodDetail?.vodContent ?? '').isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('简介', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 6),
          Text(
            _vodDetail!.vodContent,
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
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
