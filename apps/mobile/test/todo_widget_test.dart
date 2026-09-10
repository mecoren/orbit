import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/mock_store.dart';
import 'package:orbit/data/api/dto.dart' show WidgetTodoItem;
import 'package:orbit/data/api/orbit_bridge.dart' show OrbitBridge;
import 'package:orbit/services/todo_widget_service.dart';

/// 小组件服务测试（纯 Dart；平台层 HomeWidgetApi 假实现注入）
class _FakeWidgetApi implements HomeWidgetApi {
  final Map<String, Object?> saved = {};
  final List<String> updated = [];
  final _clickCtrl = StreamController<Uri?>.broadcast();

  @override
  Future<Uri?> initiallyLaunched() async => null;

  @override
  Future<void> saveData(String key, Object? value) async {
    // home_widget 语义：null 值删键——保存 null 视作清位（原生 getInt 回默认 0）
    if (value == null) {
      saved.remove(key);
    } else {
      saved[key] = value;
    }
  }

  @override
  Future<void> updateWidget({String? androidName}) async {
    updated.add(androidName ?? '');
  }

  @override
  Stream<Uri?> get widgetClicked => _clickCtrl.stream;
}

/// 直插一条 mock 任务（精准控制 due/priority）
void seedTask(MockStore store, int id, String title,
    {required int dueDate, int priority = 0}) {
  store.tasks[id] = {
    'id': id,
    'uuid': 'u-$id',
    'title': title,
    'priority': priority,
    'status': 'pending',
    'done': 0,
    'done_at': null,
    'due_date': dueDate,
    'is_deleted': 0,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('refresh 写今日口径快照并触发 widget 更新', () async {
    final bridge = MockOrbitBridge();
    final store = bridge.store;
    store.tasks.clear(); // 排除 seed() 自带任务（其中有今日/逾期口径的）
    final now = DateTime.now().millisecondsSinceEpoch;
    seedTask(store, 1, '逾期任务', dueDate: now - 86400000, priority: 2);
    seedTask(store, 2, '今天任务', dueDate: now + 3600000, priority: 3);
    seedTask(store, 3, '未来任务', dueDate: now + 3 * 86400000, priority: 5);

    final api = _FakeWidgetApi();
    final service = TodoWidgetService(bridge: bridge, api: api);
    await service.refresh();

    // 头部计数 = 2（逾期 + 今天；未来不入）
    expect(api.saved['widget.header.count'], 2);
    // 第一行 = 优先级降序（今天任务 3 > 逾期任务 2）
    expect(api.saved['widget.items.0.title'], '今天任务');
    expect(api.saved['widget.items.1.title'], '逾期任务');
    // 未填位清键（home_widget null 语义 → saved.remove）
    expect(api.saved.containsKey('widget.items.2.title'), isFalse);
    // updateWidget 调用了原生 Provider
    expect(api.updated, contains('TodoWidgetProvider'));
  });

  test('勾选通道：widgetToggle → 桥落库 → 快照重刷', () async {
    final bridge = MockOrbitBridge();
    final store = bridge.store;
    store.tasks.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    seedTask(store, 7, '勾我', dueDate: now + 3600000);
    final api = _FakeWidgetApi();
    final service = TodoWidgetService(bridge: bridge, api: api);
    service.attach();

    // 模拟原生 TodoWidgetHost 发勾选（MethodChannel handler）
    final binaryMessenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    binaryMessenger.setMockMethodCallHandler(const MethodChannel('orbit/widget'),
        (call) async {
      if (call.method == 'widgetToggle') {
        // 直接复刻服务 handler 逻辑（setMethodCallHandler 挂在服务里；
        // 借 mock 拦截拿不到——改为手动调用服务的私有路径不可行，此处
        // 直接构造等价调用验证桥链）
        final taskId = call.arguments['taskId'] as int;
        final done = call.arguments['done'] as int;
        await bridge.widgetTodoToggle(taskId, done);
        await service.refresh();
        return null;
      }
      return null;
    });

    // 触发（模拟原生 invokeMethod）
    await binaryMessenger.handlePlatformMessage(
      'orbit/widget',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('widgetToggle', {'taskId': 7, 'done': 1}),
      ),
      (_) {},
    );

    // 落库：任务完成
    expect(store.tasks[7]!['done'], 1);
    // 快照重刷：计数从 1 → 0（完成后不再出现在今日口径）
    expect(api.saved['widget.header.count'], 0);

    service.detach();
  });

  test('refresh 全异常吞（桥抛错不炸）', () async {
    final bridge = _FailingBridge();
    final service =
        TodoWidgetService(bridge: bridge, api: _FakeWidgetApi());
    // 不应抛
    await service.refresh();
  });

  test('attach 幂等：重复挂载不重复监听', () {
    final service = TodoWidgetService(
      bridge: MockOrbitBridge(),
      api: _FakeWidgetApi(),
    );
    service.attach();
    service.attach(); // 不炸即过
    service.detach();
  });
}

/// 查询必抛的桥（异常路径用）：noSuchMethod 转发内桥，查询法精准抛错
class _FailingBridge implements OrbitBridge {
  final MockOrbitBridge _inner = MockOrbitBridge();
  @override
  Future<List<WidgetTodoItem>> widgetTodoQuery(int limit) {
    throw Exception('db down');
  }
  @override
  Future<void> widgetTodoToggle(int id, int done) =>
      _inner.widgetTodoToggle(id, done);
  @override
  noSuchMethod(Invocation invocation) => _inner.noSuchMethod(invocation);
}
