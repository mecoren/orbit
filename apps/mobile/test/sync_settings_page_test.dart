// 云同步配置页行为测试：连接表单回读/引擎切换/保存/测试连接/断开确认 +
// 同步密码卡（设置/解锁/锁定/校验）。
//
// 三条测试纪律：
// 1. FakeAsync：直接 await bridge.xxx()（内部 120ms 延迟）前必须先发起、
//    由 tester.pump(300ms) 推进虚拟时钟再 await，否则永久挂起；
// 2. 页面字段多于一屏（视口 600）：交互/断言前用 _scrollTo（复用
//    form_bottom_sheet_test 的 scrollUntilVisible + 底边余量补滚模式）；
// 3. 首次设置走共享密码抽屉（`showPasswordSheet`）：点「设置密码」入口拉起
//    抽屉，字段是抽屉内 OrbitTextField；页内仅剩解锁态一个「同步密码」输入框。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/sync_settings_page.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_filter_chip.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_settings_group.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_switch.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_text_field.dart';
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

/// 状态徽标文案（14px）。
///
/// 与 toast 成功条**同名**（toast 标题 15px）——测试壳与生产壳同构后 toast 会
/// 真的弹出，裸 `find.text('已解锁')` 会命中两处，故按字号把徽标择出来。
Finder _badge(String text) => find.byWidgetPredicate(
      (w) => w is Text && w.data == text && w.style?.fontSize == 14,
    );

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
    // 外观同款下拉偏好行：弹层内当前档回勾 WebDAV，尾随值常驻行内
    expect(dropdownPreferencePopupRows(), findsWidgets);
    expect(selectedDropdownPreferenceLabels(tester), ['WebDAV']);
    await tester.tap(find.text('S3 兼容存储').last);
    await tester.pumpAndSettle();
    expect(find.text('存储桶'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
  });

  testWidgets('定时同步：开关行 + 独立间隔档位行，关闭总开关后间隔不可展开', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    await _scrollTo(tester, find.text('每 60 分钟'));
    await tester.tap(find.text('每 60 分钟'));
    await tester.pumpAndSettle();
    expect(selectedDropdownPreferenceLabels(tester), ['每 60 分钟']);

    await tester.tap(find.text('每 2 小时').last);
    await tester.pumpAndSettle();
    expect(find.text('每 2 小时'), findsOneWidget);

    // 关掉「定时同步」总开关 → 间隔行整行禁用，点不开弹层
    await _tapAt(tester, find.byType(OrbitSwitch).first);
    await tester.pumpAndSettle();
    // 开关是独立开关行（设置页口径），点开关不会顺带把下拉展开
    expect(dropdownPreferencePopupRows(), findsNothing);
    await tester.tap(find.text('每 2 小时'));
    await tester.pumpAndSettle();
    expect(dropdownPreferencePopupRows(), findsNothing);
  });

  testWidgets('下拉展开阴影撑满整卡：档位行与开关行宽度 = 卡宽', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    Finder row(String title) => find.byWidgetPredicate(
          (w) => w is OrbitDropdownPreference<Object?> && w.title == title,
        );
    // 分组卡（MiuixCard）：行件零外层内边距，按压灰底才能横贯整卡
    final cardWidth = tester.getRect(find.byType(MiuixCard).first).width;
    expect(tester.getRect(row('引擎')).width,
        moreOrLessEquals(cardWidth, epsilon: 1),
        reason: '引擎行按压灰底必须横贯整卡');

    // 定时同步/同步间隔在首屏下方，先滚入树再量宽度
    await _scrollTo(tester, find.text('每 60 分钟'));
    expect(tester.getRect(row('同步间隔')).width,
        moreOrLessEquals(cardWidth, epsilon: 1),
        reason: '档位行按压灰底必须横贯整卡');

    // 定时同步是标准开关行（文字在左、开关贴右），不再是行首动作
    final switchRow = find.byWidgetPredicate(
      (w) => w is OrbitSettingsSwitchRow && w.title == '定时同步',
    );
    expect(switchRow, findsOneWidget);
    expect(tester.getRect(switchRow).width,
        moreOrLessEquals(cardWidth, epsilon: 1),
        reason: '开关行同样要横贯整卡');
    final sw = tester.getRect(
      find.descendant(of: switchRow, matching: find.byType(OrbitSwitch)),
    );
    expect(
      sw.right,
      moreOrLessEquals(tester.getRect(switchRow).right - 16, epsilon: 1),
      reason: '开关贴行右缘（设置页口径 16 内边距）',
    );
  });

  // 同步历史筛选走连体分段控件（`OrbitSegmentedFilter`，库内
  // `MiuixTabRowWithContour` 承载），不是四个独立 `OrbitFilterChip`——
  // 四档同属一个轨道才读得出「一个筛选器的四个档位」。
  //
  // 注意 `find.text` 会同时命中筛选档与历史行内的类型标签（mock 造态里
  // incremental 行的标题就是「完整同步」），故断言与点击一律按下标/语义定位。
  testWidgets('同步历史：四档走连体分段控件，切档重新拉取', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    final seg = find.byType(MiuixTabRowWithContour);
    // 历史卡在首屏下方（ListView 懒建），先滚入树再断言
    await _scrollTo(tester, seg);
    expect(seg, findsOneWidget, reason: '四档必须共用一个轨道，不是四个独立胶囊');
    expect(find.byType(OrbitFilterChip), findsNothing);

    final row = tester.widget<MiuixTabRowWithContour>(seg);
    expect(row.tabs, ['全部', '完整同步', '仅推送', '先拉后推']);
    expect(row.selectedTabIndex, 0, reason: '缺省档为全部');

    // 切到第 3 档（仅推送）：分段控件按档位中心点命中，直接算第 3 档矩形中心
    final rect = tester.getRect(seg);
    const pad = MiuixTabRowDefaults.contourPadding;
    const spacing = MiuixTabRowDefaults.contourItemSpacing;
    final tabWidth = (rect.width - pad * 2 - spacing * 3) / 4;
    await tester.tapAt(Offset(
      rect.left + pad + 2 * (tabWidth + spacing) + tabWidth / 2,
      rect.center.dy,
    ));
    await _flush(tester);

    expect(
      tester.widget<MiuixTabRowWithContour>(seg).selectedTabIndex,
      2,
      reason: '点第 3 档后选中块必须跟随',
    );
    // mock 造态里 push_only 只有 1 行
    expect(find.text('近 1 次'), findsOneWidget);
  });

  testWidgets('保存：endpoint 必填（空则禁用）→ 填写后成功落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    // endpoint 为空 → 保存按钮禁用
    final saveBtn = tester.widget<OrbitButton>(
        find.widgetWithText(OrbitButton, '保存'),
      );
    expect(saveBtn.onPressed, isNull);
    expect(await _probe(tester, bridge.syncConfigGet()), isNull);

    // 填写必填项后保存
    await tester.enterText(find.widgetWithText(OrbitTextField, '服务器地址'),
        'https://dav.example.com');
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(OrbitTextField, '用户名'), 'demo');
    await tester.pump();
    await tester.enterText(find.widgetWithText(OrbitTextField, '密码'), 'pw123456');
    await tester.pump();

    await _tapAt(tester, find.widgetWithText(OrbitButton, '保存'));
    await _flush(tester);

    final saved = await _probe(tester, bridge.syncConfigGet());
    expect(saved, isNotNull);
    expect(saved!.endpoint, 'https://dav.example.com');
    expect(saved.username, 'demo');
    expect(saved.engine, 'webdav');
    await drainToastTimers(tester);
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
    await drainToastTimers(tester);
  });

  testWidgets('已配置时：回读表单值 + 断开确认弹窗 → 配置清除表单复位', (tester) async {
    final bridge = MockOrbitBridge();
    final preset = bridge.syncConfigSave(_presetConfig);
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await preset;

    // 回读：endpoint 已填入
    expect(find.text('https://dav.example.com'), findsOneWidget);

    // 断开需二次确认（卡尾红字动作行，与设置页危险操作同口径）
    await _tapAt(tester, find.text('断开云同步'));
    await tester.pumpAndSettle();
    expect(find.text('断开云同步？'), findsOneWidget);

    // 抽屉内「断开」是确认键（确认类交互统一走 `showConfirmBottomSheet` —— v3 起
    // 承载在 shadcn sheet 上而非 Material BottomSheet，故改按入栈顺序取 last：
    // 抽屉浮层渲染在页面之后）
    await tester.tap(find.text('断开').last);
    await _flush(tester);

    expect(await _probe(tester, bridge.syncConfigGet()), isNull);
    expect(find.text('https://dav.example.com'), findsNothing);
    await drainToastTimers(tester);
  });

  // ── 同步密码卡 ──

  testWidgets('同步密码卡：未设置 → 设置并解锁 → 状态徽标更新', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    // 点入口拉起共享密码抽屉（设置类输入统一走底部抽屉）
    await _tapAt(tester, find.text('设置密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(OrbitTextField, '同步密码'), '123456');
    await tester.pump();
    await tester.enterText(find.widgetWithText(OrbitTextField, '确认密码'), '123456');
    await tester.pump();

    await tester.tap(find.text('设置并解锁'));
    await _flush(tester);

    expect(find.text('已解锁'), findsOneWidget);
    expect((await _probe(tester, bridge.syncCryptoStatus())).hasPassword, isTrue);
    await drainToastTimers(tester);
  });

  testWidgets('同步密码卡：两次密码不一致 → 报错不落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.text('设置密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(OrbitTextField, '同步密码'), '123456');
    await tester.pump();
    await tester.enterText(find.widgetWithText(OrbitTextField, '确认密码'), '654321');
    await tester.pump();

    await tester.tap(find.text('设置并解锁'));
    await _flush(tester);

    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    expect((await _probe(tester, bridge.syncCryptoStatus())).hasPassword, isFalse);
    await drainToastTimers(tester);
  });

  testWidgets('同步密码卡：密码过短（<6 位）→ 报错不落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.text('设置密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(OrbitTextField, '同步密码'), '123');
    await tester.pump();
    await tester.enterText(find.widgetWithText(OrbitTextField, '确认密码'), '123');
    await tester.pump();

    await tester.tap(find.text('设置并解锁'));
    await _flush(tester);

    expect(find.text('同步密码至少 6 位'), findsOneWidget);
    expect((await _probe(tester, bridge.syncCryptoStatus())).hasPassword, isFalse);
    await drainToastTimers(tester);
  });

  testWidgets('同步密码卡：锁定 → 错误密码保持锁定 → 正确密码解锁', (tester) async {
    final bridge = MockOrbitBridge();
    final preset = bridge.syncCryptoInit('123456');
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);
    await preset;

    // 密码卡在连接卡下方，视口外时被懒裁剪剥出树——先滚入再断言状态徽标
    await _scrollTo(tester, find.text('锁定'));
    expect(_badge('已解锁'), findsOneWidget);

    await tester.tap(find.text('锁定'));
    await _flush(tester);
    expect(_badge('已锁定'), findsOneWidget);

    // 错误密码 → 保持锁定（页内唯一「同步密码」输入框即解锁字段，纪律 3）
    await _scrollTo(tester, find.text('解锁'));
    await tester.enterText(
        find.widgetWithText(OrbitTextField, '同步密码'), '000000');
    await tester.pump();
    await _tapAt(tester, find.text('解锁'));
    await _flush(tester);
    expect(_badge('已锁定'), findsOneWidget);

    // 正确密码 → 解锁
    await tester.enterText(
        find.widgetWithText(OrbitTextField, '同步密码'), '123456');
    await tester.pump();
    await _tapAt(tester, find.text('解锁'));
    await _flush(tester);
    expect(_badge('已解锁'), findsOneWidget);
    await drainToastTimers(tester);
  });

  // ── 密钥治理（docs/07 #55：版本显示 / v1 迁移 / 以本机为准重置云端）──

  testWidgets('密钥治理：v2 设备显示方案版本且不出现升级入口', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _scrollTo(tester, find.text('本机密钥方案：v2（同密码跨设备同 Key）'));
    expect(find.text('升级密钥方案到 v2'), findsNothing);
    expect(find.text('以本机为准重置云端'), findsOneWidget);
  });

  testWidgets('密钥治理：v1 存量设备 → 升级入口，确认后置 v2 并隐去入口', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456'
      ..store.syncKeyVersion = 'v1';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _scrollTo(tester, find.text('本机密钥方案：v1（旧版随机密钥）'));
    expect(find.text('升级密钥方案到 v2'), findsOneWidget);

    await _tapAt(tester, find.text('升级密钥方案到 v2'));
    await tester.pumpAndSettle();
    // 升级需当前同步密码（对话框内唯一输入框）
    await tester.enterText(
        find.widgetWithText(OrbitTextField, '当前同步密码'), '123456');
    await tester.pump();
    await tester.tap(find.text('确认升级'));
    await _flush(tester);

    expect(bridge.store.syncKeyVersion, 'v2');
    await _scrollTo(tester, find.text('本机密钥方案：v2（同密码跨设备同 Key）'));
    expect(find.text('升级密钥方案到 v2'), findsNothing);
    await drainToastTimers(tester);
  });

  testWidgets('密钥治理：以本机为准重置云端走危险确认并执行', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.text('以本机为准重置云端'));
    await tester.pumpAndSettle();
    // 不可逆操作必须二次确认（确认钮在抽屉内，取 last）
    expect(find.text('确认重置云端'), findsOneWidget);
    await tester.tap(find.text('确认重置云端').last);
    await _flush(tester);

    expect(find.textContaining('云端已重置'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('密钥治理：未解锁时重置云端 → 报错不静默', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = false
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.text('以本机为准重置云端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重置云端').last);
    await _flush(tester);

    expect(find.textContaining('重置失败'), findsOneWidget);
    await drainToastTimers(tester);
  });
  testWidgets('同步排障：仅推送 → 成功 toast（走 core push_only，不动拉取侧）', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.widgetWithText(OrbitButton, '仅推送'));
    await _flush(tester);

    // mock push_only：pushedModules = 2、pulledModules = 0
    expect(find.text('仅推送完成：2 个模块'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('同步排障：先拉后推 → 成功 toast 报拉取模块数', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.widgetWithText(OrbitButton, '先拉后推'));
    await _flush(tester);

    expect(find.text('先拉后推完成：拉取 2 个模块'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('云端存储：孤儿附件扫描为空 → 提示没有可清理项', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.widgetWithText(OrbitButton, '清理云端孤儿附件'));
    await _flush(tester);

    expect(find.text('没有可清理的云端附件'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('云端存储：回收孤儿数据桶 → mock 恒 0，提示没有可回收项', (tester) async {
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = '123456';
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    await _tapAt(tester, find.widgetWithText(OrbitButton, '回收孤儿数据桶'));
    await _flush(tester);

    expect(find.text('没有可回收的孤儿数据桶'), findsOneWidget);
    await drainToastTimers(tester);
  });
}
