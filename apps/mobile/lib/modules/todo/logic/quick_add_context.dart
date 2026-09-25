import 'task_logic.dart';

/// 当前「新建任务落点」的会话上下文
///
/// 底部导航的中央添加钮全局只有一处，但新建落点应跟随用户当前所在的列表
/// （项目视图预填该项目、快捷视图预填对应标记）。列表页在进场上把自己的
/// 筛选入参登记到这里，退场时清空；中央添加钮读取最新一条做预填。
/// 无页面语境（如停在清单首页）时为 null，快速添加面板内自行选择。
///
/// 只做「最后登记者生效」的单槽：多级列表叠栈的频率极低，且面板内选择器
/// 始终可手动改，不为边际场景引入栈结构。
class QuickAddContext {
  QuickAddContext._();

  static TaskFilterInput? _current;

  /// 当前落点（null = 无页面语境，面板内自选）
  static TaskFilterInput? get current => _current;

  /// 登记页面落点；传 null 清空（列表页退场时调用）
  static void set(TaskFilterInput? input) => _current = input;
}
