import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/legacy.dart';

/// 桌面端 Window 自定义窗口顶栏组件 (包含标题、Logo、窗口拖拽区、最小化/最大化/关闭按钮)
class DesktopTitleBar extends StatefulWidget {
  final String title;
  final bool isPlaybackPage;
  final Widget? leading;
  final Color backgroundColor;

  const DesktopTitleBar({
    super.key,
    this.title = 'FTV 影视',
    this.isPlaybackPage = false,
    this.leading,
    this.backgroundColor = const Color(0xFF14161C),
  });

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> implements WindowListener {
  bool _isMaximized = false;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      _checkMaximized();
    }
  }

  @override
  void dispose() {
    if (isDesktop) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  void _checkMaximized() async {
    try {
      final max = await windowManager.isMaximized();
      if (mounted) setState(() => _isMaximized = max);
    } catch (_) {}
  }

  void _refreshWindowState() {
    _checkMaximized();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
        WidgetsBinding.instance.scheduleForcedFrame();
      }
    });
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
    _refreshWindowState();
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
    _refreshWindowState();
  }

  @override
  void onWindowBlur() {}
  @override
  void onWindowClose() {}
  @override
  void onWindowDocked() {}
  @override
  void onWindowEnterFullScreen() {}
  @override
  void onWindowFocus() {}
  @override
  void onWindowLeaveFullScreen() {}
  @override
  void onWindowMinimize() {}
  @override
  void onWindowMove() {}
  @override
  void onWindowMoved() {}
  @override
  void onWindowResize() {}
  @override
  void onWindowResized() => _refreshWindowState();
  @override
  void onWindowRestore() => _refreshWindowState();
  @override
  void onWindowUndocked() {}
  @override
  void onWindowEvent(String eventName) {}

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return const SizedBox.shrink();

    return Material(
      color: widget.backgroundColor,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          border: const Border(
            bottom: BorderSide(color: Colors.white10, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            if (widget.leading != null) widget.leading!,
            Padding(
              padding: const EdgeInsets.only(left: 12.0, right: 8.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.live_tv, size: 16, color: Color(0xFFE5A00D)),
                  const SizedBox(width: 8),
                  Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            // 中间可拖拽区域（双击可切换最大化/还原）
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: () async {
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                  _refreshWindowState();
                },
                child: DragToMoveArea(
                  child: Container(
                    color: Colors.transparent,
                  ),
                ),
              ),
            ),

            // 右侧控制按钮：最小化、最大化/还原、关闭
            _buildControlButton(
              icon: Icons.remove,
              tooltip: '最小化',
              onPressed: () => windowManager.minimize(),
            ),
            _buildControlButton(
              icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
              iconSize: 12,
              tooltip: _isMaximized ? '向下还原' : '最大化',
              onPressed: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
                _refreshWindowState();
              },
            ),
            _buildControlButton(
              icon: Icons.close,
              tooltip: '关闭',
              isClose: true,
              onPressed: () => windowManager.close(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    double iconSize = 14,
    bool isClose = false,
  }) {
    return InkWell(
      onTap: onPressed,
      hoverColor: isClose ? const Color(0xFFE81123) : Colors.white12,
      highlightColor: isClose ? const Color(0xFFF1707A) : Colors.white24,
      child: SizedBox(
        width: 44,
        height: 36,
        child: Icon(
          icon,
          size: iconSize,
          color: Colors.white70,
        ),
      ),
    );
  }
}
