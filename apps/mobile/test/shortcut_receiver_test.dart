// 静态快捷方式契约回归（Android 长按图标：新建任务 / 今天 / 搜索）：
// 原生只传动作 id，Dart 侧 parse 纯函数映射 + 处理器未就绪时暂存补发。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/services/shortcut_receiver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 处理器与暂存是静态面，跨用例存活：用一次 attach + flush 排空后摘掉
  setUp(() {
    void drain(QuickAction _) {}
    ShortcutReceiver.attach(drain);
    ShortcutReceiver.flushPending();
    ShortcutReceiver.detach(drain);
  });

  group('ShortcutReceiver.parse', () {
    test('三个已知 id 映射到对应动作', () {
      expect(ShortcutReceiver.parse('new_task'), QuickAction.newTask);
      expect(ShortcutReceiver.parse('today'), QuickAction.today);
      expect(ShortcutReceiver.parse('search'), QuickAction.search);
    });

    test('未知 id 与 null 一律无动作', () {
      expect(ShortcutReceiver.parse(null), isNull);
      expect(ShortcutReceiver.parse(''), isNull);
      expect(ShortcutReceiver.parse('unknown'), isNull);
    });
  });

  group('ShortcutReceiver 派发', () {
    test('处理器未注册时暂存，注册后补发一次', () {
      ShortcutReceiver.dispatch(QuickAction.today);
      final got = <QuickAction>[];
      ShortcutReceiver.attach(got.add);
      ShortcutReceiver.flushPending();
      expect(got, [QuickAction.today]);
      // 补发即清：再次 flush 不重复执行
      ShortcutReceiver.flushPending();
      expect(got, [QuickAction.today]);
    });

    test('处理器已注册时直接执行（热运行路径）', () {
      final got = <QuickAction>[];
      ShortcutReceiver.attach(got.add);
      ShortcutReceiver.dispatch(QuickAction.newTask);
      expect(got, [QuickAction.newTask]);
    });

    test('detach 后动作回到暂存（侧栏卸载不丢动作）', () {
      final got = <QuickAction>[];
      ShortcutReceiver.attach(got.add);
      ShortcutReceiver.detach(got.add);
      ShortcutReceiver.dispatch(QuickAction.search);
      expect(got, isEmpty);
    });
  });

  test('consume 经原生通道取动作并派发（方法名与通道名契约）', () async {
    const channel = MethodChannel('orbit/shortcuts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'takePendingShortcut');
      return 'search';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final got = <QuickAction>[];
    ShortcutReceiver.attach(got.add);
    await ShortcutReceiver.consume();
    expect(got, [QuickAction.search]);
    ShortcutReceiver.detach(got.add);
  });
}
