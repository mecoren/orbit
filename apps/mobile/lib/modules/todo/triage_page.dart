// 「收件箱分诊」页（F2，docs/13 §五 F2 / §八 U2）——Things/OmniFocus Inbox
// 「捕获→澄清」的移动端形态：未分组任务一次一卡逐条决定归属。
//
// - 动作全部落在拇指区：主按钮「归入项目…」（底部抽屉选）、快捷 chips
//   今天/明天（18 点口径同桌面）、清日期/优先级（字段修正，不出队）、
//   删除（确认抽屉 + WaitToast 撤销走回收站恢复）、跳过；
// - 页头「撤销」回滚最近一次字段动作并把该卡拉回（归属动作计数回退）；
// - 队列打开即快照（logic/triage 口径，与桌面 shared/triage 同源镜像），
//   写库后的 invalidate 不影响进行中的队列；
// - 结束给「收件箱已清空」正反馈与汇总。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'logic/reschedule_due.dart';
import 'logic/task_logic.dart'
    show formatDueShort, priorityColorHex, priorityLabel;
import 'logic/triage.dart';
import 'providers/todo_providers.dart';

/// 字段动作分类：归属动作（出队）撤销时回退对应计数并拉回卡片
enum _TriageActionKind { move, schedule, edit }

class _TriageHistoryEntry {
  final int taskId;
  final int queueIndex;
  final _TriageActionKind kind;
  final Map<String, Object?> before;
  final String label;
  const _TriageHistoryEntry({
    required this.taskId,
    required this.queueIndex,
    required this.kind,
    required this.before,
    required this.label,
  });
}

class TriagePage extends ConsumerStatefulWidget {
  const TriagePage({super.key});

  @override
  ConsumerState<TriagePage> createState() => _TriagePageState();
}

class _TriagePageState extends ConsumerState<TriagePage> {
  /// 队列快照：null = 全量缓存未就绪（等待补种）。不在 initState 里
  /// read——read 不会激活 provider，首帧缓存未建时会拿到空快照
  ///（project_edit_page 的同款坑）；build 里 watch 保活 + 首帧就地补种，
  /// 补种后的 invalidate 不重算队列（防连击抖动）
  List<TodoTask>? _queue;
  /// 项目候选（归入项目抽屉数据源）：build 里 watch 保活（read 不激活
  /// provider，首帧 value 为 null 会开出空抽屉）
  List<TodoProject> _projects = const [];
  int _idx = 0;
  int _moved = 0;
  int _scheduled = 0;
  int _skipped = 0;
  int _deleted = 0;
  final List<_TriageHistoryEntry> _history = [];
  bool _busy = false;

  TodoTask? get _current =>
      (_queue == null || _idx >= _queue!.length) ? null : _queue![_idx];

  void _refreshTasks() {
    ref.invalidate(todoTasksProvider);
    ref.invalidate(taskDetailProvider);
  }

  Future<void> _patch(int taskId, Map<String, Object?> patch) async {
    await ref
        .read(orbitBridgeProvider)
        .todoTaskUpdate(taskId, encodePatch(patch));
  }

