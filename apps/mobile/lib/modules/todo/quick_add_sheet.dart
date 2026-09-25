/// 底部快速添加面板（任务列表页右下加号唤起）
///
/// 形制参考主流待办应用移动端快速添加栏，但**能力面只对齐本仓
/// 已有能力**：输入框「准备做什么？」+ 快捷操作图标行（档位由
/// [QuickActions] 配置决定）+「...」更多菜单（未启用档 + 固定「设置」入口）+ 发送。
///
/// 选中态只落在底部图标上，不在输入框上方加 chips 行：已选档位展开为
/// 「图标 + 具体值」文字胶囊（日期/项目名/标签/张数直接可见；优先级只旗子变色），
/// 优先级取该档色、其余取待办强调色；清除走各自抽屉（日期抽屉「清除日期」，
/// 优先级回选「无」，项目回选「未分组」，标签全不勾，图片走管理菜单「清空」），
/// 与桌面 QuickAddBar 同口径。
///
/// 提交口径与桌面 `QuickAddBar` 一致：标题实时走 NLP 解析（`parseQuickInput`），
/// 提交瞬间以最新输入重算，**NLP 显式值 > 面板手动选择 > 当前快捷视图默认值**
///（#39 视图标记注入：我的一天/收藏/今日/本周；今日/本周截止时刻归一 18:00）。
/// 图片走「先建任务再挂附件」两段式（任务暂无 id 无法先传附件），附件失败不阻断
/// 任务本身——部分成功口径与表单的标签/子任务挂载一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_panel.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'form_bottom_sheet.dart';
import 'logic/parse_quick_input.dart';
import 'logic/quick_actions.dart';
import 'logic/template_apply.dart';
import 'logic/task_logic.dart'
    show
        QuickViewKey,
        atViewDueHour,
        dateToMidnightMs,
        formatDueLabel,
        priorityColorHex,
        priorityLabel,
        quickViewCreateDefaults;
import 'providers/todo_providers.dart';

/// 快捷操作档 → 图标（面板工具栏与设置页预览/列表共用同一映射）
IconData quickActionIcon(QuickActionId id) => switch (id) {
      QuickActionId.due => OrbitIcons.calendar,
      QuickActionId.priority => OrbitIcons.flag,
      QuickActionId.label => OrbitIcons.tag,
      QuickActionId.project => OrbitIcons.list,
      QuickActionId.image => OrbitIcons.image,
      QuickActionId.template => OrbitIcons.template,
      QuickActionId.fullscreen => OrbitIcons.fullscreen,
    };

/// 打开快速添加面板（提交成功后自动关闭）
///
/// [defaultProjectId]/[quickView] 由入口页携入：列表页带当前项目与快捷视图，
/// 面板内新建因此与 FAB 完整表单同口径（视图标记静默附加）。
/// [initialDueDate] 预填截止（午夜毫秒，日历长按日格快捷新增用）。
///
/// **统一新建入口**：列表页 FAB/空态、侧栏 FAB（含桌面快捷方式）、日历 FAB/
/// 日格长按的新建一律走本面板；完整表单（`showTodoFormSheet`）只留给编辑态、
/// 面板内「全屏」展开与模板套用（notes/子任务字段快加面板承接不了）。
Future<void> showQuickAddSheet(
  BuildContext context, {
  int? defaultProjectId,
  QuickViewKey? quickView,
  int? initialDueDate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (_) => _QuickAddSheet(
      defaultProjectId: defaultProjectId,
      quickView: quickView,
      initialDueDate: initialDueDate,
    ),
  );
}

