// 页级返回历史单测：空栈 / 基线 / 相邻去重 / 多级回退 / 栈深上限 /
// 不可变语义 / 同帧快速连点幂等。
//
// 判定规则（与 `orbit_back_dispatch.dart` 同口径）：栈内只记模块分支访问序列，
// 末位 = 当前模块；长度 > 1 才算「存在上一个操作页面」。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/orbit_back_dispatch.dart';
import 'package:orbit/modules/shell/nav_modules.dart';

void main() {
  group('OrbitNavHistory', () {
    test('空历史：无上一页，pop 不改变状态', () {
      const history = OrbitNavHistory.empty;

      expect(history.isEmpty, isTrue);
      expect(history.hasPrevious, isFalse);
      expect(history.current, isNull);
      expect(history.previous, isNull);
      expect(history.withoutCurrent(), same(history));
    });

    test('首次访问只建立基线，不产生上一页', () {
      final history = OrbitNavHistory.empty.withVisit(2);

      expect(history.depth, 1);
      expect(history.current, 2);
      expect(history.hasPrevious, isFalse);
    });

    test('A→B：上一页是 A', () {
      final history = OrbitNavHistory.empty
          .withVisit(0)
          .withVisit(3);

      expect(history.hasPrevious, isTrue);
      expect(history.previous, 0);
      expect(history.current, 3);
    });

    test('相邻同址去重：重复访问同一模块不增长栈', () {
      final history = OrbitNavHistory.empty
          .withVisit(1)
          .withVisit(1)
          .withVisit(1);

      expect(history.depth, 1);
      expect(history.hasPrevious, isFalse);
    });

    test('A→B→C 连续回退依次到 B、A，最后无上一页', () {
      var history = OrbitNavHistory.empty
          .withVisit(0)
          .withVisit(2)
          .withVisit(5);

      expect(history.previous, 2);
      history = history.withoutCurrent();
      expect(history.current, 2);
      expect(history.previous, 0);

      history = history.withoutCurrent();
      expect(history.current, 0);
      expect(history.hasPrevious, isFalse);

      expect(history.withoutCurrent(), same(history));
    });

    test('外部直达基线：空栈登记首页后仍无上一页', () {
      final baseline = OrbitNavHistory.empty.withBaseline(0);
      expect(baseline.current, 0);
      expect(baseline.hasPrevious, isFalse);

      final detached = baseline.withVisit(6);
      // 非空栈不覆写基线，后续访问按正常入栈处理
      expect(detached.current, 6);
      expect(detached.previous, 0);
      expect(detached.withBaseline(3), same(detached));
    });

    test('栈深上限：超过上限裁掉最老访问，仍保留最近序列', () {
      var history = OrbitNavHistory.empty;
      for (var i = 0; i < OrbitNavHistory.maxDepth + 10; i++) {
        history = history.withVisit(i % 7);
      }

      expect(history.depth, OrbitNavHistory.maxDepth);
      expect(history.hasPrevious, isTrue);
      expect(history.branches.length, OrbitNavHistory.maxDepth);
      expect(
        history.branches.last,
        (OrbitNavHistory.maxDepth + 9) % 7,
      );
    });

    test('不可变：withVisit 返回新实例且不改动原实例', () {
      const first = OrbitNavHistory.empty;
      final second = first.withVisit(1);
      final third = second.withVisit(2);

      expect(first.depth, 0);
      expect(second.depth, 1);
      expect(third.depth, 2);
      expect(third.branches, [1, 2]);
    });

    test('branches 快照不可写，外部改不动内部栈', () {
      final history = OrbitNavHistory.empty.withVisit(0).withVisit(1);
      final snapshot = history.branches;

      expect(() => snapshot.add(9), throwsUnsupportedError);
      expect(history.depth, 2);
    });

    test('启动首页基线：与 startupLocation 同源，且不产生「上一页」', () {
      expect(startupModule.path, startupLocation);

      final baseline =
          OrbitNavHistory.empty.withBaseline(startupModule.branchIndex);
      expect(baseline.current, startupModule.branchIndex);
      expect(baseline.hasPrevious, isFalse);
    });
  });

  group('OrbitNavHistoryController', () {
    test('同帧快速连点：popPrevious 只消费一条历史', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(orbitNavHistoryProvider.notifier);

      controller.recordVisit(0);
      controller.recordVisit(1);
      controller.recordVisit(2);

      expect(controller.popPrevious(), 1);
      // 同一帧（微任务尚未跑）的第二次返回必须被吞掉，不越级到 0
      expect(controller.popPrevious(), isNull);
      expect(container.read(orbitNavHistoryProvider).current, 1);

      // 下一帧恢复正常：每次返回消费一条
      await Future<void>.microtask(() {});
      expect(controller.popPrevious(), 0);
      expect(container.read(orbitNavHistoryProvider).hasPrevious, isFalse);
    });

    test('无上一页时 popPrevious 返回 null 且不改状态', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(orbitNavHistoryProvider.notifier);

      controller.ensureBaseline(0);
      expect(controller.popPrevious(), isNull);
      expect(container.read(orbitNavHistoryProvider).current, 0);
    });

    test('reset 清空历史', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(orbitNavHistoryProvider.notifier);

      controller.recordVisit(0);
      controller.recordVisit(1);
      controller.reset();

      expect(container.read(orbitNavHistoryProvider).isEmpty, isTrue);
    });
  });
}
