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
}