  /// 归入项目：归属动作（出队）
  Future<void> _assign(TodoTask task, TodoProject project) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _patch(task.id, {'project_id': project.id});
      _history.add(_TriageHistoryEntry(
        taskId: task.id,
        queueIndex: _idx,
        kind: _TriageActionKind.move,
        before: {'project_id': null},
        label: '已归入「${project.title}」',
      ));
      _refreshTasks();
      if (mounted) setState(() { _moved++; _idx++; });
    } catch (_) {
      WaitToast.destructive('归入项目失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 排今天/明天（18 点口径）：归属动作（出队）。原截止同日（rescheduleDueMs
  /// 返回 null）视为已排期，直接出队不写库
  Future<void> _schedule(TodoTask task, int dayOffset) async {
    if (_busy) return;
    final n = DateTime.now();
    final target = DateTime(n.year, n.month, n.day + dayOffset);
    final due = rescheduleDueMs(task.dueDate, target);
    if (due == null) {
      setState(() { _scheduled++; _idx++; });
      return;
    }
    setState(() => _busy = true);
    try {
      await _patch(task.id, {'due_date': due});
      _history.add(_TriageHistoryEntry(
        taskId: task.id,
        queueIndex: _idx,
        kind: _TriageActionKind.schedule,
        before: {'due_date': task.dueDate},
        label: dayOffset == 0 ? '已排到今天' : '已排到明天',
      ));
      _refreshTasks();
      if (mounted) setState(() { _scheduled++; _idx++; });
    } catch (_) {
      WaitToast.destructive('排期失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 清日期：字段修正（不出队）
  Future<void> _clearDue(TodoTask task) async {
    if (_busy || task.dueDate == null) return;
    setState(() => _busy = true);
    try {
      await _patch(task.id, {'due_date': null});
      _history.add(_TriageHistoryEntry(
        taskId: task.id,
        queueIndex: _idx,
        kind: _TriageActionKind.edit,
        before: {'due_date': task.dueDate},
        label: '已清除日期',
      ));
      _refreshTasks();
      if (mounted) {
        setState(() {
          _queue = [
            for (final t in _queue!)
              if (t.id == task.id)
                t.copyWith(clearDueDate: true)
              else
                t,
          ];
        });
      }
    } catch (_) {
      WaitToast.destructive('清除日期失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 优先级六档抽屉：字段修正（不出队；桌面键盘 P 走循环档，触屏给全档）
  Future<void> _pickPriority(TodoTask task) async {
    await showSelectBottomSheet<int>(
      context,
      title: '优先级',
      current: task.priority,
      items: [
        for (var p = 0; p <= 5; p++)
          SelectItem(
            value: p,
            label: priorityLabel(p),
            colorDot: hexToColor(priorityColorHex(p)),
          ),
      ],
      onSelect: (p) => _setPriority(task, p),
    );
  }

  Future<void> _setPriority(TodoTask task, int priority) async {
    if (priority == task.priority) return;
    setState(() => _busy = true);
    try {
      await _patch(task.id, {'priority': priority});
      _history.add(_TriageHistoryEntry(
        taskId: task.id,
        queueIndex: _idx,
        kind: _TriageActionKind.edit,
        before: {'priority': task.priority},
        label: '优先级 → ${priorityLabel(priority)}',
      ));
      _refreshTasks();
      if (mounted) {
        setState(() {
          _queue = [
            for (final t in _queue!)
              if (t.id == task.id) t.copyWith(priority: priority) else t,
          ];
        });
      }
    } catch (_) {
      WaitToast.destructive('设置优先级失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 软删：确认抽屉 + 撤销走回收站恢复（toast 5 秒窗）
  Future<void> _delete(TodoTask task) async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '删除任务',
      message: '「${task.title}」将移入回收站，可在回收站恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).todoTaskDelete(task.id);
      _refreshTasks();
      if (mounted) {
        setState(() { _deleted++; _idx++; });
        WaitToast.global(
          '已删除 1 个任务',
          variant: WaitToastVariant.warning,
          description: '已移入回收站的任务可在回收站恢复',
          actionLabel: '撤销',
          onAction: () async {
            try {
              await ref.read(orbitBridgeProvider).trashTaskRestore(task.id);
              _refreshTasks();
            } catch (_) {
              WaitToast.destructive('恢复失败');
            }
          },
          autoDismissAfter: WaitToast.undoDwell,
        );
      }
    } catch (_) {
      WaitToast.destructive('删除失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 页头「撤销」：回滚最近一次字段动作；归属动作的撤销把卡片拉回
  Future<void> _undoLast() async {
    if (_busy || _history.isEmpty) return;
    setState(() => _busy = true);
    try {
      final entry = _history.removeLast();
      await _patch(entry.taskId, entry.before);
      if (entry.kind == _TriageActionKind.move) _moved--;
      if (entry.kind == _TriageActionKind.schedule) _scheduled--;
      if (entry.kind != _TriageActionKind.edit) _idx = entry.queueIndex;
      setState(() {
        _queue = [
          for (final t in _queue!)
            if (t.id == entry.taskId)
              t.copyWith(
                projectId: entry.before['project_id'] as int?,
                clearProjectId: entry.before.containsKey('project_id'),
                dueDate: entry.before['due_date'] as int?,
                clearDueDate: entry.before['due_date'] == null &&
                    entry.before.containsKey('due_date'),
                priority: entry.before['priority'] as int?,
              )
            else
              t,
        ];
      });
      _refreshTasks();
    } catch (_) {
      WaitToast.destructive('撤销失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 归入项目抽屉（色点 + 项目名；与长按菜单「更换项目」同款）。
  /// 数据源用 build 里 watch 保活的 [_projects]——read 未激活的 provider
  /// 拿到 null 会开出空抽屉
  Future<void> _pickProject(TodoTask task) async {
    final projects = _projects;
    await showSelectBottomSheet<int>(
      context,
      title: '归入项目',
      items: [
        for (final p in projects.where((x) => x.isArchived == 0))
          SelectItem(
            value: p.id,
            label: p.title,
            colorDot: hexToColor(p.hexColor),
          ),
      ],
      onSelect: (id) {
        final project = projects.where((x) => x.id == id).firstOrNull;
        if (project != null) _assign(task, project);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final tasks = ref.watch(todoTasksProvider).value;
    // 首帧数据到达时补种快照（同一帧内使用，不 setState——project_edit_page 同款）
    if (_queue == null && tasks != null) {
      _queue = collectTriageQueue(tasks);
    }
    _projects = ref.watch(todoProjectsProvider).value ?? _projects;
    final task = _current;
    final topInset =
        MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _queue == null
                ? Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: const Center(
                        child: OrbitSpinner(size: AppDimens.iconSizeLg)),
                  )
                : task == null
                    ? Padding(
                        padding: EdgeInsets.only(top: topInset),
                        child: EmptyState(
                          message: _idx == 0
                              ? '收件箱已清空'
                              : '收件箱已清空\n${formatTriageSummary(_moved, _scheduled, _skipped, _deleted)}',
                          icon: OrbitIcons.inbox,
                        ),
                      )
                    : _body(colors, task, topInset),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              showBack: true,
              title: '分诊',
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: AppDimens.space12),
                  child: TextButton(
                    onPressed: _history.isEmpty || _busy ? null : _undoLast,
                    child: const Text('撤销'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(AppColorSet colors, TodoTask task, double topInset) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppDimens.space16,
        topInset + AppDimens.space8,
        AppDimens.space16,
        AppDimens.pageInline,
      ),
      children: [
        // 进度
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: AppShapes.xs,
                child: LinearProgressIndicator(
                  value: _queue!.isEmpty ? 1 : _idx / _queue!.length,
                  minHeight: 3,
                ),
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            Text(
              '$_idx / ${_queue!.length}',
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.sectionGap),

        // 当前卡：标题 + 元信息
        Container(
          padding: const EdgeInsets.all(AppDimens.cardPadding),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: AppShapes.medium,
            border: Border.all(color: colors.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                task.title,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                [
                  if (task.dueDate != null)
                    '截止 ${formatDueShort(task.dueDate!)}',
                  if (task.priority > 0) '优先级 ${priorityLabel(task.priority)}',
                  '未分组',
                ].join(' · '),
                style: TextStyle(fontSize: 13, color: colors.secondaryText),
              ),
              const SizedBox(height: AppDimens.cardGap),

              // 主动作：归入项目（拇指区主按钮）
              sh.Button.primary(
                onPressed: _busy ? null : () => _pickProject(task),
                child: const Text('归入项目…', textAlign: TextAlign.center),
              ),
              const SizedBox(height: AppDimens.space8),

              // 快捷动作：今天 / 明天 /（有日期才出）清日期 / 优先级
              // （与周回顾弹层的 sh.Button.outline 同形态）
              Wrap(
                spacing: AppDimens.space8,
                runSpacing: AppDimens.space8,
                children: [
                  sh.Button.outline(
                    onPressed: _busy ? null : () => _schedule(task, 0),
                    child: const Text('今天'),
                  ),
                  sh.Button.outline(
                    onPressed: _busy ? null : () => _schedule(task, 1),
                    child: const Text('明天'),
                  ),
                  if (task.dueDate != null)
                    sh.Button.outline(
                      onPressed: _busy ? null : () => _clearDue(task),
                      child: const Text('清日期'),
                    ),
                  sh.Button.outline(
                    onPressed: _busy ? null : () => _pickPriority(task),
                    child: Text(task.priority > 0
                        ? '优先级 · ${priorityLabel(task.priority)}'
                        : '优先级'),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.space8),

              // 次级动作：跳过 / 删除（纯文本动作走 Material 文本钮，删除红色）
              Row(
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() { _skipped++; _idx++; }),
                    child: const Text('跳过'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => _delete(task),
                    style: TextButton.styleFrom(
                      foregroundColor: OrbitAccents.overdueRed,
                    ),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
