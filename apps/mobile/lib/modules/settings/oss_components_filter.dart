import '../../data/api/dto.dart';

/// 来源筛选档（all = 全部；前端属桌面壳，移动端不展示）
enum OssSourceFilter { all, rust, flutter }

/// 排序档（defaultOrder 保留 core 给定顺序）
enum OssSort { defaultOrder, nameAsc, nameDesc, source }

const _sourceLabels = <String, String>{
  'frontend': '前端',
  'rust': 'Rust',
  'flutter': 'Flutter',
};

/// 来源串值 → 中文标签（未知值兜底「其他」）
String ossSourceLabel(String source) => _sourceLabels[source] ?? '其他';

/// 筛选档位标签（行内当前值）
String ossSourceFilterLabel(OssSourceFilter filter) => switch (filter) {
  OssSourceFilter.all => '全部来源',
  OssSourceFilter.rust => ossSourceLabel('rust'),
  OssSourceFilter.flutter => ossSourceLabel('flutter'),
};

/// 移动端可见清单：前端（桌面壳）直接依赖不在移动端展示
List<OssComponentInfo> mobileVisibleOssComponents(
  List<OssComponentInfo> items,
) => items.where((item) => item.source != 'frontend').toList();

/// 排序档位标签（行内当前值）
String ossSortLabel(OssSort sort) => switch (sort) {
  OssSort.defaultOrder => '默认排序',
  OssSort.nameAsc => '名称 A→Z',
  OssSort.nameDesc => '名称 Z→A',
  OssSort.source => '按来源',
};

int _sourceRank(String source) => switch (source) {
  'frontend' => 0,
  'rust' => 1,
  'flutter' => 2,
  _ => 3,
};

int _byName(OssComponentInfo a, OssComponentInfo b) {
  final lower = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return lower != 0 ? lower : a.name.compareTo(b.name);
}

/// 按来源筛选（不改动原数组）
List<OssComponentInfo> filterOssComponents(
  List<OssComponentInfo> items,
  OssSourceFilter filter,
) {
  if (filter == OssSourceFilter.all) return List.of(items);
  final source = filter.name;
  return items.where((item) => item.source == source).toList();
}

/// 排序（不改动原数组；defaultOrder 保持 core 顺序）
List<OssComponentInfo> sortOssComponents(
  List<OssComponentInfo> items,
  OssSort sort,
) {
  final next = List.of(items);
  switch (sort) {
    case OssSort.nameAsc:
      next.sort(_byName);
    case OssSort.nameDesc:
      next.sort((a, b) => _byName(b, a));
    case OssSort.source:
      next.sort((a, b) {
        final rank = _sourceRank(a.source).compareTo(_sourceRank(b.source));
        return rank != 0 ? rank : _byName(a, b);
      });
    case OssSort.defaultOrder:
      break;
  }
  return next;
}
