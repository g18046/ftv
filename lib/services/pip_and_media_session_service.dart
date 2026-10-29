import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_media_session/flutter_media_session.dart';

/// 画中画 (PiP) 与 系统通知中心媒体播控卡片管理器 (原生极简画中画 + Flutter 现代通知中心插件)
class PipAndMediaSessionService {
  static final PipAndMediaSessionService _instance =
      PipAndMediaSessionService._internal();

  factory PipAndMediaSessionService() => _instance;

  PipAndMediaSessionService._internal();

  static const MethodChannel _pipChannel = MethodChannel('com.example.ftv/pip');

  FlutterMediaSession? _mediaSession;
  bool _isSessionActive = false;

  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onPlayPause;
  VoidCallback? onNext;
  VoidCallback? onPrevious;
  void Function(int sec)? onSeekTo;

  void setCallbacks({
    VoidCallback? onPlay,
    VoidCallback? onPause,
    VoidCallback? onPlayPause,
    VoidCallback? onNext,
    VoidCallback? onPrevious,
    void Function(int sec)? onSeekTo,
  }) {
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onPlayPause = onPlayPause;
    this.onNext = onNext;
    this.onPrevious = onPrevious;
    this.onSeekTo = onSeekTo;

    _initMediaSessionListener();
  }

  void _initMediaSessionListener() {
    if (_mediaSession == null) {
      _mediaSession = FlutterMediaSession();
      try {
        FlutterMediaSessionPlatform.instance.onMediaAction.listen((action) {
          switch (action.name) {
            case 'play':
              onPlay?.call();
              break;
            case 'pause':
              onPause?.call();
              break;
            case 'skipToNext':
              onNext?.call();
              break;
            case 'skipToPrevious':
              onPrevious?.call();
              break;
            case 'stop':
              onPause?.call();
              break;
            case 'seekTo':
              if (action.seekPosition != null) {
                onSeekTo?.call(action.seekPosition!.inSeconds);
              }
              break;
            default:
              break;
          }
        });
      } catch (_) {}
    }
  }

  /// 启用系统手势上滑自动进入画中画 (针对 Android 12+ 手势退出无缝过渡)
  Future<void> enableAutoPip({
    bool enabled = true,
    int numerator = 16,
    int denominator = 9,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final w = numerator <= 0 ? 16 : numerator;
      final h = denominator <= 0 ? 9 : denominator;
      await _pipChannel.invokeMethod('enableAutoPip', {
        'enabled': enabled,
        'numerator': w,
        'denominator': h,
      });
    } catch (_) {}
  }

  /// 立即触发进入系统画中画模式
  Future<bool> enterPip({int numerator = 16, int denominator = 9}) async {
    if (!Platform.isAndroid) return false;
    try {
      final w = numerator <= 0 ? 16 : numerator;
      final h = denominator <= 0 ? 9 : denominator;
      final res = await _pipChannel.invokeMethod('enterPip', {
        'numerator': w,
        'denominator': h,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// 更新系统通知中心 MediaSession 播控卡片
  Future<void> updateMediaSession({
    required String title,
    required String episode,
    String? coverUrl,
    required bool isPlaying,
    required int positionSec,
    required int durationSec,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      _mediaSession ??= FlutterMediaSession();
      if (!_isSessionActive) {
        await _mediaSession!.activate();
        _isSessionActive = true;
        _initMediaSessionListener();

        // 注册通知中心展示的标准控制按键
        await FlutterMediaSessionPlatform.instance.updateAvailableActions({
          MediaAction.play,
          MediaAction.pause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.seekTo,
        });
      }

      await FlutterMediaSessionPlatform.instance.updateMetadata(
        MediaMetadata(
          title: title,
          artist: episode,
          album: 'FTV 影视',
          artworkUri: (coverUrl != null && coverUrl.isNotEmpty) ? coverUrl : null,
          duration: Duration(seconds: durationSec),
        ),
      );

      await FlutterMediaSessionPlatform.instance.updatePlaybackState(
        PlaybackState(
          status: isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused,
          position: Duration(seconds: positionSec),
        ),
      );
    } catch (_) {}
  }

  /// 关闭并清除系统通知中心卡片
  Future<void> closeMediaSession() async {
    if (!Platform.isAndroid) return;
    try {
      if (_mediaSession != null && _isSessionActive) {
        await _mediaSession!.deactivate();
        _isSessionActive = false;
      }
    } catch (_) {}
  }

  void clear() {
    onPlay = null;
    onPause = null;
    onPlayPause = null;
    onNext = null;
    onPrevious = null;
    onSeekTo = null;
    closeMediaSession();
    enableAutoPip(enabled: false);
  }
}