/// 待挂载图片（任务创建成功后才上传，故暂存字节）
class _PendingImage {
  const _PendingImage({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;

  /// 附件 mime 按扩展名推断（图片场景只覆盖常见格式，其余回落 jpeg）
  String get mime {
    switch (name.split('.').last.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }
}

class _QuickAddSheet extends ConsumerStatefulWidget {
  const _QuickAddSheet({this.defaultProjectId, this.quickView, this.initialDueDate});

  /// 新建任务默认归属项目（null = 未分组）
  final int? defaultProjectId;

  /// 当前快捷视图（视图内新建自动带本视图标记）
  final QuickViewKey? quickView;

  /// 预填截止（午夜毫秒；日历长按日格快捷新增用）
  final int? initialDueDate;

  @override
  ConsumerState<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<_QuickAddSheet> {
  final _titleController = TextEditingController();

  /// 「更多」钮定位键：下拉面板锚在它上方弹出，用该键取全局矩形
  final _moreKey = GlobalKey();

  int _priority = 0;
  int? _dueDate;
  int? _projectId;
  List<TodoLabel> _labels = [];
  final List<_PendingImage> _images = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _projectId = widget.defaultProjectId;
    _dueDate = widget.initialDueDate;
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // ── 提交（NLP 优先于手动选择，手动选择优先于视图默认）──

  Future<void> _submit() async {
    if (_saving) return;
    final raw = _titleController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _saving = true);
    try {
      final bridge = ref.read(orbitBridgeProvider);
      final projects = ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
      final labels = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
      final parsed = parseQuickInput(
        raw,
        QuickInputContext(
          projects: [
            for (final p in projects) QuickInputRef(id: p.id, title: p.title),
          ],
          labels: [
            for (final l in labels) QuickInputRef(id: l.id, title: l.title),
          ],
          now: DateTime.now(),
        ),
      );
      final title = parsed.title.trim();
      if (title.isEmpty) {
        WaitToast.destructive('请输入任务标题');
        return;
      }
      final viewDefaults = quickViewCreateDefaults(widget.quickView);
      final inDueView = widget.quickView == QuickViewKey.today ||
          widget.quickView == QuickViewKey.week;
      final due = parsed.dueDate != null
          ? dateToMidnightMs(parsed.dueDate!)
          : (_dueDate ?? viewDefaults.dueMs);
      final created = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: title,
        projectId: parsed.projectId ?? _projectId,
        priority: parsed.priority > 0 ? parsed.priority : _priority,
        status: 'pending',
        dueDate: inDueView && due != null ? atViewDueHour(due) : due,
        // 开始日期默认今天（与移动端表单同口径：新建任务恒有开始日期）
        startDate: dateToMidnightMs(DateTime.now()),
        myDayDate: viewDefaults.myDayMs,
        isFavorite: viewDefaults.favorite,
      ));
      // 标签：NLP 命中 ∪ 手动选择（去重；单条失败不阻断任务本身）
      final labelIds = <int>{...parsed.labelIds, ..._labels.map((l) => l.id)};
      for (final labelId in labelIds) {
        try {
          await bridge.todoTaskLabelCreate(
            TodoTaskLabelCreateInput(taskId: created.id, labelId: labelId),
          );
        } catch (_) {
          /* 忽略单个标签失败 */
        }
      }
      // 图片：任务落库后逐张挂附件（失败不阻断任务本身）
      for (final image in _images) {
        try {
          await bridge.taskAttachmentAdd(
            created.id,
            image.name,
            image.mime,
            image.bytes,
          );
        } catch (_) {
          /* 忽略单张图片失败 */
        }
      }
      ref.invalidate(todoTasksProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      WaitToast.destructive('创建失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── 档位动作 ──

  Future<void> _onAction(QuickActionId id, [Rect? anchor]) async {
    switch (id) {
      case QuickActionId.due:
        await _pickDue();
      case QuickActionId.priority:
        await _pickPriority(anchor);
      case QuickActionId.label:
        await _pickLabels(anchor);
      case QuickActionId.project:
        await _pickProject(anchor);
      case QuickActionId.image:
        await _pickImage();
      case QuickActionId.template:
        await _openTemplate();
      case QuickActionId.fullscreen:
        await _openFullForm();
    }
  }

  /// 触发钮全局矩形（快捷卡片锚点；取不到回落右上形态）
  Rect? _anchorOf(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 截止日期档：快捷抽屉（今天/明天/下周/选择日期…+ 已设时清除），与桌面
  /// QuickDateMenu 和表单今天/明天/下周快捷同口径；选中态只落工具栏图标。
  Future<void> _pickDue() async {
    final today = _midnightOf(0);
    final tomorrow = _midnightOf(1);
    final nextWeek = _midnightOf(7);
    String? current;
    if (_dueDate == today) {
      current = 'today';
    } else if (_dueDate == tomorrow) {
      current = 'tomorrow';
    } else if (_dueDate == nextWeek) {
      current = 'nextweek';
    }
    await showSelectBottomSheet<String>(
      context,
      title: '截止日期',
      items: [
        const SelectItem(value: 'today', label: '今天'),
        const SelectItem(value: 'tomorrow', label: '明天'),
        const SelectItem(value: 'nextweek', label: '下周'),
        const SelectItem(value: 'custom', label: '选择日期…'),
        if (_dueDate != null) const SelectItem(value: 'clear', label: '清除日期'),
      ],
      current: current,
      onSelect: (v) async {
        switch (v) {
          case 'today':
            if (mounted) setState(() => _dueDate = today);
          case 'tomorrow':
            if (mounted) setState(() => _dueDate = tomorrow);
          case 'nextweek':
            if (mounted) setState(() => _dueDate = nextWeek);
          case 'clear':
            if (mounted) setState(() => _dueDate = null);
          case 'custom':
            await _pickCustomDue();
        }
      },
    );
  }

  /// 本地时区自然日零点毫秒（今天 + [offsetDays] 天，与表单同口径）
  int _midnightOf(int offsetDays) {
    final now = DateTime.now();
    return dateToMidnightMs(
      DateTime(now.year, now.month, now.day + offsetDays),
    );
  }

  /// 自定义日期：完整月历面板；取消/清除回 null 即不动原值，
  /// 清除走快捷抽屉「清除日期」（picker 的 null 不区分取消与清除）。
  Future<void> _pickCustomDue() async {
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: _dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(_dueDate!)
          : null,
      accent: OrbitAccents.todoAccent,
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = dateToMidnightMs(picked));
  }

  /// 优先级档：锚在触发钮上方的单选卡片（六档带档色，点选即回填并关闭）
  Future<void> _pickPriority([Rect? anchor]) async {
    await showOrbitDropdownPanel(
      context,
      anchor: anchor,
      above: true,
      groups: [
        [
          for (var i = 0; i <= 5; i++)
            OrbitPanelItem(
              icon: OrbitIcons.flag,
              label: priorityLabel(i),
              color: hexToColor(priorityColorHex(i)),
              checked: i == _priority,
              onTap: () {
                if (mounted) setState(() => _priority = i);
              },
            ),
        ],
      ],
    );
  }

  /// 标签档：锚在触发钮上方的多选卡片——点行即选中/取消并实时回填面板，
  /// 卡片常驻可连选，点卡外关闭（不要确认/取消尾栏）
  Future<void> _pickLabels([Rect? anchor]) async {
    var all = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
    if (all.isEmpty) {
      // provider 首读尚未落定（future 刚创建）：等一拍再判空，
      // 避免把加载中误报成「还没有标签」
      try {
        all = await ref.read(todoLabelsProvider.future);
      } catch (_) {
        all = const <TodoLabel>[];
      }
    }
    if (all.isEmpty) {
      WaitToast.destructive('还没有标签，可在设置 → 标签管理中新建');
      return;
    }
    if (!mounted) return;
    final picked = Set<int>.of(_labels.map((l) => l.id));
    await showOrbitFloatCard<void>(
      context,
      anchor: anchor,
      // 标签行（复选框 + 色点 + 标题）：240 宽放不下长标题，加宽到 300
      // （壳内按屏宽 - 32 钳制，不贴边）
      width: 300,
      child: StatefulBuilder(
        builder: (cardContext, setCardState) {
          final colors = AppColors.ofContext(cardContext);

          /// 点行即算选中：卡片内翻勾 + 面板实时回填（卡片不关，可连选）
          void toggle(TodoLabel label) {
            setCardState(() {
              picked.contains(label.id)
                  ? picked.remove(label.id)
                  : picked.add(label.id);
            });
            if (mounted) {
              setState(() => _labels = [
                    for (final l in all) if (picked.contains(l.id)) l,
                  ]);
            }
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 无标题头：与其他快捷卡片同形，只出条目列
              Flexible(
                // shrinkWrap + Flexible：条目少时卡片贴合内容（不留大片空白），
                // 条目多时在卡片限高内滚动
                child: ListView.builder(
                  key: const ValueKey('quick-add-label-card-list'),
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(
                      vertical: AppDimens.space8),
                  itemCount: all.length,
                  itemBuilder: (context, index) {
                    final label = all[index];
                    final checked = picked.contains(label.id);
                    return InkWell(
                      onTap: () => toggle(label),
                      child: SizedBox(
                        height: AppDimens.touchTarget,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.space16,
                          ),
                          child: Row(
                            children: [
                              CircleCheckbox(
                                checked: checked,
                                onToggle: () => toggle(label),
                                size: AppDimens.subtaskCheckboxSize,
                              ),
                              const SizedBox(width: AppDimens.space12),
                              Container(
                                width: AppDimens.colorDotSize,
                                height: AppDimens.colorDotSize,
                                decoration: BoxDecoration(
                                  color: hexToColor(
                                    label.hexColor,
                                    fallback: OrbitAccents.todoAccent,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: AppDimens.space8),
                              Expanded(
                                child: Text(
                                  label.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 15, color: colors.bodyText),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 项目档：锚在触发钮上方的单选卡片（未分组 + 项目列表带项目色，点选即回填）
  Future<void> _pickProject([Rect? anchor]) async {
    final projects = ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
    await showOrbitDropdownPanel(
      context,
      anchor: anchor,
      above: true,
      groups: [
        [
          OrbitPanelItem(
            icon: OrbitIcons.list,
            label: '未分组',
            checked: _projectId == null,
            onTap: () {
              if (mounted) setState(() => _projectId = null);
            },
          ),
          for (final project in projects)
            OrbitPanelItem(
              icon: OrbitIcons.list,
              label: project.title,
              color: hexToColor(
                project.hexColor,
                fallback: OrbitAccents.todoAccent,
              ),
              checked: _projectId == project.id,
              onTap: () {
                if (mounted) setState(() => _projectId = project.id);
              },
            ),
        ],
      ],
    );
  }

  /// 相册选图：只暂存字节，提交时随任务一并挂载（可多张累积）。
  /// 已有待传图片时先走管理菜单（继续添加/清空），代替已删除的 chips 清除行。
  Future<void> _pickImage() async {
    if (_images.isNotEmpty && mounted) {
      await showMoreActionsSheet(
        context,
        title: '图片（${_images.length}张待上传）',
        actions: [
          MoreActionItem(
            icon: OrbitIcons.image,
            label: '继续添加',
            onTap: _addImage,
          ),
          MoreActionItem(
            icon: OrbitIcons.delete,
            label: '清空图片',
            color: AppColors.ofContext(context).destructive,
            onTap: () {
              if (mounted) setState(() => _images.clear());
            },
          ),
        ],
      );
      return;
    }
    await _addImage();
  }

  Future<void> _addImage() async {
    try {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (shot == null) return;
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() => _images.add(_PendingImage(name: shot.name, bytes: bytes)));
    } catch (_) {
      if (mounted) WaitToast.destructive('选择图片失败');
    }
  }

  /// 模板档：面板让位给既有「模板选择 → 表单预填」链（与列表页长按加号同源）
  Future<void> _openTemplate() async {
    final projectId = _projectId;
    final quickView = widget.quickView;
    final bridge = ref.read(orbitBridgeProvider);
    Navigator.of(context).pop();
    await showTemplateCreateFlow(
      context,
      bridge,
      defaultProjectId: projectId,
      quickView: quickView,
    );
  }

  /// 全屏档：把当前草稿（标题/优先级/截止）带进完整新建表单做详细编辑
  Future<void> _openFullForm() async {
    final projectId = _projectId;
    final quickView = widget.quickView;
    final title = _titleController.text.trim();
    final priority = _priority;
    final dueOffsetDays = _dueOffsetDays(_dueDate);
    Navigator.of(context).pop();
    await showTodoFormSheet(
      context,
      defaultProjectId: projectId,
      quickView: quickView,
      presetTemplate: TemplatePayload(
        title: title.isEmpty ? null : title,
        priority: priority > 0 ? priority : null,
        dueOffsetDays: dueOffsetDays,
      ),
    );
  }

  /// 已选截止 → 距今天零点的天数（表单模板 payload 只认相对偏移；过去日期不回传）
  int? _dueOffsetDays(int? ms) {
    if (ms == null) return null;
    final days =
        ((ms - dateToMidnightMs(DateTime.now())) / Duration.millisecondsPerDay)
            .round();
    return days >= 0 ? days : null;
  }

  void _openSettings() {
    Navigator.of(context).pop();
    context.push('/settings/quick-actions');
  }

  /// 「更多」菜单：锚在按钮上方的下拉面板（竞品同款浮层卡片），未启用档 +
  /// 固定「设置」入口分两组；点选后菜单自关，回调内再处理面板
  Future<void> _openMoreMenu(List<QuickActionId> hidden) async {
    final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor =
        box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    await showOrbitDropdownPanel(
      context,
      anchor: anchor,
      above: true,
      groups: [
        if (hidden.isNotEmpty)
          [
            for (final id in hidden)
              OrbitPanelItem(
                icon: quickActionIcon(id),
                label: id.label,
                onTap: () => _onAction(id),
              ),
          ],
        [
          OrbitPanelItem(
            icon: OrbitIcons.settings,
            label: '设置',
            onTap: _openSettings,
          ),
        ],
      ],
    );
  }

  // ── 视图 ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final (enabled, hidden) = QuickActions.read();

    return OrbitSheetScaffold(
      showHandle: true,
      contentScrollable: false,
      maxHeightFactor: 0.7,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              0,
            ),
            child: TextField(
              controller: _titleController,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              maxLength: 200,
              style: TextStyle(fontSize: 15, color: colors.bodyText),
              decoration: InputDecoration(
                hintText: '准备做什么？',
                counterText: '',
                border: InputBorder.none,
                isDense: true,
                hintStyle: TextStyle(fontSize: 15, color: colors.deactivatedText),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space8,
              AppDimens.space4,
              AppDimens.space12,
              AppDimens.space8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final id in enabled) _toolbarButton(id),
                      ],
                    ),
                  ),
                ),
                // 「更多」固定在发送钮左侧，不随工具栏横滚被挤走
                _moreButton(),
                const SizedBox(width: AppDimens.space8),
                _sendButton(colors),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工具档按钮：未选是 42px 图标钮；已选则展开为「图标 + 具体值」
  /// 文字胶囊（日期/项目名/标签/张数直接可见，不在输入框上方加行；
  /// 优先级只旗子变色、不展字）。
  /// 点按锚点取按钮全局矩形，快捷卡片从该按钮上方弹出。
  Widget _toolbarButton(QuickActionId id) {
    final colors = AppColors.ofContext(context);
    final value = _actionValue(id);
    // 优先级只旗子变色、不展文字胶囊（active 另判）
    final active =
        value != null || (id == QuickActionId.priority && _priority > 0);
    final tone = _actionTone(id, colors, active);
    if (value == null) {
      return Builder(
        builder: (btnContext) => IconButton(
          // 优先级无文字值但仍有已选态：tooltip 显示已选值
          tooltip: active ? _actionTooltip(id) : id.label,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 42, height: 42),
          onPressed: () => _onAction(id, _anchorOf(btnContext)),
          icon: Icon(
            quickActionIcon(id),
            size: AppDimens.iconSizeMd,
            color: tone,
          ),
        ),
      );
    }
    return Builder(
      builder: (btnContext) => Tooltip(
        message: _actionTooltip(id),
        child: InkWell(
          borderRadius: AppShapes.small,
          onTap: () => _onAction(id, _anchorOf(btnContext)),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              borderRadius: AppShapes.small,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  quickActionIcon(id),
                  size: AppDimens.iconSizeMd,
                  color: tone,
                ),
                const SizedBox(width: AppDimens.space6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tone,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 档位已选的具体值（无值返回 null；优先级只旗子变色不展字、
  /// 模板/全屏恒无值）
  String? _actionValue(QuickActionId id) {
    switch (id) {
      case QuickActionId.due:
        return _dueDate == null ? null : formatDueLabel(_dueDate!);
      case QuickActionId.priority:
        return null;
      case QuickActionId.label:
        if (_labels.isEmpty) return null;
        if (_labels.length == 1) return _labels.first.title;
        return '${_labels.length}个';
      case QuickActionId.project:
        if (_projectId == null) return null;
        final projects =
            ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
        return projects
            .where((p) => p.id == _projectId)
            .firstOrNull
            ?.title;
      case QuickActionId.image:
        return _images.isEmpty ? null : '${_images.length}张';
      case QuickActionId.template || QuickActionId.fullscreen:
        return null;
    }
  }

  /// 档位图标/文字色：优先级已选取该档色，其余已选取待办强调色，未选走中性图标色
  Color _actionTone(QuickActionId id, AppColorSet colors, bool active) {
    if (!active) return colors.iconText;
    if (id == QuickActionId.priority) {
      return hexToColor(
        priorityColorHex(_priority),
        fallback: OrbitAccents.todoAccent,
      );
    }
    return OrbitAccents.todoAccent;
  }

  /// 档位提示：未选显档名，已选带上已选值（清除入口在各自抽屉内）
  String _actionTooltip(QuickActionId id) {
    switch (id) {
      case QuickActionId.due:
        return _dueDate == null ? '日期' : '截止：${formatDueLabel(_dueDate!)}';
      case QuickActionId.priority:
        return _priority <= 0
            ? '优先级'
            : '优先级：P$_priority ${priorityLabel(_priority)}';
      case QuickActionId.label:
        return _labels.isEmpty ? '标签' : '标签：已选${_labels.length}个';
      case QuickActionId.project:
        if (_projectId == null) return '项目';
        final projects =
            ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
        final title = projects
            .where((p) => p.id == _projectId)
            .firstOrNull
            ?.title;
        return title == null ? '项目' : '项目：$title';
      case QuickActionId.image:
        return _images.isEmpty ? '图片' : '图片：${_images.length}张待上传';
      case QuickActionId.template:
        return '模板';
      case QuickActionId.fullscreen:
        return '全屏';
    }
  }

  Widget _moreButton() {
    final colors = AppColors.ofContext(context);
    return IconButton(
      key: _moreKey,
      tooltip: '更多',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
      onPressed: () {
        final (_, hidden) = QuickActions.read();
        _openMoreMenu(hidden);
      },
      icon: Icon(
        OrbitIcons.moreVertical,
        size: AppDimens.iconSizeMd,
        color: colors.iconText,
      ),
    );
  }

  Widget _sendButton(AppColorSet colors) {
    final canSend = _titleController.text.trim().isNotEmpty && !_saving;
    return SizedBox.square(
      dimension: 40,
      child: Material(
        color: canSend ? OrbitAccents.themeAccent : colors.surfaceSecondary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: canSend ? _submit : null,
          child: Center(
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    OrbitIcons.send,
                    size: AppDimens.iconSizeSm,
                    color: canSend ? Colors.white : colors.deactivatedText,
                  ),
          ),
        ),
      ),
    );
  }
}
