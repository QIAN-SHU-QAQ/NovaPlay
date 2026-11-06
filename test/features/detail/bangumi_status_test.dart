import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/features/detail/detail_screen.dart';
import 'package:nova_play/models/bangumi_info.dart';
import 'package:nova_play/models/video_model.dart';
import 'package:nova_play/providers/bangumi_provider.dart';
import 'package:nova_play/providers/video_provider.dart';
import 'package:nova_play/services/bangumi_api.dart';
import 'package:nova_play/services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EmptySearchApi extends BangumiApi {
  _EmptySearchApi();

  @override
  Future<List<BangumiSubjectCandidate>> searchSubjects(String title) async {
    return const [];
  }
}

void main() {
  Future<void> pumpDetail(
    WidgetTester tester, {
    required Size size,
    required BangumiLookupResult Function() result,
    BangumiApi? api,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = VideoModel(
      id: 'detail',
      title: 'QA 样本',
      description: '简介',
      episodes: [
        EpisodeModel(id: 'ep-1', title: '第01集', url: 'https://site/ep1'),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoDetailProvider('detail').overrideWith((ref) async => video),
          bangumiInfoProvider(
            BangumiQuery(videoId: video.id, title: video.title),
          ).overrideWith((ref) async => result()),
          if (api != null) bangumiApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: DetailScreen(id: 'detail')),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [420.0, 1440.0]) {
    testWidgets('P1：Bangumi 不可用时显示可重试与手动匹配，选集仍可用 @$width', (tester) async {
      await pumpDetail(
        tester,
        size: Size(width, 1000),
        result: () => const BangumiLookupResult.unavailable(),
      );
      expect(find.text('Bangumi 资料暂不可用'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('手动匹配'), findsOneWidget);
      expect(find.text('第01集'), findsOneWidget);
    });

    testWidgets('P1：无可靠匹配时提示可手选，选集仍可用 @$width', (tester) async {
      await pumpDetail(
        tester,
        size: Size(width, 1000),
        result: () => const BangumiLookupResult.noMatch(),
      );
      expect(find.text('暂无可靠的 Bangumi 匹配'), findsOneWidget);
      expect(find.text('手动匹配'), findsOneWidget);
      expect(find.text('第01集'), findsOneWidget);
    });

    testWidgets('P1：角色接口失败时保留部分资料并显示降级提示 @$width', (tester) async {
      const info = BangumiInfo(
        score: 8.6,
        staff: [BangumiStaffEntry(role: '导演', name: 'QA Director')],
      );
      await pumpDetail(
        tester,
        size: Size(width, 1000),
        result: () => const BangumiLookupResult.success(info, partial: true),
      );
      expect(find.text('部分 Bangumi 资料不可用'), findsOneWidget);
      expect(find.text('手动匹配'), findsOneWidget);
      if (width >= 1200) {
        expect(find.text('QA Director'), findsOneWidget);
      }
      expect(find.text('第01集'), findsOneWidget);
    });
  }

  testWidgets('P1：已有关联时手动匹配可恢复自动匹配', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseService()..resetForTest();
    await db.init();
    addTearDown(db.resetForTest);
    await db.setBangumiMapping('detail', {'subjectId': 888, 'name': 'QA'});

    await pumpDetail(
      tester,
      size: const Size(1440, 1000),
      result: () => const BangumiLookupResult.noMatch(),
      api: _EmptySearchApi(),
    );
    await tester.tap(find.text('手动匹配'));
    await tester.pumpAndSettle();
    expect(find.text('恢复自动匹配'), findsOneWidget);
    await tester.tap(find.text('恢复自动匹配'));
    await tester.pumpAndSettle();
    expect(db.getBangumiMapping('detail'), isNull);
  });
}
