// taskAttachment* 桥契约回归：MockOrbitBridge 附件语义对齐
// crates/orbit-core/src/api/asset_api.rs——同任务同内容幂等（同 link）、
// 跨任务内容寻址共享 hash、上限 20、空内容拒绝、移除后列表为空。
// 与桌面 ipc-mock 的 task_attachment_* 同构。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/dto.dart';

void main() {
  group('MockOrbitBridge 任务附件', () {
    test('添加 → 列表 → 读取未缓存 NotFound 链路', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge.todoTaskCreate(
        TodoTaskCreateInput(title: '附件测试'),
      );

      final view = await bridge.taskAttachmentAdd(
          task.id, '报告.pdf', 'application/pdf', [1, 2, 3]);
      expect(view.originalName, '报告.pdf');
      expect(view.sizeBytes, 3);
      expect(view.isLocalCached, 1);

      final list = await bridge.taskAttachmentsList(task.id);
      expect(list.length, 1);
      expect(list.first.hash, view.hash);

      // 读取（mock 返回空字节流，仅验证链路通）
      final bytes = await bridge.taskAttachmentRead(view.hash);
      expect(bytes, isEmpty);
    });

    test('同任务同内容幂等（同 link），不计上限', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge.todoTaskCreate(
        TodoTaskCreateInput(title: '幂等测试'),
      );

      final v1 = await bridge.taskAttachmentAdd(task.id, 'a.png', 'image/png', [9, 9]);
      final v2 = await bridge.taskAttachmentAdd(task.id, 'b.png', 'image/png', [9, 9]);
      expect(v1.linkId, v2.linkId, reason: '同内容必须幂等返回同一关联');
      expect((await bridge.taskAttachmentsList(task.id)).length, 1);
    });

    test('单任务上限 20 拒绝', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge.todoTaskCreate(
        TodoTaskCreateInput(title: '上限测试'),
      );
      for (var i = 0; i < 20; i++) {
        await bridge.taskAttachmentAdd(
            task.id, 'f$i.txt', 'text/plain', List.generate(i + 1, (j) => j));
      }
      expect(
        () => bridge.taskAttachmentAdd(task.id, 'over.txt', 'text/plain', [1, 2, 3]),
        throwsException,
      );
    });

    test('空内容拒绝', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge.todoTaskCreate(
        TodoTaskCreateInput(title: '空内容测试'),
      );
      expect(
        () => bridge.taskAttachmentAdd(task.id, 'e.txt', 'text/plain', <int>[]),
        throwsException,
      );
    });

    test('移除后列表为空', () async {
      final bridge = MockOrbitBridge();
      final task = await bridge.todoTaskCreate(
        TodoTaskCreateInput(title: '移除测试'),
      );
      final view = await bridge.taskAttachmentAdd(task.id, 'x.txt', 'text/plain', [7]);
      await bridge.taskAttachmentRemove(view.linkId);
      expect((await bridge.taskAttachmentsList(task.id)).length, 0);
    });
  });
}
