import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/layout/orbit_breakpoints.dart';

/// 断点分档的纯函数锚点（#107）
///
/// 只测 [OrbitBreakpoints.ofWidth]，不依赖 Widget 树：
/// 360dp（手机竖屏）必须落在 compact，保证既有版式零回归；
/// 边界值取「含下界」，避免 600/840 恰好落在两档之间时行为未定义。
void main() {
  group('OrbitBreakpoints.ofWidth', () {
    test('360dp / 599.9dp 仍是 compact（手机竖屏零回归）', () {
      expect(OrbitBreakpoints.ofWidth(360), OrbitWindowSize.compact);
      expect(OrbitBreakpoints.ofWidth(599.9), OrbitWindowSize.compact);
    });

    test('600dp 起进入 medium（手机横屏/小平板）', () {
      expect(OrbitBreakpoints.ofWidth(600), OrbitWindowSize.medium);
      expect(OrbitBreakpoints.ofWidth(839.9), OrbitWindowSize.medium);
    });

    test('840dp 起进入 expanded（平板横屏/分屏）', () {
      expect(OrbitBreakpoints.ofWidth(840), OrbitWindowSize.expanded);
      expect(OrbitBreakpoints.ofWidth(1280), OrbitWindowSize.expanded);
    });
  });
}
