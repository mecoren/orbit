// 分享接收（小而美批次④）桥面测试：
// ShareReceiver.createTaskFromSharedText —— 分享文本过 NLP 短语法解析
// 建任务（dueDate 毫秒/priority/projectId/标签挂载），纯桥注入无 UI 依赖。
//
// MethodChannel('orbit/share') 的 consume 轮询属原生集成面，单测环境
// 无 handler——MissingPluginException 分支静默（原生真机验收覆盖）。
// WaitToast 在测试环境无 Overlay（rootNavigatorKey 未装配）直接 return。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/services/share_receiver.dart';

void main() {
  // WaitToast 经 rootNavigatorKey.currentState 访问 Overlay——需 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分享文本 NLP 全命中：建任务 + 截止/优先级/项目应用 + 标签挂载',
      () async {
    final bridge = MockOrbitBridge();
    // seed id 全局递增：工作=1/生活=2/紧急=3/阅读=4/任务 5+…
    // 「明天 #工作 交报告 !3 @紧急」命中截止(明天)/优先级 3/项目 1/标签 3
    final created = await ShareReceiver.createTaskFromSharedText(
        bridge, '明天 #工作 交报告 !3 @紧急');
    expect(created, isTrue);

    final task = bridge.store.tasks.values
        .firstWhere((t) => (t['title'] as String).contains('交报告'));
    expect(task['project_id'], 1, reason: 'NLP 命中项目 工作');
    expect(task['priority'], 3, reason: 'NLP 命中优先级 !3');
    expect(task['due_date'], isNotNull, reason: 'NLP 命中截止日期');
    // 标题剥离 NLP token 后仅剩正文
    expect(task['title'], '交报告');
    // 标签挂载：@紧急(labelId=3) → 新任务的 taskLabels
    final taskId = task['id'] as int;
    expect(bridge.store.taskLabels[taskId], contains(3),
        reason: '@紧急 已挂载到新任务');
  });

  test('纯文本分享（无 NLP 命中）：标题原样保留、字段全空', () async {
    final bridge = MockOrbitBridge();
    final created = await ShareReceiver.createTaskFromSharedText(
        bridge, '一段完全普通的分享文字');
    expect(created, isTrue);

    final t = bridge.store.tasks.values.firstWhere(
        (t) => (t['title'] as String) == '一段完全普通的分享文字');
    expect(t['due_date'], isNull);
    expect(t['priority'], 0);
    expect(t['project_id'], isNull);
    expect(bridge.store.taskLabels[t['id'] as int], isNull);
  });

  test('只命中文档符号但无正文（极端剥离后空）：回退整段原文为标题', () async {
    final bridge = MockOrbitBridge();
    // 「!3」剥离后正文为空 → 标题回退原文（不建空标题任务）
    final created =
        await ShareReceiver.createTaskFromSharedText(bridge, '!3');
    expect(created, isTrue);
    expect(bridge.store.tasks.values.any((t) => (t['title'] as String) == '!3'),
        isTrue,
        reason: '剥离后为空时标题回退整段原文');
  });
}
