import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/confirm_bottom_sheet.dart';
import '../../shared/widgets/controller_disposer.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/more_actions_sheet.dart' show bottomSheetTopShape;
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/select_bottom_sheet.dart';
import '../../shared/widgets/wait_toast.dart';
import '../todo/logic/task_logic.dart' show priorityLabel;
import '../todo/logic/template_apply.dart';
import '../todo/providers/todo_providers.dart';

/// 任务模板管理页 /settings/templates（对齐桌面 `templates-section.tsx`）
///
/// 移动端此前只有「长按 FAB 套用」这一个消费面，没有创建/编辑入口——
/// 模板 payload 只能靠桌面端或手写 JSON 产生。本页补齐 full CRUD。
///
/// 表单字段对齐模板 payload 白名单（`title / notes / priority /
/// due_offset_days / subtasks`，与 Rust `ALLOWED_PAYLOAD_KEYS` 同口径），
/// 白名单之外的键不会出现在表单里，也就无从产生非法 payload。
class TemplateManagerPage extends ConsumerStatefulWidget {
  const TemplateManagerPage({super.key});

  @override
  ConsumerState<TemplateManagerPage> createState() =>
      _TemplateManagerPageState();
}

class _TemplateManagerPageState extends ConsumerState<TemplateManagerPage> {
  final _scrollController = ScrollController();
  bool _busy = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  /// 模板列表（页面进入时拉取一次；写操作后 invalidate 重拉）
  final _templatesProvider = FutureProvider.autoDispose<List<TodoTemplate>>(
    (ref) => ref.watch(orbitBridgeProvider).templatesList(),
  );

  List<TodoTemplate> get _templates =>
      ref.watch(_templatesProvider).value ?? const <TodoTemplate>[];

  void _refresh() {
    ref.invalidate(_templatesProvider);
    ref.invalidate(todoTasksProvider);
  }

