// 开源许可两级页面回归（包名列表 → 许可全文）：
// - 列表：品牌卡 + 包名 + 许可数，按包名排序
// - 详情：包名、许可数、多条许可正文
// - 未知包：统一空态
// 数据通过 licenseStream 注入，不依赖真实 LicenseRegistry。
import 'package:flutter/foundation.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/settings/license_detail_page.dart';
import 'package:orbit/modules/settings/license_list_page.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';

import 'support/orbit_test_app.dart';

class _TestLicenseEntry implements LicenseEntry {
  _TestLicenseEntry(this.packages, this.paragraphs);

  @override
  final Iterable<String> packages;

  @override
  final Iterable<LicenseParagraph> paragraphs;
}

LicenseEntry _entry(List<String> packages, List<String> paragraphs) =>
    _TestLicenseEntry(packages, [
      for (final text in paragraphs) LicenseParagraph(text, 0),
    ]);

void main() {
  testWidgets('列表页：品牌卡 + 包名 + 许可数', (tester) async {
    final stream = Stream.fromIterable([
      _entry(['beta', 'alpha'], ['shared license']),
      _entry(['alpha'], ['second license']),
      _entry(['gamma'], ['third license']),
    ]);

    await tester.pumpWidget(
      orbitTestApp(home: LicenseListPage(licenseStream: stream)),
    );
    await tester.pumpAndSettle();

    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('循迹'), findsOneWidget);
    expect(find.text('Powered by Flutter'), findsOneWidget);
    expect(find.text('共 3 个开源包'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);
    expect(find.text('2 项许可'), findsOneWidget);
  });

  testWidgets('品牌卡与列表卡同宽（只保留一层水平留白）', (tester) async {
    final stream = Stream.fromIterable([
      _entry(['alpha'], ['first license body']),
    ]);

    await tester.pumpWidget(
      orbitTestApp(home: LicenseListPage(licenseStream: stream)),
    );
    await tester.pumpAndSettle();

    final brandCard = tester.getSize(find.byType(MiuixCard).first);
    final listCard = tester.getSize(find.byType(OrbitCardSegment).first);
    expect(brandCard.width, listCard.width);
  });

  testWidgets('详情页：包名、许可数与多条许可正文', (tester) async {
    final stream = Stream.fromIterable([
      _entry(['alpha'], ['first license body']),
      _entry(['alpha'], ['second license body']),
    ]);

    await tester.pumpWidget(
      orbitTestApp(
        home: LicenseDetailPage(name: 'alpha', licenseStream: stream),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('许可详情'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('2 项许可'), findsOneWidget);
    expect(find.text('许可 1'), findsOneWidget);
    expect(find.text('许可 2'), findsOneWidget);
    expect(find.text('first license body'), findsOneWidget);
    expect(find.text('second license body'), findsOneWidget);
  });

  testWidgets('详情页：未知包给空态', (tester) async {
    final stream = Stream.fromIterable([
      _entry(['alpha'], ['first license body']),
    ]);

    await tester.pumpWidget(
      orbitTestApp(
        home: LicenseDetailPage(name: 'missing', licenseStream: stream),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('许可记录不存在或加载失败'), findsOneWidget);
  });
}
