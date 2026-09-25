import 'package:flutter/material.dart';

import '../../../services/local_prefs.dart';
import '../../../core/theme/icon_map.dart';

/// 任务列表视图模式（对齐桌面 `task-panel.tsx` 的 `ViewMode`）
///
/// 桌面为四档 `list | kanban | calendar | table` + `done` 档自动接管 Logbook；
/// 移动端日历是独立路由页（`/todo/calendar`），故本枚举只承载**同页内**切换
/// 的四档：列表 / 看板 / 表格 / 矩阵（四象限，TickTick 同款，桌面暂无）。
/// Logbook 仍是「已完成」快捷视图下列表档的自动形态（`isLogbook`），
/// 不作为可选项。
enum TaskViewMode { list, kanban, table, matrix }

extension TaskViewModeMeta on TaskViewMode {
  String get label => switch (this) {
        TaskViewMode.list => '列表',
        TaskViewMode.kanban => '看板',
        TaskViewMode.table => '表格',
        TaskViewMode.matrix => '矩阵',
      };

  IconData get icon => switch (this) {
        TaskViewMode.list => OrbitIcons.list,
        TaskViewMode.kanban => OrbitIcons.kanban,
        TaskViewMode.table => OrbitIcons.tableRows,
        TaskViewMode.matrix => OrbitIcons.grid,
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

/// 单项目视图档持久化键
///
/// **为什么按键存而不是一张 JSON 表**：`LocalPrefs` 的值域就是字符串，
/// 一个项目一个键既能沿用 `getEnum` 的脏值回落，也不会因一条脏记录毁掉整张表。
String projectViewModePrefsKey(int projectId) =>
    'todo_view_mode_project_$projectId';

/// 读某项目上下文的视图档：该项目设过就用它，未设过回落全局档
/// （全局档 = 「全部任务 / 今天」等非项目视图的默认值，也是新项目的初值）
TaskViewMode loadViewModeForProject(int? projectId) {
  if (projectId == null) return loadViewMode();
  return LocalPrefs.getEnum(
    projectViewModePrefsKey(projectId),
    TaskViewMode.values,
    fallback: loadViewMode(),
  );
}

/// 写某项目的视图档（只动项目档：全局档保持「非项目视图的默认值」语义）
Future<void> saveProjectViewMode(int projectId, TaskViewMode mode) =>
    LocalPrefs.setString(projectViewModePrefsKey(projectId), mode.name);
