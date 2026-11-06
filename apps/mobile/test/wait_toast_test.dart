// WaitToast 停留口径回归（2026-09-20 修复）：撤销类浮层曾因「带 action 就不
// 自动收起」而常驻不消失（用户报「提示怎么一直在」）。现口径：
// - 纯提示 → defaultDwell 自动收；
// - 带 onTap 的提醒条 → 不收（等用户点）；
// - 撤销类 → 调用点显式传 undoDwell/窗口时长，到期自动收。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_bottom_nav.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_toast.dart';
import 'support/orbit_test_app.dart';

Widget _harness() => orbitTestApp(
      home: const Scaffold(body: SizedBox.expand()),
    );

void main() {
  // 定位口径（2026-11-06）：轻提示统一贴顶部（状态栏下沿 +8），不再压住
  // 悬浮底栏 / FAB / 批量工具条；卡面高度实测后再落位（内容行数可变）。
  testWidgets('定位：提示卡贴顶部安全区下方，不进底栏 / FAB 带', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.info('已保存');
    // 首帧：卡高未测到（整层推出屏外）；帧末回写后第二帧落位
    await tester.pump();
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(OrbitToastHost));
    final media = MediaQuery.of(ctx);
    final rect = tester.getRect(
      find.byKey(const ValueKey<String>('orbit_toast_card')),
    );

    expect(rect.top, closeTo(media.padding.top + AppDimens.space8, 0.5));
    // 与底部 chrome（悬浮底栏 + FAB）完全不重叠
    expect(
      rect.bottom,
      lessThan(media.size.height -
          OrbitBottomNav.clearanceOf(ctx) -
          AppDimens.fabSize),
    );
  });

  // 卡面（2026-11-06 真机反馈「撤销」跑到卡片中间）：正文列必须 Expanded
  // 撑满剩余宽度，动作按钮恒贴右缘——Flexible 的 loose 自适应会按文案宽度
  // 收缩，短文案时按钮就停在中间。
  testWidgets('卡面：动作按钮贴卡片最右', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.global(
      '已删除',
      variant: WaitToastVariant.warning,
      actionLabel: '撤销',
      onAction: () {},
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final card = tester.getRect(
      find.byKey(const ValueKey<String>('orbit_toast_card')),
    );
    final button = tester.getRect(find.byType(OrbitButton));
    // 卡片 render box 含外留白：16（页面基线）+ 16（卡内边距）= 按钮右缘
    // 距卡片外缘 32，中间不允许出现自适应空白
    expect(card.right - button.right, closeTo(AppDimens.pageInline * 2, 1));

    await drainToastTimers(tester, holdForever: true);
  });

  testWidgets('撤销浮层：undoDwell 到期自动收起', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.global(
      '已调整 1 个任务的优先级',
      actionLabel: '撤销',
      onAction: () {},
      autoDismissAfter: WaitToast.undoDwell,
    );
    await tester.pump();
    expect(find.text('已调整 1 个任务的优先级'), findsOneWidget);

    await tester.pump(WaitToast.undoDwell);
    await tester.pumpAndSettle();
    expect(find.text('已调整 1 个任务的优先级'), findsNothing);
  });

  testWidgets('纯提示：defaultDwell 到期自动收起', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.info('已保存');
    await tester.pump();
    expect(find.text('已保存'), findsOneWidget);

    await tester.pump(WaitToast.defaultDwell);
    await tester.pumpAndSettle();
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('带 onTap 的提醒条：不设时长则保持常驻等用户点', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.warning('待办提醒：写周报', onTap: () {});
    await tester.pump();
    expect(find.text('待办提醒：写周报'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    expect(find.text('待办提醒：写周报'), findsOneWidget);
    await drainToastTimers(tester, holdForever: true);
  });

  testWidgets('带动作但未给时长：保持常驻（错误引导类需用户处置）', (tester) async {
    await tester.pumpWidget(_harness());
    WaitToast.global(
      '同步密钥与云端数据不匹配',
      actionLabel: '去恢复',
      onAction: () {},
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 10));
    expect(find.text('同步密钥与云端数据不匹配'), findsOneWidget);
    await drainToastTimers(tester, holdForever: true);
  });
}
