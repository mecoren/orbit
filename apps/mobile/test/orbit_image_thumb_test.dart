// OrbitImageThumb 契约回归（docs/09 A9 附件缩略图）：
// 缩略图只吃「已在本机落地的图片字节」——null / 空字节流一律回落占位图标
// （mock 与云端未拉取都走这条），有字节才建 Image 并降采样解码。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/shared/widgets/shadcn/orbit_image_thumb.dart';

void main() {
  // 用仓库内真实 PNG（品牌图）作有效字节源，避免内置 base64 串失真风险
  final png = Uint8List.fromList(File('assets/app_icon.png').readAsBytesSync());

  Future<void> pumpThumb(WidgetTester tester, Uint8List? bytes) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OrbitImageThumb(
              size: 32,
              bytes: bytes,
              fallback: const Icon(Icons.insert_drive_file),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('无字节 → 占位图标，不建 Image', (tester) async {
    await pumpThumb(tester, null);
    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('空字节流 → 占位图标（mock / 未落地口径）', (tester) async {
    await pumpThumb(tester, Uint8List(0));
    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('有效字节 → 渲染 Image 且占位不出现', (tester) async {
    await pumpThumb(tester, png);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file), findsNothing);
  });
}
