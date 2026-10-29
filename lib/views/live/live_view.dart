import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../models/live_model.dart';
import '../../repositories/site_repository.dart';
import '../../services/live_service.dart';
import '../widgets/tv_focusable.dart';

/// OK影视风格 电视直播核心视图
/// 具备：
/// 1. 点进即全屏横屏 (支持遥控器键控与手势换台)
/// 2. 退出时无缝恢复手机竖屏与系统状态栏
/// 3. 左上角返回键 + 左右频道抽屉面板 + OSD 换台指示器
/// 4. 自动净化流媒体 URL ($4K 等标识剥离)
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

  int _selectedGroupIndex = 0;
  int _selectedChannelIndex = 0;
  int _selectedLineIndex = 0;

  bool _showChannelList = false;
  bool _showOsd = false;
  Timer? _osdTimer;
  Timer? _channelListHideTimer;

  // TV 焦点控制
  final FocusNode _pageFocusNode = FocusNode();

  LiveChannel? get _currentChannel {
    if (_groups.isEmpty || _selectedGroupIndex >= _groups.length) return null;
    final group = _groups[_selectedGroupIndex];
    if (group.channels.isEmpty || _selectedChannelIndex >= group.channels.length) return null;
    return group.channels[_selectedChannelIndex];
  }

  @override
  void initState() {
    super.initState();
    // 强制进入沉浸式全屏横屏模式
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _initPlayer();
    _loadLiveChannels();
  }

  @override
  void dispose() {
    // 退出直播恢复竖屏与状态栏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _osdTimer?.cancel();
    _channelListHideTimer?.cancel();
    _pageFocusNode.dispose();
    _player?.dispose();
    super.dispose();
  }

  void _initPlayer() {
    _player = Player();
    _videoController = VideoController(_player!);
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

    final rawUrl = channel.urls[_selectedLineIndex % channel.urls.length];
    final cleanUrl = LiveService.sanitizeStreamUrl(rawUrl);
    print('📺 正在播放直播: [${channel.name}] 线路 ${_selectedLineIndex + 1} -> $cleanUrl');

    try {
      _player?.open(Media(cleanUrl));
      _showOsdBriefly();
    } catch (e) {
      print('播放直播流发生错误: $e');
    }
  }

  void _showOsdBriefly() {
    _osdTimer?.cancel();
    setState(() => _showOsd = true);
    _osdTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showOsd = false);
    });
  }

  void _switchChannel(int delta) {
    if (_groups.isEmpty) return;
    final currentGroup = _groups[_selectedGroupIndex];
    if (currentGroup.channels.isEmpty) return;

    int nextIndex = _selectedChannelIndex + delta;
    if (nextIndex < 0) {
      // 切换到上一组
      int prevGroup = _selectedGroupIndex - 1;
      if (prevGroup < 0) prevGroup = _groups.length - 1;
      setState(() {
        _selectedGroupIndex = prevGroup;
        _selectedChannelIndex = _groups[prevGroup].channels.length - 1;
        _selectedLineIndex = 0;
      });
    } else if (nextIndex >= currentGroup.channels.length) {
      // 切换到下一组
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

    // 播放全屏模式下的键控
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _switchChannel(-1); // 上一个台
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _switchChannel(1); // 下一个台
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _switchLine(-1); // 上一条线路
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _switchLine(1); // 下一条线路
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
          body: GestureDetector(
            onTap: () {
              setState(() => _showChannelList = !_showChannelList);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 视频画面
                if (_videoController != null)
                  Video(
                    controller: _videoController!,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),

                // 2. 左上角返回与退出直播按钮
                Positioned(
                  top: 16,
                  left: 16,
                  child: SafeArea(
                    child: TvFocusable(
                      onPressed: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text('退出直播', style: TextStyle(color: Colors.white, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // 3. 换台 OSD 提示条
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
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFE5A00D).withOpacity(0.3),
                            blurRadius: 12,
                          ),
                        ],
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
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _currentChannel!.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
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

                // 4. 频道抽屉面板 (点击或 OK 键弹出)
                if (_showChannelList)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 380,
                    child: GestureDetector(
                      onTap: () {}, // 阻止向外层冒泡触发关闭
                      child: Container(
                        color: const Color(0xEE12141C),
                        child: Row(
                          children: [
                            // 分组列表
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

                            // 频道与线路列表
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
            ),
          ),
        ),
      ),
    );
  }
}
