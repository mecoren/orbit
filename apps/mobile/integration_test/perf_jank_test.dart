// 移动端动画帧耗时探针（profile 档专用，`perf-metrics/mobile-jank.mjs` 的被测端）
//
// **为什么要有这个文件**：移动端在此之前只有内存门禁（`mobile-mem.mjs`，
// PSS 口径），「卡不卡」长期靠手感判断。本用例把 5 个动画场景的帧耗时收进
// `IntegrationTestWidgetsFlutterBinding.reportData`，由
// `flutter drive --profile` 落盘到 `build/integration_response_data.json`，
// 再由 Node 脚本按基线判阈值。
//
// **为什么不用 `watchPerformance`**：它内部要连 VM Service（`SocketException:
// Connection refused`），`flutter drive` 不提供那条通道，五个场景会全红。
// 这里改用 `SchedulerBinding.addTimingsCallback`——引擎每帧直推
// `FrameTiming`，profile 档下数值真实，且零外部通道。指标口径与
// integration_test 保持一致（`buildDuration > 1000/60 ms` 记一次 missed）。
//
// **口径诚实性（务必先读）**：
// - 只在 **profile** 档有意义（debug 下引擎的帧调度被插桩改写，数值不能当
//   门禁），故 `skip: !kProfileMode`；用 `flutter test` 跑本目录会整组 SKIP，
//   绝不产出假数字。
// - 数据源是 `MockOrbitBridge`（内存库）：能测到**渲染/动画**成本，测不到
//   真实 SQLite 往返与 FRB 序列化抖动。这条边界与现有 3 个 integration_test
//   用例同口径。
// - `latency` 归零：本轮量的是动画帧，不是 mock 的 120ms 人为延迟。
// - 宿主套 `OrbitGlassPage`：生产壳（`HomeShell`）会把页面内容包进
//   `MiuixLayerBackdropCapture`，玻璃弹层才有背景快照可采样。裸页在测试里
//   会退化成实时 `BackdropFilter`，量不到 `MiuixGlassPanel` 的真实成本。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/calendar_screen.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/logic/view_mode.dart';
import 'package:orbit/modules/todo/quick_add_sheet.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_month_calendar.dart';

import '../test/support/orbit_test_app.dart';

/// 列表种子条数：撑满多屏并让滚动有真实内容（与 docs/09 B6 的 500 行窗口同量级）
const int _seedTasks = 500;

/// 单场景推进时长：覆盖 220ms 入场 + 320ms 形变窗 + 余量
const Duration _sceneSpan = Duration(milliseconds: 640);

/// 60Hz 单帧预算（与 integration_test 的 missed_frame_build_budget 同口径）
const double _frameBudgetMs = 1000 / 60;

late MockOrbitBridge _bridge;
late IntegrationTestWidgetsFlutterBinding _binding;

Widget _host(Widget home) => ProviderScope(
  overrides: [orbitBridgeProvider.overrideWithValue(_bridge)],
  child: orbitTestApp(home: OrbitGlassPage(child: home)),
);

/// 逐帧推进 [total]（不用 `pumpAndSettle`：它会把动画压成一帧，
/// 就采不到中间帧的构建耗时）
Future<void> _pumpFor(WidgetTester tester, [Duration total = _sceneSpan]) async {
  const step = Duration(milliseconds: 16);
  final frames = total.inMilliseconds ~/ step.inMilliseconds;
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 等首屏数据落定（mock 零延迟，但仍要跨过 provider 的异步窗口与列表构建）
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

double _ms(Duration d) => d.inMicroseconds / 1000.0;

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round();
  return sorted[idx];
}

/// 一次测量：收集 [action] 期间引擎上报的全部帧，算 build/raster 两侧统计
Future<void> _measure(
  WidgetTester tester,
  String reportKey,
  Future<void> Function() action,
) async {
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);

  SchedulerBinding.instance.addTimingsCallback(collect);
  try {
    await action();
    // 引擎按帧批量上报；末尾两帧让最后一批回调落地后再摘监听
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 32));
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(collect);
  }

  final build = timings.map((t) => _ms(t.buildDuration)).toList()..sort();
  final raster = timings.map((t) => _ms(t.rasterDuration)).toList()..sort();
  final missedBuild = build.where((v) => v > _frameBudgetMs).length;
  final missedRaster = raster.where((v) => v > _frameBudgetMs).length;

  double avg(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
  double round3(double v) => double.parse(v.toStringAsFixed(3));

  final stats = <String, dynamic>{
    'frame_count': timings.length,
    'missed_frame_build_budget_count': missedBuild,
    'missed_frame_rasterizer_budget_count': missedRaster,
    'average_frame_build_time_millis': round3(avg(build)),
    '99th_percentile_frame_build_time_millis': round3(_percentile(build, 0.99)),
    'worst_frame_build_time_millis': build.isEmpty
        ? 0.0
        : round3(build.last),
    'average_frame_rasterizer_time_millis': round3(avg(raster)),
    '99th_percentile_frame_rasterizer_time_millis': round3(
      _percentile(raster, 0.99),
    ),
    'worst_frame_rasterizer_time_millis': raster.isEmpty
        ? 0.0
        : round3(raster.last),
  };
  _binding.reportData ??= <String, dynamic>{};
  _binding.reportData![reportKey] = stats;
  debugPrint(
    '[perf_jank] $reportKey frames=${stats['frame_count']} '
    'missedBuild=$missedBuild p99Build=${stats['99th_percentile_frame_build_time_millis']}ms '
    'avgRaster=${stats['average_frame_rasterizer_time_millis']}ms',
  );
}

