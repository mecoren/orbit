// 锚定选择菜单原语（orbit_menu_popup）：承载/行样式、锚点落位与翻转、
// 点选/点外关闭、多选常驻、无锚点兜底
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_menu_popup.dart';
import 'support/orbit_test_app.dart';

/// 浮层内容节点（库内 dropdown 以内容尺寸布局，矩形即卡面落定矩形）
Finder _popup() => find.byKey(orbitSelectPopupKey);

void main() {
  testWidgets('承载与行：MiuixGlassDropdownPopup + MiuixGlassPopupItem', (
    tester,
  ) async {
    Rect? anchor;
    OrbitMenuSession? session;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  session = showOrbitMenuPopup(
                    context,
                    anchor: anchor,
                    groupsBuilder: () => [
                      [
                        const OrbitPanelItem(label: '今天', checked: true),
                        const OrbitPanelItem(label: '明天'),
                      ],
                    ],
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    anchor = tester.getRect(find.byType(TextButton));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    // 承载是库内 OS4 dropdown（形变进场与收紧），行与页头 ⋮ 菜单同源
    expect(find.byType(MiuixGlassDropdownPopup), findsOneWidget);
    expect(find.byType(MiuixGlassPopupItem), findsNWidgets(2));
    expect(find.byType(MiuixGlassPanel), findsOneWidget);
    expect(_popup(), findsOneWidget);

    session!.close();
    await tester.pumpAndSettle();
    expect(find.byType(MiuixGlassDropdownPopup), findsNothing);
    expect(_popup(), findsNothing);
  });

  testWidgets('形变菜单关闭先播回收动画，结束后移除并恢复锚点', (tester) async {
    final anchor = MiuixGlassPopupAnchor();
    addTearDown(anchor.dispose);
    late OrbitMenuSession session;
    var closed = false;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => MiuixGlassAnchor(
                anchor: anchor,
                child: IconButton(
                  onPressed: () {
                    session = showOrbitMenuPopup(
                      context,
                      transformAnchor: anchor,
                      anchorContent: const Icon(Icons.more_horiz),
                      groupsBuilder: () => [
                        [const OrbitPanelItem(label: '今天')],
                      ],
                    );
                    session.closed.then((_) => closed = true);
                  },
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(anchor.contentHidden, isTrue);

    session.close();
    await tester.pump();
    final popup = tester.widget<MiuixGlassTransformPopup>(
      find.byType(MiuixGlassTransformPopup),
    );
    expect(popup.show, isFalse);
    expect(_popup(), findsOneWidget);
    expect(closed, isFalse);
    expect(anchor.contentHidden, isTrue);

    session.close();
    await tester.pumpAndSettle();
    expect(_popup(), findsNothing);
    expect(closed, isTrue);
    expect(anchor.contentHidden, isFalse);
  });

  testWidgets('首帧前关闭：无退场可播时直接清理不泄漏', (tester) async {
    final anchor = MiuixGlassPopupAnchor();
    addTearDown(anchor.dispose);
    late OrbitMenuSession session;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => MiuixGlassAnchor(
                anchor: anchor,
                child: IconButton(
                  onPressed: () => session = showOrbitMenuPopup(
                    context,
                    transformAnchor: anchor,
                    anchorContent: const Icon(Icons.more_horiz),
                    groupsBuilder: () => [
                      [const OrbitPanelItem(label: '今天')],
                    ],
                  ),
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 触发后不 pump：Overlay entry 尚未 build，也没有可播的退场
    await tester.tap(find.byType(IconButton));
    session.close();
    await tester.pumpAndSettle();
    expect(_popup(), findsNothing);
    expect(find.byType(MiuixGlassTransformPopup), findsNothing);
  });

  testWidgets('回收动画中强制销毁：立即移除且 closed 完成', (tester) async {
    final anchor = MiuixGlassPopupAnchor();
    addTearDown(anchor.dispose);
    late OrbitMenuSession session;
    var closed = false;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => MiuixGlassAnchor(
                anchor: anchor,
                child: IconButton(
                  onPressed: () {
                    session = showOrbitMenuPopup(
                      context,
                      transformAnchor: anchor,
                      anchorContent: const Icon(Icons.more_horiz),
                      groupsBuilder: () => [
                        [const OrbitPanelItem(label: '今天')],
                      ],
                    );
                    session.closed.then((_) => closed = true);
                  },
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    session.close();
    await tester.pump();
    expect(_popup(), findsOneWidget);

    session.dispose();
    await tester.pump();
    expect(_popup(), findsNothing);
    expect(closed, isTrue);
    expect(anchor.contentHidden, isFalse);
    // 库内退场的 icon 副本有 50ms delay Timer，销毁后不会取消，收尾排空
    await tester.pump(const Duration(milliseconds: 60));
  });

  testWidgets('贴触发钮下方弹出，右沿对齐', (tester) async {
    Rect? anchor;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 40),
                child: TextButton(
                  onPressed: () => showOrbitMenuPopup(
                    context,
                    anchor: anchor,
                    groupsBuilder: () => [
                      [
                        const OrbitPanelItem(label: '今天'),
                        const OrbitPanelItem(label: '明天'),
                      ],
                    ],
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    anchor = tester.getRect(find.byType(TextButton));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    final popup = tester.getRect(_popup());
    // 下方空间充足：贴锚点下沿（含 8 呼吸位），右沿对齐后钳在屏内
    expect(popup.top, closeTo(anchor.bottom + 8, 1));
    expect(popup.right, closeTo(anchor.right, 1));
  });

  testWidgets('下方放不下时翻到触发钮上方', (tester) async {
    Rect? anchor;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.bottomCenter,
              child: TextButton(
                onPressed: () => showOrbitMenuPopup(
                  context,
                  anchor: anchor,
                  groupsBuilder: () => [
                    [
                      for (var i = 0; i < 6; i++)
                        OrbitPanelItem(label: '档位 $i'),
                    ],
                  ],
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    anchor = tester.getRect(find.byType(TextButton));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    final popup = tester.getRect(_popup());
    // 上翻时卡底停在触发钮上沿 8px 之上（卡片不遮住按钮本身），
    // 且卡片上沿越过触发钮上沿——即真的翻到了上方
    expect(popup.bottom, lessThanOrEqualTo(anchor.top - 8 + 1));
    expect(popup.top, lessThan(anchor.top));
  });

  testWidgets('点行回调并关闭；会话 closed 完成', (tester) async {
    Rect? anchor;
    var picked = '';
    var closed = false;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  final session = showOrbitMenuPopup(
                    context,
                    anchor: anchor,
                    groupsBuilder: () => [
                      [
                        OrbitPanelItem(
                          label: '今天',
                          onTap: () => picked = 'today',
                        ),
                      ],
                    ],
                  );
                  session.closed.then((_) => closed = true);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    anchor = tester.getRect(find.byType(TextButton));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(picked, 'today');
    expect(closed, isTrue);
    expect(_popup(), findsNothing);
  });

  testWidgets('多选常驻：点行不关闭且勾选态就地刷新', (tester) async {
    Rect? anchor;
    final selected = <String>{};
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showOrbitMenuPopup(
                  context,
                  anchor: anchor,
                  closeOnTap: false,
                  groupsBuilder: () => [
                    [
                      for (final label in ['紧急', '阅读'])
                        OrbitPanelItem(
                          label: label,
                          checked: selected.contains(label),
                          onTap: () => selected.contains(label)
                              ? selected.remove(label)
                              : selected.add(label),
                        ),
                    ],
                  ],
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    anchor = tester.getRect(find.byType(TextButton));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('紧急'));
    await tester.pumpAndSettle();
    // 菜单常驻（可连选），勾选态由组件内部重取 groupsBuilder
    expect(_popup(), findsOneWidget);
    final row = tester.widget<MiuixGlassPopupItem>(
      find.ancestor(
        of: find.text('紧急'),
        matching: find.byType(MiuixGlassPopupItem),
      ),
    );
    expect(row.selected, isTrue);
    expect(selected, contains('紧急'));

    // 再点即取消
    await tester.tap(find.text('紧急'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  });

  testWidgets('点卡外关闭（不铺遮罩色）', (tester) async {
    Rect? anchor;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showOrbitMenuPopup(
                  context,
                  anchor: anchor,
                  groupsBuilder: () => [
                    [const OrbitPanelItem(label: '今天')],
                  ],
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    anchor = tester.getRect(find.byType(TextButton));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(_popup(), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(_popup(), findsNothing);
  });

  testWidgets('无锚点兜底：右上角形态不越界', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showOrbitMenuPopup(
                  context,
                  anchor: null,
                  groupsBuilder: () => [
                    [const OrbitPanelItem(label: '今天')],
                  ],
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final popup = tester.getRect(_popup());
    expect(popup.right, lessThanOrEqualTo(screen.width));
    expect(popup.left, greaterThan(0));
    expect(popup.top, greaterThan(0));
  });
}
