import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/subtask_tree.dart';

/// M10 子任务多层嵌套：子树构建纯函数（与桌面 subtask-tree.test.ts 同口径）
///
/// 覆盖：层级归位、孤儿/自引用/成环保底回落顶层、折叠展平。
void main() {
  var seq = 0;
  TodoSubtask sub(String uuid, String title, {String? parentUuid}) {
    seq += 1;
    return TodoSubtask(
      id: seq,
      uuid: uuid,
      taskId: 1,
      title: title,
      done: 0,
      doneAt: null,
      position: 0,
      parentUuid: parentUuid,
      isDeleted: 0,
      createdAt: 1,
      updatedAt: 1,
      deletedAt: null,
      version: 1,
    );
  }

  List<SubtaskTreeNode> flattenAll(List<TodoSubtask> subtasks) =>
      flattenSubtaskTree(buildSubtaskTree(subtasks), (_) => false);

  group('buildSubtaskTree', () {
    test('空输入返回空数组', () {
      expect(buildSubtaskTree([]), isEmpty);
    });

    test('全顶层：顺序保持，depth 全 0', () {
      final tree = buildSubtaskTree([sub('a', '甲'), sub('b', '乙'), sub('c', '丙')]);
      expect(tree.map((n) => n.subtask.title), ['甲', '乙', '丙']);
      expect(tree.every((n) => n.depth == 0), isTrue);
      expect(tree.every((n) => n.children.isEmpty), isTrue);
    });

    test('一层父子：子挂父下，父提为顶层（输入顺序颠倒也成立）', () {
      final tree = buildSubtaskTree([sub('b', '子', parentUuid: 'a'), sub('a', '父')]);
      expect(tree, hasLength(1));
      expect(tree[0].subtask.title, '父');
      expect(tree[0].depth, 0);
      expect(tree[0].children, hasLength(1));
      expect(tree[0].children[0].subtask.title, '子');
      expect(tree[0].children[0].depth, 1);
    });

    test('三层嵌套 depth 依次 0/1/2，DFS 父在前', () {
      final nodes = flattenAll([
        sub('a', '根'),
        sub('b', '中', parentUuid: 'a'),
        sub('c', '叶', parentUuid: 'b'),
      ]);
      expect(
        nodes.map((n) => [n.subtask.title, n.depth]),
        [
          ['根', 0],
          ['中', 1],
          ['叶', 2],
        ],
      );
    });

    test('多 sibling 按入参顺序（后端 position 序）展开', () {
      final nodes = flattenAll([
        sub('a', '父'),
        sub('x', '一', parentUuid: 'a'),
        sub('y', '二', parentUuid: 'a'),
        sub('z', '三', parentUuid: 'a'),
      ]);
      expect(
        nodes.map((n) => [n.subtask.title, n.depth]),
        [
          ['父', 0],
          ['一', 1],
          ['二', 1],
          ['三', 1],
        ],
      );
    });

    test('孤儿（父 uuid 不存在）回落顶层，行不丢', () {
      final tree = buildSubtaskTree([sub('a', '甲'), sub('b', '乙', parentUuid: 'ghost')]);
      expect(tree.map((n) => n.subtask.title), ['甲', '乙']);
      expect(tree[1].depth, 0);
    });

    test('自引用回落顶层', () {
      final tree = buildSubtaskTree([sub('a', '甲', parentUuid: 'a')]);
      expect(tree, hasLength(1));
      expect(tree[0].depth, 0);
    });

    test('空白 parent_uuid 回落顶层', () {
      final tree = buildSubtaskTree([sub('a', '甲', parentUuid: '   ')]);
      expect(tree[0].depth, 0);
    });

    test('二元环：环上两个节点整体回落顶层（不产生悬挂）', () {
      final tree = buildSubtaskTree([
        sub('a', '甲', parentUuid: 'b'),
        sub('b', '乙', parentUuid: 'a'),
      ]);
      final titles = tree.map((n) => n.subtask.title).toList()..sort();
      expect(titles, ['乙', '甲']);
      expect(tree.every((n) => n.depth == 0), isTrue);
      expect(tree.every((n) => n.children.isEmpty), isTrue);
    });

    test('三元环：环上三个节点整体回落顶层', () {
      final tree = buildSubtaskTree([
        sub('a', '甲', parentUuid: 'c'),
        sub('b', '乙', parentUuid: 'a'),
        sub('c', '丙', parentUuid: 'b'),
      ]);
      expect(tree, hasLength(3));
      expect(tree.every((n) => n.depth == 0 && n.children.isEmpty), isTrue);
    });

    test('环外节点挂在「被提顶层」的父下，子树不丢', () {
      // a↔b 成环；c→a 不在环上 → c 仍挂 a 下（a 已回落顶层）
      final nodes = flattenAll([
        sub('a', '甲', parentUuid: 'b'),
        sub('b', '乙', parentUuid: 'a'),
        sub('c', '丙', parentUuid: 'a'),
        sub('d', '丁', parentUuid: 'c'),
      ]);
      final byTitle = {for (final n in nodes) n.subtask.title: n};
      expect(byTitle['甲']!.depth, 0);
      expect(byTitle['乙']!.depth, 0);
      expect(byTitle['丙']!.depth, 1);
      expect(byTitle['丁']!.depth, 2);
    });

    test('重复 uuid 以首行为准（索引不覆盖；行不丢）', () {
      // uuid 重复时索引取首行；第二行自身 parentUuid='a' 仍可解析 → 挂到父下
      final tree = buildSubtaskTree([
        sub('a', '父'),
        sub('b', '子', parentUuid: 'a'),
        sub('b', '重名行', parentUuid: 'a'),
      ]);
      expect(tree, hasLength(1));
      expect(tree[0].subtask.title, '父');
      expect(tree[0].children.map((n) => n.subtask.title), ['子', '重名行']);
    });
  });

  group('flattenSubtaskTree', () {
    test('折叠判定跳过子树（预留能力，当前 UI 无折叠入口）', () {
      final tree = buildSubtaskTree([sub('a', '父'), sub('b', '子', parentUuid: 'a')]);
      final nodes = flattenSubtaskTree(tree, (uuid) => uuid == 'a');
      expect(nodes.map((n) => n.subtask.title), ['父']);
    });

    test('空树返回空', () {
      expect(flattenSubtaskTree(const [], (_) => false), isEmpty);
    });
  });
}
