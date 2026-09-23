import 'package:flutter/services.dart';

/// Android 静态快捷方式动作（长按启动器图标；`res/xml/shortcuts.xml` 声明）
enum QuickAction {
  /// 新建任务：侧栏弹「快加」表单（与 FAB 同源）
  newTask,

  /// 今天截止：`/todo/tasks?view=today`
  today,

  /// 搜索：`/todo/search`
  search,
}

/// 静态快捷方式接收服务（对齐 ShareReceiver 的「原生暂存 → Dart 取走即清」范式）
///
/// 原生侧（MainActivity 的 `orbit/shortcuts` 通道）只存动作 id 字符串，**不复制
/// 业务判断**；语义与路由落点在 Dart：[parse] 是纯函数面（单测注入固定输入），
/// [dispatch] 交侧栏页处理（三个动作都要页面 context：弹表单 / 入栈）。
///
/// 冷启动时序：动作到达时路由可能尚未 build，先暂存（[_pending]），侧栏
/// initState 注册处理器后由 [flushPending] 下一帧补发（沿用通知冷启动
/// 「push 早于 MaterialApp.router build 会丢」的同一处理）。
class ShortcutReceiver {
  ShortcutReceiver._();

  static const _channel = MethodChannel('orbit/shortcuts');

  /// 侧栏（动作落点页）注册的处理器；未注册（路由未就绪）时动作暂存
  static void Function(QuickAction action)? _handler;
  static QuickAction? _pending;

  /// 原生动作 id → 枚举；未知 id / null 视为无动作（静默忽略）
  static QuickAction? parse(String? id) => switch (id) {
        'new_task' => QuickAction.newTask,
        'today' => QuickAction.today,
        'search' => QuickAction.search,
        _ => null,
      };

  /// 取一次原生待取动作（冷启动首帧与 resumed 各一次；取走即清，幂等）
  ///
  /// 非 Android 平台无该通道（MissingPluginException / PlatformException）
  /// ——静默返回，平台特性不作错误处理。
  static Future<void> consume() async {
    String? id;
    try {
      id = await _channel.invokeMethod<String>('takePendingShortcut');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    final action = parse(id);
    if (action != null) dispatch(action);
  }

  /// 派发动作：处理器未就绪则暂存（冷启动首帧早于侧栏装配）
  static void dispatch(QuickAction action) {
    final handler = _handler;
    if (handler == null) {
      _pending = action;
      return;
    }
    handler(action);
  }

  /// 注册处理器（侧栏 initState；落点页全局唯一，后注册者覆盖）
  static void attach(void Function(QuickAction action) handler) =>
      _handler = handler;

  /// 补发暂存动作：注册后下一帧调用——initState 期不能做 InheritedWidget
  /// 依赖（GoRouter.of）与弹层，必须等首帧
  static void flushPending() {
    final action = _pending;
    final handler = _handler;
    if (action == null || handler == null) return;
    _pending = null;
    handler(action);
  }

  /// 解注册（侧栏 dispose；仅当仍是自己时清，防重建竞态——用 `==` 而非
  /// `identical`：方法 tear-off 的相等语义覆盖得住）
  static void detach(void Function(QuickAction action) handler) {
    if (_handler == handler) _handler = null;
  }
}
