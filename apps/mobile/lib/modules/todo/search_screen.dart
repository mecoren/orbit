import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
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
  const SearchScreen({super.key});

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
                      ? const SizedBox.shrink()
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
          _header(context, '任务'),
          for (final t in result.tasks)
            ListTile(
              leading: Icon(
                t.done == 1
                    ? OrbitIcons.success
                    : OrbitIcons.circle,
                size: AppDimens.iconSizeMd,
                color: t.done == 1 ? OrbitAccents.todoAccent : colors.secondaryText,
              ),
              title: AnimatedStrikethrough(
                text: t.title,
                done: t.done == 1,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 15,
                  color: colors.titleText,
                ),
                doneColor: colors.titleText,
              ),
              subtitle: t.dueDate != null
                  ? Text(
                      _formatDate(t.dueDate!),
                      style:
                          TextStyle(fontSize: 12, color: colors.secondaryText),
                    )
                  : null,
              trailing: Text(
                priorityLabel(t.priority),
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              onTap: () => context.push('/todo/${t.id}'),
            ),
        ],
        if (result.projects.isNotEmpty) ...[
          _header(context, '项目'),
          for (final p in result.projects)
            ListTile(
              leading: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _parseColor(p.hexColor),
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
          _header(context, '评论'),
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

  Widget _header(BuildContext context, String label) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        AppDimens.space8,
        AppDimens.space16,
        AppDimens.space4,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colors.secondaryText,
        ),
      ),
    );
  }

  static String _formatDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static Color _parseColor(String? hex) {
    if (hex == null || hex.length != 7 || !hex.startsWith('#')) {
      return OrbitAccents.todoAccent;
    }
    final v = int.tryParse(hex.substring(1), radix: 16);
    return v == null ? OrbitAccents.todoAccent : Color(0xFF000000 | v);
  }
}