  Future<void> _upsert({TodoTemplate? editing}) async {
    final draft = await _showTemplateForm(editing: editing);
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    final bridge = ref.read(orbitBridgeProvider);
    try {
      final payloadJson = jsonEncode(draft.payload);
      if (editing == null) {
        await bridge.templateCreate(draft.name, payloadJson);
      } else {
        await bridge.templateUpdate(editing.id, draft.name, payloadJson);
      }
      _refresh();
      if (mounted) {
        WaitToast.success(editing == null ? '已新建模板' : '已保存模板');
      }
    } catch (e) {
      if (mounted) WaitToast.destructive('保存失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(TodoTemplate tpl) async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '删除模板「${tpl.name}」？',
      message: '已按该模板创建的任务不受影响。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).templateDelete(tpl.id);
      _refresh();
      if (mounted) WaitToast.success('已删除模板');
    } catch (e) {
      if (mounted) WaitToast.destructive('删除失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 模板表单底部抽屉（新建/编辑共用）
  Future<({String name, Map<String, Object?> payload})?> _showTemplateForm(
      {TodoTemplate? editing}) async {
    final parsed = editing == null
        ? const TemplatePayload()
        : parseTemplatePayload(editing.payload);
    final nameCtrl = TextEditingController(text: editing?.name ?? '');
    final titleCtrl = TextEditingController(text: parsed.title ?? '');
    final notesCtrl = TextEditingController(text: parsed.notes ?? '');
    final subtasksCtrl =
        TextEditingController(text: parsed.subtasks.join('\n'));
    int? priority = parsed.priority;
    int? offsetDays = parsed.dueOffsetDays;
    final colors = AppColors.ofContext(context);

    return showModalBottomSheet<({String name, Map<String, Object?> payload})>(
        context: context,
        isScrollControlled: true,
        backgroundColor: colors.popup,
        shape: bottomSheetTopShape,
        builder: (sheetContext) => ControllerDisposer(
          controllers: [nameCtrl, titleCtrl, notesCtrl, subtasksCtrl],
          child: StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final sheetColors = AppColors.ofContext(sheetContext);
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: SafeArea(
                top: false,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        MediaQuery.of(sheetContext).size.height * 0.85,
                  ),
                  // 表单滚动 + 底部操作区固定：长表单（备注/子任务多行）会把
                  // 保存按钮顶出可视区，固定尾栏才保证「保存」始终可点
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(AppDimens.space16),
                    children: [
                      Text(
                        editing == null ? '新建模板' : '编辑模板',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: sheetColors.titleText,
                        ),
                      ),
                      const SizedBox(height: AppDimens.space16),
                      TextField(
                        key: const ValueKey('tpl-field-name'),
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: '模板名称',
                          helperText: '列表里显示的名字',
                        ),
                      ),
                      const SizedBox(height: AppDimens.space12),
                      TextField(
                        key: const ValueKey('tpl-field-title'),
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: '任务标题',
                          helperText: '套用时预填；留空则不预填',
                        ),
                      ),
                      const SizedBox(height: AppDimens.space8),
                      _selectRow(
                        label: '优先级',
                        value: priority == null
                            ? '不预填'
                            : priorityLabel(priority!),
                        onTap: () => showSelectBottomSheet<int>(
                          sheetContext,
                          title: '优先级',
                          current: priority,
                          items: [
                            for (var p = 0; p <= 5; p++)
                              SelectItem(value: p, label: priorityLabel(p)),
                          ],
                          onSelect: (v) =>
                              setSheetState(() => priority = v),
                        ),
                      ),
                      _selectRow(
                        label: '截止偏移',
                        value: offsetDays == null ? '不预填' : '$offsetDays 天后',
                        onTap: () async {
                          await showSelectBottomSheet<int>(
                            sheetContext,
                            title: '截止偏移（套用当天起算）',
                            current: offsetDays,
                            items: [
                              for (final d in const [0, 1, 3, 7, 14, 30])
                                SelectItem(
                                  value: d,
                                  label: d == 0 ? '今天' : '$d 天后',
                                ),
                            ],
                            onSelect: (v) =>
                                setSheetState(() => offsetDays = v),
                          );
                        },
                      ),
                      const SizedBox(height: AppDimens.space12),
                      TextField(
                        key: const ValueKey('tpl-field-notes'),
                        controller: notesCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: '备注（可选）',
                        ),
                      ),
                      const SizedBox(height: AppDimens.space12),
                      TextField(
                        key: const ValueKey('tpl-field-subtasks'),
                        controller: subtasksCtrl,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '子任务（每行一条，可选）',
                        ),
                      ),
                    ],
                  ),
                      ),
                      // 固定尾栏：不随表单滚动，保证「保存」始终可点
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppDimens.space16,
                          AppDimens.space8,
                          AppDimens.space16,
                          AppDimens.space16,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    Navigator.of(sheetContext).pop(null),
                                child: const Text('取消'),
                              ),
                            ),
                            const SizedBox(width: AppDimens.space8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () {
                                  final name = nameCtrl.text.trim();
                                  if (name.isEmpty) {
                                    WaitToast.destructive('模板名称不能为空');
                                    return;
                                  }
                                  Navigator.of(sheetContext).pop((
                                    name: name,
                                    payload: _buildPayload(
                                      title: titleCtrl.text,
                                      notes: notesCtrl.text,
                                      priority: priority,
                                      offsetDays: offsetDays,
                                      subtasks: subtasksCtrl.text,
                                    ),
                                  ));
                                },
                                child: const Text('保存'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                          height: MediaQuery.of(sheetContext).padding.bottom),
                    ],
                  ),
                ),
              ),
            );
          },
          ),
        ),
      );
  }

  /// 表单 → payload（只出白名单键；空值不出键 = 套用时不预填）
  Map<String, Object?> _buildPayload({
    required String title,
    required String notes,
    required int? priority,
    required int? offsetDays,
    required String subtasks,
  }) {
    final t = title.trim();
    final n = notes.trim();
    final subs = subtasks
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return {
      if (t.isNotEmpty) 'title': t,
      if (n.isNotEmpty) 'notes': n,
      // null 即「不预填」：用 null-aware entry 直接省掉该键，
      // 而不是写进 null（Rust 侧按「存在键」判预填，null 会被当成值）
      'priority': ?priority,
      'due_offset_days': ?offsetDays,
      if (subs.isNotEmpty) 'subtasks': subs,
    };
  }

  Widget _selectRow({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final colors = AppColors.ofContext(context);
    return InkWell(
      borderRadius: AppShapes.medium,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        child: Row(
          children: [
            Text(label,
                style: TextStyle(fontSize: 14, color: colors.bodyText)),
            const Spacer(),
            Text(
              value,
              style: TextStyle(fontSize: 14, color: OrbitAccents.themeAccent),
            ),
            Icon(Icons.chevron_right_rounded,
                size: AppDimens.iconSizeMd, color: colors.secondaryText),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final templates = _templates;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              controller: _scrollController,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top +
                    LiquidGlassTitleBar.rowHeight +
                    AppDimens.space16,
                left: AppDimens.space16,
                right: AppDimens.space16,
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                SectionCard(
                  title: '任务模板',
                  subtitle: templates.isEmpty ? null : '${templates.length} 个',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '模板用于一键生成常用任务（含子任务与默认优先级/截止偏移）。'
                        '在任务列表长按右下角新建按钮即可套用。',
                        style:
                            TextStyle(fontSize: 12, color: colors.secondaryText),
                      ),
                      const SizedBox(height: AppDimens.space8),
                      if (templates.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppDimens.space16),
                          child: Center(
                            child: Text(
                              '还没有模板。',
                              style: TextStyle(
                                  fontSize: 12, color: colors.secondaryText),
                            ),
                          ),
                        )
                      else
                        for (final t in templates) _card(colors, t),
                      const SizedBox(height: AppDimens.space8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : () => _upsert(),
                          icon: const Icon(Icons.add_rounded,
                              size: AppDimens.iconSizeSm + 2),
                          label: const Text('新建模板'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '任务模板',
              scrollOffsetListenable:
                  ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(AppColorSet colors, TodoTemplate tpl) {
    final p = parseTemplatePayload(tpl.payload);
    final priorityText =
        p.priority == null ? null : '优先级 ${priorityLabel(p.priority!)}';
    final offsetText = p.dueOffsetDays == null
        ? null
        : (p.dueOffsetDays == 0 ? '今天截止' : '${p.dueOffsetDays} 天后截止');
    final subtaskText =
        p.subtasks.isEmpty ? null : '${p.subtasks.length} 个子任务';
    final subtitle = [
      ?p.title,
      ?priorityText,
      ?offsetText,
      ?subtaskText,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(top: AppDimens.space8),
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space12,
        vertical: AppDimens.space4,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary.withValues(alpha: 0.4),
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: AppShapes.small,
              onTap: _busy ? null : () => _upsert(editing: tpl),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: AppDimens.space8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tpl.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: colors.bodyText),
                    ),
                    const SizedBox(height: AppDimens.space2),
                    Text(
                      subtitle.isEmpty ? '无预填字段' : subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 11, color: colors.secondaryText),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: _busy ? null : () => _upsert(editing: tpl),
            tooltip: '编辑',
            icon: Icon(Icons.edit_outlined,
                size: AppDimens.iconSizeMd, color: colors.secondaryText),
          ),
          IconButton(
            onPressed: _busy ? null : () => _delete(tpl),
            tooltip: '删除',
            icon: Icon(Icons.delete_outline_rounded,
                size: AppDimens.iconSizeMd, color: colors.destructive),
          ),
        ],
      ),
    );
  }
}

// 表单控制器的释放交给 shared/widgets/controller_disposer.dart 的
// ControllerDisposer（见该文件顶部关于「弹层退出动画期重建」的说明）。
