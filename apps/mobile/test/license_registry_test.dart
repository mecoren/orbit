import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/modules/settings/license_registry.dart';

class _TestLicenseEntry implements LicenseEntry {
  _TestLicenseEntry(this.packages, this.paragraphs);

  @override
  final Iterable<String> packages;

  @override
  final Iterable<LicenseParagraph> paragraphs;
}

LicenseEntry _entry(
  List<String> packages, [
  List<String> paragraphs = const ['license text'],
]) => _TestLicenseEntry(packages, [
  for (final text in paragraphs) LicenseParagraph(text, 0),
]);

void main() {
  test('按包名聚合，一条许可属于多个包时每个包各计一次', () {
    final grouped = groupLicenses([
      _entry(['beta', 'alpha'], ['shared license']),
      _entry(['alpha'], ['second license']),
      _entry(['gamma'], ['third license']),
    ]);

    expect(grouped.map((package) => package.name), ['alpha', 'beta', 'gamma']);
    expect(grouped.first.licenseCount, 2);
    expect(grouped[1].licenseCount, 1);
  });

  test('包名排序忽略大小写', () {
    final grouped = groupLicenses([
      _entry(['Zulu']),
      _entry(['alpha']),
      _entry(['Beta']),
    ]);

    expect(grouped.map((package) => package.name), ['alpha', 'Beta', 'Zulu']);
  });

  test('同一条 packages 里重复包名只计一次', () {
    final grouped = groupLicenses([
      _entry(['alpha', 'alpha']),
    ]);

    expect(grouped.single.licenseCount, 1);
  });

  test('段落缩进：负数（居中）不缩进，其余按层级缩进', () {
    expect(licenseParagraphIndent(const LicenseParagraph('centered', -1)), 0);
    expect(
      licenseParagraphIndent(const LicenseParagraph('level 2', 2)),
      AppDimens.space12 * 2,
    );
    expect(
      isCenteredLicenseParagraph(const LicenseParagraph('centered', -1)),
      isTrue,
    );
    expect(
      isCenteredLicenseParagraph(const LicenseParagraph('normal', 0)),
      isFalse,
    );
  });
}
