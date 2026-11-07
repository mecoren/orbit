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
///
/// **表面材质（2026-11-03）**：面板换成 OS4 玻璃（`OrbitGlassSurface`），材质档
/// 与页头/底栏同一档 `puredThinGlass`（栏体玻璃，不做仿生折射着色）——承载层
/// 透明 + 遮罩淡一档，玻璃采样壳层 `MiuixLayerBackdropCapture` 录制的页面内容；
/// 无壳/测试裸页（拿不到 `OrbitGlassScope`）自动退回实时模糊。输入框与按钮行
/// 的版式、选中态口径一律不动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart'
    show MiuixGlassAnchor, MiuixGlassPopupAnchor, MiuixLayerBackdrop;
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
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_glass_surface.dart';
import '../../shared/widgets/shadcn/orbit_menu_popup.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_icon_button.dart';
import '../../shared/widgets/shadcn/orbit_text_field.dart';
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
        formatDueShort,
        nextMondayMidnightMs,
        priorityColorHex,
        priorityLabel,
        quickViewCreateDefaults,
        reminderPresets;
import 'providers/todo_providers.dart';

/// 快捷操作档 → 图标（面板工具栏与设置页预览/列表共用同一映射）
IconData quickActionIcon(QuickActionId id) => switch (id) {
  QuickActionId.due => OrbitIcons.calendar,
  QuickActionId.reminder => OrbitIcons.notification,
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
  // 玻璃表面要采样「面板背后的页面内容」：壳层（`HomeShell`）已把页面内容录进
  // `MiuixLayerBackdropCapture`，这里取同一个采样器（无壳/测试裸页为 null，
  // 面板退回实时模糊）。面板挂在根 Navigator 的 Overlay 上、位于捕获树之外，
  // 不会把自己拍进背景（自采样会让面板越糊越实）。
  final backdrop = OrbitGlassScope.maybeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // 表面由面板自绘玻璃：承载层必须透明且 elevation 归零，否则 Material 会在
    // 透明底上再补一圈**直角**阴影，把顶部圆角玻璃的边界弄脏
    backgroundColor: Colors.transparent,
    elevation: 0,
    // 玻璃面板比实色抽屉轻，遮罩比默认 black54 淡一档，背后列表仍隐约可见
    barrierColor: Colors.black.withValues(alpha: 0.32),
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (_) => _QuickAddSheet(
      defaultProjectId: defaultProjectId,
      quickView: quickView,
      initialDueDate: initialDueDate,
      backdrop: backdrop,
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
  const _QuickAddSheet({
    this.defaultProjectId,
    this.quickView,
    this.initialDueDate,
    this.backdrop,
  });

  /// 新建任务默认归属项目（null = 未分组）
  final int? defaultProjectId;

  /// 当前快捷视图（视图内新建自动带本视图标记）
  final QuickViewKey? quickView;

  /// 预填截止（午夜毫秒；日历长按日格快捷新增用）
  final int? initialDueDate;

  /// OS4 玻璃背景采样器（`OrbitGlassScope` 暴露；null = 实时模糊降级）
  final MiuixLayerBackdrop? backdrop;

  @override
  ConsumerState<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<_QuickAddSheet> {
  final _titleController = TextEditingController();

  /// 输入框焦点：工具栏弹层（底部抽屉/锚点卡片都是新路由）会抢走焦点致输入法
  /// 下沉，弹层关闭后凭它把焦点还回去（见 [_withKeyboard]），可边选边打字。
  final _titleFocus = FocusNode();

  /// 工具栏按钮尺寸（形变锚点与落位微调用同一数值）
  static const double _toolbarButtonSize = 42;

  /// 工具栏档位按钮的形变锚点（每个档位一个；菜单从按钮轮廓连续长出来，
  /// 与底栏「更多」同款）
  final _menuAnchors = <QuickActionId, MiuixGlassPopupAnchor>{
    for (final id in QuickActionId.values) id: MiuixGlassPopupAnchor(),
  };

  /// 「更多」钮的形变锚点
  final _moreAnchor = MiuixGlassPopupAnchor();

  int _priority = 0;
  int? _dueDate;

  /// 提醒时刻（绝对毫秒；提交时任务落库后再建提醒实体，两段式与表单同口径）
  int? _remindAt;

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
    // 菜单挂在根 Overlay 上，不随本面板路由一起销毁：锚点即将释放，必须
    // 立即移除 entry，不能继续在已卸载的按钮上播回收动画。
    _menuSession?.dispose();
    for (final anchor in _menuAnchors.values) {
      anchor.dispose();
    }
    _moreAnchor.dispose();
    _titleController.dispose();
    _titleFocus.dispose();
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
      final projects =
          ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
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
      final inDueView =
          widget.quickView == QuickViewKey.today ||
          widget.quickView == QuickViewKey.week;
      // F4：NLP 显式时刻原样落库（勿归一零点/视图 18 点），无时刻沿用零点口径
      final nlpHasTime = parsed.dueHasTime && parsed.dueDate != null;
      final due = parsed.dueDate != null
          ? (nlpHasTime
                ? parsed.dueDate!.millisecondsSinceEpoch
                : dateToMidnightMs(parsed.dueDate!))
          : (_dueDate ?? viewDefaults.dueMs);
      final created = await bridge.todoTaskCreate(
        TodoTaskCreateInput(
          title: title,
          projectId: parsed.projectId ?? _projectId,
          priority: parsed.priority > 0 ? parsed.priority : _priority,
          status: 'pending',
          dueDate: inDueView && due != null && !nlpHasTime
              ? atViewDueHour(due)
              : due,
          // 开始日期默认今天（与移动端表单同口径：新建任务恒有开始日期）
          startDate: dateToMidnightMs(DateTime.now()),
          myDayDate: viewDefaults.myDayMs,
          isFavorite: viewDefaults.favorite,
          // F4：NLP 命中的时长/重复随任务一次落库（重复锚点日已在 dueDate 里）
          durationMinutes: parsed.durationMinutes,
          repeatMode: parsed.repeat?.mode,
          repeatAfter: parsed.repeat?.after,
          repeatWeekdays: parsed.repeat?.weekdays,
        ),
      );
      // 提醒：任务落库后建提醒实体（两段式，与表单/桌面 QuickAddBar 同口径；
      // 提醒是独立表，创建入参里没有该字段）
      if (_remindAt != null) {
        try {
          await bridge.todoReminderCreate(
            TodoReminderCreateInput(taskId: created.id, remindAt: _remindAt!),
          );
        } catch (_) {
          /* 忽略提醒失败（任务本身已建成） */
        }
      }
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

  Future<void> _onAction(QuickActionId id) async {
    switch (id) {
      case QuickActionId.due:
        _pickDue();
      case QuickActionId.reminder:
        _pickReminder();
      case QuickActionId.priority:
        _pickPriority();
      case QuickActionId.label:
        await _pickLabels();
      case QuickActionId.project:
        _pickProject();
      case QuickActionId.image:
        await _pickImage();
      case QuickActionId.template:
        await _openTemplate();
      case QuickActionId.fullscreen:
        await _openFullForm();
    }
  }

  /// 工具栏弹层关闭后把焦点还给输入框（输入法重新升起）。
  /// 上面还有下级弹层时不抢——由下级关闭时恢复，避免键盘盖住日期面板。
  void _restoreKeyboard(bool hadFocus) {
    if (!hadFocus || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _titleFocus.requestFocus();
  }

  /// 包一层键盘保持：打开底部抽屉前记住输入框是否有焦点，关闭后恢复。
  /// 模板/全屏/设置会关掉本面板（导航离开），不包这层。
  /// 锚定菜单走 [showOrbitMenuPopup]（Overlay 直挂，根本不抢焦点）。
  Future<void> _withKeyboard(Future<void> Function() open) async {
    final hadFocus = _titleFocus.hasFocus;
    await open();
    _restoreKeyboard(hadFocus);
  }

  /// 当前锚定菜单会话（Overlay 直挂；返回键拦截见 build 的 PopScope）
  OrbitMenuSession? _menuSession;

  bool get _menuOpen => _menuSession?.isOpen ?? false;

  /// 关闭当前菜单（幂等；点卡外/返回键/点选都由组件内部走同一条 close）
  void _closeMenu() {
    _menuSession?.close();
  }

  /// 形变期按钮副本（库内会隐藏按钮本体，副本按按钮矩形缩放显示）
  Widget _menuAnchorContent(QuickActionId id) {
    final colors = AppColors.ofContext(context);
    final active =
        _actionValue(id) != null ||
        (id == QuickActionId.priority && _priority > 0);
    return Center(
      child: Icon(
        quickActionIcon(id),
        size: AppDimens.iconSizeMd,
        color: _actionTone(id, colors, active),
      ),
    );
  }

  /// 打开锚定菜单（[showOrbitMenuPopup] 统一承载与动效，与底栏「更多」同款：
  /// 卡片从按钮轮廓连续形变长出、玻璃卡面、44 行高语义色行；Overlay 直挂不
  /// 新建路由，输入法全程保持升起，可边选边打字）。
  ///
  /// [groupsBuilder] 在每次重建时取值（多选连选靠它翻勾），闭包里读调用方
  /// 当下的选中集合；宽度走库内菜单档（200–288），标签这类长文案菜单传
  /// `maxWidth: 300`。`gap` 把卡片底边抬到按钮上方，不压住触发钮。
  ///
  /// 同一锚点重开的前提是旧菜单已收走：库内退场结束会把按钮本体恢复，若
  /// 在退场窗口内同锚点开新菜单会出现双本体。当前库内拦截层吞掉该窗口的
  /// 点击，用户不可达；不要把拦截层改成透传。
  OrbitMenuSession _openMenu({
    required MiuixGlassPopupAnchor anchor,
    required Widget anchorContent,
    required String title,
    required List<List<OrbitPanelItem>> Function() groupsBuilder,
    bool closeOnTap = true,
    double? maxWidth,
    Key? contentKey,
  }) {
    _menuSession?.close();
    final session = showOrbitMenuPopup(
      context,
      transformAnchor: anchor,
      anchorContent: anchorContent,
      gap: -(_toolbarButtonSize + AppDimens.space8),
      groupsBuilder: groupsBuilder,
      // 标题行 + 行内「编辑」：与底栏「更多」面板同版式（编辑 = 快捷操作设置）
      title: title,
      actionLabel: '编辑',
      onAction: _openSettings,
      closeOnTap: closeOnTap,
      maxWidth: maxWidth,
      contentKey: contentKey,
      backdrop: widget.backdrop,
      restoreFocus: _titleFocus,
    );
    _menuSession = session;
    session.closed.whenComplete(() {
      if (!mounted || _menuSession != session) return;
      setState(() => _menuSession = null);
    });
    setState(() {});
    return session;
  }

  /// 截止日期档：快捷菜单（今天/明天/下周/选择日期…+ 已设时清除），与桌面
  /// QuickDateMenu 和表单今天/明天/下周快捷同口径（下周＝下周一 00:00）；
  /// 选中态只落行尾对勾。
  void _pickDue() {
    final today = _midnightOf(0);
    final tomorrow = _midnightOf(1);
    final nextWeek = nextMondayMidnightMs();
    String? current;
    if (_dueDate == today) {
      current = 'today';
    } else if (_dueDate == tomorrow) {
      current = 'tomorrow';
    } else if (_dueDate == nextWeek) {
      current = 'nextweek';
    }
    // 自定义日期会再开下级日期面板（底部抽屉）：把焦点记忆传进去，由下级
    // 关闭时恢复（本级菜单 Overlay 直挂，不抢焦点）
    final hadFocus = _titleFocus.hasFocus;
    late final OrbitMenuSession session;

    void apply(String value) {
      switch (value) {
        case 'today':
          if (mounted) setState(() => _dueDate = today);
        case 'tomorrow':
          if (mounted) setState(() => _dueDate = tomorrow);
        case 'nextweek':
          if (mounted) setState(() => _dueDate = nextWeek);
        case 'clear':
          if (mounted) setState(() => _dueDate = null);
        case 'custom':
          // 先等本级菜单回收完成再开下级日期面板：库内退场结束会把焦点
          // 归还给输入框，若同帧 push 下级路由，键盘会被拽回背景面板。
          session.closed.then((_) {
            if (mounted) _pickCustomDue(hadFocus);
          });
      }
    }

    OrbitPanelItem item(String value, String label) => OrbitPanelItem(
      label: label,
      checked: current == value,
      onTap: () => apply(value),
    );

    session = _openMenu(
      anchor: _menuAnchors[QuickActionId.due]!,
      anchorContent: _menuAnchorContent(QuickActionId.due),
      title: '日期',
      groupsBuilder: () => [
        [
          item('today', '今天'),
          item('tomorrow', '明天'),
          item('nextweek', '下周'),
          item('custom', '选择日期…'),
          if (_dueDate != null) item('clear', '清除日期'),
        ],
      ],
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
  /// [hadFocus] 由上级截止抽屉传入（本面板是下级，关闭时由这里恢复键盘）。
  Future<void> _pickCustomDue([bool hadFocus = false]) async {
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: _dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(_dueDate!)
          : null,
      accent: OrbitAccents.todoAccent,
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() => _dueDate = dateToMidnightMs(picked));
    }
    _restoreKeyboard(hadFocus);
  }

  /// 提醒档：相对档快捷（与表单/详情同源的 [reminderPresets]）+ 自定义时刻 +
  /// 已设时清除。
  ///
  /// 档位随截止日期变化（有截止 → 截止当天 9:00 / 截止前 N 分钟；无截止 →
  /// 今天/明天 9:00），故每次打开都按当下 [_dueDate] 重算；产物仍是**绝对
  /// 毫秒时刻**，不做「随截止漂移」的绑定（与表单、桌面同口径）。
  void _pickReminder() {
    final presets = reminderPresets(
      dueDate: _dueDate,
      // 新建任务恒有开始日期（今天零点）：零点不带时刻，不会凭空多出「结束时」档
      startDate: dateToMidnightMs(DateTime.now()),
    );
    // 自定义时间会再开下级日期+时分面板（路由）：焦点记忆传下去，由下级关闭
    // 时恢复（本级菜单 Overlay 直挂 + 焦点护航，不抢焦点）
    final hadFocus = _titleFocus.hasFocus;
    late final OrbitMenuSession session;

    session = _openMenu(
      anchor: _menuAnchors[QuickActionId.reminder]!,
      anchorContent: _menuAnchorContent(QuickActionId.reminder),
      title: '提醒时间',
      groupsBuilder: () => [
        [
          for (final preset in presets)
            OrbitPanelItem(
              label: preset.label,
              checked: _remindAt == preset.ms,
              onTap: () {
                if (mounted) setState(() => _remindAt = preset.ms);
              },
            ),
          OrbitPanelItem(
            label: '自定义时间…',
            // 与日期档同：先等本级菜单回收完成再开下级面板，避免退场归还焦点
            // 与下级路由进场抢帧
            onTap: () => session.closed.then((_) {
              if (mounted) _pickCustomReminder(hadFocus);
            }),
          ),
          if (_remindAt != null)
            OrbitPanelItem(
              label: '清除提醒',
              onTap: () {
                if (mounted) setState(() => _remindAt = null);
              },
            ),
        ],
      ],
    );
  }

  /// 自定义提醒时刻：日期 + 时分单面板（与表单 `_pickCustomReminder` 同源）。
  /// 取消不清值——清空走菜单里的「清除提醒」。
  Future<void> _pickCustomReminder([bool hadFocus = false]) async {
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: _remindAt != null
          ? DateTime.fromMillisecondsSinceEpoch(_remindAt!)
          : null,
      showTime: true,
      accent: OrbitAccents.todoAccent,
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() => _remindAt = picked.millisecondsSinceEpoch);
    }
    _restoreKeyboard(hadFocus);
  }

  /// 优先级档：锚定单选菜单（六档带档色，点选即回填并关闭）
  void _pickPriority() {
    _openMenu(
      anchor: _menuAnchors[QuickActionId.priority]!,
      anchorContent: _menuAnchorContent(QuickActionId.priority),
      title: '优先级',
      groupsBuilder: () => [
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

  /// 标签档：锚定多选菜单——点行即选中/取消并实时回填面板，
  /// 菜单常驻可连选，点卡外关闭（不要确认/取消尾栏）
  Future<void> _pickLabels() async {
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
    _openMenu(
      anchor: _menuAnchors[QuickActionId.label]!,
      anchorContent: _menuAnchorContent(QuickActionId.label),
      title: '标签',
      // 标签行（色点 + 标题 + 选中打勾）：默认 288 宽放不下长标题，加宽到 300
      // （库内按屏宽 - 24 钳制，不贴边）
      maxWidth: 300,
      // 多选要连选，菜单常驻不关（closeOnTap: false，行点击后组件重取勾选态）
      closeOnTap: false,
      contentKey: const ValueKey('quick-add-label-card-list'),
      groupsBuilder: () => [
        [
          for (final label in all)
            OrbitPanelItem(
              leading: Container(
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
              label: label.title,
              checked: picked.contains(label.id),
              onTap: () {
                picked.contains(label.id)
                    ? picked.remove(label.id)
                    : picked.add(label.id);
                if (!mounted) return;
                setState(
                  () => _labels = [
                    for (final l in all)
                      if (picked.contains(l.id)) l,
                  ],
                );
              },
            ),
        ],
      ],
    );
  }

  /// 项目档：锚定单选菜单（未分组 + 项目列表带项目色，点选即回填）
  void _pickProject() {
    final projects =
        ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
    _openMenu(
      anchor: _menuAnchors[QuickActionId.project]!,
      anchorContent: _menuAnchorContent(QuickActionId.project),
      title: '项目',
      groupsBuilder: () => [
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
      // 管理菜单内「继续添加」会再进系统相册：焦点记忆同样透传
      final hadFocus = _titleFocus.hasFocus;
      await _withKeyboard(
        () => showMoreActionsSheet(
          context,
          title: '图片（${_images.length}张待上传）',
          actions: [
            OrbitPanelItem(
              icon: OrbitIcons.image,
              label: '继续添加',
              onTap: () => _addImage(hadFocus),
            ),
            OrbitPanelItem(
              icon: OrbitIcons.delete,
              label: '清空图片',
              color: AppColors.ofContext(context).destructive,
              onTap: () {
                if (mounted) setState(() => _images.clear());
              },
            ),
          ],
        ),
      );
      return;
    }
    await _addImage();
  }

  /// [keepKeyboard] 由上级管理菜单透传（本调用是下级，关闭时由这里恢复）；
  /// 直接调用时按当前焦点自行判断。
  Future<void> _addImage([bool? keepKeyboard]) async {
    // 系统相册同样会让输入法下沉，回来后恢复
    final hadFocus = keepKeyboard ?? _titleFocus.hasFocus;
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
    } finally {
      _restoreKeyboard(hadFocus);
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

  /// 全屏档：把当前草稿（标题/优先级/截止/提醒）带进完整新建表单做详细编辑
  Future<void> _openFullForm() async {
    final projectId = _projectId;
    final quickView = widget.quickView;
    final title = _titleController.text.trim();
    final priority = _priority;
    final dueOffsetDays = _dueOffsetDays(_dueDate);
    final remindAt = _remindAt;
    Navigator.of(context).pop();
    await showTodoFormSheet(
      context,
      defaultProjectId: projectId,
      quickView: quickView,
      // 提醒是绝对时刻，模板 payload 不承接（模板域无提醒能力），单独带入
      initialRemindAt: remindAt,
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

  /// 「更多」菜单：未启用档 + 固定「设置」入口分两组；点选后菜单自关，
  /// 回调内再处理面板。Overlay 直挂（不抢键盘，与底栏「更多」同款形变）；
  /// 导航离开类入口（设置）照旧先关面板。
  void _openMoreMenu(List<QuickActionId> hidden) {
    _openMenu(
      anchor: _moreAnchor,
      anchorContent: Center(
        child: Icon(
          OrbitIcons.moreVertical,
          size: AppDimens.iconSizeMd,
          color: AppColors.ofContext(context).iconText,
        ),
      ),
      title: '更多',
      groupsBuilder: () => [
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

    // 菜单开着时返回键先关菜单（Overlay 不占路由，默认会直接关面板丢草稿）
    return PopScope(
      canPop: !_menuOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          // 路由开始退场时 State 仍要活到过渡结束；立刻撤下根浮层，不能等
          // dispose 才清，否则菜单会悬在已开始关闭的面板上方。
          _menuSession?.dispose();
        } else {
          _closeMenu();
        }
      },
      // 键盘避让落在玻璃**之外**（`OrbitGlassSheet` 已收口：玻璃只覆盖面板
      // 本体，键盘高度不进模糊纹理）
      child: OrbitGlassSheet(
        backdrop: widget.backdrop,
        child: OrbitSheetScaffold(
          showHandle: true,
          contentScrollable: false,
          maxHeightFactor: 0.7,
          // 卡面由 OrbitGlassSheet 自绘：骨架若再画一层不透明浮起卡片，会在
          // 玻璃内再缩进 16，左/右/下露出「玻璃边 + 实色卡」两层边缘
          floatingCard: false,
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
                child: OrbitTextField(
                  controller: _titleController,
                  focusNode: _titleFocus,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 200,
                  hintText: '准备做什么？',
                  style: TextStyle(fontSize: 15, color: colors.bodyText),
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
        ),
      ),
    );
  }

  /// 工具档按钮：未选是 42px 图标钮；已选则展开为「图标 + 具体值」
  /// 文字胶囊（日期/项目名/标签/张数直接可见，不在输入框上方加行；
  /// 优先级只旗子变色、不展字）。
  /// 按钮本体包进 `MiuixGlassAnchor`：菜单从该按钮轮廓连续形变长出
  /// （与底栏「更多」同款），展开期按钮内容由 `anchorContent` 副本承担。
  Widget _toolbarButton(QuickActionId id) {
    final colors = AppColors.ofContext(context);
    final value = _actionValue(id);
    // 优先级只旗子变色、不展文字胶囊（active 另判）
    final active =
        value != null || (id == QuickActionId.priority && _priority > 0);
    final tone = _actionTone(id, colors, active);
    return MiuixGlassAnchor(
      anchor: _menuAnchors[id]!,
      child: value == null
          ? OrbitIconButton(
              // 优先级无文字值但仍有已选态：tooltip 显示已选值
              tooltip: active ? _actionTooltip(id) : id.label,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(
                width: _toolbarButtonSize,
                height: _toolbarButtonSize,
              ),
              onPressed: () => _onAction(id),
              icon: Icon(
                quickActionIcon(id),
                size: AppDimens.iconSizeMd,
                color: tone,
              ),
            )
          : Tooltip(
              message: _actionTooltip(id),
              child: InkWell(
                borderRadius: AppShapes.small,
                onTap: () => _onAction(id),
                child: Container(
                  height: _toolbarButtonSize,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space8,
                  ),
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
      case QuickActionId.reminder:
        return _remindAt == null ? null : formatDueShort(_remindAt!);
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
        return projects.where((p) => p.id == _projectId).firstOrNull?.title;
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
      case QuickActionId.reminder:
        return _remindAt == null ? '提醒' : '提醒：${formatDueShort(_remindAt!)}';
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
    return MiuixGlassAnchor(
      anchor: _moreAnchor,
      child: OrbitIconButton(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: _toolbarButtonSize,
          height: _toolbarButtonSize,
        ),
        onPressed: () {
          final (_, hidden) = QuickActions.read();
          _openMoreMenu(hidden);
        },
        icon: Icon(
          OrbitIcons.moreVertical,
          size: AppDimens.iconSizeMd,
          color: colors.iconText,
        ),
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
                ? const OrbitSpinner(size: 16, color: Colors.white)
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
