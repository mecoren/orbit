import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/confirm_bottom_sheet.dart';
import '../../shared/widgets/controller_disposer.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/more_actions_sheet.dart' show bottomSheetTopShape;
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/wait_toast.dart';
import '../todo/logic/task_logic.dart' show labelPaletteHexes;
import '../todo/providers/todo_providers.dart';

/// 标签管理页 /settings/labels（对齐桌面 `label-manager.tsx`）
///
/// 移动端此前只能在任务详情里「新建并挂载」，改名/改色/删除都没有入口
/// （列表页标签筛选与卡片色点都依赖标签属性，缺管理入口会让标签体系
/// 一旦建错就永久错）。
///
/// 与桌面的差异：删除不给撤销。桌面撤销是「重建同名同色行」，任务上的
/// 历史关联无法恢复——重建出来的标签看起来一样但关联全丢，反而更危险，
/// 故此处改为确认抽屉明示后果，不做假撤销。
class LabelManagerPage extends ConsumerStatefulWidget {
  const LabelManagerPage({super.key});

  @override
  ConsumerState<LabelManagerPage> createState() => _LabelManagerPageState();
}

class _LabelManagerPageState extends ConsumerState<LabelManagerPage> {
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

  List<TodoLabel> get _labels =>
      ref.watch(todoLabelsProvider).value ?? const <TodoLabel>[];

  void _refresh() {
    ref.invalidate(todoLabelsProvider);
    ref.invalidate(taskLabelsProjectionProvider);
    ref.invalidate(taskDetailProvider);
  }

  // ── 色板抽屉（8 色，行高满足触控热区） ──

  Future<String?> _pickColor(String current) async {
    final colors = AppColors.ofContext(context);
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Text(
                '标签颜色',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space16,
                vertical: AppDimens.space8,
              ),
              child: Wrap(
                spacing: AppDimens.space16,
                runSpacing: AppDimens.space16,
                children: [
                  for (final hex in labelPaletteHexes)
                    GestureDetector(
                      onTap: () => Navigator.of(sheetContext).pop(hex),
                      child: Container(
                        width: AppDimens.touchTarget - AppDimens.space8,
                        height: AppDimens.touchTarget - AppDimens.space8,
                        decoration: BoxDecoration(
                          color: hexToColor(hex),
                          shape: BoxShape.circle,
                          border: hex.toUpperCase() == current.toUpperCase()
                              ? Border.all(
                                  color: colors.titleText,
                                  width: 2,
                                )
                              : null,
                        ),
                        child: hex.toUpperCase() == current.toUpperCase()
                            ? const Icon(Icons.check_rounded,
                                size: AppDimens.iconSizeSm,
                                color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: AppDimens.gestureInsetFallback / 2),
          ],
        ),
      ),
    );
  }

  // ── 写操作 ──

