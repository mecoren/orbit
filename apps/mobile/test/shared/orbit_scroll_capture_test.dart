// 滚动感知背景捕获（OrbitScrollAwareBackdropCapture）的行为锁定
//
// 核心口径：滚动活跃期快照冻结（不录新帧），滚动 settle 后恢复录制并补录
// 一次。判据用快照对象同一性（ui.Image 每次录制都是新实例）：
// - 首帧录到快照；
// - 惯性滚动中途（暂停窗内）快照与滚动前是同一张；
// - settle 后（静默 120ms + 补录帧）快照换成新实例。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('滚动期冻结快照，settle 后恢复录制', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    await tester.pumpWidget(
      _host(
        OrbitScrollAwareBackdropCapture(
          backdrop: backdrop,
          child: ListView(
            children: [
              for (var i = 0; i < 60; i++)
                ListTile(title: Text('行 $i'), key: ValueKey(i)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final first = backdrop.snapshot;
    expect(first, isNotNull, reason: '首帧应录到快照');

    // 惯性滚动中途：暂停窗内不再录新帧（快照冻结在滚动前那一帧）
    await tester.fling(find.byType(ListView), const Offset(0, -400), 2000);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      identical(backdrop.snapshot, first),
      isTrue,
      reason: '滚动活跃期快照应冻结',
    );

    // settle：惯性滚动停 + 120ms 静默 → 恢复并补录（新实例替换旧快照）
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      identical(backdrop.snapshot, first),
      isFalse,
      reason: 'settle 后应补录新快照',
    );
    backdrop.dispose();
  });

  testWidgets('静止内容不触发暂停，快照持续可用', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    await tester.pumpWidget(
      _host(
        OrbitScrollAwareBackdropCapture(
          backdrop: backdrop,
          child: const Center(child: Text('静止内容')),
        ),
      ),
    );
    await tester.pump();
    expect(backdrop.snapshot, isNotNull);
    backdrop.dispose();
  });
}
