import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/history_item.dart';
import '../services/database_service.dart';

class HistoryNotifier extends StateNotifier<List<HistoryItem>> {
  HistoryNotifier() : super(DatabaseService().getHistory());

  /// 按 videoId upsert（同一视频只保留最新一条，置顶）
  Future<void> record(HistoryItem item) async {
    final db = DatabaseService();
    await db.saveHistory(item);
    // 播放器 dispose 时可能触发最后一次落盘；ProviderScope 已销毁时
    // 只写入存储，不再更新已 dispose 的 StateNotifier。
    if (!mounted) return;
    state = db.getHistory();
  }

  Future<void> remove(String videoId) async {
    await DatabaseService().removeHistory(videoId);
    state = state.where((h) => h.videoId != videoId).toList();
  }

  Future<void> clear() async {
    await DatabaseService().clearHistory();
    state = [];
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryItem>>((ref) {
      return HistoryNotifier();
    });
