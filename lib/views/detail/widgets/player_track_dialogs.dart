import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import '../../../models/vod_model.dart';

String _formatVideoTrackLabel(VideoTrack track, int? fallbackW, int? fallbackH) {
  final parts = <String>[];
  final w = track.w ?? fallbackW;
  final h = track.h ?? fallbackH;
  if (w != null && h != null && w > 0 && h > 0) {
    parts.add('$w × $h');
  }
  if (track.title != null && track.title!.trim().isNotEmpty) {
    parts.add(track.title!.trim());
  }
  if (track.codec != null && track.codec!.trim().isNotEmpty) {
    parts.add(track.codec!.trim().toUpperCase());
  }
  if (track.fps != null && track.fps! > 0) {
    parts.add('${track.fps!.toStringAsFixed(track.fps! % 1 == 0 ? 0 : 2)}fps');
  }
  return parts.isNotEmpty ? parts.join(' | ') : '视轨 ${track.id}';
}

void showVideoTrackDialog({
required BuildContext context,
required Player? player,
required int? videoWidth,
required int? videoHeight,
required void Function(IconData icon, String text) onShowHud,
}) {
  final tracks = (player?.state.tracks.video ?? [])
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentTrack = player?.state.track.video;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      final screenHeight = MediaQuery.of(ctx).size.height;
      return Container(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.72),
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
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                          (videoWidth != null && videoHeight != null && videoWidth > 0 && videoHeight > 0) ? '$videoWidth × $videoHeight' : '默认轨道',
                          style: const TextStyle(color: Color(0xFF2979FF), fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      )
                    else
                      ...tracks.map((track) {
                        final isSel = currentTrack?.id == track.id;
                        final label = _formatVideoTrackLabel(track, videoWidth, videoHeight);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            onTap: () {
                              if (isSel) {
                                print('🚫 [VIDEO] 取消/关闭视轨');
                                player?.setVideoTrack(VideoTrack.no());
                                Navigator.pop(ctx);
                                onShowHud(Icons.videocam_off, '已关闭视轨');
                              } else {
                                print('🎞️ [VIDEO] 切换视轨: id=${track.id}, label=$label');
                                player?.setVideoTrack(track);
                                Navigator.pop(ctx);
                                onShowHud(Icons.video_library, '已切换视轨: $label');
                              }
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
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: TextStyle(
                                        color: isSel ? const Color(0xFF2979FF) : Colors.black87,
                                        fontSize: 14,
                                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  if (isSel) const Icon(Icons.check_circle, size: 18, color: Color(0xFF2979FF)),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

void _showTopToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      top: MediaQuery.of(ctx).padding.top + 48,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xE61E2028),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.28),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 1800), () {
    if (entry.mounted) entry.remove();
  });
}

String _formatAudioTrackLabel(AudioTrack track) {
  final parts = <String>[];
  if (track.title != null && track.title!.trim().isNotEmpty) {
    parts.add(track.title!.trim());
  }
  if (track.language != null && track.language!.trim().isNotEmpty) {
    final lang = track.language!.trim();
    if (!parts.any((p) => p.toLowerCase().contains(lang.toLowerCase()))) {
      parts.add(lang);
    }
  }
  final meta = <String>[];
  if (track.codec != null && track.codec!.trim().isNotEmpty) {
    meta.add(track.codec!.trim().toUpperCase());
  }
  if (track.channels != null && track.channels!.trim().isNotEmpty) {
    final ch = track.channels!.trim();
    meta.add(RegExp(r'^\d+$').hasMatch(ch) ? '${ch}ch' : ch);
  }
  if (meta.isNotEmpty) parts.add(meta.join(' · '));
  return parts.isNotEmpty ? parts.join(' | ') : '音轨 ${track.id}';
}

String _formatSubtitleTrackLabel(SubtitleTrack track) {
  final parts = <String>[];
  if (track.title != null && track.title!.trim().isNotEmpty) {
    parts.add(track.title!.trim());
  }
  if (track.language != null && track.language!.trim().isNotEmpty) {
    final lang = track.language!.trim();
    if (!parts.any((p) => p.toLowerCase().contains(lang.toLowerCase()))) {
      parts.add(lang);
    }
  }
  if (track.codec != null && track.codec!.trim().isNotEmpty) {
    parts.add(track.codec!.trim().toUpperCase());
  }
  return parts.isNotEmpty ? parts.join(' | ') : '字幕轨 ${track.id}';
}

