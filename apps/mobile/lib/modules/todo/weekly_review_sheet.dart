import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../shared/widgets/shadcn/orbit_sheets.dart'
    show bottomSheetMotion, bottomSheetTopShape;
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'logic/reschedule_due.dart' show rescheduleDueMs;
import 'logic/weekly_review.dart';

/// 引导式周回顾向导弹层（G5，镜像桌面 `weekly-review-dialog.tsx`）
///
/// GTD 周回顾的产品化：三步引导（逾期处置 → 无日期排期 → 停滞唤醒），
/// 每步列出待处置任务并给「一键处理」快捷动作，免用户逐清单翻找。
///
/// - 步骤 1 逾期：复用顺延（顺延到今天/明天）或逐条排期/跳过；
/// - 步骤 2 无日期：逐条排「今天/明天/下周」或跳过（保留无日期）；
/// - 步骤 3 停滞：逐条「动一动」（更新 updated_at 唤醒）或跳过。
///
/// 写路径由调用方注入（[onSetDue] / [onWake]）——本层只管向导流与清单
/// 状态，不直接碰桥；这与桌面 Dialog 只经 batch-actions 写库同构。
/// 返回值 = 被处置的任务 id 集（调用方据此统一失效缓存）。
Future<Set<int>?> showWeeklyReviewSheet(
  BuildContext context, {
  required List<TodoTask> tasks,
  required Future<void> Function(int taskId, int dueMs) onSetDue,
  required Future<void> Function(int taskId) onWake,
}) {
  return showModalBottomSheet<Set<int>>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _WeeklyReviewSheet(
      tasks: tasks,
      onSetDue: onSetDue,
      onWake: onWake,
    ),
  );
}

/// 向导三步
enum _ReviewStep { overdue, undated, stalled }

extension on _ReviewStep {
  String get title => switch (this) {
        _ReviewStep.overdue => '逾期任务',
        _ReviewStep.undated => '无日期任务',
        _ReviewStep.stalled => '停滞任务',
      };

  String get desc => switch (this) {
        _ReviewStep.overdue => '这些任务已过截止还没完成——顺延到今天/明天，或逐条决定去留',
        _ReviewStep.undated => '没有截止日的任务容易被遗忘——给它们排个日期，或先留着',
        _ReviewStep.stalled => '超过 7 天没动过的任务——碰一下表示「还在关注」',
      };

  IconData get icon => switch (this) {
        _ReviewStep.overdue => OrbitIcons.warning,
        _ReviewStep.undated => OrbitIcons.listChecks,
        _ReviewStep.stalled => OrbitIcons.clock,
      };
}

const _stepOrder = _ReviewStep.values;

/// 无日期/停滞档的排期快捷（与批量改期档同口径：今天/明天/下周）
enum _DuePreset { today, tomorrow, nextWeek }

extension on _DuePreset {
  String get label => switch (this) {
        _DuePreset.today => '今天',
        _DuePreset.tomorrow => '明天',
        _DuePreset.nextWeek => '下周',
      };

  DateTime get day {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (this) {
      case _DuePreset.today:
        return today;
      case _DuePreset.tomorrow:
        return today.add(const Duration(days: 1));
      case _DuePreset.nextWeek:
        // 周一起始周（与批量改期 batchRescheduleMs 同口径）
        final offset = (8 - today.weekday) % 7;
        return today.add(Duration(days: offset == 0 ? 7 : offset));
    }
  }
}

class _WeeklyReviewSheet extends StatefulWidget {
  const _WeeklyReviewSheet({
    required this.tasks,
    required this.onSetDue,
    required this.onWake,
  });

  final List<TodoTask> tasks;
  final Future<void> Function(int taskId, int dueMs) onSetDue;
  final Future<void> Function(int taskId) onWake;

  @override
  State<_WeeklyReviewSheet> createState() => _WeeklyReviewSheetState();
}

class _WeeklyReviewSheetState extends State<_WeeklyReviewSheet> {
  int _stepIdx = 0;

  /// 已处置的任务 id（各步内「跳过/处理」都算处置，出清单）
  final Set<int> _handled = {};
  bool _busy = false;

  _ReviewStep get _step => _stepOrder[_stepIdx];

  /// 本步待处置清单（已处置实时收缩）
  List<TodoTask> get _currentList {
    final all = switch (_step) {
      _ReviewStep.overdue => _buckets.overdue,
      _ReviewStep.undated => _buckets.undated,
      _ReviewStep.stalled => _buckets.stalled,
    };
    return all.where((t) => !_handled.contains(t.id)).toList();
  }

  late final WeeklyReviewBuckets _buckets =
      collectWeeklyReview(widget.tasks, DateTime.now().millisecondsSinceEpoch);

