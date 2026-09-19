import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/providers/todo_providers.dart';

/// B6 单份缓存与关键词通道取数口径回归：
/// - 列表缓存不携关键词（列裁剪下 description 缺失，客户端过滤会把
///   描述搜索静默变无结果——桌面 6c6c2b0 反向教训）；
/// - 关键词必须过服务端通道原样送 bridge（SQL LIKE 含 description）。
class _RecordingBridge extends MockOrbitBridge {
  final filters = <ListFilter>[];

  @override
  Future<List<TodoTask>> todoTaskList(ListFilter filter) {
    filters.add(filter);
    return super.todoTaskList(filter);
  }
}

void main() {
  test('单份缓存：无关键词、按上限页大小取全量', () async {
    final bridge = _RecordingBridge();
    final container = ProviderContainer(overrides: [
      orbitBridgeProvider.overrideWithValue(bridge),
    ]);
    addTearDown(container.dispose);

    await container.read(todoTasksProvider.future);

    expect(bridge.filters, hasLength(1));
    expect(bridge.filters.single.keyword, isNull);
    expect(bridge.filters.single.pageSize, taskListPageSize);
  });

  test('服务端关键词通道：关键词原样过桥', () async {
    final bridge = _RecordingBridge();
    final container = ProviderContainer(overrides: [
      orbitBridgeProvider.overrideWithValue(bridge),
    ]);
    addTearDown(container.dispose);

    await container.read(todoTasksSearchProvider('奶').future);

    expect(bridge.filters.single.keyword, '奶');
    expect(bridge.filters.single.pageSize, taskListPageSize);
  });
}
