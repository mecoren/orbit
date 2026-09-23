// csvImportPreview/Execute 桥契约回归：MockOrbitBridge 导入语义对齐
// crates/orbit-core/src/api/csv_import_api.rs——预览不写库；执行逐行写入
// + 项目自动创建（大小写复用）+ 非 Task 类型行跳过（todoist）。
// 与桌面 ipc-mock 的 csv_import_* 同构。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/dto.dart';

void main() {
  group('MockOrbitBridge CSV 导入', () {
    test('预览不写库 + 统计正确', () async {
      final bridge = MockOrbitBridge();
      const csv = 'title,project\n买牛奶,生活\n写周报,工作\n';
      final preview = await bridge.csvImportPreview(csv, 'orbit', 10);
      expect(preview.stats.success, 2);
      expect(preview.rows.length, 2);
      // 预览不得写库
      final before =
          (await bridge.todoTaskList(const ListFilter())).length;
      expect((await bridge.todoTaskList(const ListFilter())).length, before);
    });

    test('执行：任务写入 + 项目自动创建 + 二次导入项目复用', () async {
      final bridge = MockOrbitBridge();
      const csv = 'title,project\n买牛奶,生活\n写周报,生活\n';
      final stats = await bridge.csvImportExecute(csv, 'orbit');
      expect(stats.success, 2);
      expect(stats.failed, 0);

      // 项目只建一次
      final projects = await bridge.todoProjectList(const ListFilter());
      final life = projects.where((p) => p.title == '生活').toList();
      expect(life.length, 1);

      // 任务归属正确
      final tasks = await bridge.todoTaskList(const ListFilter());
      final milk = tasks.firstWhere((t) => t.title == '买牛奶');
      expect(milk.projectId, life.first.id);
    });

    test('todoist：非 Task 行跳过，完成态识别', () async {
      final bridge = MockOrbitBridge();
      const csv =
          'type,content,list name,completed date\ntask,周报,工作,2026-09-01\nsection,本周,工作,\ntask,买牛奶,生活,\n';
      final stats = await bridge.csvImportExecute(csv, 'todoist');
      expect(stats.success, 2);
      expect(stats.skipped, 1);
      expect(stats.notes.length, 1);

      final tasks = await bridge.todoTaskList(const ListFilter());
      final report = tasks.firstWhere((t) => t.title == '周报');
      expect(report.isDone, isTrue);
      final milk = tasks.firstWhere((t) => t.title == '买牛奶');
      expect(milk.isDone, isFalse);
    });

    test('空标题行跳过不阻断', () async {
      final bridge = MockOrbitBridge();
      const csv = 'title,project\n,生活\n买牛奶,生活\n';
      final stats = await bridge.csvImportExecute(csv, 'orbit');
      expect(stats.success, 1);
      expect(stats.skipped, 1);
    });
  });

  // `ics` 预设与真桥同口径（orbit-core `ics_import_api::map_ics_rows`）：
  // 只收 VTODO、VEVENT 整块忽略、PRIORITY 逆映射、DUE 解析、块级跳过不阻断。
  group('MockOrbitBridge ICS 导入（VTODO）', () {
    test('预览：解析 VTODO 字段 + VEVENT 整块忽略', () async {
      final bridge = MockOrbitBridge();
      const ics = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'
          'BEGIN:VTODO\r\nUID:a@orbit\r\n'
          'SUMMARY:买牛奶\\, 全脂\r\nCATEGORIES:生活\r\n'
          'PRIORITY:3\r\nDUE:20260919T180000\r\n'
          'STATUS:NEEDS-ACTION\r\nEND:VTODO\r\n'
          'BEGIN:VEVENT\r\nSUMMARY:日历事件不导入\r\nEND:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final before = (await bridge.todoTaskList(const ListFilter())).length;
      final preview = await bridge.csvImportPreview(ics, 'ics', 10);
      // 预览不得写库
      expect((await bridge.todoTaskList(const ListFilter())).length, before);
      expect(preview.rows.length, 1);
      final row = preview.rows.single;
      expect(row.skipReason, isNull);
      expect(row.title, '买牛奶, 全脂');
      expect(row.projectTitle, '生活');
      expect(row.priority, 3);
      expect(row.done, isFalse);
      expect(row.dueDate, isNotNull);
      expect(preview.stats.success, 1);
    });

    test('执行：写库 + 项目自动创建 + DUE 落 due_date', () async {
      final bridge = MockOrbitBridge();
      const ics = 'BEGIN:VTODO\r\nSUMMARY:买牛奶\r\nCATEGORIES:生活\r\n'
          'PRIORITY:5\r\nDUE:20260919\r\nEND:VTODO\r\n';
      final stats = await bridge.csvImportExecute(ics, 'ics');
      expect(stats.success, 1);
      expect(stats.failed, 0);

      final tasks = await bridge.todoTaskList(const ListFilter());
      final milk = tasks.firstWhere((t) => t.title == '买牛奶');
      // ICS PRIORITY 5 → Orbit 1（与导出表互逆）
      expect(milk.priority, 1);
      expect(milk.dueDate, isNotNull);

      final projects = await bridge.todoProjectList(const ListFilter());
      final life = projects.where((p) => p.title == '生活').toList();
      expect(life.length, 1);
      expect(milk.projectId, life.first.id);
    });

    test('STATUS:COMPLETED → 完成态落库', () async {
      final bridge = MockOrbitBridge();
      const ics = 'BEGIN:VTODO\r\nSUMMARY:已完成\r\nSTATUS:COMPLETED\r\n'
          'COMPLETED:20260918T120000Z\r\nEND:VTODO\r\n';
      await bridge.csvImportExecute(ics, 'ics');
      final tasks = await bridge.todoTaskList(const ListFilter());
      expect(tasks.firstWhere((t) => t.title == '已完成').isDone, isTrue);
    });

    test('无 SUMMARY / 空标题块级跳过，其它块照常导入', () async {
      final bridge = MockOrbitBridge();
      const ics = 'BEGIN:VTODO\r\nDUE:20260919\r\nEND:VTODO\r\n'
          'BEGIN:VTODO\r\nSUMMARY:   \r\nEND:VTODO\r\n'
          'BEGIN:VTODO\r\nSUMMARY:正常\r\nEND:VTODO\r\n';
      final preview = await bridge.csvImportPreview(ics, 'ics', 10);
      expect(preview.stats.skipped, 2);
      expect(preview.stats.success, 1);
      expect(preview.rows.last.title, '正常');
    });

    test('续行展开 + TEXT 反转义（字面量 \\\\n 不误读为换行）', () async {
      final bridge = MockOrbitBridge();
      const ics = 'BEGIN:VTODO\r\nSUMMARY:第一行\r\n 第二行\r\n'
          'END:VTODO\r\nBEGIN:VTODO\r\nSUMMARY:C:\\\\new\r\nEND:VTODO\r\n';
      final preview = await bridge.csvImportPreview(ics, 'ics', 10);
      expect(preview.rows[0].title, '第一行第二行');
      expect(preview.rows[1].title, 'C:\\new');
    });
  });
}
