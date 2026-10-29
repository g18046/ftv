import 'package:flutter/material.dart';
import '../global/storage_bridge.dart';

/// 全局主题与壁纸管理服务
class ThemeService {
  static final ThemeService _instance = ThemeService._internal();
  factory ThemeService() => _instance;
  ThemeService._internal();

  /// 预设按钮主题色选项 (默认 OK 影视琥珀金)
  static const List<Map<String, dynamic>> presetColors = [
    {'name': '琥珀金 (默认)', 'color': Color(0xFFE5A00D)},
    {'name': '翡翠绿', 'color': Color(0xFF26A69A)},
    {'name': '海洋蓝', 'color': Color(0xFF2196F3)},
    {'name': '珊瑚红', 'color': Color(0xFFE91E63)},
    {'name': '极光紫', 'color': Color(0xFF9C27B0)},
    {'name': '冰川青', 'color': Color(0xFF00BCD4)},
  ];

  /// 预设渐变壁纸套系 (默认 OK 影视水墨青绿渐变)
  static const List<Map<String, dynamic>> presetWallpapers = [
    {
      'name': '苍翠水墨 (OK影视默认)',
      'colors': [Color(0xFF74ADA2), Color(0xFF3F7D72), Color(0xFF205047), Color(0xFF13362F)],
    },
    {
      'name': '极夜深灰',
      'colors': [Color(0xFF2C3038), Color(0xFF1E2127), Color(0xFF14161B), Color(0xFF0D0E11)],
    },
    {
      'name': '暮色紫澜',
      'colors': [Color(0xFF4A3B69), Color(0xFF31254A), Color(0xFF201733), Color(0xFF120C1F)],
    },
    {
      'name': '幽谷黛蓝',
      'colors': [Color(0xFF2A4D69), Color(0xFF1B354B), Color(0xFF112333), Color(0xFF09141E)],
    },
    {
      'name': '暖玉琥珀',
      'colors': [Color(0xFF5D4A3E), Color(0xFF3E3129), Color(0xFF29201B), Color(0xFF181310)],
    },
  ];

  final ValueNotifier<Color> accentColorNotifier =
      ValueNotifier<Color>(const Color(0xFFE5A00D));

  final ValueNotifier<int> wallpaperIndexNotifier =
      ValueNotifier<int>(0);

  Color get accentColor => accentColorNotifier.value;
  int get wallpaperIndex => wallpaperIndexNotifier.value;

  LinearGradient get currentGradient {
    final idx = wallpaperIndex.clamp(0, presetWallpapers.length - 1);
    final colors = presetWallpapers[idx]['colors'] as List<Color>;
    return LinearGradient(
      colors: colors,
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );
  }

  Future<void> init() async {
    try {
      final savedColorHex = await StorageBridge.getValue('app_accent_color');
      if (savedColorHex != null && savedColorHex.isNotEmpty) {
        final val = int.tryParse(savedColorHex, radix: 16);
        if (val != null) {
          accentColorNotifier.value = Color(val);
        }
      }

      final savedWpIdx = await StorageBridge.getValue('app_wallpaper_index');
      if (savedWpIdx != null && savedWpIdx.isNotEmpty) {
        final idx = int.tryParse(savedWpIdx);
        if (idx != null) {
          wallpaperIndexNotifier.value = idx.clamp(0, presetWallpapers.length - 1);
        }
      }
    } catch (_) {}
  }

  Future<void> setAccentColor(Color color) async {
    accentColorNotifier.value = color;
    try {
      await StorageBridge.setValue(
        'app_accent_color',
        color.toARGB32().toRadixString(16),
      );
    } catch (_) {}
  }

  Future<void> nextWallpaper() async {
    final nextIdx = (wallpaperIndexNotifier.value + 1) % presetWallpapers.length;
    await setWallpaperIndex(nextIdx);
  }

  Future<void> setWallpaperIndex(int index) async {
    final safeIdx = index.clamp(0, presetWallpapers.length - 1);
    wallpaperIndexNotifier.value = safeIdx;
    try {
      await StorageBridge.setValue('app_wallpaper_index', safeIdx.toString());
    } catch (_) {}
  }
}
