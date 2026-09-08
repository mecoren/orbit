// savedFilters* 桥契约回归：MockOrbitBridge 筛选器语义对齐
// crates/orbit-core/src/api/saved_filter_api.rs——创建校验/列表/删除。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/dto.dart';

void main() {
  group('MockOrbitBridge 保存的筛选器', () {
    test('创建 → 列表 → 删除 roundtrip', () async {
      final bridge = MockOrbitBridge();
      final created = await bridge.savedFilterCreate('本周紧急', '{"priority_min":4}');
      expect(created.name, '本周紧急');
      expect(created.conditions, contains('priority_min'));

      final list = await bridge.savedFiltersList();
      expect(list.length, 1);

      await bridge.savedFilterDelete(created.id);
      expect((await bridge.savedFiltersList()).length, 0);
    });

    test('空名称拒绝', () async {
      final bridge = MockOrbitBridge();
      expect(
        () => bridge.savedFilterCreate('  ', '{}'),
        throwsException,
      );
    });
  });
}
