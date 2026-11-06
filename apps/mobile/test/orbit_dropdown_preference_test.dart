// 下拉偏好行：共享锚定原语的玻璃卡、返回键与点选回调
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('返回键先关菜单；点选立即回调并播回收', (tester) async {
    var picked = 30;
    var current = 30;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: OrbitDropdownPreference<int>(
                title: '保留时间',
                items: const [
                  SelectItem(value: 7, label: '7 天'),
                  SelectItem(value: 30, label: '30 天'),
                  SelectItem(value: 90, label: '90 天'),
                  SelectItem(value: 0, label: '永久'),
                ],
                current: current,
                onSelect: (v) {
                  picked = v;
                  setState(() => current = v);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);
    expect(find.byType(MiuixGlassPanel), findsOneWidget);
    // 承载 = 与「今天」页头 ⋮ 菜单同款的 OS4 形变（卡片从本行轮廓长出、
    // 关闭播逆形变），不再是贴行下沿揭开的 dropdown 承载
    expect(find.byType(MiuixGlassTransformPopup), findsOneWidget);
    expect(find.byType(MiuixGlassDropdownPopup), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsNothing);
    expect(find.text('保留时间'), findsOneWidget);

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 天'));
    await tester.pump();
    expect(picked, 7);
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsNothing);
    expect(find.text('7 天'), findsOneWidget);
  });

  /// 回弹期副本必须显示**新值**（2026-11-05 回归）：Overlay 是独立 widget
  /// 树，父级 setState 不重建弹层；副本若是一次性快照会停在旧值
  /// （实测：toast 已显示「30 天」，逆形变回弹画面仍写「永久」）。
  testWidgets('回弹期副本显示新档（不是打开时的旧值）', (tester) async {
    var current = 0; // 打开时是「永久」
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: OrbitDropdownPreference<int>(
                title: '保留时间',
                items: const [
                  SelectItem(value: 7, label: '7 天'),
                  SelectItem(value: 30, label: '30 天'),
                  SelectItem(value: 0, label: '永久'),
                ],
                current: current,
                onSelect: (v) => setState(() => current = v),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();

    // 选中「30 天」：行回调立刻触发，父级换档 → didUpdateWidget 刷新副本
    await tester.tap(find.text('30 天'));
    await tester.pump();

    // 逆形变进行中：弹层仍在，副本必须是新值「30 天」
    // 副本里的值文本不在任何 MiuixGlassPopupItem 内（条目行的文案才算旧快照）
    // 逆形变进行中：弹层仍在，副本必须已换成新值「30 天」
    //
    // 判据（探针实测的稳定口径）：点选后弹层里「30 天」出现 2 次 = 条目行
    // + 形变副本；旧值「永久」只剩 1 次 = 条目行。若副本停在旧值，两次计数
    // 正好相反（30天=1、永久=2）。
    expect(
      find.text('30 天').evaluate().length,
      2,
      reason: '回弹期副本应已按新档重建（条目行 + 副本各一份）',
    );
    expect(
      find.text('永久').evaluate().length,
      1,
      reason: '旧值只应留在条目行上，不得残留在回弹副本',
    );

    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsNothing);
    // 落到行上也是新值
    expect(find.text('30 天'), findsOneWidget);
    expect(find.text('永久'), findsNothing);
  });

  /// 退场截断（2026-11-06 反馈「回收到最后一步还是卡一下」）：库内 transform
  /// 逆形变按 0.0015 容差要跑到 ~690ms，但探针实测卡面 **320ms** 就已贴合本行
  /// 矩形，此后只有 1–2px 过冲回摆——那 ~370ms「画面已经收好、弹层还挂着」
  /// 就是最后一步的停顿。断言：贴合即收尾（360ms 内收走，远早于库内 ~690ms），
  /// 且本行内容与撤弹层**同帧**复位（不能空出一帧「行内容消失」）。
  testWidgets('回收在卡面贴合本行时收尾（不等库内弹簧尾巴）', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: OrbitDropdownPreference<int>(
              title: '保留时间',
              items: const [
                SelectItem(value: 7, label: '7 天'),
                SelectItem(value: 30, label: '30 天'),
              ],
              current: 30,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    double anchorOpacity() => tester
        .widget<Opacity>(
          find
              .descendant(
                of: find.byType(MiuixGlassAnchor),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(orbitDropdownPopupKey),
      findsOneWidget,
      reason: '逆形变仍在播（卡面还没落到本行上）',
    );
    expect(anchorOpacity(), 0, reason: '形变期本行内容由副本承担');

    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.byKey(orbitDropdownPopupKey),
      findsNothing,
      reason: '卡面贴合本行即收尾，不再空挂到库内 ~690ms',
    );
    expect(anchorOpacity(), 1, reason: '行内容与撤弹层同帧复位，不空帧');

    await tester.pumpAndSettle();
    expect(find.text('保留时间'), findsOneWidget);
  });

  /// 锚点收窄（2026-11-06 详情页「优先级」反馈）：形变期只有「尾随值 + 箭头」
  /// 参与，标题不许跟着一起弹出去——副本若仍带整行，标题会在弹层打开/回收
  /// 期间出现第二份（随锚点矩形缩放、模糊淡出的那一份）。
  testWidgets('形变期只有值参与，标题不进副本', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: OrbitDropdownPreference<int>(
              title: '保留时间',
              items: const [
                SelectItem(value: 7, label: '7 天'),
                SelectItem(value: 30, label: '30 天'),
              ],
              current: 30,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保留时间'));
    await tester.pump();
    // 形变进行中（副本尚未完全淡出）
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('保留时间').evaluate().length,
      1,
      reason: '标题只应留在行上，不得进入形变副本',
    );

    // 锚点矩形只覆盖行尾值块：宽度远小于整行（标题区不被采样）
    final popup = tester.widget<MiuixGlassTransformPopup>(
      find.byType(MiuixGlassTransformPopup),
    );
    final anchorBounds = popup.anchor?.bounds;
    final rowWidth = tester
        .getSize(find.byType(OrbitDropdownPreference<int>))
        .width;
    expect(anchorBounds, isNotNull);
    expect(
      anchorBounds!.width,
      lessThan(rowWidth * 0.5),
      reason: '形变起点应是值块，不是整行轮廓',
    );

    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);
    expect(find.text('保留时间').evaluate().length, 1);
  });

  testWidgets('OrbitGlassPage 下弹层拿到背景采样器', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: OrbitGlassPage(
          child: Scaffold(
            body: Center(
              child: OrbitDropdownPreference<int>(
                title: '类型',
                items: const [
                  SelectItem(value: 0, label: '全部'),
                  SelectItem(value: 1, label: '到期'),
                ],
                current: 0,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('类型'));
    await tester.pumpAndSettle();
    // 形变承载：材质继承锚点表面（MiuixGlassAnchor 发布的 surface），
    // 不走「无快照退实色」分支——云同步页曾因此看着像实色白卡
    final popup = tester.widget<MiuixGlassTransformPopup>(
      find.byType(MiuixGlassTransformPopup),
    );
    expect(popup.anchor, isNotNull, reason: '根级页的形变锚点由本行提供（行内容在形变期隐藏）');
    expect(popup.anchorContent, isNotNull, reason: '形变期由副本承接行内容');
  });

  /// 观感契约（2026-11-05）：弹层承载与「今天」页头 ⋮ 菜单同款——
  /// 关闭时播逆形变收回本行轮廓，退场完成才移除条目；不是 dropdown 承载的
  /// 「淡出 + 整卡高斯模糊」闪没。云同步「引擎」弹层曾因此与页头菜单观感不一致。
  testWidgets('关闭播逆形变：收起期卡片仍挂载，完成后才移除', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: OrbitDropdownPreference<int>(
              title: '保留时间',
              items: const [
                SelectItem(value: 7, label: '7 天'),
                SelectItem(value: 30, label: '30 天'),
              ],
              current: 30,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);

    // 点外部请求关闭：退场动画期间条目仍挂载（逆形变在播）
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.byType(MiuixGlassTransformPopup),
      findsOneWidget,
      reason: '逆形变期间承载仍在（不是立即移除）',
    );

    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsNothing);
  });
}
