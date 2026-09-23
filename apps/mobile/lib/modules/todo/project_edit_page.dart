import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_color_picker.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_panel.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import 'logic/project_actions.dart';
import 'logic/project_palette.dart';
import 'logic/view_mode.dart';
import 'providers/todo_providers.dart';

/// 编辑项目整页（2026-09-23：由 `AlertDialog` 升级为整页）
///
/// 版式对齐竞品「编辑清单」：页头 = `X` 关闭 + 标题 + `✓` 保存 + `⋮` 更多；
/// 主体两段 ✅→ 名称行（项目名，行首文件夹图标按项目色染色，与侧栏同形制）
/// /「清单颜色」（无颜色 + 10 色预设 + 自定义取色）/「视图类型」（列表 / 看板 /
/// 表格三张预览卡，选中打勾并写入**每项目视图档**）。
///
/// **为什么整页**：对话框放不下「颜色 + 视图档」两组带预览的选项，且移动端
/// 弹层宽度受限（AGENTS.md 选择类交互口径）——整页给足横向空间，也顺带让
/// 「归档 / 删除」有地方收（页头 ⋮，沿用 [deleteProject] 的删除保护流）。
///
/// **有意不做**（参考图里的剩余项，对应 Orbit 不存在的概念）：添加新成员（协作，
/// docs/10 §八 明确不跟进）、文件夹（清单层级，backlog B-1 要动 DDL）、
/// 清单类型 / 在智能清单中显示（Orbit 无智能清单，只有保存的筛选器）、背景。
/// 段落标题走 [SectionCard]（accent 色）而非参考图的深色标题——与详情页区块
/// 同口径，不为单页另立一套。
class ProjectEditPage extends ConsumerStatefulWidget {
  const ProjectEditPage({super.key, required this.projectId});

  /// 路由参数；非法 id 走「项目不存在」态
  final int? projectId;

  @override
  ConsumerState<ProjectEditPage> createState() => _ProjectEditPageState();
}

class _ProjectEditPageState extends ConsumerState<ProjectEditPage> {
  final _titleController = TextEditingController();

  /// 当前选择（`projectNoColor` 空串 = 无颜色）
  String _color = projectNoColor;
  TaskViewMode _viewMode = TaskViewMode.list;

  /// 初值快照：判断「有无改动」（✓ 按钮的可用态）与「视图档要不要落盘」
  String _originalTitle = '';
  String _originalColor = projectNoColor;
  TaskViewMode _originalViewMode = TaskViewMode.list;

  /// 已按项目初始化过一次（provider 首帧可能尚未就绪，故与 build 同帧补种）
  bool _seeded = false;
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  /// 用项目当前值播种表单（幂等；只在首次进入与项目首次到达时调用）
  void _seed(TodoProject project) {
    _titleController.text = project.title;
    _color = project.hexColor;
    _viewMode = loadViewModeForProject(project.id);
    _originalTitle = project.title;
    _originalColor = project.hexColor;
    _originalViewMode = _viewMode;
    _seeded = true;
  }

  bool _isDirty(TodoProject project) =>
      _titleController.text.trim() != _originalTitle ||
      _color != _originalColor ||
      _viewMode != _originalViewMode;

  /// 该项目下未完成任务数（删除保护流用；与侧栏计数同口径）
  ///
  /// 在 build 里算、随点击带进去，而不是回调里现读：`todoTasksProvider` 若没有
  /// 任何 watch 方就**从未被创建**，首帧 `read().value` 恒为 null——删除保护会
  /// 静默失效（有未完成任务也照删）。watch 一次即可保证已加载且随变更刷新。
  int _undoneCount(List<TodoTask> tasks, TodoProject project) =>
      tasks.where((t) => t.projectId == project.id && !t.isDone).length;

  Future<void> _save(TodoProject project) async {
    setState(() => _saving = true);
    final ok = await saveProject(
      ref,
      project: project,
      title: _titleController.text,
      hexColor: _color,
    );
    // 视图档只写「项目档」：全局档保持「非项目视图的默认值」语义；
    // 用户没改过视图档时不落盘（否则会把全局档钉死成该项目的初值）。
    // 不 await 落盘（与列表页 [_setViewMode] 同口径）：内存态即时生效，
    // 写盘失败静默——不必为一次偏好写盘阻塞「保存并返回」
    if (_viewMode != _originalViewMode) {
      unawaited(saveProjectViewMode(project.id, _viewMode));
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) context.pop();
  }

  /// 页头 ⋮：归档 / 取消归档 + 删除（与侧栏长按菜单同一套写路径）
  void _showMorePanel(TodoProject project, int undoneCount) {
    showOrbitDropdownPanel(
      context,
      topInset: _topInset(context),
      groups: [
        [
          OrbitPanelItem(
            icon: OrbitIcons.archive,
            label: project.isArchived == 1 ? '取消归档' : '归档项目',
            onTap: () => toggleProjectArchive(ref, project),
          ),
          OrbitPanelItem(
            icon: OrbitIcons.delete,
            label: '删除项目',
            color: OrbitAccents.overdueRed,
            onTap: () => _delete(project, undoneCount),
          ),
        ],
      ],
    );
  }

