import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_play/app.dart';
import 'package:nova_play/core/network/http_client.dart';
import 'package:nova_play/providers/scraper_provider.dart';
import 'package:nova_play/services/scraper/lziapi_scraper.dart';

class _RecoveringAdapter implements HttpClientAdapter {
  bool online = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!online) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'code': 1,
        'list': [
          {'vod_id': 123, 'vod_name': '恢复成功', 'vod_play_url': ''},
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('数据源全部失败显示错误，网络恢复后可重试', (tester) async {
    final dio = HttpClient().dio;
    final originalAdapter = dio.httpClientAdapter;
    final adapter = _RecoveringAdapter();
    dio.httpClientAdapter = adapter;
    addTearDown(() => dio.httpClientAdapter = originalAdapter);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentScraperProvider.overrideWithValue(LziApiScraper())],
        child: const NovaPlayApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

    adapter.online = true;
    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsNothing);
    expect(find.text('恢复成功'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
