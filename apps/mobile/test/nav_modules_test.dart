// 底部导航可配置模块：状态解析消毒 / 启停 / 区内重排 / 落盘口径（纯 Dart）
//
// 模块排布是壳层视图态（LocalPrefs 承载，不进 DB），这里直接驱动 provider
// 与序列化函数验证业务口径；底栏/面板的渲染联动见 home_shell_test.dart。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/shell/nav_modules.dart';
import 'package:orbit/services/local_prefs.dart';

void main() {
  setUp(() => LocalPrefs.resetForTest());

  NavModulesState stateOf(ProviderContainer container) =>
      container.read(navModulesProvider);

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('默认配置与解析消毒', () {
    test('未配置时落默认：八模块全启用，前四进底栏其余进面板', () {
      final container = makeContainer();
      final state = stateOf(container);
      expect(
        state.enabled,
        [OrbitNavModule.today, OrbitNavModule.sidebar,
         OrbitNavModule.calendar, OrbitNavModule.matrix, OrbitNavModule.stats,
         OrbitNavModule.search, OrbitNavModule.trash, OrbitNavModule.settings],
      );
      expect(state.disabled, isEmpty);
      expect(state.bottomTabs, hasLength(NavModulesState.bottomTabLimit));
      expect(state.morePanelItems,
          [OrbitNavModule.stats, OrbitNavModule.search,
           OrbitNavModule.trash, OrbitNavModule.settings]);
      // 启动落点 = 启用序第一个（顶层惰性求值，默认配置下即「今天」）
      expect(startupLocation, '/today');
    });

    test('序列化往返一致', () {
      final container = makeContainer();
      final state = stateOf(container);
      final parsed =
          NavModulesState.parse(LocalPrefs.getString(navModulesPrefsKey) ??
              '');
      expect(parsed.enabled, state.enabled);
      expect(parsed.disabled, state.disabled);
    });

    test('未知 id 剔除、去重、池内缺员补进停用区', () {
      final raw = '{"on": ["today", "ghost", "today", "calendar"],'
          '"off": ["settings", "nope"]}';
      final state = NavModulesState.parse(raw);
      expect(state.enabled,
          [OrbitNavModule.today, OrbitNavModule.calendar]);
      // sidebar/matrix/stats/search/trash 六个未提及成员全部补进停用区
      expect(state.disabled, [
        OrbitNavModule.settings,
        OrbitNavModule.sidebar,
        OrbitNavModule.matrix,
        OrbitNavModule.stats,
        OrbitNavModule.search,
        OrbitNavModule.trash,
      ]);
    });

    test('启用区清空回落默认；坏 JSON 回落默认', () {
      expect(NavModulesState.parse('{"on": [], "off": []}').enabled,
          NavModulesState.fallback().enabled);
      expect(NavModulesState.parse('not-json').enabled,
          NavModulesState.fallback().enabled);
      expect(NavModulesState.parse('').enabled,
          NavModulesState.fallback().enabled);
    });
  });

  group('启停', () {
    test('停用追加到停用区尾；启用追加到启用区尾（竞品同款）', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);

      // 停用「统计」（默认启用序第 5 位）：底栏前 4 不动，面板少一项
      await controller.toggle(OrbitNavModule.stats);
      var state = stateOf(container);
      expect(state.enabled.contains(OrbitNavModule.stats), false);
      expect(state.disabled, [OrbitNavModule.stats]);
      expect(state.morePanelItems, [OrbitNavModule.search,
        OrbitNavModule.trash, OrbitNavModule.settings]);
      expect(state.bottomTabs.first, OrbitNavModule.today);

      // 再启用：追加到启用区尾（排在「设置」后），面板重新出现
      await controller.toggle(OrbitNavModule.stats);
      state = stateOf(container);
      expect(state.enabled.last, OrbitNavModule.stats);
      expect(state.disabled, isEmpty);
      expect(state.morePanelItems.last, OrbitNavModule.stats);
    });

    test('最后一个启用模块不可停用', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      for (final m in OrbitNavModule.values) {
        if (m == OrbitNavModule.today) continue;
        await controller.toggle(m);
      }
      expect(stateOf(container).enabled, [OrbitNavModule.today]);

      await controller.toggle(OrbitNavModule.today);
      expect(stateOf(container).enabled, [OrbitNavModule.today]);
    });

    test('启停写后落盘，新容器读到同一状态', () async {
      final container = makeContainer();
      await container
          .read(navModulesProvider.notifier)
          .toggle(OrbitNavModule.trash);
      final persisted = LocalPrefs.getString(navModulesPrefsKey);
      expect(persisted, isNotNull);

      final container2 = makeContainer();
      // 新容器从落盘态重建：回收站停在停用区
      expect(stateOf(container2).enabled.contains(OrbitNavModule.trash), false);
      expect(stateOf(container2).disabled, [OrbitNavModule.trash]);
      expect(
        NavModulesState.parse(persisted!).enabled,
        stateOf(container2).enabled,
      );
    });
  });

  group('区内重排', () {
    test('启用区内拖拽（onReorderItem 语义插入位口径，无需再归一化）', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      // 把第 0 位「今天」拖到第 2 位（插入位 = 2）
      await controller.reorder(
          enabledSection: true, oldIndex: 0, newIndex: 2);
      expect(stateOf(container).enabled.take(4),
          [OrbitNavModule.sidebar, OrbitNavModule.calendar,
           OrbitNavModule.today, OrbitNavModule.matrix]);
    });

    test('停用区内拖拽互不影响启用区', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      await controller.toggle(OrbitNavModule.settings);
      await controller.toggle(OrbitNavModule.trash);
      expect(stateOf(container).disabled,
          [OrbitNavModule.settings, OrbitNavModule.trash]);
      // 把「回收站」拖到停用区首位
      await controller.reorder(
          enabledSection: false, oldIndex: 1, newIndex: 0);
      expect(stateOf(container).disabled.first, OrbitNavModule.trash);
      expect(stateOf(container).enabled, hasLength(6));
    });

    test('原位拖拽为无操作', () async {
      final container = makeContainer();
      final before = stateOf(container);
      await container.read(navModulesProvider.notifier).reorder(
          enabledSection: true, oldIndex: 1, newIndex: 1);
      expect(stateOf(container).enabled, before.enabled);
    });
  });

  group('跨段移动', () {
    test('停用按槽位插入停用区指定位置', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      // 把启用序第 5 位「统计」停用到停用区首位（默认停用区空）
      await controller.move(
          module: OrbitNavModule.stats, toEnabled: false, destSlot: 0);
      final state = stateOf(container);
      expect(state.enabled.contains(OrbitNavModule.stats), false);
      expect(state.disabled, [OrbitNavModule.stats]);
      // 启用序前 4（底栏）不受影响
      expect(state.bottomTabs, [
        OrbitNavModule.today,
        OrbitNavModule.sidebar,
        OrbitNavModule.calendar,
        OrbitNavModule.matrix,
      ]);
    });

    test('启用按槽位插入启用区指定位置', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      await controller.toggle(OrbitNavModule.settings);
      await controller.toggle(OrbitNavModule.trash);
      // 把「回收站」启用到启用区首位
      await controller.move(
          module: OrbitNavModule.trash, toEnabled: true, destSlot: 0);
      final state = stateOf(container);
      expect(state.enabled.first, OrbitNavModule.trash);
      expect(state.disabled, [OrbitNavModule.settings]);
    });

    test('槽位越界钳制到尾部', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      await controller.move(
          module: OrbitNavModule.today, toEnabled: false, destSlot: 99);
      final state = stateOf(container);
      expect(state.disabled, [OrbitNavModule.today]);
      expect(state.enabled.first, OrbitNavModule.sidebar);
    });

    test('最后一个启用模块不可停用', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      for (final m in OrbitNavModule.values) {
        if (m == OrbitNavModule.today) continue;
        await controller.toggle(m);
      }
      await controller.move(
          module: OrbitNavModule.today, toEnabled: false, destSlot: 0);
      expect(stateOf(container).enabled, [OrbitNavModule.today]);
    });

    test('同段调用退化为区内重排', () async {
      final container = makeContainer();
      final controller = container.read(navModulesProvider.notifier);
      await controller.move(
          module: OrbitNavModule.today, toEnabled: true, destSlot: 2);
      expect(stateOf(container).enabled.take(4), [
        OrbitNavModule.sidebar,
        OrbitNavModule.calendar,
        OrbitNavModule.today,
        OrbitNavModule.matrix,
      ]);
    });

    test('跨段移动写后落盘', () async {
      final container = makeContainer();
      await container.read(navModulesProvider.notifier).move(
          module: OrbitNavModule.trash, toEnabled: false, destSlot: 0);
      final persisted = LocalPrefs.getString(navModulesPrefsKey);
      expect(persisted, isNotNull);
      final container2 = makeContainer();
      expect(stateOf(container2).disabled, [OrbitNavModule.trash]);
    });
  });

  group('不变量（枚举序 = 路由分支序的契约）', () {
    test('branchIndex 恒等于枚举序；路径唯一且非空；文案唯一', () {
      final paths = <String>{};
      final labels = <String>{};
      for (final m in OrbitNavModule.values) {
        expect(m.branchIndex, m.index);
        expect(m.path, startsWith('/'));
        expect(paths.add(m.path), true, reason: '${m.path} 路径重复');
        expect(labels.add(m.label), true, reason: '${m.label} 文案重复');
      }
      // tryParse 与 name 双向一致
      for (final m in OrbitNavModule.values) {
        expect(OrbitNavModule.tryParse(m.name), m);
      }
      expect(OrbitNavModule.tryParse('ghost'), isNull);
    });

    test('模块池共 8 个，枚举序与路由分支声明序一致（app_router 契约）', () {
      // 路由侧按枚举序声明分支，这里锁定枚举序防无序改动
      expect(
        OrbitNavModule.values,
        [OrbitNavModule.today, OrbitNavModule.sidebar,
         OrbitNavModule.calendar, OrbitNavModule.matrix, OrbitNavModule.stats,
         OrbitNavModule.search, OrbitNavModule.trash, OrbitNavModule.settings],
      );
    });
  });
}
