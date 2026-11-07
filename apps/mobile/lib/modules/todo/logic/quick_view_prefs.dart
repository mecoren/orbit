/// 今天页签「视图菜单」选中档的本机持久化（2026-11-07）
///
/// 页头标题点开的那颗玻璃菜单统一称**视图菜单**：八档快捷视图
/// （我的一天 / 今天 / 近7天 / 全部任务 / 未完成 / 已完成 / 收藏 / 无日期）。
/// 此前是纯会话态，退出重进回落「今天」本位；现按本机偏好记住上次选的档，
/// 与视图档 `todo_view_mode`、看板分组 `todo_kanban_group_by` 同口径
/// （[LocalPrefs] 落 prefs.json，不进 DB、不进云同步）。
///
/// 桌面无对应键：桌面快捷视图在侧栏，点选即路由，不存在「上次停在哪一档」。
library;

import '../../../services/local_prefs.dart';
import 'task_logic.dart';

/// 视图菜单选中档的持久化键
const String quickViewPrefsKey = 'todo_quick_view';

/// 读上次在视图菜单里选的档；未存过 / 脏值回落「今天」
QuickViewKey loadQuickView() => LocalPrefs.getEnum(
  quickViewPrefsKey,
  QuickViewKey.values,
  fallback: QuickViewKey.today,
);

/// 写视图菜单选择（切回「今天」也写，保证重启后回到本位而非停在上一档）
Future<void> saveQuickView(QuickViewKey view) =>
    LocalPrefs.setString(quickViewPrefsKey, view.name);
