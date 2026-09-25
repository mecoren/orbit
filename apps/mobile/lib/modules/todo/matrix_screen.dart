import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_dimens.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'logic/task_logic.dart';
import 'matrix_view.dart';
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
    final tasksAsync = ref.watch(todoTasksProvider);
    final tasks = tasksAsync.value ?? const <TodoTask>[];
    // 完成历史不入桶（groupEisenhower 内再兜一层）；桶内截止升序、无截止沉底
    final visible = sortTasks(
      tasks.where((t) => !t.isDone).toList(),
      TaskSortKey.due,
    );
    final topInset =
        MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: !tasksAsync.hasValue && tasksAsync.isLoading
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
                    padding: EdgeInsets.fromLTRB(
                      AppDimens.space12,
                      topInset + AppDimens.space8,
                      AppDimens.space12,
                      AppDimens.space16,
                    ),
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