  Future<void> _createLabel() async {
    final draft = await _askLabelDraft(title: '新建标签');
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).todoLabelCreate(
            TodoLabelCreateInput(
              title: draft.$1,
              hexColor: draft.$2,
            ),
          );
      _refresh();
      if (mounted) WaitToast.success('已创建标签「${draft.$1}」');
    } catch (e) {
      if (mounted) WaitToast.destructive('创建失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(TodoLabel label) async {
    final draft = await _askLabelDraft(
      title: '编辑标签',
      initialTitle: label.title,
      initialColor: label.hexColor,
    );
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).todoLabelUpdate(
            label.id,
            encodePatch({'title': draft.$1, 'hex_color': draft.$2}),
          );
      _refresh();
      if (mounted) WaitToast.success('已保存');
    } catch (e) {
      if (mounted) WaitToast.destructive('保存失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeColor(TodoLabel label) async {
    final hex = await _pickColor(label.hexColor);
    if (hex == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoLabelUpdate(label.id, encodePatch({'hex_color': hex}));
      _refresh();
    } catch (e) {
      if (mounted) WaitToast.destructive('改色失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(TodoLabel label) async {
    final ok = await showConfirmBottomSheet(
      context,
      title: '删除标签「${label.title}」？',
      message: '标签会从所有任务上移除，且无法撤销（任务本身不受影响）。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).todoLabelDelete(label.id);
      _refresh();
      if (mounted) WaitToast.success('已删除标签');
    } catch (e) {
      if (mounted) WaitToast.destructive('删除失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 新建/编辑共用表单（标题 + 色板；返回 (名称, 颜色hex)）
  Future<(String, String)?> _askLabelDraft({
    required String title,
    String initialTitle = '',
    String initialColor = '#3B82F6',
  }) async {
    final controller = TextEditingController(text: initialTitle);
    var color = initialColor;
    {
      final ok = await showDialog<bool>(
        context: context,
        // 控制器交给对话框子树释放（弹层退出动画期间表单会重建一次，
        // 提前 dispose 会让那一帧读到已释放的 controller）
        builder: (ctx) => ControllerDisposer(
          controllers: [controller],
          child: StatefulBuilder(
          builder: (ctx, setDialogState) {
            final colors = AppColors.ofContext(ctx);
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '标签名称'),
                  ),
                  const SizedBox(height: AppDimens.space16),
                  Wrap(
                    spacing: AppDimens.space12,
                    runSpacing: AppDimens.space12,
                    children: [
                      for (final hex in labelPaletteHexes)
                        GestureDetector(
                          onTap: () => setDialogState(() => color = hex),
                          child: Container(
                            width: AppDimens.touchTarget - AppDimens.space12,
                            height: AppDimens.touchTarget - AppDimens.space12,
                            decoration: BoxDecoration(
                              color: hexToColor(hex),
                              shape: BoxShape.circle,
                              border: hex.toUpperCase() == color.toUpperCase()
                                  ? Border.all(color: colors.titleText, width: 2)
                                  : null,
                            ),
                            child: hex.toUpperCase() == color.toUpperCase()
                                ? const Icon(Icons.check_rounded,
                                    size: AppDimens.iconSizeSm,
                                    color: Colors.white)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
          ),
        ),
      );
      if (ok != true) return null;
      final name = controller.text.trim();
      if (name.isEmpty) {
        WaitToast.destructive('标签名称不能为空');
        return null;
      }
      return (name, color);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final labels = _labels;

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
                  title: '标签',
                  subtitle: labels.isEmpty ? null : '${labels.length} 个',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '标签用于跨项目归类任务；列表页可按标签筛选，看板与表格会显示标签色点。',
                        style:
                            TextStyle(fontSize: 12, color: colors.secondaryText),
                      ),
                      const SizedBox(height: AppDimens.space8),
                      if (labels.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppDimens.space16),
                          child: Center(
                            child: Text(
                              '还没有标签。',
                              style: TextStyle(
                                  fontSize: 12, color: colors.secondaryText),
                            ),
                          ),
                        )
                      else
                        for (final l in labels) _row(colors, l),
                      const SizedBox(height: AppDimens.space8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _createLabel,
                          icon: const Icon(Icons.add_rounded,
                              size: AppDimens.iconSizeSm + 2),
                          label: const Text('新建标签'),
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
              title: '标签管理',
              scrollOffsetListenable:
                  ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(AppColorSet colors, TodoLabel label) {
    return Container(
      margin: const EdgeInsets.only(top: AppDimens.space8),
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space12,
        vertical: AppDimens.space4,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        children: [
          // 色点即改色入口（点一下弹色板抽屉）
          InkWell(
            borderRadius: AppShapes.small,
            onTap: _busy ? null : () => _changeColor(label),
            child: Padding(
              padding: const EdgeInsets.all(AppDimens.space8),
              child: Container(
                width: AppDimens.colorDotSize + AppDimens.space4,
                height: AppDimens.colorDotSize + AppDimens.space4,
                decoration: BoxDecoration(
                  color: hexToColor(label.hexColor),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppDimens.space8),
          Expanded(
            child: Text(
              label.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.bodyText),
            ),
          ),
          IconButton(
            onPressed: _busy ? null : () => _rename(label),
            tooltip: '编辑',
            icon: Icon(Icons.edit_outlined,
                size: AppDimens.iconSizeMd, color: colors.secondaryText),
          ),
          IconButton(
            onPressed: _busy ? null : () => _delete(label),
            tooltip: '删除',
            icon: Icon(Icons.delete_outline_rounded,
                size: AppDimens.iconSizeMd, color: colors.destructive),
          ),
        ],
      ),
    );
  }
}