  Future<void> _delete(TodoProject project, int undoneCount) async {
    final deleted =
        await deleteProject(ref, context, project, undoneCount);
    // 删掉的项目没有可返回的列表页：直接回侧栏（被删项目仍在栈上会留下空列表）
    if (deleted && mounted) context.go('/todo');
  }

  Future<void> _pickCustomColor() async {
    final picked = await showOrbitColorPickerSheet(
      context,
      initial: hexToColor(_color.isEmpty ? null : _color),
    );
    if (picked == null || !mounted) return;
    setState(() => _color = colorToHex(picked));
  }

  double _topInset(BuildContext context) =>
      MediaQuery.of(context).padding.top + OrbitPageHeader.rowHeight;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final projectId = widget.projectId;
    final project = projectId == null
        ? null
        : (ref.watch(todoProjectsProvider).value ?? const <TodoProject>[])
            .where((p) => p.id == projectId)
            .firstOrNull;

    // provider 首帧未就绪时就地补种（同一帧内使用，故不 setState）
    if (project != null && !_seeded) _seed(project);

    // 任务列表只为「删除保护流」的未完成数服务：watch 一次保证已加载
    //（见 [_undoneCount] 的注释：没有 watch 方时 provider 从未被创建）
    final tasks = ref.watch(todoTasksProvider).value ?? const <TodoTask>[];
    final undoneCount = project == null ? 0 : _undoneCount(tasks, project);