/// 音轨选择弹窗 (参考图 9)
void showAudioTrackDialog({
required BuildContext context,
required Player? player,
required void Function(IconData icon, String text) onShowHud,
}) {
  final tracks = (player?.state.tracks.audio ?? [])
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentTrack = player?.state.track.audio;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      final screenHeight = MediaQuery.of(ctx).size.height;
      return Container(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.72),
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
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                        final label = _formatAudioTrackLabel(track);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            onTap: () {
                              if (isSel) {
                                print('🔇 [AUDIO] 取消/关闭音轨');
                                player?.setAudioTrack(AudioTrack.no());
                                Navigator.pop(ctx);
                                onShowHud(Icons.volume_off, '已关闭音轨');
                              } else {
                                print('🔊 [AUDIO] 切换音轨: id=${track.id}, label=$label');
                                player?.setAudioTrack(track);
                                Navigator.pop(ctx);
                                onShowHud(Icons.audiotrack, '已切换音轨: $label');
                              }
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
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 字幕选择弹窗
void showSubtitleTrackDialog({
required BuildContext context,
required Player? player,
required bool isMounted,
required VoidCallback onOpenSubtitleSettings,
required void Function(IconData icon, String text) onShowHud,
}) {
  final tracks = (player?.state.tracks.subtitle ?? [])
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentTrack = player?.state.track.subtitle;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      final screenHeight = MediaQuery.of(ctx).size.height;
      return Container(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.72),
        decoration: const BoxDecoration(
          color: Color(0xFFF6F8FA),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '选择字幕',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    onOpenSubtitleSettings();
                  },
                  icon: const Icon(Icons.tune, size: 16, color: Color(0xFF2979FF)),
                  label: const Text('字幕样式', style: TextStyle(fontSize: 13, color: Color(0xFF2979FF))),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () {
                        print('💬 [SUBTITLE] 关闭字幕');
                        player?.setSubtitleTrack(SubtitleTrack.no());
                        Navigator.pop(ctx);
                        onShowHud(Icons.subtitles_off, '已关闭字幕');
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: currentTrack?.id == 'no' ? const Color(0xFF2979FF) : Colors.black12,
                            width: currentTrack?.id == 'no' ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.white,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '关闭字幕',
                                style: TextStyle(
                                  color: currentTrack?.id == 'no' ? const Color(0xFF2979FF) : Colors.black87,
                                  fontSize: 14,
                                  fontWeight: currentTrack?.id == 'no' ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (currentTrack?.id == 'no')
                              const Icon(Icons.check_circle, size: 18, color: Color(0xFF2979FF)),
                          ],
                        ),
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
                        final label = _formatSubtitleTrackLabel(track);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            onTap: () {
                              if (isSel) {
                                print('💬 [SUBTITLE] 取消/关闭字幕');
                                player?.setSubtitleTrack(SubtitleTrack.no());
                                Navigator.pop(ctx);
                                onShowHud(Icons.subtitles_off, '已关闭字幕');
                              } else {
                                print('💬 [SUBTITLE] 切换字幕: id=${track.id}, label=$label');
                                player?.setSubtitleTrack(track);
                                Navigator.pop(ctx);
                                onShowHud(Icons.subtitles, '已切换字幕: $label');
                              }
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
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 播放链接详情弹窗 (支持查看与复制 直链、User-Agent、Referer、Cookie 等完整参数)
void showPlayLinkDetailDialog({
required BuildContext context,
required VodItem? vodDetail,
required String currentEpisodeName,
required String currentPlayUrl,
String? proxyPlayUrl,
required Map<String, String> currentHeaders,
required int? videoWidth,
required int? videoHeight,
required void Function(IconData icon, String text) onShowHud,
}) {
  final title = '${vodDetail?.vodName ?? ""}：$currentEpisodeName';

  // 容错提取 Header 字段 (不区分大小写)
  String? findHeader(List<String> keys) {
    for (final k in keys) {
      for (final entry in currentHeaders.entries) {
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
  fullInfoBuffer.writeln('【直链】$currentPlayUrl');
  if (proxyPlayUrl != null && proxyPlayUrl.isNotEmpty) {
    fullInfoBuffer.writeln('【代理】$proxyPlayUrl');
  }
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
                  _showTopToast(context, '已复制 $label 至剪贴板');
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
                      buildInfoTile('播放直链 (URL)', currentPlayUrl, isUrl: true),
                      if (proxyPlayUrl != null && proxyPlayUrl.isNotEmpty)
                        buildInfoTile('代理播放链接 (Proxy)', proxyPlayUrl, isUrl: true),
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
                      onShowHud(Icons.check, '已复制全部播放参数至剪贴板');
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
void showCastDialog({
required BuildContext context,
required String currentPlayUrl,
String? proxyPlayUrl,
required VodItem? vodDetail,
required String currentEpisodeName,
required void Function(IconData icon, String text) onShowHud,
}) {
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
                onShowHud(Icons.cast_connected, '已将当前视频推送至客厅电视');
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.laptop, color: Colors.white70),
              title: const Text('我的电脑 (DLNA Renderer)', style: TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                onShowHud(Icons.cast_connected, '已将当前视频推送至电脑');
              },
            ),
            const Divider(color: Colors.white12),
            InkWell(
              onTap: () {
                final copyUrl = (proxyPlayUrl != null && proxyPlayUrl.isNotEmpty)
                    ? proxyPlayUrl
                    : currentPlayUrl;
                Clipboard.setData(ClipboardData(text: copyUrl));
                Navigator.pop(ctx);
                onShowHud(
                  Icons.copy,
                  (proxyPlayUrl != null && proxyPlayUrl.isNotEmpty)
                      ? '已复制本地代理播放链接供其他设备播放'
                      : '已复制播放地址供外部投屏播放器解析',
                );
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
