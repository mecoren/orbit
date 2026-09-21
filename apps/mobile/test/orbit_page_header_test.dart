// 页头（OrbitPageHeader）状态栏避让口径：
// 页头由 `Positioned(top: 0)` 挂在页面 Stack 顶部，因此自身必须避让状态栏，
// 否则标题被状态栏压到顶部（各页内容区让位却是「状态栏 + rowHeight」）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';
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
}
