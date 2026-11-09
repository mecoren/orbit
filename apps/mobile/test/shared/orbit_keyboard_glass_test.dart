// 键盘抬升动画期的玻璃链路性能契约（2026-11-09）
//
// 真机点「新增待办」时输入法弹出会掉帧：键盘动画逐帧改 `viewInsets`，此前
// 捕获树每帧重录整页背景快照（`toImageSync`），每次 `updateSnapshot` 又通知
// 所有玻璃消费方重建；同时形变闸门自己订阅了 `viewInsets`，卡面（玻璃表面
// + `MiuixGlassPanel` + 工具栏）逐帧重建。模拟器 x64 无软键盘动画，帧耗时
// 门禁量不到这条路径，故用逐帧 `viewInsets` 把行为钉在这里。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/quick_add_sheet.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';

import '../support/orbit_test_app.dart';

/// 模拟一次 Android 输入法动画：10 帧、每帧抬升/回落 30dp
Future<void> _pumpKeyboard(WidgetTester tester, {required bool up}) async {
  for (var i = 1; i <= 10; i++) {
    final bottom = (up ? i : 10 - i) * 30.0;
    tester.view.viewInsets = FakeViewPadding(bottom: bottom);
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 宿主：壳层同款「玻璃作用域 + 捕获树 + 玻璃弹层」，弹层内容用计数器探针
///
/// route builder 与生产一致返回稳定实例，避免宿主自身每帧 new 一棵面板。
Future<void> _openSheet(
  WidgetTester tester,
  MiuixLayerBackdrop backdrop,
  List<int> contentBuilds,
) async {
  final sheet = OrbitGlassSheet(
    backdrop: backdrop,
    child: _Probe(contentBuilds),
  );
  await tester.pumpWidget(
    orbitTestApp(
      home: OrbitGlassScope(
        backdrop: backdrop,
        child: OrbitScrollAwareBackdropCapture(
          backdrop: backdrop,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    backgroundColor: Colors.transparent,
                    builder: (_) => sheet,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  addTearDown(tester.view.resetViewInsets);
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pump();
  // 入场 220ms + 320ms 形变窗落定（键盘动画从真玻璃档起测）
  await tester.pump(const Duration(milliseconds: 400));
}

class _Probe extends StatelessWidget {
  const _Probe(this.counter);

  final List<int> counter;

  @override
  Widget build(BuildContext context) {
    counter[0]++;
    return const SizedBox(height: 80);
  }
}

void main() {
  testWidgets('键盘抬升/回落动画期背景快照冻结，落定后各补录一次', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    addTearDown(backdrop.dispose);
    var snapshots = 0;
    backdrop.addListener(() => snapshots++);

    await _openSheet(tester, backdrop, <int>[0]);
    expect(snapshots, greaterThan(0), reason: '首帧应已录到背景快照');

    var before = snapshots;
    await _pumpKeyboard(tester, up: true);
    expect(
      snapshots - before,
      0,
      reason: '键盘动画期逐帧 toImageSync 整页是掉帧主因，必须冻结',
    );
    // 静默 120ms 后恢复录制并补录一次（恢复触发的重绘在下一帧）
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 16));
    expect(snapshots - before, 1, reason: '键盘落定后只补录一次');

    before = snapshots;
    await _pumpKeyboard(tester, up: false);
    expect(snapshots - before, 0, reason: '键盘回落同样在动画期冻结');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 16));
    expect(snapshots - before, 1, reason: '回落后补录一次');
  });

  testWidgets('真实快速添加面板：键盘动画期卡面不重建、输入法不丢', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    final bridge = MockOrbitBridge()..latency = Duration.zero;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(
          home: const OrbitGlassPage(
            child: SubListScreen(
              query: TaskFilterInput(quickView: QuickViewKey.all),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    showQuickAddSheet(tester.element(find.byType(SubListScreen)));
    await tester.pump();
    // 入场 220ms + 320ms 形变窗落定
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.testTextInput.isVisible, isTrue, reason: '自动聚焦已起输入法');

    final panel = find.descendant(
      of: find.byType(OrbitGlassSheet),
      matching: find.byType(MiuixGlassPanel),
    );
    expect(panel, findsOneWidget, reason: '有快照时弹层走 OS4 玻璃档');
    Object? lastPanel = tester.widget(panel);
    var rebuilds = 0;
    for (var i = 1; i <= 10; i++) {
      tester.view.viewInsets = FakeViewPadding(bottom: i * 30);
      await tester.pump(const Duration(milliseconds: 16));
      final current = tester.widget(panel);
      // 头两帧允许「切入键盘形变窗」这一档材质切换
      if (i > 2 && !identical(current, lastPanel)) rebuilds++;
      lastPanel = current;
      expect(
        tester.testTextInput.isVisible,
        isTrue,
        reason: '键盘抬升期间输入框焦点一帧都不能丢',
      );
    }

    expect(
      rebuilds,
      0,
      reason: '键盘每帧只该改一层底部 padding，玻璃面板与工具栏不得逐帧重建',
    );
    // 缓存卡面不能把键盘避让一起冻住：叶子 padding 必须跟上最终键盘高度，
    // 卡面底部要落在键盘上沿之上。
    // `FakeViewPadding` 的 bottom 是物理像素，MediaQuery 侧要按 DPR 换算。
    final dpr = tester.view.devicePixelRatio;
    final keyboard = tester.view.viewInsets.bottom / dpr;
    final lifted = find.descendant(
      of: find.byType(OrbitGlassSheet),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.padding.resolve(TextDirection.ltr).bottom == keyboard,
      ),
    );
    expect(lifted, findsOneWidget, reason: '键盘抬升由叶子 padding 承接');
    final viewportHeight = tester.view.physicalSize.height / dpr;
    expect(
      tester.getRect(panel).bottom,
      lessThanOrEqualTo(viewportHeight - keyboard),
      reason: '卡面必须浮在键盘上沿之上',
    );
    await tester.enterText(find.byType(TextField).first, '写周报');
    await tester.pump();
    expect(find.text('写周报'), findsOneWidget);
  });
}
