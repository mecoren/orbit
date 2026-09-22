// 下拉刷新共用回调（pullToRefresh）口径：
// - 未配置云同步：只做本地业务缓存重读，全程不抛错、不碰同步桥；
// - 已配置：跑一轮 cloudSyncNow 后再次失效（拉取合并写入不走 db-change）。
//
// FakeAsync 约束（同 backup_page_test 头注释）：mock 的 _delay 是真 Timer，
// 必须靠 tester.pump 推进假时钟，否则 await 永远不落定。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/providers/todo_providers.dart';

import 'support/orbit_test_app.dart';

/// 计数代理：确认 pullToRefresh 是否真的跑了一轮同步
class _CountingBridge extends MockOrbitBridge {
  int syncCalls = 0;

  @override
  Future<SyncResultJson> cloudSyncNow({String origin = 'manual'}) {
    syncCalls++;
    return super.cloudSyncNow(origin: origin);
  }
}

Future<WidgetRef> _pumpRef(
  WidgetTester tester,
  MockOrbitBridge bridge,
) async {
  late WidgetRef ref;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(
        home: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return ref;
}

/// 推进假时钟直到 future 落定，并把值/异常透传回断言侧
Future<T> _settle<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  Object? error;
  future.then(
    (v) {
      done = true;
      value = v;
    },
    onError: (Object e) {
      done = true;
      error = e;
    },
  );
  var ticks = 0;
  while (!done) {
    if (++ticks > 100) throw StateError('future 在 100 个时钟步内未落定');
    await tester.pump(const Duration(milliseconds: 300));
  }
  if (error != null) throw error!;
  return value;
}

void main() {
  testWidgets('未配置云同步：只做本地重读，不跑同步、不抛错', (tester) async {
    final bridge = _CountingBridge();
    final ref = await _pumpRef(tester, bridge);

    await _settle(tester, pullToRefresh(ref));

    expect(bridge.syncCalls, 0, reason: '未配置时不得触发云同步');
    expect(await _settle(tester, ref.read(syncConfigProvider.future)), isNull);
  });

  testWidgets('已配置云同步：跑一轮 cloudSyncNow 后再次失效', (tester) async {
    final bridge = _CountingBridge();
    bridge.store.syncConfigured = true;
    final ref = await _pumpRef(tester, bridge);

    await _settle(tester, pullToRefresh(ref));

    expect(bridge.syncCalls, 1, reason: '已配置时下拉必须带一轮手动同步');
    expect(
      await _settle(tester, ref.read(syncConfigProvider.future)),
      isNotNull,
    );
  });
}
