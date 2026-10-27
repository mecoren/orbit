// 窗口化桥面契约（mock 侧）：分页谓词/游标与看板组键必须与 core
// `build_task_where` / `board_group_expr` 同口径。真实 Rust 桥由
// `cargo test -p orbit-core` 的 predicate/keyset/board 用例守护，这里只锁
// 移动端 MockOrbitBridge 这面镜子——镜像漂移会让 widget 测试假绿。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';

const int _day = 86400000;

void main() {
  late MockOrbitBridge bridge;
  late int base;

  /// 造一条任务，返回 id
  int mk({
    String title = 't',
    int? projectId,
    int priority = 0,
    int done = 0,
    int? due,
    int? start,
    int? doneAt,
    int? myDay,
    int favorite = 0,
  }) {
    final id = (bridge.store.tasks.keys.fold<int>(0, (a, b) => a > b ? a : b)) + 1;
    bridge.store.tasks[id] = <String, dynamic>{
      ...bridge.store.newEntity('f'),
      'id': id,
      'title': '$title-$id',
      'description': null,
      'project_id': projectId,
      'priority': priority,
      'status': done == 1 ? 'done' : 'pending',
      'done': done,
      'done_at': doneAt,
      'due_date': due,
      'start_date': start,
      'repeat_after': 1,
      'repeat_mode': 0,
      'hex_color': '',
      'percent_done': 0,
      'position': id.toDouble(),
      'is_favorite': favorite,
      'my_day_date': myDay,
      'is_deleted': 0,
      'created_at': base + id,
      'updated_at': base + id,
      'deleted_at': null,
      'version': 1,
    };
    return id;
  }

  setUp(() {
    bridge = MockOrbitBridge();
    bridge.store.tasks.clear();
    base = DateTime(2026, 10, 20).millisecondsSinceEpoch;
  });

  group('todoTaskPage：谓词下推', () {
    test('done=false/true 与 project_ids 集合谓词', () async {
      mk(title: '未完成', projectId: 7);
      mk(title: '已完成', done: 1, doneAt: base);
      mk(title: '其他项目', projectId: 8);

      final undone = await bridge.todoTaskPage(
        const ListFilter(done: false),
        null,
        100,
      );
      expect(undone.items.map((t) => t.title), ['未完成-1', '其他项目-3']);

      final done = await bridge.todoTaskPage(
        const ListFilter(done: true),
        null,
        100,
      );
      expect(done.items.single.title, '已完成-2');

      final scoped = await bridge.todoTaskPage(
        const ListFilter(done: false, projectIds: [7]),
        null,
        100,
      );
      expect(scoped.items.single.title, '未完成-1');
    });

    test('start 区间：NULL 不命中（日历时间轴按块起点取数）', () async {
      mk(title: '范围内', start: base + 1000);
      mk(title: '范围前', start: base - _day);
      mk(title: '无开始');

      final page = await bridge.todoTaskPage(
        ListFilter(startFrom: base, startTo: base + _day),
        null,
        100,
      );
      expect(page.items.single.title, '范围内-1');
    });

    test('exclude_due_before 保留无截止行', () async {
      mk(title: '逾期', due: base - _day);
      mk(title: '未来', due: base + _day);
      mk(title: '无截止');

      final page = await bridge.todoTaskPage(
        ListFilter(excludeDueBefore: base),
        null,
        100,
      );
      // 排序口径由调用方 filter 决定，这里只锁谓词命中集合
      expect(page.items.map((t) => t.title).toSet(), {'未来-2', '无截止-3'});
    });
  });

  group('todoTaskPage：键集游标', () {
    test('首页 limit + 次页游标续拉不重不漏', () async {
      for (var i = 0; i < 5; i++) {
        mk(title: '任务$i');
      }
      final first = await bridge.todoTaskPage(
        const ListFilter(sortKey: 'manual', sortDir: 'asc'),
        null,
        2,
      );
      expect(first.items.length, 2);
      expect(first.hasMore, isTrue);
      expect(first.nextCursor, isNotNull);

      final second = await bridge.todoTaskPage(
        const ListFilter(sortKey: 'manual', sortDir: 'asc'),
        first.nextCursor,
        2,
      );
      expect(second.items.length, 2);
      final ids = {...first.items.map((t) => t.id), ...second.items.map((t) => t.id)};
      expect(ids.length, 4); // 无重复
    });

    test('done_at 档可续拉（Logbook）', () async {
      mk(title: '早', done: 1, doneAt: base);
      mk(title: '晚', done: 1, doneAt: base + 1000);

      final page = await bridge.todoTaskPage(
        const ListFilter(done: true, sortKey: 'done_at', sortDir: 'desc'),
        null,
        100,
      );
      expect(page.items.map((t) => t.title), ['晚-2', '早-1']);
    });
  });

  group('todoTaskBoard：组键与每列上限', () {
    test('项目档：{id}/ungrouped；每列限额但 total 报真实数', () async {
      for (var i = 0; i < 3; i++) {
        mk(projectId: 7);
      }
      mk();

      final board = await bridge.todoTaskBoard(
        const ListFilter(done: false),
        TodoBoardGroupBy.project,
        2,
        base,
        base + _day,
      );
      final byKey = {for (final g in board.groups) g.key: g};
      expect(byKey['7']!.total, 3);
      expect(byKey['7']!.items.length, 2);
      expect(byKey['ungrouped']!.total, 1);
      expect(board.total, 4);
    });

    test('四象限：done 不入桶，紧急 = due < 明日零点', () async {
      mk(priority: 4, due: base); // 紧急且重要
      mk(priority: 1, due: base); // 紧急不重要
      mk(priority: 4); // 重要不紧急
      mk(priority: 1, done: 1, doneAt: base); // 完成：不入桶

      final board = await bridge.todoTaskBoard(
        const ListFilter(),
        TodoBoardGroupBy.quadrant,
        10,
        base,
        base + _day,
      );
      final byKey = {for (final g in board.groups) g.key: g};
      expect(byKey['urgentImportant']!.total, 1);
      expect(byKey['urgentNotImportant']!.total, 1);
      expect(byKey['importantNotUrgent']!.total, 1);
      expect(byKey['neither'], isNull); // 空组不返回（与 core 只回有行组同口径）
    });

    test('优先级档：pri:{n} 六档内取，越界落 pri:0', () async {
      mk(priority: 3);
      mk(priority: 9);

      final board = await bridge.todoTaskBoard(
        const ListFilter(),
        TodoBoardGroupBy.priority,
        10,
        base,
        base + _day,
      );
      final byKey = {for (final g in board.groups) g.key: g};
      expect(byKey['pri:3']!.total, 1);
      expect(byKey['pri:0']!.total, 1);
    });
  });
}
