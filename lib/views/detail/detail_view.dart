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

  bool _isPlaying = false;
  bool _isLocked = false;
  bool _showOverlay = true;
  bool _isLandscape = false;
  double _playbackRate = 1.0;
  BoxFit _videoFit = BoxFit.contain;
  double? _customAspectRatio;
  String _fitName = '原始';
  bool _showRightFitDrawer = false;

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

  /// 监听本地 NanoHTTPD 服务触发的刷新指令 (如 PanUtils.js 刷新的弹幕/字幕)
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
      return;
    }
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) {
      _startOverlayTimer();
    }
  }

  void _startOverlayTimer() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying && !_isLocked && !_showRightEpisodeDrawer) {
        setState(() => _showOverlay = false);
      }
    });
  }

  String _formatDuration(Duration duration) {
    final minutes =
        duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final hours = duration.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _loadDetailAndAutoPlay() async {
    setState(() => _isLoading = true);
    VodItem? detail;

    if (widget.vodItem != null) {
      detail = widget.vodItem;
    } else if (widget.vodId.contains('://') ||
        widget.vodId.startsWith('magnet:') ||
        widget.vodId.startsWith('ed2k:')) {
      detail = await widget.repository.pushLink(widget.vodId);
    } else {
      detail = await widget.repository.fetchDetail(widget.vodId);
    }

    setState(() {
      _vodDetail = detail;
      _isLoading = false;
      _selectedSourceIndex = 0;
    });

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

  /// 刷新当前播放 (重新加载播放链接与恢复进度)
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

      _videoController ??= VideoController(_player!);

      _posSub?.cancel();
      _durSub?.cancel();
      _playSub?.cancel();

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

  /// 参考【小白弹幕】：搜索列表先展示每个弹幕源，再展示每个弹幕源下所有剧集
  void _showDanmakuSearchDialog() {
    final titleController =
        TextEditingController(text: _vodDetail?.vodName ?? '');
    List<LogVarAnimeSource> animeSources = [];
    bool isSearchingLogVar = false;

    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            title: const Row(
              children: [
                Icon(Icons.search, color: Color(0xFFE5A00D)),
                SizedBox(width: 8),
                Text('匹配 LogVar 在线弹幕 (小白弹幕源)',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('服务器: ${_danmakuConfig.serverUrl}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: titleController,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: '搜索关键词 (剧名/动漫)',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE5A00D)),
                        onPressed: isSearchingLogVar
                            ? null
                            : () async {
                                setDialogState(() => isSearchingLogVar = true);
                                final res = await _danmakuService
                                    .searchLogVarAnimes(
                                        titleController.text.trim());
                                setDialogState(() {
                                  animeSources = res;
                                  isSearchingLogVar = false;
                                });
                              },
                        child: isSearchingLogVar
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Text('搜索',
                                style: TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (animeSources.isNotEmpty) ...[
                    const Text('弹幕源列表 (参照小白弹幕，展开查看剧集):',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 240,
                      child: ListView.separated(
                        itemCount: animeSources.length,
                        separatorBuilder: (_, ___) => const SizedBox(height: 8),
                        itemBuilder: (context, idx) {
                          final source = animeSources[idx];
                          return Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF262832),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: ExpansionTile(
                              dense: true,
                              initiallyExpanded: idx == 0,
                              leading: const Icon(Icons.movie_filter,
                                  color: Color(0xFFE5A00D), size: 18),
                              title: Text(
                                source.animeTitle,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ),
                              subtitle: Text(
                                '类型: ${source.typeDescription} | 共 ${source.episodes.length} 集',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 10),
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: source.episodes.map((ep) {
                                      return ActionChip(
                                        backgroundColor:
                                            const Color(0xFF1E2028),
                                        side: const BorderSide(
                                            color: Colors.white24),
                                        label: Text(
                                          ep.episodeTitle,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11),
                                        ),
                                        onPressed: () async {
                                          Navigator.pop(context);
                                          setState(
                                              () => _isDanmakuLoading = true);
                                          final items = await _danmakuService
                                              .fetchDanmakuByEpisodeId(
                                                  ep.episodeId);
                                          if (mounted) {
                                            setState(() {
                                              _danmakus = items;
                                              _matchedLogVarEpisodeId =
                                                  ep.episodeId;
                                              _isDanmakuLoading = false;
                                            });
                                            _showHud(Icons.check_circle,
                                                '已关联 [${source.animeTitle} - ${ep.episodeTitle}] (${items.length}条弹幕)');
                                          }
                                        },
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
  }

  /// 实时“推送/发送弹幕”弹窗面板
  void _showSendDanmakuDialog() {
    final textController = TextEditingController();
    Color selectedColor = Colors.white;
    DanmakuType selectedType = DanmakuType.scroll;
    bool isSending = false;

    final colorList = [
      {'color': Colors.white, 'name': '纯白'},
      {'color': const Color(0xFFFF4D4F), 'name': '鲜红'},
      {'color': const Color(0xFFFFC53D), 'name': '暖黄'},
      {'color': const Color(0xFF73D13D), 'name': '翠绿'},
      {'color': const Color(0xFF40A9FF), 'name': '蔚蓝'},
      {'color': const Color(0xFFF759AB), 'name': '粉红'},
      {'color': const Color(0xFF36CFC9), 'name': '青色'},
    ];

    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final curSeconds = _position.inMilliseconds / 1000.0;
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2028),
            title: Row(
              children: [
                const Icon(Icons.send, color: Color(0xFFE5A00D)),
                const SizedBox(width: 8),
                const Text('发送弹幕',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
                const Spacer(),
                Text(
                  '时间点: ${_formatDuration(_position)}',
                  style: const TextStyle(
                      color: Color(0xFFE5A00D),
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: textController,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: '输入你想说的弹幕内容...',
                      hintStyle: TextStyle(color: Colors.white38),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('选择弹幕颜色:',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: colorList.map((c) {
                      final col = c['color'] as Color;
                      final isSel = selectedColor == col;
                      return ChoiceChip(
                        selected: isSel,
                        backgroundColor: const Color(0xFF262832),
                        selectedColor: col,
                        label: Text(
                          c['name'] as String,
                          style: TextStyle(
                            color: isSel && col == Colors.white
                                ? Colors.black
                                : Colors.white,
                            fontSize: 11,
                            fontWeight:
                                isSel ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        onSelected: (val) {
                          if (val) setDialogState(() => selectedColor = col);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  const Text('弹幕样式/位置:',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      ChoiceChip(
                        selected: selectedType == DanmakuType.scroll,
                        selectedColor: const Color(0xFFE5A00D),
                        label: Text('自右向左 滚动',
                            style: TextStyle(
                                color: selectedType == DanmakuType.scroll
                                    ? Colors.black
                                    : Colors.white70,
                                fontSize: 11)),
                        onSelected: (v) {
                          if (v) {
                            setDialogState(
                                () => selectedType = DanmakuType.scroll);
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        selected: selectedType == DanmakuType.top,
                        selectedColor: const Color(0xFFE5A00D),
                        label: Text('顶部固定',
                            style: TextStyle(
                                color: selectedType == DanmakuType.top
                                    ? Colors.black
                                    : Colors.white70,
                                fontSize: 11)),
                        onSelected: (v) {
                          if (v) {
                            setDialogState(
                                () => selectedType = DanmakuType.top);
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        selected: selectedType == DanmakuType.bottom,
                        selectedColor: const Color(0xFFE5A00D),
                        label: Text('底部固定',
                            style: TextStyle(
                                color: selectedType == DanmakuType.bottom
                                    ? Colors.black
                                    : Colors.white70,
                                fontSize: 11)),
                        onSelected: (v) {
                          if (v) {
                            setDialogState(
                                () => selectedType = DanmakuType.bottom);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE5A00D)),
                onPressed: isSending
                    ? null
                    : () async {
                        final msg = textController.text.trim();
                        if (msg.isEmpty) return;

                        setDialogState(() => isSending = true);

                        // 1. 本地即时插帧绘制
                        final newItem = DanmakuItem(
                          time: curSeconds,
                          text: msg,
                          color: selectedColor,
                          type: selectedType,
                        );

                        setState(() {
                          _danmakus.add(newItem);
                          _danmakus.sort((a, b) => a.time.compareTo(b.time));
                        });

                        Navigator.pop(context);
                        _showHud(Icons.check, '✅ 弹幕即刻发射成功！');

                        // 2. 后台异步推送到 LogVar 服务器
                        _danmakuService.sendDanmaku(
                          vodName: _vodDetail?.vodName ?? '',
                          episodeName: _currentEpisodeName,
                          episodeId: _matchedLogVarEpisodeId,
                          time: curSeconds,
                          text: msg,
                          color: selectedColor,
                          type: selectedType,
                        );
                      },
                child: const Text('发送弹幕',
                    style: TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _savePlaybackHistory() async {
    if (_vodDetail == null || _position.inSeconds < 5) return;
    try {
      final key = 'hist_${widget.vodId}_$_currentEpisodeName';
      await StorageBridge().set(key, _position.inSeconds.toString());
    } catch (_) {}
  }

  Future<void> _restorePlaybackHistory() async {
    try {
      final key = 'hist_${widget.vodId}_$_currentEpisodeName';
      final savedStr = await StorageBridge().get(key);
      if (savedStr != null && savedStr.isNotEmpty) {
        final sec = int.tryParse(savedStr);
        if (sec != null && sec > 10 && _player != null) {
          _player!.seek(Duration(seconds: sec));
          _showHud(Icons.history,
              '已为您恢复到上次播放位置: ${_formatDuration(Duration(seconds: sec))}');
        }
      }
    } catch (_) {}
  }

  void _showHud(IconData icon, String text) {
    _gestureHudTimer?.cancel();
    setState(() {
      _showGestureHud = true;
      _gestureHudIcon = icon;
      _gestureHudText = text;
    });
    _gestureHudTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _showGestureHud = false);
    });
  }

  void _onPanStart(DragStartDetails details, BoxConstraints constraints) {
    if (_isLocked) return;
    _dragStartX = details.localPosition.dx;
    _dragStartY = details.localPosition.dy;
    _isDraggingSeek = false;
    _isDraggingLeft = false;
    _isDraggingRight = false;
  }

  void _onPanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_isLocked || _duration.inSeconds <= 0) return;

    final dx = details.localPosition.dx - _dragStartX;
    final dy = details.localPosition.dy - _dragStartY;

    if (!_isDraggingLeft &&
        !_isDraggingRight &&
        (dx.abs() > 20 || _isDraggingSeek)) {
      _isDraggingSeek = true;
      final seekDeltaSeconds = (dx / constraints.maxWidth) * 120;
      double target = (_position.inSeconds + seekDeltaSeconds)
          .clamp(0.0, _duration.inSeconds.toDouble());
      _seekTargetSeconds = target;

      final sign = seekDeltaSeconds >= 0 ? '+' : '';
      final deltaText = '$sign${seekDeltaSeconds.toInt()}s';
      final targetDuration = Duration(seconds: target.toInt());

      _showHud(
        seekDeltaSeconds >= 0 ? Icons.fast_forward : Icons.fast_rewind,
        '[$deltaText]  ${_formatDuration(targetDuration)} / ${_formatDuration(_duration)}',
      );
      return;
    }

    if (!_isDraggingSeek &&
        (dy.abs() > 15 || _isDraggingLeft || _isDraggingRight)) {
      final isLeft = _dragStartX < constraints.maxWidth * 0.5;
      final step = -dy / constraints.maxHeight;

      if (isLeft) {
        _isDraggingLeft = true;
        _currentBrightness =
            (_currentBrightness + step * 0.1).clamp(0.05, 1.0);
        _showHud(
            Icons.brightness_6, '亮度: ${(_currentBrightness * 100).toInt()}%');
      } else {
        _isDraggingRight = true;
        _currentVolume = (_currentVolume + step * 10).clamp(0.0, 100.0);
        _player?.setVolume(_currentVolume);
        _showHud(
          _currentVolume == 0 ? Icons.volume_off : Icons.volume_up,
          '音量: ${_currentVolume.toInt()}%',
        );
      }
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isDraggingSeek) {
      _player?.seek(Duration(seconds: _seekTargetSeconds.toInt()));
    }
    _isDraggingSeek = false;
    _isDraggingLeft = false;
    _isDraggingRight = false;
  }

  KeyEventResult _handlePlayerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_showRightEpisodeDrawer || _showRightFitDrawer) {
        return KeyEventResult.ignored;
      }
      _toggleOverlay();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final newPos = max(0, _position.inSeconds - 10);
      _player?.seek(Duration(seconds: newPos));
      _showHud(
          Icons.fast_rewind, '-10s  ${_formatDuration(Duration(seconds: newPos))}');
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final newPos = min(_duration.inSeconds, _position.inSeconds + 10);
      _player?.seek(Duration(seconds: newPos));
      _showHud(
          Icons.fast_forward, '+10s  ${_formatDuration(Duration(seconds: newPos))}');
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _currentVolume = min(100.0, _currentVolume + 5);
      _player?.setVolume(_currentVolume);
      _showHud(Icons.volume_up, '音量: ${_currentVolume.toInt()}%');
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _currentVolume = max(0.0, _currentVolume - 5);
      _player?.setVolume(_currentVolume);
      _showHud(Icons.volume_down, '音量: ${_currentVolume.toInt()}%');
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_showRightEpisodeDrawer || _showRightFitDrawer) {
        setState(() {
          _showRightEpisodeDrawer = false;
          _showRightFitDrawer = false;
        });
        return KeyEventResult.handled;
      }
      if (_isLandscape) {
        _toggleOrientation();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _playerFocusNode,
      autofocus: true,
      onKeyEvent: _handlePlayerKeyEvent,
      child: Scaffold(
        backgroundColor: const Color(0xFF101216),
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFFE5A00D)))
            : _vodDetail == null
                ? _buildErrorView()
                : _isLandscape
                    ? _buildLandscapePlayer()
                    : _buildPortraitLayout(),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return SafeArea(
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildVideoPlayerArea(),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14.0, vertical: 10.0),
              children: [
                _buildVodMetaInfo(),
                const SizedBox(height: 12),
                _buildSourceAndEpisodesSection(),
                const SizedBox(height: 16),
                _buildQuickSearchSection(),
              ],
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
            if (_player != null) {
              _player!.playOrPause();
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
              ),

              if (_showGestureHud)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: const Color(0xFFE5A00D), width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_gestureHudIcon,
                            color: const Color(0xFFE5A00D), size: 28),
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
                          style:
                              TextStyle(color: Colors.white70, fontSize: 13)),
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
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 40),
                        const SizedBox(height: 8),
                        Text(_playErrorMsg!,
                            style: const TextStyle(color: Colors.white70)),
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
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.black87,
            Colors.transparent,
            Colors.transparent,
            Colors.black87
          ],
          stops: [0.0, 0.25, 0.75, 1.0],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () {
                    if (_isLandscape) {
                      _toggleOrientation();
                    } else {
                      Navigator.pop(context);
                    }
                  },
                ),
                Expanded(
                  child: Text(
                    '${_vodDetail?.vodName ?? ""}  $_currentEpisodeName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                  ),
                ),
                // 刷新播放按钮
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  tooltip: '刷新播放',
                  onPressed: _refreshPlayback,
                ),
                // 发送弹幕快捷入口
                TextButton.icon(
                  onPressed: _showSendDanmakuDialog,
                  icon:
                      const Icon(Icons.send, color: Color(0xFFE5A00D), size: 16),
                  label: const Text('发弹幕',
                      style: TextStyle(
                          color: Color(0xFFE5A00D),
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ),
                // 搜索/匹配 LogVar 弹幕
                IconButton(
                  icon: Icon(
                    _danmakuConfig.enabled
                        ? Icons.comment
                        : Icons.comments_disabled,
                    color: _danmakuConfig.enabled
                        ? const Color(0xFFE5A00D)
                        : Colors.grey,
                  ),
                  tooltip: '搜索与匹配弹幕',
                  onPressed: _showDanmakuSearchDialog,
                ),
              ],
            ),
          ),

          Positioned(
            left: 16,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                icon: Icon(
                  _isLocked ? Icons.lock : Icons.lock_open,
                  color: _isLocked ? const Color(0xFFE5A00D) : Colors.white70,
                ),
                onPressed: () => setState(() => _isLocked = !_isLocked),
              ),
            ),
          ),

          if (!_isLocked)
            Positioned(
              left: 12,
              right: 12,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(_formatDuration(_position),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                      // 💡 仅在横屏时显示进度条 Slider，竖屏不展示
                      if (_isLandscape)
                        Expanded(
                          child: Slider(
                            value: _position.inSeconds.toDouble().clamp(0.0,
                                max(1.0, _duration.inSeconds.toDouble())),
                            max: max(1.0, _duration.inSeconds.toDouble()),
                            activeColor: const Color(0xFFE5A00D),
                            inactiveColor: Colors.white24,
                            onChanged: (val) {
                              _startOverlayTimer();
                              _player?.seek(Duration(seconds: val.toInt()));
                            },
                          ),
                        )
                      else
                        const Spacer(),
                      Text(_formatDuration(_duration),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white),
                        onPressed: () => _player?.playOrPause(),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _showSpeedMenu,
                        child: Text('${_playbackRate}x',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ),
                      TextButton(
                        onPressed: _showFitMenu,
                        child: Text(_fitName,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() => _showRightEpisodeDrawer = true);
                        },
                        child: const Text('选集',
                            style: TextStyle(
                                color: Color(0xFFE5A00D),
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                      ),
                      IconButton(
                        icon: Icon(
                            _isLandscape
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            color: Colors.white),
                        onPressed: _toggleOrientation,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// OK 影视横屏右侧抽屉式选集面板 (点击空白遮罩处关闭)
  Widget _buildLandscapeRightDrawer() {
    final sources = _vodDetail?.playSources ?? [];
    final currentEpisodes = sources.isNotEmpty
        ? sources[_selectedSourceIndex].episodes
        : <EpisodeItem>[];

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showRightEpisodeDrawer = false),
            child: Container(color: Colors.black38),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 320,
          child: Container(
            color: const Color(0xEE12141C),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('选集与线路',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () =>
                          setState(() => _showRightEpisodeDrawer = false),
                    ),
                  ],
                ),
                const Divider(height: 10, color: Colors.white12),
                if (sources.length > 1) ...[
                  const Text('播放线路:',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 34,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: sources.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, idx) {
                        final isSel = idx == _selectedSourceIndex;
                        return ChoiceChip(
                          selected: isSel,
                          selectedColor: const Color(0xFFE5A00D),
                          label: Text(
                            sources[idx].name,
                            style: TextStyle(
                              color: isSel ? Colors.black : Colors.white70,
                              fontSize: 12,
                              fontWeight: isSel
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          onSelected: (val) {
                            if (val) {
                              setState(() => _selectedSourceIndex = idx);
                              final ep = sources[idx].episodes.firstOrNull;
                              if (ep != null) {
                                _playEpisode(sources[idx].name, ep);
                              }
                            }
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: 2.2,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: currentEpisodes.length,
                    itemBuilder: (context, idx) {
                      final ep = currentEpisodes[idx];
                      final isPlayingThis = ep.name == _currentEpisodeName;

                      return TvFocusable(
                        onPressed: () {
                          setState(() {
                            _showRightEpisodeDrawer = false;
                            _showRightFitDrawer = false;
                          });
                          _playEpisode(sources[_selectedSourceIndex].name, ep);
                        },
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isPlayingThis
                                ? const Color(0xFFE5A00D)
                                : const Color(0xFF22242E),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            ep.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  isPlayingThis ? Colors.black : Colors.white,
                              fontSize: 12,
                              fontWeight: isPlayingThis
                                  ? FontWeight.bold
                                  : FontWeight.normal,
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
      ],
    );
  }

  void _showSpeedMenu() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      builder: (context) {
        return ListView(
          shrinkWrap: true,
          children: speeds.map((s) {
            return ListTile(
              title: Text('${s}x',
                  style: TextStyle(
                      color: s == _playbackRate
                          ? const Color(0xFFE5A00D)
                          : Colors.white)),
              trailing: s == _playbackRate
                  ? const Icon(Icons.check, color: Color(0xFFE5A00D))
                  : null,
              onTap: () {
                setState(() => _playbackRate = s);
                _player?.setRate(s);
                Navigator.pop(context);
              },
            );
          }).toList(),
        );
      },
    );
  }

  void _applyVideoFit(String name, BoxFit fit, double? aspectRatio) {
    setState(() {
      _fitName = name;
      _videoFit = fit;
      _customAspectRatio = aspectRatio;
    });
    _showHud(Icons.aspect_ratio, '画面比例: $name');
  }

  void _showFitMenu() {
    if (_isLandscape) {
      setState(() {
        _showRightFitDrawer = !_showRightFitDrawer;
        _showRightEpisodeDrawer = false;
      });
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.aspect_ratio,
                        color: Color(0xFFE5A00D), size: 18),
                    SizedBox(width: 8),
                    Text('画面比例 / 尺寸模式',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _fitOptions.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (context, idx) {
                    final item = _fitOptions[idx];
                    final name = item['name'] as String;
                    final fit = item['fit'] as BoxFit;
                    final ar = item['aspectRatio'] as double?;
                    final desc = item['desc'] as String;
                    final isSel = name == _fitName;

                    return ListTile(
                      dense: true,
                      title: Text(
                        name,
                        style: TextStyle(
                          color:
                              isSel ? const Color(0xFFE5A00D) : Colors.white,
                          fontWeight:
                              isSel ? FontWeight.bold : FontWeight.normal,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(desc,
                          style:
                              const TextStyle(color: Colors.grey, fontSize: 11)),
                      trailing: isSel
                          ? const Icon(Icons.check_circle,
                              color: Color(0xFFE5A00D), size: 18)
                          : null,
                      onTap: () {
                        _applyVideoFit(name, fit, ar);
                        Navigator.pop(context);
                      },
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

  /// 横屏右侧画面比例抽屉面板 (点击空白处关闭)
  Widget _buildLandscapeFitDrawer() {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showRightFitDrawer = false),
            child: Container(color: Colors.black38),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 290,
          child: Container(
            color: const Color(0xEE12141C),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.aspect_ratio,
                        color: Color(0xFFE5A00D), size: 20),
                    const SizedBox(width: 8),
                    const Text('画面比例与尺寸',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () =>
                          setState(() => _showRightFitDrawer = false),
                    ),
                  ],
                ),
                const Divider(height: 10, color: Colors.white12),
                const SizedBox(height: 6),
                Expanded(
                  child: ListView.separated(
                    itemCount: _fitOptions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, idx) {
                      final item = _fitOptions[idx];
                      final name = item['name'] as String;
                      final fit = item['fit'] as BoxFit;
                      final ar = item['aspectRatio'] as double?;
                      final desc = item['desc'] as String;
                      final isSel = name == _fitName;

                      return TvFocusable(
                        onPressed: () => _applyVideoFit(name, fit, ar),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSel
                                ? const Color(0xFF26241C)
                                : const Color(0xFF1E2028),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSel
                                  ? const Color(0xFFE5A00D)
                                  : Colors.white12,
                              width: isSel ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: TextStyle(
                                        color: isSel
                                            ? const Color(0xFFE5A00D)
                                            : Colors.white,
                                        fontWeight: isSel
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      desc,
                                      style: TextStyle(
                                        color: isSel
                                            ? const Color(0xFFE5A00D)
                                                .withOpacity(0.8)
                                            : Colors.grey,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSel)
                                const Icon(Icons.check_circle,
                                    color: Color(0xFFE5A00D), size: 18),
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
      ],
    );
  }

  Widget _buildVodMetaInfo() {
    final vod = _vodDetail!;
    final year = vod.vodYear ?? '';
    final area = vod.vodArea ?? '';
    final remarks = vod.vodRemarks ?? '';
    final content = vod.vodContent ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onLongPress: _triggerQuickSearch,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  vod.vodName,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5A00D).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: const Color(0xFFE5A00D).withOpacity(0.5)),
                ),
                child: const Text('长按秒搜',
                    style: TextStyle(
                        color: Color(0xFFE5A00D),
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            if (year.isNotEmpty)
              Text(year,
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
            if (area.isNotEmpty)
              Text(area,
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
            if (remarks.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5A00D).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  remarks,
                  style: const TextStyle(
                      color: Color(0xFFE5A00D),
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        if (content.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
        if (_isQuickSearching)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: const [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFFE5A00D))),
                SizedBox(width: 8),
                Text('🔍 正在全网并发秒搜同名片源...',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        if (_quickSearchResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.flash_on, color: Color(0xFFE5A00D), size: 16),
              const SizedBox(width: 4),
              Text(
                '秒搜换源 (${_quickSearchResults.length})',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 135,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _quickSearchResults.length,
              itemBuilder: (context, idx) {
                final qVod = _quickSearchResults[idx];
                return Container(
                  width: 95,
                  margin: const EdgeInsets.only(right: 8),
                  child: TvFocusable(
                    onPressed: () {
                      if (qVod.isFolder) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FolderListView(
                              repository: widget.repository,
                              folderVod: qVod,
                            ),
                          ),
                        );
                      } else {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DetailView(
                              repository: widget.repository,
                              vodId: qVod.vodId,
                            ),
                          ),
                        );
                      }
                    },
                    child: Card(
                      color: const Color(0xFF1E2028),
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          qVod.vodPic.isNotEmpty
                              ? Image.network(
                                  qVod.vodPic,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                      Icons.movie,
                                      size: 28,
                                      color: Colors.grey),
                                )
                              : const Icon(Icons.movie,
                                  size: 28, color: Colors.grey),
                          if (qVod.siteName != null)
                            Positioned(
                              top: 2,
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(3)),
                                child: Text(qVod.siteName!,
                                    style: const TextStyle(
                                        color: Color(0xFFE5A00D),
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              color: Colors.black87,
                              padding: const EdgeInsets.all(3),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    qVod.vodName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  if (qVod.vodRemarks.isNotEmpty)
                                    Text(
                                      qVod.vodRemarks,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 8),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
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
        Row(
          children: [
            const Text('线路:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white70)),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: sources.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final src = entry.value;
                    final isSel = idx == _selectedSourceIndex;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ChoiceChip(
                        selected: isSel,
                        selectedColor: const Color(0xFFE5A00D),
                        label: Text(
                          src.name,
                          style: TextStyle(
                            color: isSel ? Colors.black : Colors.white70,
                            fontWeight: isSel
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        onSelected: (val) {
                          if (val) setState(() => _selectedSourceIndex = idx);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              '选集 (${currentEpisodes.length})',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () =>
                  setState(() => _isReversedOrder = !_isReversedOrder),
              icon: Icon(
                  _isReversedOrder ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 14,
                  color: Colors.grey),
              label: Text(_isReversedOrder ? '倒序' : '正序',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Builder(
          builder: (context) {
            final displayList = _isReversedOrder
                ? currentEpisodes.reversed.toList()
                : currentEpisodes;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 2.2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: displayList.length,
              itemBuilder: (context, idx) {
                final ep = displayList[idx];
                final isCurrent = ep.name == _currentEpisodeName;

                return TvFocusable(
                  onPressed: () =>
                      _playEpisode(sources[_selectedSourceIndex].name, ep),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? const Color(0xFFE5A00D)
                          : const Color(0xFF1E2028),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      ep.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent ? Colors.black : Colors.white,
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                        fontSize: 12,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickSearchSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF181A22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flash_on, color: Color(0xFFE5A00D), size: 18),
              const SizedBox(width: 6),
              const Text('同名全网秒搜换源',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE5A00D),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _isQuickSearching ? null : _triggerQuickSearch,
                child: const Text('秒搜',
                    style: TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          if (_quickSearchResults.isNotEmpty) ...[
            const SizedBox(height: 10),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: min(5, _quickSearchResults.length),
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: Colors.white10),
              itemBuilder: (context, idx) {
                final item = _quickSearchResults[idx];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.vodName,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text(item.vodRemarks,
                      style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  trailing: const Icon(Icons.play_circle_outline,
                      color: Color(0xFFE5A00D)),
                  onTap: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DetailView(
                            repository: widget.repository, vodId: item.vodId),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _triggerQuickSearch() async {
    if (_vodDetail == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ 正在长按快速搜索 [${_vodDetail!.vodName}] 其它站点资源...'),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF1E2028),
      ),
    );
    setState(() => _isQuickSearching = true);
    try {
      final results =
          await widget.repository.quickSearchAll(_vodDetail!.vodName);
      if (mounted) {
        setState(() {
          _quickSearchResults = results;
          _isQuickSearching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isQuickSearching = false);
    }
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 12),
          const Text('加载影视详情失败', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loadDetailAndAutoPlay,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
