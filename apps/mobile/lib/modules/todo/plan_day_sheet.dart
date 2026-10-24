// 「规划今天」底部抽屉（F3 日排程，docs/13 §五 F3 / §八 U3，ADR 0013）——
// 本地启发式排程：时间轴建议列表（HH:mm–HH:mm + 勾选 + 理由徽标）、未排入
// 区（带原因）、超载警示条；**阶段二应用**：勾选槽位写 my_day_date + start_date
//（不改 due_date，core 单事务），prev 快照经 WaitToast 撤销钮写回。
//
// 口径：算法真值在 core day_planner_api（纯函数分钟域），mock 桥镜像同口径；
// 弹层机制 = showModalBottomSheet + bottomSheetTopShape/Motion（共享弹层族）。
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
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'providers/todo_providers.dart';

/// 规划今天：排程预览弹层。[nowMs] 仅测试注入用（排程从「现在」起排，
/// 假时钟注入固定到工作窗内，用例不随跑测墙钟漂移）
Future<void> showPlanDaySheet(BuildContext context, {int? nowMs}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _PlanDaySheet(nowMs: nowMs),
  );
}

String _hhmm(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _PlanDaySheet extends ConsumerStatefulWidget {
  const _PlanDaySheet({this.nowMs});

  /// 测试注入的「现在」（null = 真实当前）
  final int? nowMs;

  @override
  ConsumerState<_PlanDaySheet> createState() => _PlanDaySheetState();
}

class _PlanDaySheetState extends ConsumerState<_PlanDaySheet> {
  DayPlan? _plan;
  String? _error;
  /// 勾选集（task_id；新预览到达时重置为全选）
  Set<int> _checked = {};
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final plan = await ref.read(orbitBridgeProvider).dayPlanPreview(
          DayPlanPrefs.defaults,
          widget.nowMs ?? DateTime.now().millisecondsSinceEpoch);
      if (mounted) {
        setState(() {
          _plan = plan;
          _checked = {for (final s in plan.slots) s.taskId};
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '排程预览加载失败');
      WaitToast.destructive('排程预览加载失败');
    }
  }

  /// 应用勾选槽位：写 my_day/start（core 单事务）；prev 快照进撤销栈
  ///（WaitToast 撤销钮逐条写回）
  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null || _applying || _checked.isEmpty) return;
    setState(() => _applying = true);
    try {
      final picked = [
        for (final s in plan.slots)
          if (_checked.contains(s.taskId))
            ApplySlotInput(taskId: s.taskId, startMs: s.startMs),
      ];
      final r = await ref
          .read(orbitBridgeProvider)
          .dayPlanApply(plan.dayStartMs, picked);
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
      if (!mounted) return;
      setState(() {
        _applying = false;
        _checked = {};
      });
      await _load();
      if (!mounted) return;
      WaitToast.global(
        '已应用 ${r.applied.length} 条排程',
        variant: WaitToastVariant.success,
        description: '写入开始时间与我的一天，截止日期不变',
        actionLabel: '撤销',
        onAction: () async {
          try {
            for (final a in r.applied) {
              await ref.read(orbitBridgeProvider).todoTaskUpdate(
                  a.taskId,
                  encodePatch({
                    'my_day_date': a.prevMyDayDate,
                    'start_date': a.prevStartDate,
                  }));
            }
            ref.invalidate(todoTasksProvider);
          } catch (_) {
            WaitToast.destructive('撤销失败');
          }
        },
        autoDismissAfter: WaitToast.undoDwell,
      );
    } catch (_) {
      if (mounted) setState(() => _applying = false);
      WaitToast.destructive('应用失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final plan = _plan;
    final maxH = MediaQuery.of(context).size.height * 0.82;

    return SafeArea(
      child: Container(
        constraints: BoxConstraints(maxHeight: maxH),
        padding: const EdgeInsets.all(AppDimens.cardPadding),
        child: _error != null
            ? SizedBox(
                height: 120,
                child: Center(
                    child: Text(_error!,
                        style: TextStyle(
                            fontSize: 14, color: colors.secondaryText))),
              )
            : plan == null
                ? const SizedBox(
                    height: 160,
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题行 + 容量
                      Text(
                        '规划今天',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: colors.titleText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '剩余可排 ${plan.capacityMinutes} 分钟 · 候选 ${plan.loadMinutes} 分钟 · 只读预览',
                        style: TextStyle(
                            fontSize: 12, color: colors.secondaryText),
                      ),
                      const SizedBox(height: AppDimens.space8),
                      Flexible(
                        child: plan.slots.isEmpty && plan.unscheduled.isEmpty
                            ? SizedBox(
                                height: 180,
                                child: const EmptyState(
                                  message:
                                      '没有可规划的任务\n给任务设置截止、加入我的一天或填写预计时长后给出建议',
                                  icon: OrbitIcons.calendarCheck,
                                ),
                              )
                            : ListView(
                                shrinkWrap: true,
                                children: [
                                  if (plan.overloaded)
                                    Container(
                                      margin: const EdgeInsets.only(
                                          bottom: AppDimens.space8),
                                      padding:
                                          const EdgeInsets.all(AppDimens.space8),
                                      decoration: BoxDecoration(
                                        color: OrbitAccents.myDayAmber
                                            .withValues(alpha: 0.12),
                                        borderRadius: AppShapes.small,
                                      ),
                                      child: Text(
                                        '候选总量超出今日剩余容量 ${plan.loadMinutes - plan.capacityMinutes} 分钟，建议把低优先级项移到明天',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: OrbitAccents.myDayAmber),
                                      ),
                                    ),
                                  for (final s in plan.slots)
                                    Container(
                                      margin: const EdgeInsets.only(
                                          bottom: 6),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: AppDimens.space12,
                                          vertical: AppDimens.space8),
                                      decoration: BoxDecoration(
                                        color: colors.surfaceSecondary,
                                        borderRadius: AppShapes.small,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 92,
                                            child: Text(
                                              '${_hhmm(s.startMs)} – ${_hhmm(s.endMs)}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color:
                                                      colors.secondaryText),
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              s.title,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  color: colors.titleText),
                                            ),
                                          ),
                                          const SizedBox(
                                              width: AppDimens.space8),
                                          Text(
                                            s.reason,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: s.reason.startsWith('已逾期')
                                                  ? OrbitAccents.overdueRed
                                                  : colors.secondaryText,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (plan.unscheduled.isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(
                                          top: AppDimens.space8,
                                          bottom: 4),
                                      child: Text(
                                        '未排入（${plan.unscheduled.length}）',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: colors.secondaryText),
                                      ),
                                    ),
                                    for (final u in plan.unscheduled)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                u.title,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    color: colors
                                                        .secondaryText),
                                              ),
                                            ),
                                            Text(
                                              u.reason,
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color:
                                                      colors.secondaryText),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                      ),
                      // 应用按钮（拇指区底部；勾选默认全选，可逐条取消）
                      if (plan.slots.isNotEmpty) ...[
                        const SizedBox(height: AppDimens.space8),
                        sh.Button.primary(
                          onPressed: _applying || _checked.isEmpty
                              ? null
                              : _apply,
                          child: Text(
                            _applying
                                ? '应用中…'
                                : '应用到 ${_checked.length} 条任务',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ],
                  ),
      ),
    );
  }
}
