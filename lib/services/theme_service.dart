import 'package:flutter/material.dart';
import '../global/storage_bridge.dart';

/// 全局主题与壁纸管理服务
class ThemeService {
  static final ThemeService _instance = ThemeService._internal();
  factory ThemeService() => _instance;
  ThemeService._internal();

  /// 预设按钮主题色选项 (默认纯白)
  static const List<Map<String, dynamic>> presetColors = [
    {'name': '纯白 (默认)', 'color': Color(0xFFFFFFFF)},
    {'name': '琥珀金', 'color': Color(0xFFE5A00D)},
    {'name': '翡翠绿', 'color': Color(0xFF26A69A)},
    {'name': '海洋蓝', 'color': Color(0xFF2196F3)},
    {'name': '珊瑚红', 'color': Color(0xFFE91E63)},
    {'name': '极光紫', 'color': Color(0xFF9C27B0)},
    {'name': '冰川青', 'color': Color(0xFF00BCD4)},
  ];

  /// 预设 4 套渐变壁纸（点击设置页房子图标可顺序循环切换）
  static const List<Map<String, dynamic>> presetWallpapers = [
    {
      'name': '苍翠水墨 (默认)',
      'colors': [Color(0xFF9AD4CA), Color(0xFF539E8A), Color(0xFF287462), Color(0xFF1A4B40)],
    },
    {
      'name': '暮光紫蓝',
      'colors': [Color(0xFF6B85EE), Color(0xFF5865D8), Color(0xFF5A45B5), Color(0xFF473799)],
    },
    {
      'name': '雾霭霞光',
      'colors': [Color(0xFFA7C7D8), Color(0xFF9E8D9B), Color(0xFF568EA6), Color(0xFF2A6C86)],
    },
    {
      'name': '极简暗夜',
      'colors': [Color(0xFF2E2E2E), Color(0xFF262626), Color(0xFF1E1E1E), Color(0xFF181818)],
    },
  ];

  final ValueNotifier<Color> accentColorNotifier =
      ValueNotifier<Color>(const Color(0xFFFFFFFF));

  final ValueNotifier<int> wallpaperIndexNotifier =
      ValueNotifier<int>(0);

  Color get accentColor => accentColorNotifier.value;
  int get wallpaperIndex => wallpaperIndexNotifier.value;

  LinearGradient get currentGradient {
    final idx = wallpaperIndex.clamp(0, presetWallpapers.length - 1);
    final colors = presetWallpapers[idx]['colors'] as List<Color>;
    return LinearGradient(
      colors: colors,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
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
