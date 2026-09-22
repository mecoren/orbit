// 长按拖拽重排（#37）核心纯函数单测：
// - reorderItems：语义插入位移动/越界防御（侧栏项目段既有函数随迁用例）
// - midpointPosition：相邻 position 取中值（与桌面 shared/position.ts 同口径）
// widget 层断言（整行长按拾起/拖动落库/原地松手弹菜单）见 task_reorder_test.dart——依赖
// MockOrbitBridge 编译，须待并发会话工作区稳定后一并运行。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';

void main() {
  group('reorderItems（onReorderItem 语义插入位）', () {
    test('后移：oldIndex=0 → newIndex=2（已归一化，直接传）', () {
      final out = reorderItems(['a', 'b', 'c', 'd'], 0, 2);
      expect(out, ['b', 'c', 'a', 'd']);
    });

    test('前移：oldIndex=3 → newIndex=0', () {
      final out = reorderItems(['a', 'b', 'c', 'd'], 3, 0);
      expect(out, ['d', 'a', 'b', 'c']);
    });

    test('越界防御：返回原序拷贝不崩溃', () {
      final src = ['a', 'b'];
      expect(reorderItems(src, -1, 0), src);
      expect(reorderItems(src, 0, 5), src);
      expect(reorderItems(src, 2, 0), src);
    });
  });

  group('midpointPosition（与桌面 midpoint 同口径）', () {
    test('前后都缺省（唯一行）：0 与 100000 的中值 50000', () {
      expect(midpointPosition(null, null), 50000);
    });

    test('插到最前：prev 缺省视为 0', () {
      expect(midpointPosition(null, 100), 50);
    });

    test('插到最后：next 缺省视为 100000', () {
      expect(midpointPosition(100, null), 50050);
    });

    test('中间插入：两值取中', () {
      expect(midpointPosition(0, 100000), 50000);
      expect(midpointPosition(10, 20), 15);
    });

    test('f64 中值不丢精度（连拖同区间多次）', () {
      // 连续在同一区间拖拽：中值逐次逼近但不溢出 int 表达
      var mid = midpointPosition(0, 100000);
      mid = midpointPosition(0, mid);
      mid = midpointPosition(0, mid);
      expect(mid, 12500);
    });
  });
}
