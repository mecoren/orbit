import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/project_tree.dart';

/// M8 清单文件夹分组：项目树构建纯函数
///
/// 覆盖：层级归位、孤儿/自引用/成环回落顶层、折叠展平、候选排除自身与后代。
void main() {
  var seq = 0;
  TodoProject proj(String uuid, String title, {String? parentUuid}) {
    seq += 1;
    return TodoProject(
      id: seq,
      uuid: uuid,
      title: title,
      description: null,
      hexColor: '#3B82F6',
      sortOrder: seq.toDouble(),
      parentUuid: parentUuid,
      isArchived: 0,
      isDeleted: 0,
      createdAt: 1,
      updatedAt: 1,
      deletedAt: null,
      version: 1,
    );
  }

  List<ProjectTreeNode> flattenAll(List<TodoProject> projects) =>
      flattenProjectTree(buildProjectTree(projects), (_) => false);

  group('normalizeParentUuid', () {
    test('空值/空白一律归 null（顶层）', () {
      expect(normalizeParentUuid(null), isNull);
      expect(normalizeParentUuid(''), isNull);
      expect(normalizeParentUuid('   '), isNull);
    });

    test('有效 uuid 去空白保留', () {
      expect(normalizeParentUuid('abc'), 'abc');
      expect(normalizeParentUuid('  abc  '), 'abc');
    });
  });

  group('buildProjectTree', () {
    test('空输入返回空数组', () {
      expect(buildProjectTree(const []), isEmpty);
    });

    test('全顶层：顺序保持，depth 全 0', () {
      final tree = buildProjectTree([
        proj('a', '甲'),
        proj('b', '乙'),
        proj('c', '丙'),
      ]);
      expect(tree.map((n) => n.project.title).toList(), ['甲', '乙', '丙']);
      expect(tree.every((n) => n.depth == 0), isTrue);
      expect(tree.every((n) => n.children.isEmpty), isTrue);
    });

    test('一层父子：子挂父下，父提为顶层（输入顺序颠倒也成立）', () {
      final tree = buildProjectTree([
        proj('b', '子', parentUuid: 'a'),
        proj('a', '父'),
      ]);
      expect(tree, hasLength(1));
      expect(tree[0].project.title, '父');
      expect(tree[0].depth, 0);
      expect(tree[0].children, hasLength(1));
      expect(tree[0].children[0].project.title, '子');
      expect(tree[0].children[0].depth, 1);
    });

    test('三层嵌套 depth 依次 0/1/2', () {
      final nodes = flattenProjectTree(
        buildProjectTree([
          proj('a', '根'),
          proj('b', '中', parentUuid: 'a'),
          proj('c', '叶', parentUuid: 'b'),
        ]),
        (_) => false,
      );
      expect(nodes.map((n) => [n.project.title, n.depth]).toList(), [
        ['根', 0],
        ['中', 1],
        ['叶', 2],
      ]);
    });

    test('孤儿（父 uuid 不存在）回落顶层，行不丢', () {
      final tree = buildProjectTree([
        proj('a', '甲'),
        proj('b', '乙', parentUuid: 'ghost'),
      ]);
      expect(tree.map((n) => n.project.title).toList(), ['甲', '乙']);
      expect(tree[1].depth, 0);
    });

    test('自引用回落顶层', () {
      final tree = buildProjectTree([proj('a', '甲', parentUuid: 'a')]);
      expect(tree, hasLength(1));
      expect(tree[0].depth, 0);
    });

    test('空白 parentUuid 回落顶层', () {
      final tree = buildProjectTree([proj('a', '甲', parentUuid: '   ')]);
      expect(tree[0].depth, 0);
    });

    test('二元环：环上两个节点整体回落顶层（不产生悬挂）', () {
      final tree = buildProjectTree([
        proj('a', '甲', parentUuid: 'b'),
        proj('b', '乙', parentUuid: 'a'),
      ]);
      expect(tree.map((n) => n.project.title).toSet(), {'甲', '乙'});
      expect(tree.every((n) => n.depth == 0), isTrue);
      expect(tree.every((n) => n.children.isEmpty), isTrue);
    });

    test('三元环：环上三个节点整体回落顶层', () {
      final tree = buildProjectTree([
        proj('a', '甲', parentUuid: 'c'),
        proj('b', '乙', parentUuid: 'a'),
        proj('c', '丙', parentUuid: 'b'),
      ]);
      expect(tree, hasLength(3));
      expect(tree.every((n) => n.depth == 0), isTrue);
    });

    test('环外挂子：环回落顶层，挂在环上节点的子树仍完整', () {
      final tree = buildProjectTree([
        proj('a', '甲', parentUuid: 'b'),
        proj('b', '乙', parentUuid: 'a'),
        proj('c', '丙', parentUuid: 'a'),
      ]);
      final rootA = tree.firstWhere((n) => n.project.title == '甲');
      expect(rootA.depth, 0);
      expect(rootA.children.map((n) => n.project.title).toList(), ['丙']);
      expect(rootA.children[0].depth, 1);
    });

    test('同层保持输入相对顺序', () {
      final tree = buildProjectTree([
        proj('r', '根'),
        proj('c2', '子二', parentUuid: 'r'),
        proj('c1', '子一', parentUuid: 'r'),
      ]);
      expect(tree[0].children.map((n) => n.project.title).toList(), [
        '子二',
        '子一',
      ]);
    });

    test('每个节点只归属一处：展平数量等于输入数量', () {
      final projects = [
        proj('r', '根'),
        proj('a', '甲', parentUuid: 'r'),
        proj('b', '乙', parentUuid: 'a'),
        proj('x', '独立'),
      ];
      expect(flattenAll(projects), hasLength(projects.length));
    });

    test('uuid 为空串的项目不参与父查找（按顶层处置）', () {
      final tree = buildProjectTree([
        proj('', '无 uuid'),
        proj('a', '甲', parentUuid: ''),
      ]);
      expect(tree.map((n) => n.project.title).toList(), ['无 uuid', '甲']);
    });
  });

  group('flattenProjectTree', () {
    List<TodoProject> sample() => [
      proj('a', '根'),
      proj('b', '子', parentUuid: 'a'),
      proj('c', '孙', parentUuid: 'b'),
      proj('d', '独立'),
    ];

    test('不折叠：父在前，子孙紧随其后', () {
      expect(flattenAll(sample()).map((n) => n.project.title).toList(), [
        '根',
        '子',
        '孙',
        '独立',
      ]);
    });

    test('折叠顶层父：子孙全部隐藏，其它分支不受影响', () {
      final flat = flattenProjectTree(
        buildProjectTree(sample()),
        (uuid) => uuid == 'a',
      );
      expect(flat.map((n) => n.project.title).toList(), ['根', '独立']);
    });

    test('折叠中间层：只隐藏其子树，根仍可见', () {
      final flat = flattenProjectTree(
        buildProjectTree(sample()),
        (uuid) => uuid == 'b',
      );
      expect(flat.map((n) => n.project.title).toList(), ['根', '子', '独立']);
    });

    test('折叠叶子节点无副作用（本来就没有子孙）', () {
      final flat = flattenProjectTree(
        buildProjectTree(sample()),
        (uuid) => uuid == 'c',
      );
      expect(flat, hasLength(4));
    });
  });

  group('collectDescendantUuids', () {
    List<TodoProject> sample() => [
      proj('a', '根'),
      proj('b', '子', parentUuid: 'a'),
      proj('c', '孙', parentUuid: 'b'),
      proj('d', '独立'),
    ];

    test('返回全部后代（不含自身）', () {
      expect(collectDescendantUuids(sample(), 'a'), {'b', 'c'});
    });

    test('中间层只含其子树', () {
      expect(collectDescendantUuids(sample(), 'b'), {'c'});
    });

    test('叶子返回空集；不存在的 uuid 也返回空集', () {
      expect(collectDescendantUuids(sample(), 'c'), isEmpty);
      expect(collectDescendantUuids(sample(), 'ghost'), isEmpty);
    });
  });

  group('parentFolderCandidates', () {
    List<TodoProject> sample() => [
      proj('a', '根'),
      proj('b', '子', parentUuid: 'a'),
      proj('c', '孙', parentUuid: 'b'),
      proj('d', '独立'),
    ];

    test('编辑根：排除自身与全部后代，只剩无关项目', () {
      expect(
        parentFolderCandidates(sample(), 'a').map((p) => p.uuid).toList(),
        ['d'],
      );
    });

    test('编辑中层：排除自身与后代，父与无关项保留', () {
      expect(
        parentFolderCandidates(sample(), 'b').map((p) => p.uuid).toList(),
        ['a', 'd'],
      );
    });

    test('编辑叶子：排除自身，其余全保留', () {
      expect(
        parentFolderCandidates(sample(), 'c').map((p) => p.uuid).toList(),
        ['a', 'b', 'd'],
      );
    });

    test('新建（selfUuid = null）返回全量', () {
      expect(parentFolderCandidates(sample(), null), hasLength(4));
    });
  });

  group('buildFolderPathLabels', () {
    test('层级路径用 / 拼接，顶层为纯标题', () {
      final labels = buildFolderPathLabels(
        buildProjectTree([
          proj('a', '根'),
          proj('b', '子', parentUuid: 'a'),
          proj('c', '孙', parentUuid: 'b'),
          proj('d', '独立'),
        ]),
      );
      expect(labels['a'], '根');
      expect(labels['b'], '根 / 子');
      expect(labels['c'], '根 / 子 / 孙');
      expect(labels['d'], '独立');
    });
  });
}
