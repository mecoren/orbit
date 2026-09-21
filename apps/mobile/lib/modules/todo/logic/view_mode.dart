import 'package:flutter/material.dart';

import '../../../services/local_prefs.dart';
import '../../../core/theme/icon_map.dart';

/// 任务列表视图模式（对齐桌面 `task-panel.tsx` 的 `ViewMode`）
///
/// 桌面为四档 `list | kanban | calendar | table` + `done` 档自动接管 Logbook；
/// 移动端日历是独立路由页（`/todo/calendar`），故本枚举只承载**同页内**切换
/// 的三档：列表 / 看板 / 表格。Logbook 仍是「已完成」快捷视图下列表档的
/// 自动形态（`isLogbook`），不作为可选项。
enum TaskViewMode { list, kanban, table }

extension TaskViewModeMeta on TaskViewMode {
  String get label => switch (this) {
        TaskViewMode.list => '列表',
        TaskViewMode.kanban => '看板',
        TaskViewMode.table => '表格',
      };

  IconData get icon => switch (this) {
        TaskViewMode.list => OrbitIcons.list,
        TaskViewMode.kanban => OrbitIcons.kanban,
        TaskViewMode.table => OrbitIcons.tableRows,
      };
}

/// 看板分列维度（对齐桌面 `kanban-view.tsx` 的 `groupBy`）
enum KanbanGroupBy { project, status }

extension KanbanGroupByMeta on KanbanGroupBy {
  String get label => switch (this) {
        KanbanGroupBy.project => '按项目',
        KanbanGroupBy.status => '按状态',
      };
}

/// 视图模式持久化键（与桌面 localStorage `todo_view_mode` 同名同值域）
const String viewModePrefsKey = 'todo_view_mode';

/// 看板分组持久化键（桌面为组件内存态，移动端一并持久化以保持手感）
const String kanbanGroupByPrefsKey = 'todo_kanban_group_by';

/// 读取持久化视图模式（脏值/首次运行回落列表档）
TaskViewMode loadViewMode() => LocalPrefs.getEnum(
      viewModePrefsKey,
      TaskViewMode.values,
      fallback: TaskViewMode.list,
    );

/// 读取持久化看板分组（默认按项目，与桌面一致）
KanbanGroupBy loadKanbanGroupBy() => LocalPrefs.getEnum(
      kanbanGroupByPrefsKey,
      KanbanGroupBy.values,
      fallback: KanbanGroupBy.project,
    );
