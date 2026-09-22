// 动效 token 别名口径锁定：路由/滚动收口的只是别名，数值必须恒等于原字面量。
// 改数值 = 改视觉，必须单独立项评审，不许顺手调——本文件就是那道门。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';

void main() {
  test('路由转场 token 数值 = 原硬编码字面量', () {
    expect(AppMotion.pageEnter, const Duration(milliseconds: 280));
    expect(AppMotion.pageExit, const Duration(milliseconds: 220));
    expect(AppMotion.pageInCubic, Curves.easeOutCubic);
    expect(AppMotion.pageOutCubic, Curves.easeInCubic);
  });

  test('滚动定位 token 数值 = 原硬编码字面量', () {
    expect(AppMotion.scrollSettle, const Duration(milliseconds: 260));
    expect(AppMotion.scrollSettleCurve, Curves.easeOutCubic);
  });
}