void main() {
  _binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 月历/议程的中文日期格式依赖 intl 语言数据（生产入口 main.dart 装载；
    // 用例进程必须自己装一次，否则 CalendarScreen 首帧抛 LocaleDataException）
    await initializeDateFormatting('zh_CN');
    await initializeDateFormatting('en_US');
    _bridge = MockOrbitBridge()..latency = Duration.zero;
    await _bridge.devSeedDemoData(const DevSeedPlan(tasks: _seedTasks));
  });

  setUp(() => LocalPrefs.setString(viewModePrefsKey, TaskViewMode.list.name));
  tearDown(
    () => LocalPrefs.setString(viewModePrefsKey, TaskViewMode.list.name),
  );

  // profile 之外的档位一律跳过：不产出假数字（见文件头「口径诚实性」）。
  // `testWidgets.skip` 只吃 bool，原因写在 description 与文件头。
  final skip = !kProfileMode;

  testWidgets('sheet_open：快速添加面板入场（含自动聚焦起键盘）', (tester) async {
    await tester.pumpWidget(
      _host(
        const SubListScreen(
          query: TaskFilterInput(quickView: QuickViewKey.all),
        ),
      ),
    );
    await _settle(tester);

    await _measure(tester, 'sheet_open', () async {
      showQuickAddSheet(tester.element(find.byType(SubListScreen)));
      await _pumpFor(tester);
    });

    // 收场：面板挂在根 Navigator，必须推掉，否则下一个用例的帧里还有它
    await tester.pump(const Duration(milliseconds: 400));
    rootNavigatorKey.currentState?.pop();
    await _pumpFor(tester, const Duration(milliseconds: 320));
  }, skip: skip);

  testWidgets('menu_morph：页头 ⋮ 锚定菜单形变开合', (tester) async {
    await tester.pumpWidget(
      _host(
        const SubListScreen(
          query: TaskFilterInput(quickView: QuickViewKey.all),
        ),
      ),
    );
    await _settle(tester);

    await _measure(tester, 'menu_morph', () async {
      await tester.tap(find.byTooltip('更多操作'));
      await _pumpFor(tester);
      // 二级面板堆叠展开/收回（视图档）：2026-11-08 起形变窗口内降实色
      // （此前「只解冻不降材质」，二级面板 origin/size 逐帧变导致玻璃纹理
      // 缓存逐帧失效）——本段是该回归的防回归锚点
      await tester.tap(find.text('视图'));
      await _pumpFor(tester);
      await tester.tap(find.text('返回上级'));
      await _pumpFor(tester);
    });

    // 再点遮罩收起，让下一用例从干净状态起跑
    await tester.tapAt(const Offset(4, 4));
    await _pumpFor(tester, const Duration(milliseconds: 320));
  }, skip: skip);

  testWidgets('list_scroll：列表连续滑动 20 次', (tester) async {
    await tester.pumpWidget(
      _host(
        const SubListScreen(
          query: TaskFilterInput(quickView: QuickViewKey.all),
        ),
      ),
    );
    await _settle(tester);

    final list = find.byType(ReorderableListView);
    await _measure(tester, 'list_scroll', () async {
      for (var i = 0; i < 20; i++) {
        await tester.fling(list, const Offset(0, -320), 1400);
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.pump(const Duration(milliseconds: 200));
    });
  }, skip: skip);

  testWidgets('view_switch：列表 → 看板 AnimatedSwitcher 过渡', (tester) async {
    await tester.pumpWidget(
      _host(
        const SubListScreen(
          query: TaskFilterInput(quickView: QuickViewKey.all),
        ),
      ),
    );
    await _settle(tester);

    await _measure(tester, 'view_switch', () async {
      await tester.tap(find.byTooltip('更多操作'));
      await _pumpFor(tester, const Duration(milliseconds: 400));
      await tester.tap(find.text('视图'));
      await _pumpFor(tester, const Duration(milliseconds: 400));
      await tester.tap(find.text('看板视图'));
      await _pumpFor(tester);
    });
  }, skip: skip);

  testWidgets('calendar_page：月历连续翻 3 个月', (tester) async {
    await tester.pumpWidget(_host(const CalendarScreen()));
    await _settle(tester);

    final calendar = find.byType(OrbitMonthCalendar);
    await _measure(tester, 'calendar_page', () async {
      for (var i = 0; i < 3; i++) {
        await tester.drag(calendar, const Offset(-360, 0));
        await _pumpFor(tester, const Duration(milliseconds: 400));
      }
    });
  }, skip: skip);
}
