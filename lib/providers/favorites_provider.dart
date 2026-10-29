import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/video_model.dart';
import '../services/database_service.dart';

class FavoritesNotifier extends StateNotifier<List<VideoModel>> {
  FavoritesNotifier() : super(DatabaseService().getFavorites());

  /// 已收藏则取消，否则置顶添加
  Future<void> toggle(VideoModel video) async {
    final db = DatabaseService();
    if (state.any((v) => v.id == video.id)) {
      await db.removeFavorite(video.id);
      state = state.where((v) => v.id != video.id).toList();
    } else {
      await db.addFavorite(video);
      state = [video, ...state];
    }
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, List<VideoModel>>((ref) {
  return FavoritesNotifier();
});
