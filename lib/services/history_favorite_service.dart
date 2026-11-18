import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/vod_model.dart';
import '../global/storage_bridge.dart';

/// 影视收藏与播放历史管理器
class HistoryFavoriteService {
  static final HistoryFavoriteService _instance =
      HistoryFavoriteService._internal();
  factory HistoryFavoriteService() => _instance;
  HistoryFavoriteService._internal();

  final ValueNotifier<List<Map<String, dynamic>>> favoritesNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  final ValueNotifier<List<Map<String, dynamic>>> historyNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  bool _isLoaded = false;

  Future<void> init() async {
    if (_isLoaded) return;
    await loadFavorites();
    await loadHistory();
    _isLoaded = true;
  }

  // ─────────────────────────────────────────────────────────────
  // 收藏管理器 (Favorites)
  // ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> loadFavorites() async {
    try {
      final jsonStr = await StorageBridge.getValue('app_vod_favorites');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final list = jsonDecode(jsonStr);
        if (list is List) {
          final items = list.map((e) => Map<String, dynamic>.from(e)).toList();
          favoritesNotifier.value = items;
          return items;
        }
      }
    } catch (_) {}
    favoritesNotifier.value = [];
    return [];
  }

  bool isFavorite(String vodId) {
    return favoritesNotifier.value.any((e) => e['vodId']?.toString() == vodId);
  }

  Future<bool> toggleFavorite(VodItem vod) async {
    await init();
    final currentList = List<Map<String, dynamic>>.from(favoritesNotifier.value);
    final idx = currentList.indexWhere((e) => e['vodId']?.toString() == vod.vodId);

    bool isNowFav = false;
    if (idx >= 0) {
      currentList.removeAt(idx);
      isNowFav = false;
    } else {
      currentList.insert(0, {
        'vodId': vod.vodId,
        'vodName': vod.vodName,
        'vodPic': vod.vodPic,
        'vodRemarks': vod.vodRemarks,
        'siteKey': vod.siteKey ?? '',
        'siteName': vod.siteName ?? '',
        'time': DateTime.now().millisecondsSinceEpoch,
      });
      isNowFav = true;
    }

    favoritesNotifier.value = currentList;
    try {
      await StorageBridge.setValue('app_vod_favorites', jsonEncode(currentList));
    } catch (_) {}
    return isNowFav;
  }

  // ─────────────────────────────────────────────────────────────
  // 播放历史管理器 (Playback History)
  // ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> loadHistory() async {
    try {
      final jsonStr = await StorageBridge.getValue('app_vod_history');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final list = jsonDecode(jsonStr);
        if (list is List) {
          final items = list.map((e) => Map<String, dynamic>.from(e)).toList();
          historyNotifier.value = items;
          return items;
        }
      }
    } catch (_) {}
    historyNotifier.value = [];
    return [];
  }

  Future<void> recordHistory({
    required VodItem vod,
    required String episodeName,
    required int positionSec,
    required int durationSec,
    String? sourceName,
    String? siteKey,
    String? siteName,
  }) async {
    if (vod.vodId.isEmpty) return;
    await init();

    final currentList = List<Map<String, dynamic>>.from(historyNotifier.value);
    final resolvedSiteKey = (siteKey != null && siteKey.isNotEmpty)
        ? siteKey
        : (vod.siteKey ?? '');
    final resolvedSiteName = (siteName != null && siteName.isNotEmpty)
        ? siteName
        : (vod.siteName ?? '');

    currentList.removeWhere((e) =>
        e['vodId']?.toString() == vod.vodId &&
        (resolvedSiteKey.isEmpty ||
            (e['siteKey']?.toString() ?? '').isEmpty ||
            e['siteKey']?.toString() == resolvedSiteKey));

    currentList.insert(0, {
      'vodId': vod.vodId,
      'vodName': vod.vodName,
      'vodPic': vod.vodPic,
      'vodRemarks': vod.vodRemarks,
      'siteKey': resolvedSiteKey,
      'siteName': resolvedSiteName,
      'sourceName': sourceName ?? '',
      'episodeName': episodeName,
      'positionSec': positionSec,
      'durationSec': durationSec,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });

    if (currentList.length > 50) {
      currentList.removeRange(50, currentList.length);
    }

    historyNotifier.value = currentList;
    try {
      await StorageBridge.setValue('app_vod_history', jsonEncode(currentList));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> getLastPlayback(String vodId, {String? siteKey}) async {
    await init();
    if (siteKey != null && siteKey.isNotEmpty) {
      for (final e in historyNotifier.value) {
        if (e['vodId']?.toString() == vodId &&
            e['siteKey']?.toString() == siteKey) {
          return e;
        }
      }
    }
    try {
      return historyNotifier.value.firstWhere(
        (e) => e['vodId']?.toString() == vodId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clearHistory() async {
    historyNotifier.value = [];
    try {
      await StorageBridge.setValue('app_vod_history', '[]');
    } catch (_) {}
  }

  Future<void> clearFavorites() async {
    favoritesNotifier.value = [];
    try {
      await StorageBridge.setValue('app_vod_favorites', '[]');
    } catch (_) {}
  }
}
