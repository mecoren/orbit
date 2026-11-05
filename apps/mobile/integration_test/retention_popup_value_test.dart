// 真机回归：设置页「保留时间」点选后必须显示**新档**
//
// **能力边界（务必先读）**：本用例在 `MockOrbitBridge` 下运行，而 mock 的
// `trashSetRetentionDays` 是**同步完成**的（未走 `_delay`，见
// `mock_orbit_bridge.dart`）——真实 Rust 桥的 DB 往返窗口在这里不存在，
// 因此本用例**证明不了**「写库未回期间显示旧值」那一层时序。它钉住的是
// 另一半契约：点选后行内尾随值 / 回弹副本都会收敛到新档，不会停在旧值
// （副本固化的回归由 `test/orbit_dropdown_preference_test.dart` 的
// 「回弹期副本显示新档」用例覆盖）。
//
// 真机手工验收要点：在真机（真实 DB）上点选一档，观察逆形变回弹画面——
// 尾随值应为新档而非打开时的旧档。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/settings_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';

import '../test/support/orbit_test_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('保留时间：点选后行内与回弹副本都收敛到新档', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('保留时间'));
    await tester.pumpAndSettle();
    expect(find.byKey(orbitDropdownPopupKey), findsOneWidget);

    await tester.tap(find.text('30 天').last);
    await tester.pump();

    // 条目行本身列出所有档位，故「30 天」至少 2 次（条目行 + 副本/行内）；
    // 旧值「永久」只该剩条目行那 1 次，不得出现在副本或行尾随值上
    expect(
      find.text('永久').evaluate().length,
      1,
      reason: '旧档只应留在条目行，不得残留在回弹副本或行尾随值',
    );

    await tester.pumpAndSettle();
    expect(find.text('30 天'), findsWidgets);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
