import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_dimens.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'logic/paged_query.dart';
import 'logic/task_logic.dart';
import 'matrix_view.dart';
import 'providers/task_window_provider.dart';
import 'providers/todo_providers.dart';

/// 四象限页签 /todo/matrix（独立主导航入口）
///
/// 全量任务（跨项目）按轴口径落桶：重要 = 优先级≥高，紧急 = 截止≤今天末；
/// 桶内按截止升序（无截止沉底），与列表档排序口径同源。整幅 2×2 恒在，
/// 板面填满页头与底栏之间的可视区（不做整页滚动，格内自滚见
/// [EisenhowerMatrixBoard]）。
class MatrixScreen extends ConsumerWidget {
  const MatrixScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 提醒投影（A4 只读聚合）：行内提醒徽标数据源；未就绪回落空表
    final reminderRows = ref.watch(taskRemindersProjectionProvider).value ??
        const <TaskRemindersProjection>[];
    final remindersByTask = {
      for (final r in reminderRows) r.taskId: r.reminders,
    };
    // 四象限窗口化（P1）：每象限前 kBoardPageLimit 条 + 象限真实总数；
    // 完成历史不入桶（board 谓词 done=false），桶内截止升序、无截止沉底
    //（filter.sort_key=due 与旧 sortTasks(due) 同口径）。
    final now = DateTime.now();
    final dayStart =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final boardAsync = ref.watch(taskBoardProvider(BoardQuery(
      query: const PagedTaskQuery(
        filter: ListFilter(done: false, sortKey: 'due', sortDir: 'asc'),
        sortKey: 'due',
        sortDir: 'asc',
      ),
      groupBy: TodoBoardGroupBy.quadrant,
      dayStart: dayStart,
      dayEnd: dayStart + 86400000,
    )));
    final board = boardAsync.value;
    final visible = [
      for (final g in board?.groups ?? const <TodoTaskBoardGroup>[]) ...g.items,
    ];
    final totalByQuadrant = board == null
        ? null
        : {
            for (final g in board.groups)
              for (final q in EisenhowerQuadrant.values)
                if (q.name == g.key) q: g.total,
          };
    final topInset =
        MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: !boardAsync.hasValue && boardAsync.isLoading
                // 初次加载骨架：与列表页同款占位（四格等分板在数据前不闪空象限）
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      AppDimens.space12,
                      topInset + AppDimens.space8,
                      AppDimens.space12,
                      AppDimens.space16,
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Expanded(child: OrbitSkeleton.block()),
                              const SizedBox(width: AppDimens.cardGap),
                              const Expanded(child: OrbitSkeleton.block()),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppDimens.cardGap),
                        Expanded(
                          child: Row(
                            children: [
                              const Expanded(child: OrbitSkeleton.block()),
                              const SizedBox(width: AppDimens.cardGap),
                              const Expanded(child: OrbitSkeleton.block()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : EisenhowerMatrixBoard(
                    tasks: visible,
                    totalByQuadrant: totalByQuadrant,
                    padding: EdgeInsets.fromLTRB(
                      AppDimens.space12,
                      topInset + AppDimens.space8,
                      AppDimens.space12,
                      AppDimens.space16,
                    ),
                    remindersByTask: remindersByTask,
                    onOpen: (t) => context.push('/todo/${t.id}'),
                    onToggleDone: (t) async {
                      try {
                        if (t.isDone) {
                          await ref.read(orbitBridgeProvider).todoTaskUpdate(
                                t.id,
                                encodePatch(buildDoneTogglePatch(t)),
                              );
                        } else {
                          await ref
                              .read(orbitBridgeProvider)
                              .todoTaskComplete(t.id);
                        }
                        ref.invalidate(todoTasksProvider);
                        ref.invalidate(taskBoardProvider);
                        ref.invalidate(taskDetailProvider);
                      } catch (_) {
                        WaitToast.destructive('更新失败');
                      }
                    },
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '四象限',
              // 页签根：无返回键（底部导航承担回退语义）
              showBack: false,
            ),
          ),
        ],
      ),
    );
  }
}
