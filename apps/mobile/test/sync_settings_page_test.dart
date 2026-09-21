// 云同步配置页行为测试：连接表单回读/引擎切换/保存/测试连接/断开确认 +
// 同步密码卡（设置/解锁/锁定/校验）。
//
// 三条测试纪律：
// 1. FakeAsync：直接 await bridge.xxx()（内部 120ms 延迟）前必须先发起、
//    由 tester.pump(300ms) 推进虚拟时钟再 await，否则永久挂起；
// 2. 页面字段多于一屏（视口 600）：交互/断言前用 _scrollTo（复用
//    form_bottom_sheet_test 的 scrollUntilVisible + 底边余量补滚模式）；
// 3. 密码卡与解锁态同页存在两个「同步密码」TextFormField（设置/解锁），
//    用 .first/.last 限定（设置态字段在卡上方，解锁态字段在卡下方）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/sync_settings_page.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: SyncSettingsPage()),
    );

/// 发起桥调用 → pump 推进虚拟时钟 → await 完成（纪律 1）
Future<T> _probe<T>(WidgetTester tester, Future<T> future) async {
  await tester.pump(const Duration(milliseconds: 300));
  return future;
}

/// 越过 Mock 120ms 延迟并收敛帧
Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 滚动到目标可见再交互。密码卡在连接卡下方，超出 600 视口时被
/// ListView 懒裁剪剥离出树（estimatedChildren=3 但仅渲染 1 张卡），
/// 必须 dragUntilVisible 先让目标进树，再按底边余量补滚确保可命中。
/// 注意主滚动定位用 ListView（页面仅一个纵向 ListView）；不能用
/// find.byType(Scrollable).last——那会命中字段内横向 EditableText。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(ListView);
  await tester.dragUntilVisible(finder, scrollable, const Offset(0, -200));
  await tester.pumpAndSettle();
  // dragUntilVisible 末尾的 ensureVisible 会把目标顶端对齐到视口顶部，
  // 而顶部 56px 被液态玻璃标题栏盖住 → 命中落到标题栏上。先向下回滚
  // 到标题栏之下，再补滚确保底边离视口下沿有 20px 余量。
  for (var i = 0; i < 8; i++) {
    if (tester.getRect(finder).top >= 80) break;
    await tester.drag(scrollable, const Offset(0, 100));
    await tester.pumpAndSettle();
  }
  for (var i = 0; i < 8; i++) {
    // 留 20px 余量确保可命中点击
    if (tester.getRect(finder).bottom <= 580) break;
    await tester.drag(scrollable, const Offset(0, -100));
    await tester.pumpAndSettle();
  }
}

Future<void> _tapAt(WidgetTester tester, Finder finder) async {
  await _scrollTo(tester, finder);
  await tester.tap(finder);
}

const _presetConfig = <String, Object?>{
  'engine': 'webdav',
  'endpoint': 'https://dav.example.com',
  'username': 'demo',
  'password': 'pw',
};

