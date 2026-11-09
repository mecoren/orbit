import 'package:flutter/foundation.dart';

import '../../core/theme/app_dimens.dart';

/// 一个开源包及其全部许可条目（系统 `LicenseRegistry` 的展示层聚合）
class LicensePackage {
  const LicensePackage({required this.name, required this.entries});

  final String name;

  /// 该包对应的许可条目（一个包可能有多条许可）
  final List<LicenseEntry> entries;

  int get licenseCount => entries.length;
}

/// 将 `LicenseRegistry.licenses` 的扁平条目按包名聚合。
///
/// 口径与系统 `LicensePage` 一致：同一条许可属于多个包时，每个包各计一次；
/// 包名忽略大小写排序；同一条目里重复出现的包名只计一次。
List<LicensePackage> groupLicenses(Iterable<LicenseEntry> entries) {
  final byPackage = <String, List<LicenseEntry>>{};

  for (final entry in entries) {
    final seen = <String>{};
    for (final package in entry.packages) {
      if (package.trim().isEmpty || !seen.add(package)) continue;
      byPackage.putIfAbsent(package, () => []).add(entry);
    }
  }

  final names = byPackage.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  return [
    for (final name in names)
      LicensePackage(name: name, entries: byPackage[name]!),
  ];
}

/// 段落左缩进（`LicenseParagraph.indent` 为负数时表示居中，不缩进）
double licenseParagraphIndent(LicenseParagraph paragraph) =>
    paragraph.indent <= 0 ? 0 : paragraph.indent * AppDimens.space12;

/// 是否为居中的版权声明段（系统 `LicenseParagraph` 用负数表示居中）
bool isCenteredLicenseParagraph(LicenseParagraph paragraph) =>
    paragraph.indent < 0;
