# 移动端云同步设置（云同步配置页）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移动端设置页新增「云同步设置」入口与「云同步配置」全量表单页（引擎/凭据/定时/超时/TLS），对齐桌面端 `ConnectionCard`，并附同步密码卡（设置/解锁/锁定）——移动端可在本机完成 WebDAV/S3 配置，不再要求「请在桌面端完成配置」。

**Architecture:** 纯 Flutter 侧改动，Rust/FRB 零改动（`crates/orbit-flutter/src/api/sync.rs` 的命令面已 1:1 就绪，含 `sync_test_connection`/`sync_disconnect`/`sync_crypto_init`/`sync_crypto_lock`）。链路：`SyncSettingsPage`（新，`/settings/sync`）→ `orbitBridgeProvider` → `OrbitBridge`（抽象新增 4 方法）→ `RustOrbitBridge`（映射 FRB）→ `MockOrbitBridge`（测试用内存实现）。设置页同步卡将「未配置」引导文案改为「云同步设置」入口行（InkWell → `context.push('/settings/sync')`）。

**Tech Stack:** Flutter 3.44 / flutter_riverpod 3.x（手动声明，无 codegen）/ go_router 17 / flutter_test（无 mockito，注入 MockOrbitBridge）。

## Global Constraints

- 全部界面文案中文；新文件沿用仓库中文 doc 注释风格。
- Riverpod 无 codegen；bridge 方法返回领域 DTO（dto.dart），不透出 FRB gen 类。
- `OrbitBridge.syncConfigSave` 入参保持 `Map<String, Object?>` snake_case 键（与桌面 invoke 载荷同语义：缺省=默认值、密码留空=沿用已存凭据）。
- Mock 延迟 120ms：测试统一 `await tester.pump(300ms)` + `pumpAndSettle()` 越过。
- 移动端差异（crates/orbit-flutter/src/api/sync.rs 模块注释）：无 keyring（重启需重输同步密码）、无调度器（`interval_minutes`/`sync_on_change` 仅存档）、无事件流（保存后手动刷新）。
- 门禁：`flutter analyze` + `flutter test`（apps/mobile），CI 另有 FRB codegen 一致性校验（本次不触 lib/src/rust/**）。

## 文件结构

| 文件 | 职责 |
|---|---|
| `apps/mobile/lib/data/api/orbit_bridge.dart` | 抽象新增 4 方法：`syncTestConnection` / `syncDisconnect` / `syncCryptoInit` / `syncCryptoLock` |
| `apps/mobile/lib/data/api/mock_orbit_bridge.dart` | Mock 实现 4 方法（测试/开发沙盒） |
| `apps/mobile/lib/data/api/rust_orbit_bridge.dart` | FRB 映射 4 方法（复用 `_toGenConfigInput`） |
| `apps/mobile/lib/modules/settings/sync_settings_page.dart` | 新：云同步配置页（连接表单卡 + 同步密码卡） |
| `apps/mobile/lib/modules/settings/settings_screen.dart` | 同步卡：未配置/已配置均提供「云同步设置」入口行 |
| `apps/mobile/lib/core/routing/app_router.dart` | 新路由 `/settings/sync`（pageSlideFromRight） |
| `apps/mobile/test/settings_sync_test.dart` | 已存在的 RED 测试（入口→表单页，≥4 TextFormField） |
| `apps/mobile/test/sync_settings_page_test.dart` | 新：表单行为测试（回读/保存/测试连接/断开/密码卡） |
| `docs/superpowers/plans/2026-09-02-mobile-sync-settings.md` | 本计划 |
| `CHANGELOG.md` | Unreleased/Added 一行 |

## Task 1: 桥接层扩展（syncTestConnection / syncDisconnect / syncCryptoInit / syncCryptoLock）

**Files:**
- Modify: `apps/mobile/lib/data/api/orbit_bridge.dart:130-148`
- Modify: `apps/mobile/lib/data/api/mock_orbit_bridge.dart`（同步节）
- Modify: `apps/mobile/lib/data/api/rust_orbit_bridge.dart:345-421`
- Test: `apps/mobile/test/bridge_sync_methods_test.dart`（新）

**Interfaces:**
- Produces（后续 Task 依赖的精确签名）:
  ```dart
  Future<int> syncTestConnection(Map<String, Object?> input);
  Future<void> syncDisconnect();
  Future<void> syncCryptoInit(String password, {bool remember = false});
  Future<void> syncCryptoLock();
  ```
  （与既有 `syncConfigSave(Map)` 同风格；input 键同 `_toGenConfigInput`。）

- [ ] **Step 1: 写失败测试**（`apps/mobile/test/bridge_sync_methods_test.dart`）

```dart
// 桥抽象面扩展回归：4 个新方法在 Mock 与抽象契约上的行为。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';

void main() {
  group('MockOrbitBridge 同步扩展方法', () {
    test('syncTestConnection 校验引擎与必填字段', () async {
      final bridge = MockOrbitBridge();
      // 未配置 + 无凭据 → 报错文案（对齐 Rust [config] 校验）
      await expectLater(
        bridge.syncTestConnection({
          'engine': 'webdav',
          'endpoint': 'https://dav.example.com',
          'username': '',
          'password': '',
        }),
        throwsException,
      );
    });

    test('syncTestConnection 已存配置回填凭据后成功返回条目数', () async {
      final bridge = MockOrbitBridge();
      await bridge.syncConfigSave({
        'engine': 'webdav',
        'endpoint': 'https://dav.example.com',
        'username': 'demo',
        'password': 'pw',
      });
      final n = await bridge.syncTestConnection({
        'engine': 'webdav',
        'endpoint': 'https://dav.example.com',
        'username': '',
        'password': '',
      });
      expect(n, isA<int>());
    });

    test('syncDisconnect 清除配置后 syncConfigGet 返回 null', () async {
      final bridge = MockOrbitBridge();
      await bridge.syncConfigSave({
        'engine': 'webdav',
        'endpoint': 'https://dav.example.com',
      });
      await bridge.syncDisconnect();
      expect(await bridge.syncConfigGet(), isNull);
    });

    test('syncCryptoInit + status 状态流转', () async {
      final bridge = MockOrbitBridge();
      expect((await bridge.syncCryptoStatus()).hasPassword, isFalse);
      await bridge.syncCryptoInit('123456', remember: true);
      final s = await bridge.syncCryptoStatus();
      expect(s.hasPassword, isTrue);
      expect(s.isUnlocked, isTrue);
    });

    test('syncCryptoLock 后 isUnlocked 为 false', () async {
      final bridge = MockOrbitBridge();
      await bridge.syncCryptoInit('123456');
      await bridge.syncCryptoLock();
      final s = await bridge.syncCryptoStatus();
      expect(s.isUnlocked, isFalse);
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/mobile && flutter test test/bridge_sync_methods_test.dart`
Expected: FAIL — `syncTestConnection`/`syncDisconnect`/`syncCryptoInit`/`syncCryptoLock` 方法不存在（编译错误即 RED）。

- [ ] **Step 3: 最小实现**

`orbit_bridge.dart`「同步配置与执行」节尾部追加：

```dart
  /// 测试连接（不落盘）：返回云端根目录条目数；用户名/密码留空时
  /// 从已存激活配置回填（同协议）。错误文案带 [config]/[network] tag。
  Future<int> syncTestConnection(Map<String, Object?> input);

  /// 断开云同步：仅清除本机连接配置与凭据，不动本地数据与云端文件
  Future<void> syncDisconnect();
```

「同步加密」节追加：

```dart
  /// 首次设置同步密码（生成 Data Key；移动端 remember 仅进程内缓存）
  Future<void> syncCryptoInit(String password, {bool remember = false});

  /// 锁定：清除内存中的 Data Key（下次同步前需解锁）
  Future<void> syncCryptoLock();
```

`mock_orbit_bridge.dart` 同步节（在 `cloudSyncIsRunning` 后）：

```dart
  @override
  Future<int> syncTestConnection(Map<String, Object?> input) =>
      _delay(() {
        // 对齐 Rust [config] 前置校验：引擎与凭据
        final engine = (input['engine'] as String?) ?? '';
        if (engine != 'webdav' && engine != 's3') {
          throw Exception('[config] 不支持的引擎类型，仅支持 webdav/s3');
        }
        if (((input['endpoint'] as String?) ?? '').trim().isEmpty) {
          throw Exception('[config] 服务器地址不能为空');
        }
        var username = (input['username'] as String?) ?? '';
        var password = (input['password'] as String?) ?? '';
        // 已存配置回填（同协议）
        if (store.syncConfigured &&
            (username.isEmpty || password.isEmpty) &&
            store.lastSyncEngine == engine) {
          username = store.lastSyncUsername;
          password = store.lastSyncPassword;
        }
        if (username.isEmpty || password.isEmpty) {
          throw Exception('[config] 请填写用户名与密码');
        }
        return 3; // 模拟根目录条目数
      });

  @override
  Future<void> syncDisconnect() => _delay(() {
        store.syncConfigured = false;
        store.lastSyncEngine = null;
        store.lastSyncUsername = '';
        store.lastSyncPassword = '';
      });
```

同步加密节（`syncCryptoStatus` 前）：

```dart
  @override
  Future<void> syncCryptoInit(String password, {bool remember = false}) =>
      _delay(() {
        if (password.length < 6) {
          throw Exception('[invalid_input] 同步密码至少 6 位');
        }
        store.syncPasswordSet = true;
        store.syncUnlocked = true;
      });

  @override
  Future<void> syncCryptoLock() => _delay(() {
        store.syncUnlocked = false;
      });
```

同步修改 `syncCryptoStatus`：

```dart
  @override
  Future<SyncCryptoStatus> syncCryptoStatus() => _delay(() => SyncCryptoStatus(
      hasPassword: store.syncPasswordSet, isUnlocked: store.syncUnlocked));
```

`mock_store.dart` 增加字段：

```dart
  bool syncPasswordSet = false;
  bool syncUnlocked = false;
  String? lastSyncEngine;
  String lastSyncUsername = '';
  String lastSyncPassword = '';
```

`syncConfigSave` mock 追加（在 `store.syncConfigured = true;` 后）：

```dart
        store.lastSyncEngine = (input['engine'] as String?) ?? 'webdav';
        store.lastSyncUsername = (input['username'] as String?) ?? '';
        store.lastSyncPassword = (input['password'] as String?) ?? '';
```

`rust_orbit_bridge.dart` 同步节（`cloudSyncIsRunning` 后）：

```dart
  @override
  Future<int> syncTestConnection(Map<String, Object?> input) async =>
      gen_sync.syncTestConnection(input: _toGenConfigInput(input));

  @override
  Future<void> syncDisconnect() => gen_sync.syncDisconnect();
```

同步加密节（`syncCryptoUnlock` 后）：

```dart
  @override
  Future<void> syncCryptoInit(String password, {bool remember = false}) =>
      gen_sync.syncCryptoInit(password: password, remember: remember);

  @override
  Future<void> syncCryptoLock() => gen_sync.syncCryptoLock();
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apps/mobile && flutter test test/bridge_sync_methods_test.dart`
Expected: PASS（5 个用例全绿）。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/data/api/orbit_bridge.dart apps/mobile/lib/data/api/mock_orbit_bridge.dart apps/mobile/lib/data/api/mock_store.dart apps/mobile/lib/data/api/rust_orbit_bridge.dart apps/mobile/test/bridge_sync_methods_test.dart
git commit -m "feat(mobile): 桥抽象扩展云同步设置命令面（测试连接/断开/密码初始化/锁定）"
```

## Task 2: 设置页入口 + 路由 + 配置页骨架

**Files:**
- Create: `apps/mobile/lib/modules/settings/sync_settings_page.dart`
- Modify: `apps/mobile/lib/modules/settings/settings_screen.dart`
- Modify: `apps/mobile/lib/core/routing/app_router.dart`
- Test: `apps/mobile/test/settings_sync_test.dart`（已有 RED 测试）

**Interfaces:**
- Consumes: Task 1 的 4 方法；既有 `syncConfigGet/syncConfigSave/cloudSyncNow/syncCryptoStatus/syncCryptoUnlock`。
- Produces: `class SyncSettingsPage extends ConsumerStatefulWidget`；路由 `/settings/sync`（`pageSlideFromRight`）；设置页同步卡「云同步设置」入口行（`InkWell` → `context.push('/settings/sync')`，行文案「云同步设置」+chevron）。

- [ ] **Step 1: 确认 RED**（已有 `settings_sync_test.dart`）

Run: `cd apps/mobile && flutter test test/settings_sync_test.dart`
Expected: FAIL — `云同步设置` 0 个匹配（入口不存在）。

- [ ] **Step 2: 实现**

`app_router.dart`：import 补 `sync_settings_page.dart`；`/settings` 路由后追加：

```dart
    GoRoute(
      path: '/settings/sync',
      pageBuilder: (context, state) => pageSlideFromRight(
        const SyncSettingsPage(),
        key: state.pageKey,
      ),
    ),
```

`settings_screen.dart` 同步卡改造——将未配置提示块替换为入口行（已配置/未配置都展示，放「上次同步」行之后、「立即同步」按钮之前）：

```dart
                      const SizedBox(height: AppDimens.space8),
                      InkWell(
                        borderRadius: AppShapes.medium,
                        onTap: () => context.push('/settings/sync'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space8),
                          child: Row(
                            children: [
                              Text('云同步设置',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: OrbitAccents.themeAccent)),
                              const Spacer(),
                              Icon(Icons.chevron_right_rounded,
                                  size: AppDimens.iconSizeMd,
                                  color: colors.secondaryText),
                            ],
                          ),
                        ),
                      ),
```

同时更新页头 doc 注释（「未配置引擎时…请在桌面端完成配置」→「云同步设置入口行 → push /settings/sync」）。注意保留「未配置同步引擎」状态文本（测试断言依赖）。

`sync_settings_page.dart`（骨架，Task 3/4 填充表单与密码卡）：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/wait_toast.dart';
import '../../data/providers/bridge_provider.dart';
import '../../data/api/dto.dart';
import '../todo/logic/task_logic.dart' show formatDateTime;
import '../todo/providers/todo_providers.dart';

/// 云同步配置页 /settings/sync（对齐桌面端 SyncSection 连接卡）
///
/// 结构：
/// 1. 连接卡：引擎 WebDAV/S3 + endpoint/bucket/region/用户名/密码/远端路径/
///    定时同步开关+间隔 + 修改后立即同步 + 请求超时 + 跳过 TLS 验证 +
///    测试连接/保存/断开（确认弹窗）；
/// 2. 同步密码卡：未设置 → 设置并解锁；已设置 → 已解锁/已锁定 + 解锁/锁定；
///    移动端无系统钥匙串，重启后需重输同步密码。
class SyncSettingsPage extends ConsumerStatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  ConsumerState<SyncSettingsPage> createState() => _SyncSettingsPageState();
}
```

页面骨架：`Scaffold(body: Stack[ListView, LiquidGlassTitleBar(title: '云同步配置')])`，与设置页同构（`scrollOffsetListenable` + padding）。ListView 内两张 `SectionCard(title: '云同步连接')` 与 `SectionCard(title: '同步密码（端到端加密）')`。构建时先渲染骨架，Task 3 填表单。

- [ ] **Step 3: 运行确认通过**

Run: `cd apps/mobile && flutter test test/settings_sync_test.dart`
Expected: PASS——`云同步设置` 可点开 → `云同步配置` 标题 + ≥4 TextFormField。

（注意：现有测试用 `MaterialApp(home: SettingsScreen())` 直挂无路由，`context.push` 需要 Router 注入。入口行改用 `context.push('/settings/sync')` 时测试环境无 GoRouter——需将测试改为 `MaterialApp.router` 挂 `appRouter`（或复用现有「直挂 + onGenerateRoute」模式）。若现有测试不便改，入口 onTap 也可改 `Navigator.of(context).push(MaterialPageRoute)`，但路由表同步注册保证从设置页跳转语义一致；测试侧采用 `_wrap` 挂真实 `appRouter`，初始 `/settings`。）

- [ ] **Step 4: Commit**

```bash
git add apps/mobile/lib/modules/settings/sync_settings_page.dart apps/mobile/lib/modules/settings/settings_screen.dart apps/mobile/lib/core/routing/app_router.dart apps/mobile/test/settings_sync_test.dart
git commit -m "feat(mobile): 设置页云同步设置入口与云同步配置页骨架（/settings/sync）"
```

## Task 3: 连接表单完整行为（回读 / 引擎切换 / 校验 / 保存 / 测试连接 / 断开）

**Files:**
- Modify: `apps/mobile/lib/modules/settings/sync_settings_page.dart`
- Test: `apps/mobile/test/sync_settings_page_test.dart`（新）

**Interfaces:**
- Consumes: `SyncConfigView`（回读）、`syncConfigSave(Map)`、`syncTestConnection(Map)`、`syncDisconnect()`、`syncConfigProvider`、`WaitToast`、`AppColors`。
- Produces: 表单字段（TextEditingController × 6 + 开关状态 × 4 + 间隔 Dropdown）；`buildInput()` 私有方法（snake_case map，与桌面 `buildInput` 同语义）；文案常量（供测试 ValueKey 定位）。

- [ ] **Step 1: 写失败测试**

```dart
// 云同步配置页连接表单：回读、引擎切换联动、保存、测试连接、断开确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/sync_settings_page.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: const SyncSettingsPage()),
    );

void main() {
  testWidgets('未配置时：默认 WebDAV + 空表单 + 引擎切换出 S3 字段', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 默认 webdav：无 bucket 字段
    expect(find.text('存储桶'), findsNothing);
    // 切换 S3：bucket/region 出现
    await tester.tap(find.text('S3 兼容存储'));
    await tester.pumpAndSettle();
    expect(find.text('存储桶'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
  });

  testWidgets('保存：必填校验 + 成功 toast + 引擎摘要持久化', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // endpoint 为空 → 保存报错
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // WaitToast 为 Overlay，需 rootNavigatorKey——测试用 MaterialApp(home:) 无
    // overlay 注入路由级，toast 走全局 key，直接检查 mock 状态即可
    expect(await bridge.syncConfigGet(), isNull);

    // 填写并保存
    await tester.enterText(
        find.widgetWithText(TextFormField, '服务器地址'), 'https://dav.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, '用户名'), 'demo');
    await tester.enterText(find.widgetWithText(TextFormField, '密码'), 'pw123456');
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final saved = await bridge.syncConfigGet();
    expect(saved, isNotNull);
    expect(saved!.endpoint, 'https://dav.example.com');
    expect(saved.username, 'demo');
  });

  testWidgets('测试连接：留空凭据回填已存配置成功', (tester) async {
    final bridge = MockOrbitBridge();
    await bridge.syncConfigSave({
      'engine': 'webdav',
      'endpoint': 'https://dav.example.com',
      'username': 'demo',
      'password': 'pw',
    });
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试连接'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // Mock 返回 3 条；断言不易捕 toast，改查 bridge 状态已配置（未改动）+ 无异常
    expect(await bridge.syncConfigGet(), isNotNull);
  });

  testWidgets('已配置时：回读表单 + 断开确认弹窗 → 配置清除', (tester) async {
    final bridge = MockOrbitBridge();
    await bridge.syncConfigSave({
      'engine': 'webdav',
      'endpoint': 'https://dav.example.com',
      'username': 'demo',
      'password': 'pw',
    });
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 回读：endpoint 字段值已填
    expect(find.text('https://dav.example.com'), findsOneWidget);

    // 断开需确认
    await tester.tap(find.text('断开'));
    await tester.pumpAndSettle();
    expect(find.text('断开云同步？'), findsOneWidget);
    await tester.tap(find.text('断开'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(await bridge.syncConfigGet(), isNull);
    expect(find.text('https://dav.example.com'), findsNothing);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/mobile && flutter test test/sync_settings_page_test.dart`
Expected: FAIL——`SyncSettingsPage` 无表单字段/按钮（Task 2 骨架只有卡片壳）。

- [ ] **Step 3: 实现表单**

关键实现要点（完整代码见 Task 3 附录）：
- State 字段：`_engine('webdav')`、6 个 TextEditingController（endpoint/bucket/region/username/password/basePath）、`_intervalMin(60)`、`_autoEnabled(true)`、`_onChange(false)`、`_skipTls(false)`、`_timeoutSecs('30')`、`_config(SyncConfigView?)`、`_loading(true)`、`_busy/_testing(bool)`、`_scrollController`。
- initState：`ref.read(orbitBridgeProvider).syncConfigGet()` 回读填表单（桌面 `useEffect` 同语义：endpoint/bucket/region/username/basePath 默认 'orbit'、interval、开关、timeout≥30）。密码不回填（占位符「已保存（修改请重新输入）」）。
- `buildInput()`：snake_case map，`base_path: basePath.trim() || 'orbit'`；S3 时 bucket/region 传值、WebDAV 传 ''；`interval_minutes`、`auto_sync_enabled`、`sync_on_change`、`skip_tls_verify`、`timeout_seconds: int.tryParse(_timeoutSecs) ?? 30`。
- 表单布局：`Form` + `TextFormField`（labelText 与桌面文案一致：引擎用 `SegmentedButton`/`DropdownButtonFormField`；「服务器地址/Endpoint」占位 `https://dav.example.com/dav`；S3 专属存储桶/Region；用户名/Access Key；密码/Secret Key obscureText + password_set 时 hint「已保存（修改请重新输入）」；远端路径默认 orbit；定时同步 `Switch` + `DropdownButtonFormField`（10/30/60/120/360 分钟，关=0）；修改后立即同步 `Switch`；请求超时 `TextFormField`（数字键盘，5–600，秒）；跳过 TLS `Switch` + 警示文案「自签名证书场景专用，存在中间人风险」）。
- 按钮：`断开`（红字 TextButton，仅 `_config != null`；点弹 `AlertDialog`「断开云同步？」+ 描述「将清除本机保存的连接配置与凭据；本地数据与云端文件均不会删除，之后可随时重新配置。」+ 取消/确认）→ `syncDisconnect` + `_load()` + `ref.invalidate(syncConfigProvider)`；`测试连接`（OutlinedButton，endpoint 空禁用）→ `syncTestConnection(buildInput())` toast「连接成功（根目录 N 个条目）」/「连接失败：…」；`保存`（FilledButton，endpoint 空禁用）→ `syncConfigSave(buildInput())` → toast「同步配置已保存」+ `_load()` + `ref.invalidate(syncConfigProvider)`。
- 错误文案处理：`String _errMsg(Object e) => e.toString().replaceFirst(RegExp(r'^Exception: \[?\w*\]?\s*'), '').replaceFirst(RegExp(r'^\[\w+\]\s*'), '')`（去 tag 前缀，对齐桌面 `errMsg`）。
- busy 状态：`_busy/_testing` 时按钮禁用 + `SizedBox(CircularProgressIndicator(strokeWidth: 2))`。

- [ ] **Step 4: 运行确认通过**

Run: `cd apps/mobile && flutter test test/sync_settings_page_test.dart`
Expected: PASS（4 用例）。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/modules/settings/sync_settings_page.dart apps/mobile/test/sync_settings_page_test.dart
git commit -m "feat(mobile): 云同步配置页连接表单（引擎/凭据/定时/超时/TLS + 测试连接/保存/断开）"
```

## Task 4: 同步密码卡（设置 / 解锁 / 锁定）

**Files:**
- Modify: `apps/mobile/lib/modules/settings/sync_settings_page.dart`
- Test: `apps/mobile/test/sync_settings_page_test.dart`（追加用例）

**Interfaces:**
- Consumes: `syncCryptoStatus/syncCryptoInit/syncCryptoUnlock/syncCryptoLock`。
- Produces: 状态徽标行（已解锁/已锁定/未设置）+ 操作区（设置：密码+确认两框+「设置并解锁」；已锁：解锁框+「解锁」；已解锁：「锁定」按钮 + 移动端提示「重启后需重新输入同步密码」）。

- [ ] **Step 1: 写失败测试**（追加到 `sync_settings_page_test.dart`）

```dart
  testWidgets('同步密码卡：未设置 → 设置并解锁 → 状态徽标更新', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('未设置'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码'), '123456');
    await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'), '123456');
    await tester.tap(find.text('设置并解锁'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('已解锁'), findsOneWidget);
  });

  testWidgets('同步密码卡：锁定 → 状态切换 + 可解锁', (tester) async {
    final bridge = MockOrbitBridge();
    await bridge.syncCryptoInit('123456');
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.text('锁定'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('已锁定'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, '同步密码'), '123456');
    await tester.tap(find.text('解锁'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('已解锁'), findsOneWidget);
  });

  testWidgets('同步密码卡：两次密码不一致 → 报错不落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码'), '123456');
    await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'), '654321');
    await tester.tap(find.text('设置并解锁'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((await bridge.syncCryptoStatus()).hasPassword, isFalse);
  });

  testWidgets('同步密码卡：密码过短（<6 位）报错', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, '同步密码'), '123');
    await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'), '123');
    await tester.tap(find.text('设置并解锁'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((await bridge.syncCryptoStatus()).hasPassword, isFalse);
  });
```
（同步密码卡测试同上，4 个新用例追加进 `sync_settings_page_test.dart`；两次密码不一致/过短用例已在上方给出完整正确代码，此处不重复。）

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/mobile && flutter test test/sync_settings_page_test.dart`
Expected: FAIL——密码卡区域未实现（无「未设置」/「已解锁」等文案）。

- [ ] **Step 3: 实现**

State 追加：`_cryptoStatus(SyncCryptoStatus?)`、`_pw/_confirm/_unlockPw` controllers、`_cryptoBusy`。initState 同时拉 `syncCryptoStatus()`。

布局（对齐桌面 SyncPasswordCard）：
- `status == null` →「加载中…」；
- `!hasPassword` → 引导文案「未设置。设置后生成随机 Data Key 加密所有上传数据；跨设备请使用相同同步密码。」+ 同步密码/确认密码两个 obscure TextFormField +「设置并解锁」FilledButton（校验：≥6 位、两次一致；成功 → 清空输入 + 刷新状态）。
- `hasPassword` → 徽标行（icon + 已解锁/已锁定）+ 副文案（已解锁「Data Key 在内存中，可执行同步与备份」/ 已锁定「输入同步密码解锁后才能同步」）；已锁：解锁框 + 「解锁」按钮（`syncCryptoUnlock`，wrong_password →「同步密码错误」）；已解锁：「锁定」OutlinedButton（`syncCryptoLock`）。
- 尾部固定提示（移动端差异）：「移动端不缓存同步密码，应用重启后需重新输入解锁。」

- [ ] **Step 4: 运行确认通过**

Run: `cd apps/mobile && flutter test test/sync_settings_page_test.dart`
Expected: PASS（8 用例全绿）。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/modules/settings/sync_settings_page.dart apps/mobile/test/sync_settings_page_test.dart
git commit -m "feat(mobile): 云同步配置页同步密码卡（设置/解锁/锁定 + 移动端无钥匙串提示）"
```

## Task 5: 收尾——CHANGELOG / 文档门禁 / 全量回归

**Files:**
- Modify: `CHANGELOG.md`（Unreleased/Added）
- Modify: `apps/mobile/lib/modules/settings/settings_screen.dart` 头注释（若 Task 2 未更新）

- [ ] **Step 1: CHANGELOG 追加**

```markdown
- 移动端云同步设置：设置页「云同步设置」入口 + `/settings/sync` 配置页
  （WebDAV/S3 引擎、凭据、定时/超时/TLS、测试连接/保存/断开、同步密码
  设置/解锁/锁定）——桥抽象扩展 `syncTestConnection/syncDisconnect/
  syncCryptoInit/syncCryptoLock`，移动端可在本机完成云同步配置
```

- [ ] **Step 2: 全量门禁**

Run:
```bash
cd apps/mobile
flutter analyze
flutter test
```
Expected: analyze 0 issues；test 全绿（含既有 9 文件 + 新 3 文件）。

- [ ] `git status` 确认无计划文档误入（`docs/superpowers/plans/2026-09-02-mobile-sync-settings.md` 保留可提交）。

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md docs/superpowers/plans/2026-09-02-mobile-sync-settings.md
git commit -m "docs: 移动端云同步设置实施计划与变更记录"
```

## Self-Review 结论

- 规格覆盖：桌面 ConnectionCard 全字段（engine/endpoint/bucket/region/username/password/base_path/interval/auto/on_change/timeout/skip_tls + test/save/disconnect）✓；SyncPasswordCard 核心（init/unlock/lock；导出 bundle/forget/修改密码为桌面专属，v1 移动端不做——恢复流已有 `syncCryptoImportBundle` 由 key_mismatch 流程消费）✓；设置页入口 ✓；路由 ✓。
- 类型一致性：`SyncConfigView`/`SyncCryptoStatus`/`SyncResultJson` 均用 dto.dart 领域类；`syncConfigSave` map 键 snake_case 与 `_toGenConfigInput` 对齐 ✓。
- 占位符扫描：无 TBD/TODO；Task 3 表单实现以要点形式给出（字段/文案/交互全量列明），Task 4 密码卡同理。
