// 页头（OrbitPageHeader）状态栏避让口径：
// 页头由 `Positioned(top: 0)` 挂在页面 Stack 顶部，因此自身必须避让状态栏，
// 否则标题被状态栏压到顶部（各页内容区让位却是「状态栏 + rowHeight」）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_progressive_blur.dart';
import 'support/orbit_test_app.dart';

void main() {
  Future<void> pumpHeader(WidgetTester tester, {required double statusBar}) async {
    await tester.pumpWidget(orbitTestApp(
      home: MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(top: statusBar)),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OrbitPageHeader(title: '日历'),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('页头避让状态栏：占高 = 状态栏 + rowHeight，标题落在状态栏之下',
      (tester) async {
    await pumpHeader(tester, statusBar: 24);

    expect(
      tester.getSize(find.byType(OrbitPageHeader)).height,
      24 + OrbitPageHeader.rowHeight,
      reason: '表面铺满状态栏区域，与内容区让位口径一致',
    );
    expect(
      tester.getCenter(find.text('日历')).dy,
      closeTo(24 + OrbitPageHeader.rowHeight / 2, 1),
      reason: '标题行整体下移状态栏高度，不再贴顶',
    );
  });

  testWidgets('无状态栏（平板横屏等）：页头高度 = rowHeight', (tester) async {
    await pumpHeader(tester, statusBar: 0);

    expect(
      tester.getSize(find.byType(OrbitPageHeader)).height,
      OrbitPageHeader.rowHeight,
    );
  });

  testWidgets('玻璃表面：铺满整栏的渐进模糊层，前景 Material 不再画实色底',
      (tester) async {
    await pumpHeader(tester, statusBar: 24);

    final blurFinder = find.descendant(
      of: find.byType(OrbitPageHeader),
      matching: find.byType(OrbitProgressiveBlur),
    );
    expect(blurFinder, findsOneWidget);
    expect(
      tester.getSize(blurFinder),
      tester.getSize(find.byType(OrbitPageHeader)),
      reason: '模糊层铺满状态栏 + 标题行，标题栏与状态栏连成一片',
    );

    // 标题行只承载水波（透明 Material）：不透明底色会挡住下方模糊层，
    // 表现为「页头永远是实色」。
    final surface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(OrbitPageHeader),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.type, MaterialType.transparency);
  });

  testWidgets('进度线：传 progress 出 2px 主题色线，null 不渲染', (tester) async {
    Future<void> pumpWith(double? progress) async {
      await tester.pumpWidget(orbitTestApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 0)),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: OrbitPageHeader(title: '任务', progress: progress),
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    // 进度线是页头内唯一的 FractionallySizedBox（宽度因子 = 进度值）
    final line = find.byType(FractionallySizedBox);

    // 无进度：不渲染
    await pumpWith(null);
    expect(line, findsNothing);

    // 有进度：恰一条 2px 线，宽度 = 页宽 × 进度
    //（FractionallySizedBox 自身撑满父宽，宽度因子作用在子 Container 上）
    await pumpWith(0.5);
    expect(line, findsOneWidget);
    final pageWidth = tester.getSize(find.byType(OrbitPageHeader)).width;
    final bar = find.descendant(of: line, matching: find.byType(Container)).first;
    expect(tester.getSize(bar).width, closeTo(pageWidth * 0.5, 1.5));
  });
}
