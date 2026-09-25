import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_header.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

/// 全局搜索页 /todo/search（backlog #26：补齐与桌面 Ctrl+K 对等的能力）
///
/// 防抖 300ms → bridge.globalSearch 三路聚合（任务/项目/评论）：
/// - 任务行 → 点击进详情；项目行 → 点击进该项目子列表；
/// - 评论行 → 显示所属任务与内容摘要，点击进所属任务详情；
/// - 空态文案与桌面同口径（连续输入两字起更精准可选）。
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.showBack = true});

  /// 页头返回键（模块分支根传 false；推入语义保留默认）
  final bool showBack;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _scrollController = ScrollController();
  final _controller = TextEditingController();
  Timer? _debounce;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _keyword = _controller.text);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final kw = _keyword.trim();
    // family 参数复用 keyword 相等语义（防抖后重查）
    final result =
        kw.isEmpty ? null : ref.watch(searchProvider(kw)).value;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                SizedBox(
                  height: MediaQuery.of(context).padding.top +
                      OrbitPageHeader.rowHeight,
                ),
                // 搜索框（自动聚焦）
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space16,
                  ),
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(fontSize: 15, color: colors.titleText),
                    decoration: InputDecoration(
                      hintText: '搜索任务 / 项目 / 评论',
                      hintStyle:
                          TextStyle(fontSize: 15, color: colors.secondaryText),
                      prefixIcon: Icon(
                        OrbitIcons.search,
                        size: AppDimens.iconSizeMd,
                        color: colors.secondaryText,
                      ),
                      suffixIcon: _keyword.isNotEmpty
                          ? IconButton(
                              tooltip: '清除搜索',
                              icon: Icon(
                                OrbitIcons.close,
                                size: AppDimens.iconSizeMd,
                                color: colors.secondaryText,
                              ),
                              onPressed: () {
                                _controller.clear();
                                setState(() => _keyword = '');
                              },
                            )
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  child: result == null
                      // 初始态给引导占位：整块空白会让「搜不了」像「坏了」
                      ? const EmptyState(
                          message: '输入关键词，搜索任务、项目或评论',
                          icon: OrbitIcons.search,
                        )
                      : _ResultList(result: result, scrollController: _scrollController),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '搜索',
              showBack: widget.showBack,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultList extends StatelessWidget {
  const _ResultList({required this.result, required this.scrollController});

  final GlobalSearchResult result;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    if (result.tasks.isEmpty &&
        result.projects.isEmpty &&
        result.comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 64),
        child: EmptyState(
          message: '没有找到相关内容',
          icon: OrbitIcons.searchEmpty,
        ),
      );
    }

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.only(
        top: AppDimens.space8,
        // 底栏页签常驻：页尾只留呼吸留白
        bottom: AppDimens.space16,
      ),
      children: [
        if (result.tasks.isNotEmpty) ...[
          const OrbitSectionHeader(label: '任务'),
          for (final t in result.tasks)
            _TaskResultRow(task: t, projects: result.projects),
        ],
        if (result.projects.isNotEmpty) ...[
          const OrbitSectionHeader(label: '项目'),
          for (final p in result.projects)
            ListTile(
              leading: Container(
                width: AppDimens.colorDotSize,
                height: AppDimens.colorDotSize,
                decoration: BoxDecoration(
                  // 解析失败回落 hexToColor 默认值（即待办强调色）
                  color: hexToColor(p.hexColor),
                  shape: BoxShape.circle,
                ),
              ),
              title: Text(
                p.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: colors.titleText,
                ),
              ),
              trailing: Icon(
                OrbitIcons.chevronRight,
                size: AppDimens.iconSizeMd,
                color: colors.secondaryText,
              ),
              onTap: () => context.push('/todo/tasks?projectId=${p.id}'),
            ),
        ],
        if (result.comments.isNotEmpty) ...[
          const OrbitSectionHeader(label: '评论'),
          for (final c in result.comments)
            ListTile(
              leading: Icon(
                OrbitIcons.message,
                size: AppDimens.iconSizeMd,
                color: colors.secondaryText,
              ),
              title: Text(
                c.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: colors.titleText),
              ),
              subtitle: Text(
                '评论于「${c.taskTitle}」',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              onTap: () => context.push('/todo/${c.taskId}'),
            ),
        ],
      ],
    );
  }
}

/// 搜索结果任务行：视觉对齐主列表任务行（信息层级 / 完成态 / 逾期色同口径）
///
/// 刻意不带勾选框与侧滑：搜索语境是只读跳板，完成操作进详情做——
/// 引导图标用「描边色承载优先级」的圆圈语言与列表行呼应（P0「无」回落次要色）。
class _TaskResultRow extends StatelessWidget {
  const _TaskResultRow({required this.task, required this.projects});

  final TodoTask task;
  final List<TodoProject> projects;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final done = task.isDone;
    final overdue = isOverdue(task);
    final project = task.projectId == null
        ? null
        : projects.where((p) => p.id == task.projectId).firstOrNull;
    final ringHex = done ? null : priorityRingHex(task.priority);
    final dueLabel =
        task.dueDate == null ? null : formatDueShort(task.dueDate!);

    return InkWell(
      onTap: () => context.push('/todo/${task.id}'),
      child: Container(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space16,
          vertical: AppDimens.space8,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: Row(
          children: [
            Icon(
              done ? OrbitIcons.success : OrbitIcons.circle,
              size: AppDimens.iconSizeLg,
              color: done
                  ? OrbitAccents.todoAccent
                  : (ringHex != null
                      ? hexToColor(ringHex)
                      : colors.secondaryText),
            ),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedStrikethrough(
                    text: task.title,
                    done: done,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: colors.titleText,
                    ),
                    // 完成态全口径统一：划线 + 置灰一档
                    doneColor: colors.secondaryText,
                  ),
                  if (project != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        project.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          // 项目名按项目色着字（无色回退次要色，与列表行同口径）
                          color: project.hexColor.isNotEmpty
                              ? hexToColor(project.hexColor,
                                  fallback: colors.secondaryText)
                              : colors.secondaryText,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (dueLabel != null) ...[
              const SizedBox(width: AppDimens.space8),
              Text(
                dueLabel,
                style: TextStyle(
                  fontSize: 12,
                  // 未来与今天走主题蓝，逾期转红（任务行同口径）
                  color: overdue
                      ? OrbitAccents.overdueRed
                      : OrbitAccents.themeAccent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