    final topInset = _topInset(context);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: project == null
                ? Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: const EmptyState(message: '项目不存在或已删除'),
                  )
                : _form(colors, project, topInset),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              showBack: false,
              leading: IconButton(
                tooltip: '关闭',
                padding: const EdgeInsets.only(right: AppDimens.space8),
                icon: Icon(
                  OrbitIcons.close,
                  size: AppDimens.iconSizeLg,
                  color: colors.titleText,
                ),
                onPressed: () {
                  if (context.canPop()) context.pop();
                },
              ),
              title: '编辑项目',
              actions: [
                // 保存：无改动时置灰（避免「点了没反应」的空提交）
                IconButton(
                  tooltip: '保存',
                  onPressed: project == null || _saving || !_isDirty(project)
                      ? null
                      : () => _save(project),
                  icon: _saving
                      ? const SizedBox(
                          width: AppDimens.iconSizeSm,
                          height: AppDimens.iconSizeSm,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          OrbitIcons.check,
                          size: AppDimens.iconSizeLg,
                          color: project != null && _isDirty(project)
                              ? colors.titleText
                              : colors.deactivatedText,
                        ),
                ),
                IconButton(
                  tooltip: '更多操作',
                  onPressed: project == null
                      ? null
                      : () => _showMorePanel(project, undoneCount),
                  icon: Icon(
                    OrbitIcons.moreVertical,
                    size: AppDimens.iconSizeMd,
                    color: colors.titleText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(AppColorSet colors, TodoProject project, double topInset) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppDimens.space16,
        topInset + AppDimens.space8,
        AppDimens.space16,
        AppDimens.gestureInsetFallback + AppDimens.space32,
      ),
      children: [
        _nameRow(colors),
        const SizedBox(height: AppDimens.cardGap),
        SectionCard(
          title: '清单颜色',
          child: _colorRow(colors),
        ),
        const SizedBox(height: AppDimens.cardGap),
        SectionCard(
          title: '视图类型',
          child: Row(
            children: [
              for (final mode in TaskViewMode.values) ...[
                _viewTypeCard(colors, mode),
                if (mode != TaskViewMode.values.last)
                  const SizedBox(width: AppDimens.space8),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 名称行：行首文件夹图标按当前色染色（与侧栏项目行同形制），无边框输入
  Widget _nameRow(AppColorSet colors) {
    return OrbitCard(
      child: Row(
        children: [
          Icon(
            OrbitIcons.folder,
            size: AppDimens.iconSizeMd,
            color: _color.isEmpty ? colors.accent : hexToColor(_color),
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: TextField(
              controller: _titleController,
              maxLength: 50,
              textInputAction: TextInputAction.done,
              // 无边框内联输入（同详情页标题原地编辑口径）
              style: TextStyle(fontSize: 16, color: colors.titleText),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                counterText: '',
                hintText: '项目名称',
                hintStyle: TextStyle(
                  fontSize: 16,
                  color: colors.deactivatedText,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }

  /// 颜色行：无颜色 + 10 色预设 + 自定义取色（彩虹环）
  ///
  /// 视觉 32 / 热区 48（外层 `Padding` 补白，与标签色板 / 侧栏色板同口径）。
  Widget _colorRow(AppColorSet colors) {
    final custom = isCustomProjectColor(_color);
    return Wrap(
      spacing: AppDimens.space8,
      runSpacing: AppDimens.space8,
      children: [
        _swatch(
          colors: colors,
          value: projectNoColor,
          selected: _color.isEmpty,
          visual: Icon(
            OrbitIcons.noColor,
            size: AppDimens.iconSizeSm,
            color: colors.iconText,
          ),
        ),
        for (final hex in projectColorPalette)
          _swatch(
            colors: colors,
            value: hex,
            selected: _color.toUpperCase() == hex,
            visual: null,
            fill: hexToColor(hex),
          ),
        // 自定义：彩虹环常驻；取过自定义色时该圆点即选中态（环内显示结果色）
        _swatch(
          colors: colors,
          value: _color,
          selected: custom,
          onTap: _pickCustomColor,
          fill: custom ? hexToColor(_color) : null,
          visual: custom
              ? null
              : Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        for (final hex in projectColorPalette) hexToColor(hex),
                        hexToColor(projectColorPalette.first),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _swatch({
    required AppColorSet colors,
    required String value,
    required bool selected,
    required Widget? visual,
    Color? fill,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap ?? () => setState(() => _color = value),
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.space8),
        child: Container(
          width: AppDimens.space32,
          height: AppDimens.space32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill ?? (value.isEmpty ? Colors.transparent : null),
            border: Border.all(
              color: selected ? colors.accent : colors.outline,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: visual == null
              ? null
              : Center(
                  child: ClipOval(
                    child: SizedBox(
                      width: AppDimens.space24,
                      height: AppDimens.space24,
                      child: visual,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  /// 视图类型预览卡：选中 = accent 描边 + 右上打勾 + 标签转 accent
  Widget _viewTypeCard(AppColorSet colors, TaskViewMode mode) {
    final selected = _viewMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _viewMode = mode),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(AppDimens.space8),
              decoration: BoxDecoration(
                color: colors.surfaceSecondary,
                borderRadius: AppShapes.small,
                border: Border.all(
                  color: selected ? colors.accent : colors.outline,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  _ViewPreview(mode: mode, colors: colors),
                  if (selected)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(AppDimens.space2),
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          OrbitIcons.check,
                          size: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.space6),
            Text(
              '${mode.label}视图',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? colors.accent : colors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视图类型示意图（灰底线框；纯几何示形，不是真实数据渲染）
///
/// 尺寸是本组件内的线框几何（非主题刻度），故直接用局部常量表达
/// 「一行的粗细 / 格子的间距」，避免把线框尺寸污染进 [AppDimens] 语义刻度。
class _ViewPreview extends StatelessWidget {
  const _ViewPreview({required this.mode, required this.colors});

  final TaskViewMode mode;
  final AppColorSet colors;

  static const double _previewHeight = 56;
  static const double _bar = 3;
  static const double _chip = 8;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _previewHeight,
      child: switch (mode) {
        TaskViewMode.list => _listPreview(),
        TaskViewMode.kanban => _kanbanPreview(),
        TaskViewMode.table => _tablePreview(),
      },
    );
  }

  /// 列表：三行「勾选框 + 长短两条标题」
  Widget _listPreview() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 3; i++)
          Row(
            children: [
              Container(
                width: _chip,
                height: _chip,
                decoration: BoxDecoration(
                  borderRadius: AppShapes.xs,
                  border: Border.all(color: colors.outline),
                ),
              ),
              const SizedBox(width: AppDimens.space6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _line(widthFactor: i == 1 ? 0.6 : 0.8),
                    const SizedBox(height: AppDimens.space2),
                    _line(widthFactor: 0.35),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// 看板：三列卡片，列内条数/高度错落
  Widget _kanbanPreview() {
    const heights = [
      [16.0, 10.0],
      [10.0, 16.0],
      [16.0, 10.0],
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < heights.length; c++) ...[
          if (c > 0) const SizedBox(width: AppDimens.space6),
          Expanded(
            child: Column(
              children: [
                for (final h in heights[c]) ...[
                  Container(
                    height: h,
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: AppShapes.xs,
                    ),
                  ),
                  const SizedBox(height: AppDimens.space4),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 表格：三行三列细线网格
  Widget _tablePreview() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var r = 0; r < 3; r++)
          Row(
            children: [
              for (var c = 0; c < 3; c++) ...[
                if (c > 0) const SizedBox(width: AppDimens.space6),
                Expanded(child: _line(widthFactor: 1)),
              ],
            ],
          ),
      ],
    );
  }

  Widget _line({required double widthFactor}) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: _bar,
          decoration: BoxDecoration(
            color: colors.divider,
            borderRadius: BorderRadius.circular(_bar / 2),
          ),
        ),
      );
}
