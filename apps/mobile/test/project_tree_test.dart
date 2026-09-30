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

  /// 模拟落库后重新拉取：按新 sortOrder 排序 → 按新 parentUuid 构树 → DFS 展平。
  /// 这是 planProjectDrop 的真实消费路径（列表查询按 sortOrder 升序），
  /// 断言它才能验出「顺序漂移」这类只有重建才暴露的缺陷。
  List<String> displayAfter(
    List<TodoProject> projects,
    int activeId,
    ProjectDropPlan plan,
  ) {
    final so = <int, int>{};
    for (var i = 0; i < plan.order.length; i++) {
      so[plan.order[i]] = i + 1;
    }
    final next = [
      for (final p in projects)
        TodoProject(
          id: p.id,
          uuid: p.uuid,
          title: p.title,
          description: p.description,
          hexColor: p.hexColor,
          sortOrder: (so[p.id] ?? p.sortOrder.round()).toDouble(),
          parentUuid: p.id == activeId ? plan.parentUuid : p.parentUuid,
          isArchived: p.isArchived,
          isDeleted: p.isDeleted,
          createdAt: p.createdAt,
          updatedAt: p.updatedAt,
          deletedAt: p.deletedAt,
          version: p.version,
        ),
    ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return [
      for (final n in flattenAll(next)) '${n.project.title}(${n.depth})',
    ];
  }

  group('collectDescendantIds / projectIdsWithDescendants', () {
    test('无子项：后代为空，集合只有自身', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      expect(collectDescendantIds([a, b], a.id), isEmpty);
      expect(projectIdsWithDescendants([a, b], a.id), [a.id]);
    });

    test('一层父子：集合 = 自身 + 子（自身排首位）', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙', parentUuid: 'a');
      expect(collectDescendantIds([a, b], a.id), [b.id]);
      expect(projectIdsWithDescendants([a, b], a.id), [a.id, b.id]);
    });

    test('三层嵌套：后代按 DFS 序（中 → 叶）', () {
      final a = proj('a', '根');
      final b = proj('b', '中', parentUuid: 'a');
      final c = proj('c', '叶', parentUuid: 'b');
      final d = proj('d', '独立');
      expect(projectIdsWithDescendants([a, b, c, d], a.id), [a.id, b.id, c.id]);
      expect(collectDescendantIds([a, b, c, d], b.id), [c.id]);
      expect(collectDescendantIds([a, b, c, d], d.id), isEmpty);
    });

    test('孤儿项目（父不存在）不算任何人的后代', () {
      final a = proj('a', '甲');
      final orphan = proj('x', '孤儿', parentUuid: 'missing');
      expect(collectDescendantIds([a, orphan], a.id), isEmpty);
    });

    test('id 不在列表里仍返回自身——项目列表未加载完时不能退化成空集', () {
      final a = proj('a', '甲');
      expect(collectDescendantIds([a], 999999), isEmpty);
      expect(projectIdsWithDescendants([a], 999999), [999999]);
    });
  });

  group('planProjectDrop', () {
    test('位移不足阈值 → 同级重排（保持原父）', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final c = proj('c', '丙');
      final list = [a, b, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: a.id,
        overId: c.id,
        deltaX: 0,
      );
      expect(plan, isNotNull);
      expect(plan!.kind, ProjectDropKind.reorder);
      expect(plan.parentUuid, isNull);
      expect(displayAfter(list, a.id, plan), ['乙(0)', '丙(0)', '甲(0)']);
    });

    test('向上拖 → 插到落点之前', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final c = proj('c', '丙');
      final list = [a, b, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: c.id,
        overId: a.id,
        deltaX: 0,
      )!;
      expect(plan.kind, ProjectDropKind.reorder);
      expect(displayAfter(list, c.id, plan), ['丙(0)', '甲(0)', '乙(0)']);
    });

    test('右移达阈值 → 内嵌为落点行的子项', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final c = proj('c', '丙');
      final list = [a, b, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: a.id,
        overId: c.id,
        deltaX: dragReparentPx,
      )!;
      expect(plan.kind, ProjectDropKind.nest);
      expect(plan.parentUuid, 'c');
      expect(displayAfter(list, a.id, plan), ['乙(0)', '丙(0)', '甲(1)']);
    });

    test('内嵌对象已有子项 → 排到子项末位（不插队）', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final b1 = proj('b1', '乙一', parentUuid: 'b');
      final b2 = proj('b2', '乙二', parentUuid: 'b');
      final list = [a, b, b1, b2];
      final plan = planProjectDrop(
        projects: list,
        activeId: a.id,
        overId: b.id,
        deltaX: 99,
      )!;
      expect(plan.kind, ProjectDropKind.nest);
      expect(plan.parentUuid, 'b');
      expect(displayAfter(list, a.id, plan), [
        '乙(0)',
        '乙一(1)',
        '乙二(1)',
        '甲(1)',
      ]);
    });

    test('内嵌到自身后代 → 成环被拒，回落同级重排', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙', parentUuid: 'a');
      final plan = planProjectDrop(
        projects: [a, b],
        activeId: a.id,
        overId: b.id,
        deltaX: 99,
      )!;
      expect(plan.kind, ProjectDropKind.reorder);
      expect(plan.parentUuid, isNull);
      expect(displayAfter([a, b], a.id, plan), ['甲(0)', '乙(1)']);
    });

    test('左移达阈值 → 提升一级，排在原父之后', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙', parentUuid: 'a');
      final c = proj('c', '丙');
      final list = [a, b, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: b.id,
        overId: a.id,
        deltaX: -dragReparentPx,
      )!;
      expect(plan.kind, ProjectDropKind.outdent);
      expect(plan.parentUuid, isNull);
      expect(displayAfter(list, b.id, plan), ['甲(0)', '乙(0)', '丙(0)']);
    });

    test('提升一级带子项 → 子树跟随，落位紧跟原父', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙', parentUuid: 'a');
      final b1 = proj('b1', '乙一', parentUuid: 'b');
      final c = proj('c', '丙');
      final list = [a, b, b1, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: b.id,
        overId: a.id,
        deltaX: -dragReparentPx,
      )!;
      expect(plan.kind, ProjectDropKind.outdent);
      expect(plan.parentUuid, isNull);
      expect(displayAfter(list, b.id, plan), [
        '甲(0)',
        '乙(0)',
        '乙一(1)',
        '丙(0)',
      ]);
    });

    test('已在顶层左移 → 无处可升，回落同级重排', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final c = proj('c', '丙');
      final list = [a, b, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: a.id,
        overId: b.id,
        deltaX: -99,
      )!;
      expect(plan.kind, ProjectDropKind.reorder);
      expect(plan.parentUuid, isNull);
      expect(displayAfter(list, a.id, plan), ['乙(0)', '甲(0)', '丙(0)']);
    });

    test('同级重排只在自身兄弟组内挪位：落在别组子树里 → 贴到该子树前后', () {
      final a = proj('a', '甲');
      final a1 = proj('a1', '甲一', parentUuid: 'a');
      final b = proj('b', '乙');
      final c = proj('c', '丙');
      final list = [a, a1, b, c];
      final plan = planProjectDrop(
        projects: list,
        activeId: c.id,
        overId: a1.id,
        deltaX: 0,
      )!;
      expect(plan.kind, ProjectDropKind.reorder);
      expect(plan.parentUuid, isNull);
      expect(displayAfter(list, c.id, plan), [
        '甲(0)',
        '甲一(1)',
        '丙(0)',
        '乙(0)',
      ]);
    });

    test('自定义阈值：位移 5 时默认阈值不触发、阈值 5 触发', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final c = proj('c', '丙');
      final list = [a, b, c];
      expect(
        planProjectDrop(
          projects: list,
          activeId: a.id,
          overId: c.id,
          deltaX: 5,
        )!.kind,
        ProjectDropKind.reorder,
      );
      expect(
        planProjectDrop(
          projects: list,
          activeId: a.id,
          overId: c.id,
          deltaX: 5,
          threshold: 5,
        )!.kind,
        ProjectDropKind.nest,
      );
    });

    test('自身拖自身 / 未知 id → null', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙');
      final list = [a, b];
      expect(
        planProjectDrop(
          projects: list,
          activeId: a.id,
          overId: a.id,
          deltaX: 99,
        ),
        isNull,
      );
      expect(
        planProjectDrop(
          projects: list,
          activeId: 999999,
          overId: a.id,
          deltaX: 99,
        ),
        isNull,
      );
      expect(
        planProjectDrop(
          projects: list,
          activeId: a.id,
          overId: 999999,
          deltaX: 99,
        ),
        isNull,
      );
    });

    test('order 恒为全量项目 id 的一个排列（不丢行、不重复）', () {
      final a = proj('a', '甲');
      final b = proj('b', '乙', parentUuid: 'a');
      final c = proj('c', '丙');
      final d = proj('d', '丁', parentUuid: 'c');
      final list = [a, b, c, d];
      final plan = planProjectDrop(
        projects: list,
        activeId: d.id,
        overId: b.id,
        deltaX: 99,
      )!;
      expect(plan.order.toSet(), {a.id, b.id, c.id, d.id});
      expect(plan.order.length, 4);
    });
  });
}