void main() {
  testWidgets('未配置时：默认 WebDAV + 切换 S3 出现 bucket/region 字段', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    // 默认 webdav：无 S3 专属字段
    expect(find.text('存储桶'), findsNothing);
    expect(find.text('Region'), findsNothing);

    // 切换 S3：bucket/region 出现
    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('S3 兼容存储').last);
    await tester.pumpAndSettle();
    expect(find.text('存储桶'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
  });

  testWidgets('保存：endpoint 必填（空则禁用）→ 填写后成功落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    // endpoint 为空 → 保存按钮禁用
    final saveBtn = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    expect(saveBtn.onPressed, isNull);
    expect(await _probe(tester, bridge.syncConfigGet()), isNull);

    // 填写必填项后保存
    await tester.enterText(find.widgetWithText(TextFormField, '服务器地址'),
        'https://dav.example.com');
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, '用户名'), 'demo');
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, '密码'), 'pw123456');
    await tester.pump();

    await _tapAt(tester, find.widgetWithText(FilledButton, '保存'));
    await _flush(tester);

    final saved = await _probe(tester, bridge.syncConfigGet());
    expect(saved, isNotNull);
    expect(saved!.endpoint, 'https://dav.example.com');
    expect(saved.username, 'demo');
    expect(saved.engine, 'webdav');
  });

  testWidgets('测试连接：留空凭据回填已存配置（同引擎）成功', (tester) async {
    final bridge = MockOrbitBridge();
    // 预置已存配置：先发起，pumpWidget+300ms 推进时钟后再 await（纪律 1）
    final preset = bridge.syncConfigSave(_presetConfig);
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await preset;

    await _tapAt(tester, find.text('测试连接'));
    await _flush(tester);
    // Mock 同引擎回填凭据成功（无异常抛出即连接成功路径）
    expect(await _probe(tester, bridge.syncConfigGet()), isNotNull);
  });

  testWidgets('已配置时：回读表单值 + 断开确认弹窗 → 配置清除表单复位', (tester) async {
    final bridge = MockOrbitBridge();
    final preset = bridge.syncConfigSave(_presetConfig);
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await preset;

    // 回读：endpoint 已填入
    expect(find.text('https://dav.example.com'), findsOneWidget);

    // 断开需二次确认
    await _tapAt(tester, find.text('断开'));
    await tester.pumpAndSettle();
    expect(find.text('断开云同步？'), findsOneWidget);

    // 抽屉内「断开」是确认键（确认类交互统一走底部抽屉）
    await tester.tap(find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('断开'),
    ));
    await _flush(tester);

    expect(await _probe(tester, bridge.syncConfigGet()), isNull);
    expect(find.text('https://dav.example.com'), findsNothing);
  });

  // ── 同步密码卡 ──

  testWidgets('同步密码卡：未设置 → 设置并解锁 → 状态徽标更新', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _scrollTo(tester, find.text('设置并解锁'));
    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码').first, '123456');
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'), '123456');
    await tester.pump();

    await _tapAt(tester, find.text('设置并解锁'));
    await _flush(tester);

    expect(find.text('已解锁'), findsOneWidget);
    expect((await _probe(tester, bridge.syncCryptoStatus())).hasPassword, isTrue);
  });

  testWidgets('同步密码卡：两次密码不一致 → 报错不落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _scrollTo(tester, find.text('设置并解锁'));
    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码').first, '123456');
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'), '654321');
    await tester.pump();

    await _tapAt(tester, find.text('设置并解锁'));
    await _flush(tester);

    expect((await _probe(tester, bridge.syncCryptoStatus())).hasPassword, isFalse);
  });

  testWidgets('同步密码卡：密码过短（<6 位）→ 报错不落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _scrollTo(tester, find.text('设置并解锁'));
    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码').first, '123');
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'), '123');
    await tester.pump();

    await _tapAt(tester, find.text('设置并解锁'));
    await _flush(tester);

    expect((await _probe(tester, bridge.syncCryptoStatus())).hasPassword, isFalse);
  });

  testWidgets('同步密码卡：锁定 → 错误密码保持锁定 → 正确密码解锁', (tester) async {
    final bridge = MockOrbitBridge();
    final preset = bridge.syncCryptoInit('123456');
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await preset;

    // 密码卡在连接卡下方，视口外时被懒裁剪剥出树——先滚入再断言状态徽标
    await _scrollTo(tester, find.text('锁定'));
    expect(find.text('已解锁'), findsOneWidget);

    await tester.tap(find.text('锁定'));
    await _flush(tester);
    expect(find.text('已锁定'), findsOneWidget);

    // 错误密码 → 保持锁定（解锁态字段在卡下方，用 .last，纪律 3）
    await _scrollTo(tester, find.text('解锁'));
    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码').last, '000000');
    await tester.pump();
    await _tapAt(tester, find.text('解锁'));
    await _flush(tester);
    expect(find.text('已锁定'), findsOneWidget);

    // 正确密码 → 解锁
    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码').last, '123456');
    await tester.pump();
    await _tapAt(tester, find.text('解锁'));
    await _flush(tester);
    expect(find.text('已解锁'), findsOneWidget);
  });
}
