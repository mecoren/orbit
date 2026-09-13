// 项目归档三端口径回归（mock 桥契约层）：默认列表排除归档、归档列表
// 独立入口、patchJson 翻转、恢复归零——对齐 Rust business_api::project_archive_tests。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';

void main() {
  group('MockOrbitBridge 项目归档', () {
    test('归档后退出默认列表 + 进归档列表', () async {
      final bridge = MockOrbitBridge();
      final p = await bridge
          .todoProjectCreate(const TodoProjectCreateInput(title: '旧项目'));

      // 归档前在列
      var list = await bridge
          .todoProjectList(const ListFilter(pageSize: 1000));
      expect(list.any((x) => x.id == p.id), isTrue);

      await bridge.todoProjectUpdate(p.id, '{"is_archived":1}');

      list = await bridge.todoProjectList(const ListFilter(pageSize: 1000));
      expect(list.any((x) => x.id == p.id), isFalse);
      final archived = await bridge.todoProjectListArchived();
      expect(
        archived.any((x) => x.id == p.id && x.isArchived == 1),
        isTrue,
      );
    });

    test('恢复归档回主列表 + 归档区清空', () async {
      final bridge = MockOrbitBridge();
      final p = await bridge
          .todoProjectCreate(const TodoProjectCreateInput(title: '再启用'));
      await bridge.todoProjectUpdate(p.id, '{"is_archived":1}');
      await bridge.todoProjectUpdate(p.id, '{"is_archived":0}');

      final list = await bridge
          .todoProjectList(const ListFilter(pageSize: 1000));
      expect(list.any((x) => x.id == p.id && x.isArchived == 0), isTrue);
      expect(await bridge.todoProjectListArchived(), isEmpty);
    });

    test('软删项目不出现在归档列表（墓碑优先于归档）', () async {
      final bridge = MockOrbitBridge();
      final p = await bridge
          .todoProjectCreate(const TodoProjectCreateInput(title: '归档又删'));
      await bridge.todoProjectUpdate(p.id, '{"is_archived":1}');
      await bridge.todoProjectDelete(p.id);
      expect(await bridge.todoProjectListArchived(), isEmpty);
    });
  });
}