  void _markHandled(Iterable<int> ids, String label) {
    setState(() => _handled.addAll(ids));
    if (ids.isNotEmpty) {
      WaitToast.success('$label ${ids.length} 条');
    }
  }

  /// 步骤 1：顺延全部逾期（按实际写入行标记处置）
  Future<void> _rolloverAll(_DuePreset preset) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final list = _currentList;
      final plan = <int>[];
      for (final t in list) {
        final next = rescheduleDueMs(t.dueDate, preset.day);
        if (next == null) continue; // 同日无变化跳过
        await widget.onSetDue(t.id, next);
        plan.add(t.id);
      }
      _markHandled(plan, '顺延到${preset.label}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 步骤 2/3：单条排期
  Future<void> _setDue(TodoTask t, _DuePreset preset) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = rescheduleDueMs(t.dueDate, preset.day);
      await widget.onSetDue(t.id, next ?? preset.day.millisecondsSinceEpoch);
      _markHandled([t.id], '已排期');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 步骤 3：唤醒（touch updated_at）
  Future<void> _wake(TodoTask t) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onWake(t.id);
      _markHandled([t.id], '已唤醒');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _skip(TodoTask t) => _markHandled([t.id], '已跳过');

  void _next() {
    if (_stepIdx < _stepOrder.length - 1) {
      setState(() => _stepIdx++);
    } else {
      Navigator.of(context).pop(_handled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final list = _currentList;
    final isLast = _stepIdx == _stepOrder.length - 1;

    return OrbitSheetScaffold(
      // 自定义标题行：步骤图标 + 标题 + 步进
      header: Padding(
        padding: const EdgeInsets.fromLTRB(AppDimens.space16, AppDimens.space16,
            AppDimens.space16, AppDimens.space4),
        child: Row(
          children: [
            Icon(_step.icon, size: 20, color: colors.accent),
            const SizedBox(width: AppDimens.space8),
            Expanded(
              child: Text(
                '周回顾 · ${_step.title}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
            ),
            Text(
              '第 ${_stepIdx + 1} / ${_stepOrder.length} 步',
              style: TextStyle(fontSize: 12, color: colors.deactivatedText),
            ),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 步骤进度条（三段，前段主色）
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space16, vertical: AppDimens.space4),
            child: Row(
              children: [
                for (var i = 0; i < _stepOrder.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppDimens.space4),
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= _stepIdx
                            ? colors.accent
                            : colors.surfaceSecondary,
                        borderRadius: AppShapes.xs,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space16, vertical: AppDimens.space4),
            child: Text(
              _step.desc,
              style: TextStyle(fontSize: 12, color: colors.deactivatedText),
            ),
          ),
          // 本步清单
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppDimens.space24),
              child: Column(
                children: [
                  Icon(OrbitIcons.success, size: 32, color: colors.success),
                  const SizedBox(height: AppDimens.space8),
                  Text(
                    '${_step.title}已处理完',
                    style:
                        TextStyle(fontSize: 13, color: colors.deactivatedText),
                  ),
                ],
              ),
            )
          else
            for (final t in list) _row(t, colors),
        ],
      ),
      actions: Padding(
        padding: const EdgeInsets.all(AppDimens.space12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 逾期档：一键顺延整组（本步有未处置行时）
            if (_step == _ReviewStep.overdue && list.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: sh.Button.outline(
                      onPressed: _busy ? null : () => _rolloverAll(_DuePreset.today),
                      child: const Text('全部顺延到今天',
                          textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Expanded(
                    child: sh.Button.outline(
                      onPressed: _busy
                          ? null
                          : () => _rolloverAll(_DuePreset.tomorrow),
                      child: const Text('全部顺延到明天',
                          textAlign: TextAlign.center),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.space8),
            ],
            sh.Button.primary(
              onPressed: _busy ? null : _next,
              child: Text(
                isLast ? '完成回顾' : '下一步',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单行待处置任务：标题 + 档位快捷钮 + 跳过
  Widget _row(TodoTask t, AppColorSet colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space16, vertical: AppDimens.space4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.titleText),
            ),
          ),
          if (_step == _ReviewStep.overdue) ...[
            _action('今天', () => _setDue(t, _DuePreset.today)),
            _action('明天', () => _setDue(t, _DuePreset.tomorrow)),
          ] else if (_step == _ReviewStep.undated) ...[
            _action('今天', () => _setDue(t, _DuePreset.today)),
            _action('明天', () => _setDue(t, _DuePreset.tomorrow)),
            _action('下周', () => _setDue(t, _DuePreset.nextWeek)),
          ] else ...[
            _action('动一动', () => _wake(t)),
          ],
          _action('跳过', () => _skip(t)),
        ],
      ),
    );
  }

  Widget _action(String label, VoidCallback onTap) {
    return sh.Button.ghost(
      onPressed: _busy ? null : onTap,
      child: Text(label),
    );
  }
}
