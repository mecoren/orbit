import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/settings/oss_components_filter.dart';

OssComponentInfo _component(
  String name,
  String source, {
  String version = '1.0.0',
}) => OssComponentInfo(
  name: name,
  version: version,
  source: source,
  description: '$name 说明',
  license: 'MIT',
);

final _rows = [
  _component('react', 'frontend'),
  _component('zustand', 'frontend'),
  _component('ag-grid', 'frontend'),
  _component('tauri', 'rust'),
  _component('sqlx', 'rust'),
  _component('go_router', 'flutter'),
  _component('flutter_miuix', 'flutter'),
];

void main() {
  group('filterOssComponents', () {
    test('all 保留全部条目', () {
      expect(filterOssComponents(_rows, OssSourceFilter.all), hasLength(7));
    });

    test('按来源过滤且不改动原数组', () {
      final before = List<OssComponentInfo>.from(_rows);
      final filtered = filterOssComponents(_rows, OssSourceFilter.rust);
      expect(filtered.map((row) => row.name), ['tauri', 'sqlx']);
      expect(_rows.map((row) => row.name), before.map((row) => row.name));
    });
  });

  group('mobileVisibleOssComponents', () {
    test('隐藏前端来源条目且不改动原数组', () {
      final before = _rows.map((row) => row.name).toList();
      final visible = mobileVisibleOssComponents(_rows);
      expect(visible.map((row) => row.name), [
        'tauri',
        'sqlx',
        'go_router',
        'flutter_miuix',
      ]);
      expect(_rows.map((row) => row.name), before);
    });
  });

  group('sortOssComponents', () {
    test('defaultOrder 保留数据源顺序', () {
      expect(
        sortOssComponents(_rows, OssSort.defaultOrder).map((row) => row.name),
        _rows.map((row) => row.name),
      );
    });

    test('名称升序忽略大小写', () {
      final data = [
        _component('Zustand', 'frontend'),
        _component('ag-grid', 'frontend'),
        _component('React', 'frontend'),
      ];
      expect(sortOssComponents(data, OssSort.nameAsc).map((row) => row.name), [
        'ag-grid',
        'React',
        'Zustand',
      ]);
    });

    test('名称降序', () {
      expect(
        sortOssComponents(_rows, OssSort.nameDesc).map((row) => row.name),
        [
          'zustand',
          'tauri',
          'sqlx',
          'react',
          'go_router',
          'flutter_miuix',
          'ag-grid',
        ],
      );
    });

    test('来源排序按 前端 → Rust → Flutter，同来源内名称升序', () {
      expect(sortOssComponents(_rows, OssSort.source).map((row) => row.name), [
        'ag-grid',
        'react',
        'zustand',
        'sqlx',
        'tauri',
        'flutter_miuix',
        'go_router',
      ]);
    });

    test('不修改原数组顺序', () {
      final before = _rows.map((row) => row.name).toList();
      sortOssComponents(_rows, OssSort.nameAsc);
      expect(_rows.map((row) => row.name), before);
    });
  });

  group('标签', () {
    test('来源标签', () {
      expect(ossSourceLabel('frontend'), '前端');
      expect(ossSourceLabel('rust'), 'Rust');
      expect(ossSourceLabel('flutter'), 'Flutter');
      expect(ossSourceLabel('unknown'), '其他');
    });

    test('筛选与排序档位标签', () {
      expect(ossSourceFilterLabel(OssSourceFilter.all), '全部来源');
      expect(ossSourceFilterLabel(OssSourceFilter.rust), 'Rust');
      expect(ossSortLabel(OssSort.defaultOrder), '默认排序');
      expect(ossSortLabel(OssSort.nameAsc), '名称 A→Z');
    });
  });
}
