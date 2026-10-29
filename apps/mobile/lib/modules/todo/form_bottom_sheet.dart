import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/api/orbit_bridge.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_info_row.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart'
    show bottomSheetMotion, bottomSheetTopShape;
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突
import 'logic/parse_quick_input.dart';
import 'logic/repeat_logic.dart' as rep;
import 'logic/template_apply.dart';
import 'logic/task_logic.dart'
    show
        QuickViewKey,
        atViewDueHour,
        dateToMidnightMs,
        formatDueShort,
        formatDurationMinutes,
        formatStampLabel,
        nextMondayMidnightMs,
        priorityColorHex,
        priorityLabel,
        quickViewCreateDefaults,
        reminderPresets,
        statusColorHex,
        statusLabel;
import 'providers/todo_providers.dart';
import 'repeat_edit_sheet.dart';
import '../../core/theme/icon_map.dart';

/// 提醒选择抽屉的「自定义时间…」哨兵值（毫秒档位取值域是纯数字，不冲突）
const String _reminderCustomKey = 'custom';

/// 截止日期选择器（表单抽屉"自定义"与详情页截止日期行共用）
///
/// 已切换为 wait-home 移植的 OrbitDatePicker 底部面板（月历 + 年月/年视图），
/// 函数签名保持不变，detail_screen 等调用方自动跟随。
Future<DateTime?> showTodoDatePicker(
  BuildContext context, {
  DateTime? initialDate,
}) {
  return OrbitDatePicker.pick(
    context,
    initialDate: initialDate,
    accent: OrbitAccents.todoAccent,
  );
}

/// 新建/编辑待办底部抽屉（docs/05 §4.4 简化版，移动端任务书口径）
///
/// 字段顺序：标题* → 描述 → 项目下拉 → 优先级六档横排色点 → 截止日期
/// （今天/明天/下周/自定义）。保存调 create/update 后 invalidate 相关 provider。
///
/// 用法：`await showTodoFormSheet(context, editingTaskId: id, defaultProjectId: pid);`
Future<void> showTodoFormSheet(
  BuildContext context, {
  int? editingTaskId,
  int? defaultProjectId,

  /// 新建态预填的截止日期毫秒（日历长按日格快捷新增用；编辑态忽略）
  int? initialDueDate,

  /// 当前选中的快捷视图（#39：视图内新建自动带本视图标记；仅新建态消费）
  QuickViewKey? quickView,

  /// 任务模板预填（套用模板时传入；优先级：模板 > 日历长按 > 视图默认）
  TemplatePayload? presetTemplate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (_) => _TodoFormSheet(
      editingTaskId: editingTaskId,
      defaultProjectId: defaultProjectId,
      initialDueDate: initialDueDate,
      quickView: quickView,
      presetTemplate: presetTemplate,
    ),
  );
}

/// 从模板新建：拉模板列表 → 选择 → payload 预填完整新建表单
///
/// 与任务列表页「长按加号」、快速添加面板「模板」档共用同一链，避免选择逻辑
/// 在两处复刻。无模板或拉取失败静默返回（模板是可选入口，不炸主流程）。
Future<void> showTemplateCreateFlow(
  BuildContext context,
  OrbitBridge bridge, {
  int? defaultProjectId,
  QuickViewKey? quickView,
}) async {
  try {
    final templates = await bridge.templatesList();
    if (!context.mounted || templates.isEmpty) return;
    final colors = AppColors.ofContext(context);
    final tpl = await showModalBottomSheet<TodoTemplate>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Text(
                '从模板新建',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
            ),
            for (final t in templates)
              ListTile(
                title: Text(
                  t.name,
                  style: TextStyle(fontSize: 14, color: colors.bodyText),
                ),
                onTap: () => Navigator.pop(ctx, t),
              ),
          ],
        ),
      ),
    );
    if (tpl == null || !context.mounted) return;
    await showTodoFormSheet(
      context,
      defaultProjectId: defaultProjectId,
      quickView: quickView,
      presetTemplate: parseTemplatePayload(tpl.payload),
    );
  } catch (_) {
    /* 模板拉取失败：静默（模板是可选入口） */
  }
}

/// 提醒同步（桌面端 task-form-sheet 同语义）：
/// - 清空（remindAt=null）→ 删旧提醒；
/// - 变更（时刻或持续标记）→ 删旧建新；
/// - 未动（同值）→ 跳过。
/// 新建场景 existing 传 null：有值即建立。
///
/// `isConstant`（G2 持续提醒）：1 = 到期后未完成则每 5 分钟再提醒，直至完成。
/// 参与「未动」判定——只翻转开关而时刻不变时同样要删旧建新。
Future<void> syncTaskReminder(
  OrbitBridge bridge,
  int taskId,
  int? remindAt,
  TodoReminder? existing, {
  int isConstant = 0,
}) async {
  if (remindAt == null) {
    if (existing != null) await bridge.todoReminderDelete(existing.id);
    return;
  }
  if (existing != null &&
      existing.remindAt == remindAt &&
      existing.isConstant == isConstant) {
    return;
  }
  if (existing != null) await bridge.todoReminderDelete(existing.id);
  await bridge.todoReminderCreate(
    TodoReminderCreateInput(
      taskId: taskId,
      remindAt: remindAt,
      isConstant: isConstant,
    ),
  );
}

class _TodoFormSheet extends ConsumerStatefulWidget {
  const _TodoFormSheet({
    this.editingTaskId,
    this.defaultProjectId,
    this.initialDueDate,
    this.quickView,
    this.presetTemplate,
  });

  /// 有值 = 编辑态（异步预填 todoTaskGet）
  final int? editingTaskId;

  /// 新建态默认归属项目（子列表项目入口携入）
  final int? defaultProjectId;

  /// 新建态预填的截止日期毫秒（日历长按快捷新增；编辑态忽略）
  final int? initialDueDate;

  /// 当前选中的快捷视图（#39：视图内新建自动带本视图标记；仅新建态消费）
  final QuickViewKey? quickView;

  /// 任务模板预填（新建态消费；编辑态忽略）
  final TemplatePayload? presetTemplate;

  @override
  ConsumerState<_TodoFormSheet> createState() => _TodoFormSheetState();
}

class _TodoFormSheetState extends ConsumerState<_TodoFormSheet> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  /// 自定义时长输入：由表单态持有，避免关闭动画期间被子抽屉提前 dispose
  final _durationCtl = TextEditingController();

  /// 新建标签输入（选择标签抽屉内就地创建，对齐桌面 TagsField）
  final _newLabelCtl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  int? _projectId;
  int _priority = 0;
  int? _dueDate;
  String _status = 'pending';

  /// 编辑态原始状态：保存时据此判断是否跨 done 边界（跨边界走完成引擎）
  String _originalStatus = 'pending';
  int? _startDate;
  int? _remindAt;

  /// 预计时长（分钟，M9 阶段一）；null = 未设置
  int? _durationMinutes;

  /// 持续提醒开关（G2）：到期未完成则每 5 分钟再提醒，直至完成
  bool _remindConstant = false;

  /// 新建态手动选择的标签（G5，对齐桌面 TagsField；与 NLP 命中标签合并挂载）
  final List<TodoLabel> _pickedLabels = [];

  /// 新建态待建子任务标题（G5，对齐桌面 SubtasksField）；保存后逐条建立
  final List<String> _subtaskTitles = [];

  /// 子任务添加输入框（仅新建态挂载）
  final _subtaskController = TextEditingController();
  TodoReminder? _existingReminder;
  // 重复规则值（预设/自定义/扩展字段的全部编辑都收敛到重复编辑抽屉，
  // 表单侧只存结果，不再持有自定义档/间隔输入等中间态）
  int _repeatMode = rep.RepeatMode.none;
  int _repeatAfter = 1;
  // #34 重复规则扩展：星期几掩码（bit0=周一…bit6=周日）+ 结束条件 + when done
  int _repeatWeekdays = 0;
  int _repeatEndType = 0;
  int _repeatEndParam = 0;
  bool _repeatFromDone = false;
  // 月高级语义（#72）：月模式 + 序数 + 单选星期（仅 MONTHLY 生效）
  int _repeatMonthMode = rep.RepeatMonthMode.day;
  int _repeatNthWeek = 0;
  int _repeatMonthWeekday = 0;
  bool _saving = false;
  bool _loaded = false;
  String? _loadError;

  /// 标题 NLP 实时解析结果（新建态生效；编辑态不启用避免覆盖回填字段）
  ParsedQuickInput? _titleParse;

  /// 标题 NLP 命中的逐项取消（F4）：按解析值键控——token 改动后取消态自动失效
  int? _dismissDueMs;
  int _dismissPriority = 0;
  int? _dismissProjectId;
  List<int> _dismissLabelIds = const [];
  int? _dismissDuration;
  String? _dismissRepeatKey;

  /// 标题输入实时解析（parseQuickInput 同源移植桌面 #7 + F4 时刻/时长/重复）：
  /// 命中日期/时刻/时长/重复/优先级/项目/标签时在标题下显示预览 chips
  ///（可逐项取消），保存时应用未取消项并剥离 token
  void _onTitleChanged(String raw) {
    if (widget.editingTaskId != null) return; // 编辑态不启用
    final projects = ref.read(todoProjectsProvider).value ?? [];
    final labels = ref.read(todoLabelsProvider).value ?? [];
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
    // 有任何命中才显示（无命中时清空预览）
    final hit =
        parsed.dueDate != null ||
        parsed.priority > 0 ||
        parsed.projectId != null ||
        parsed.labelIds.isNotEmpty ||
        parsed.durationMinutes != null ||
        parsed.repeat != null;
    setState(() => _titleParse = hit ? parsed : null);
  }

  /// 保存时应用标题解析结果：字段填充 + 标题剥离（与桌面 QuickAddBar 同口径；
  /// chips 取消的维度跳过，回落到表单字段当前值）
  void _applyTitleParse() {
    final p = _titleParse;
    if (p == null) return;
    if (p.dueDate != null &&
        p.dueDate!.millisecondsSinceEpoch != _dismissDueMs) {
      // F4：显式时刻原样保留（今日/本周视图的 18 点归一见 _save）
      _dueDate = p.dueHasTime
          ? p.dueDate!.millisecondsSinceEpoch
          : dateToMidnightMs(p.dueDate!);
    }
    if (p.priority > 0 && p.priority != _dismissPriority) {
      _priority = p.priority;
    }
    if (p.projectId != null && p.projectId != _dismissProjectId) {
      _projectId = p.projectId;
    }
    if (p.durationMinutes != null && p.durationMinutes != _dismissDuration) {
      _durationMinutes = p.durationMinutes;
    }
    final rep = p.repeat;
    if (rep != null && _repeatKeyOf(rep) != _dismissRepeatKey) {
      // 结束条件/月高级语义不参与 NLP，维持表单当前值
      _repeatMode = rep.mode;
      _repeatAfter = rep.after;
      _repeatWeekdays = rep.weekdays;
    }
    // 标签挂载在任务创建后进行（见 _save 的 _pendingLabelIds）
    _pendingLabelIds = [
      for (final id in p.labelIds)
        if (!_dismissLabelIds.contains(id)) id,
    ];
    _titleController.text = p.title;
  }

  /// 解析命中的标签 id（保存链消费后清空）
  List<int> _pendingLabelIds = [];

  @override
  void initState() {
    super.initState();
    _projectId = widget.defaultProjectId;
    if (widget.editingTaskId != null) {
      _loadEditing(widget.editingTaskId!);
    } else {
      // 截止日期预填优先级：模板 > 日历长按 > 视图默认（today/week）> 无
      //（模板是用户显式选择，语义最强）
      final tpl = widget.presetTemplate;
      final viewDefaults = quickViewCreateDefaults(widget.quickView);
      if (tpl?.dueOffsetDays != null) {
        _dueDate = templateDueDateMs(tpl!.dueOffsetDays!);
      } else {
        _dueDate = widget.initialDueDate ?? viewDefaults.dueMs;
      }
      if (tpl?.title != null) _titleController.text = tpl!.title!;
      if (tpl?.notes != null) _descriptionController.text = tpl!.notes!;
      if (tpl?.priority != null) _priority = tpl!.priority!;
      // 新增默认开始日期：今天（本地零点，与桌面表单同口径）
      _startDate = dateToMidnightMs(DateTime.now());
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _subtaskController.dispose();
    _durationCtl.dispose();
    _newLabelCtl.dispose();
    super.dispose();
  }

  /// 编辑态异步预填（含提醒：取该任务第一条未删除提醒）
  Future<void> _loadEditing(int taskId) async {
    try {
      final bridge = ref.read(orbitBridgeProvider);
      final task = await bridge.todoTaskGet(taskId);
      // 提醒为独立实体，列表拉取后按 task_id 过滤（与桌面端一致）
      final reminders = await bridge.todoReminderList(const ListFilter());
      final firstReminder = reminders
          .where((r) => r.taskId == taskId && r.isDeleted == 0)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _titleController.text = task.title;
        _descriptionController.text = task.description ?? '';
        _projectId = task.projectId;
        _priority = task.priority;
        _dueDate = task.dueDate;
        _status = task.status;
        _originalStatus = task.status;
        _startDate = task.startDate;
        _repeatMode = task.repeatMode;
        _repeatAfter = task.repeatAfter;
        _repeatWeekdays = task.repeatWeekdays;
        _repeatEndType = task.repeatEndType;
        _repeatEndParam = task.repeatEndParam;
        _repeatFromDone = task.repeatFromDone == 1;
        _repeatMonthMode = task.repeatMonthMode;
        _repeatNthWeek = task.repeatNthWeek;
        _repeatMonthWeekday =
            task.repeatWeekdays != 0 &&
                (task.repeatWeekdays & (task.repeatWeekdays - 1)) == 0
            ? task.repeatWeekdays
            : 0;
        _existingReminder = firstReminder;
        _remindAt = firstReminder?.remindAt;
        _remindConstant = firstReminder?.constant ?? false;
        _durationMinutes = task.durationMinutes;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = '记录不存在或加载失败');
    }
  }

  // ── 保存链：校验标题非空 → create/update → invalidate + 关闭 ──

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    // 应用标题 NLP 解析结果（日期/优先级/项目/标签 + 标题剥离）后再取值
    _applyTitleParse();
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    final repeatMode = _repeatMode;
    final repeatAfter = _repeatAfter;
    // 重复规则扩展落库口径（与桌面 RepeatField/RepeatEditor 同源）：
    // 周档星期掩码多选；月档第 N 个星期 X 走单选星期位 + 月模式/序数两列；
    // 其余档位扩展清零（掩码仅周档生效同口径）
    final nthOn =
        repeatMode == rep.RepeatMode.monthly &&
        _repeatMonthMode == rep.RepeatMonthMode.nth;
    final repeatWeekdays = repeatMode == rep.RepeatMode.weekly
        ? _repeatWeekdays
        : nthOn
        ? _repeatMonthWeekday
        : 0;
    final repeatMonthMode = repeatMode == rep.RepeatMode.monthly && nthOn
        ? rep.RepeatMonthMode.nth
        : 0;
    final repeatNthWeek = repeatMode == rep.RepeatMode.monthly && nthOn
        ? _repeatNthWeek
        : 0;
    // 完成引擎推进出的下一期 due（新建/编辑两条路径共用，成功后弹提示）
    int? nextDueMs;
    try {
      final bridge = ref.read(orbitBridgeProvider);
      if (widget.editingTaskId == null) {
        // 视图标记静默附加（#39）：我的一天/收藏视图下新建自动带标记
        //（表单无对应字段，用户取消可长按菜单一键解除）；保存瞬间重算
        //（表单跨零点长开时 myDayDate 不落昨天）。dueDate 用户手动清空时
        // 不回注视图默认（_dueDate 预填后可被用户删掉，此时尊重显式选择）。
        final viewDefaults = quickViewCreateDefaults(widget.quickView);
        // 今日/本周视图内截止时刻归一 18:00（用户口径）：快捷胶囊/日历等日期
        // 来源只表达日期；NLP 显式时刻（F4，未被取消且未被手动改期）跳过归一
        final inDueView =
            widget.quickView == QuickViewKey.today ||
            widget.quickView == QuickViewKey.week;
        final tp = _titleParse;
        final nlpDueHasTime =
            tp != null &&
            tp.dueHasTime &&
            tp.dueDate != null &&
            tp.dueDate!.millisecondsSinceEpoch != _dismissDueMs &&
            _dueDate == tp.dueDate!.millisecondsSinceEpoch;
        // 新建即完成：先落非完成态再走完成引擎——直接写 status=done 只会
        // 得到 done=0 的不一致行，且重复任务不会推进下一期（G11 同口径）
        final created = await bridge.todoTaskCreate(
          TodoTaskCreateInput(
            title: title,
            description: description.isEmpty ? null : description,
            projectId: _projectId,
            priority: _priority,
            status: _status == 'done' ? 'pending' : _status,
            dueDate: inDueView && _dueDate != null && !nlpDueHasTime
                ? atViewDueHour(_dueDate!)
                : _dueDate,
            startDate: _startDate,
            repeatMode: repeatMode,
            repeatAfter: repeatAfter,
            repeatWeekdays: repeatWeekdays,
            repeatEndType: _repeatEndType,
            repeatEndParam: _repeatEndParam,
            repeatFromDone: _repeatFromDone ? 1 : 0,
            repeatMonthMode: repeatMonthMode,
            repeatNthWeek: repeatNthWeek,
            myDayDate: viewDefaults.myDayMs,
            isFavorite: viewDefaults.favorite,
            durationMinutes: _durationMinutes,
          ),
        );
        // 新建：设置提醒 → 建立提醒实体
        if (_remindAt != null) {
          await syncTaskReminder(
            bridge,
            created.id,
            _remindAt,
            null,
            isConstant: _remindConstant ? 1 : 0,
          );
        }
        // 新建：标签挂载（NLP 命中 ∪ 手动勾选，去重；失败不阻断保存——
        // 部分成功口径，与桌面 TagsField 提交链一致）
        final labelIds = <int>{
          ..._pendingLabelIds,
          for (final l in _pickedLabels) l.id,
        };
        for (final labelId in labelIds) {
          try {
            await bridge.todoTaskLabelCreate(
              TodoTaskLabelCreateInput(taskId: created.id, labelId: labelId),
            );
          } catch (_) {
            // 标签挂载失败不阻断保存（部分成功口径）
          }
        }
        _pendingLabelIds = [];
        // 新建：子任务逐条建立（手动添加 ∪ 模板预填；percent_done 由后端按
        // 完成度回算；单条失败不阻断——部分成功口径与标签挂载一致）
        for (final title in _subtaskTitles) {
          try {
            await bridge.todoSubtaskCreate(
              TodoSubtaskCreateInput(taskId: created.id, title: title),
            );
          } catch (_) {}
        }
        // 新建：模板子任务逐条建立（percent_done 由后端按完成度回算；
        // 单条失败不阻断——部分成功口径与标签挂载一致）
        final tplSubs = widget.presetTemplate?.subtasks ?? const <String>[];
        for (final title in tplSubs) {
          try {
            await bridge.todoSubtaskCreate(
              TodoSubtaskCreateInput(taskId: created.id, title: title),
            );
          } catch (_) {}
        }
        // 新建即完成：子任务/标签/提醒挂载完再走完成引擎（重复任务生成的
        // 下一期才能承接子任务与提醒；直接写 status=done 会丢下一期）
        if (_status == 'done') {
          try {
            final res = await bridge.todoTaskComplete(created.id);
            nextDueMs = res.nextInstance?.dueDate;
          } catch (_) {
            if (mounted) {
              WaitToast.destructive('任务已创建，但标记完成失败，请手动勾选完成');
            }
          }
        }
      } else {
        // 状态跨 done 边界：完成必须走 todoTaskComplete（重复任务由 core
        // 单事务推进下一实例）；切回未完成要同时清 done/done_at
        final becomesDone = _status == 'done' && _originalStatus != 'done';
        final uncomplete = _originalStatus == 'done' && _status != 'done';
        await bridge.todoTaskUpdate(
          widget.editingTaskId!,
          encodePatch({
            'title': title,
            'description': description.isEmpty ? null : description,
            'project_id': _projectId,
            'priority': _priority,
            if (!becomesDone) 'status': _status,
            if (uncomplete) 'done': 0,
            if (uncomplete) 'done_at': null,
            'due_date': _dueDate,
            'start_date': _startDate,
            'repeat_mode': repeatMode,
            'repeat_after': repeatAfter,
            'repeat_weekdays': repeatWeekdays,
            'repeat_end_type': _repeatEndType,
            'repeat_end_param': _repeatEndParam,
            'repeat_from_done': _repeatFromDone ? 1 : 0,
            'repeat_month_mode': repeatMonthMode,
            'repeat_nth_week': repeatNthWeek,
            'duration_minutes': _durationMinutes,
          }),
        );
        // 编辑：提醒按"清空删/变更删旧建新/未动跳过"同步（先于完成引擎，
        // 下一期承接的是本次修改后的提醒时刻）
        await syncTaskReminder(
          bridge,
          widget.editingTaskId!,
          _remindAt,
          _existingReminder,
          isConstant: _remindConstant ? 1 : 0,
        );
        if (becomesDone) {
          try {
            final res = await bridge.todoTaskComplete(widget.editingTaskId!);
            nextDueMs = res.nextInstance?.dueDate;
          } catch (_) {
            // 普通字段已落库；完成未生效时明确提示，避免误以为整单保存失败
            if (mounted) {
              WaitToast.destructive('字段已保存，但完成状态未生效，请重试');
            }
          }
        }
      }
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
      if (mounted) {
        if (nextDueMs != null) {
          WaitToast.success('已完成，已生成下一期：${rep.formatCnDate(nextDueMs)}');
        }
        Navigator.of(context).pop();
      }
    } catch (_) {
      WaitToast.destructive('保存失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── 新字段选择器 ──

  /// 日期字段选择（开始/结束日期共用：取自然日零点毫秒）
  Future<void> _pickDateField({
    required int? current,
    required ValueChanged<int> onPicked,
  }) async {
    final picked = await showTodoDatePicker(
      context,
      initialDate: current != null
          ? DateTime.fromMillisecondsSinceEpoch(current)
          : null,
    );
    if (picked != null && mounted) onPicked(dateToMidnightMs(picked));
  }

  /// 提醒时间选择：先给相对档快捷（见 [reminderPresets]），
  /// 末项「自定义时间…」进日期+时分单面板；两路产物都是绝对毫秒时刻
  Future<void> _pickReminder() async {
    await showSelectBottomSheet<String>(
      context,
      title: '提醒时间',
      items: [
        for (final p in reminderPresets(
          dueDate: _dueDate,
          startDate: _startDate,
          durationMinutes: _durationMinutes,
        ))
          SelectItem<String>(value: '${p.ms}', label: p.label),
        const SelectItem<String>(value: _reminderCustomKey, label: '自定义时间…'),
      ],
      onSelect: (v) {
        if (v == _reminderCustomKey) {
          _pickCustomReminder();
        } else {
          setState(() => _remindAt = int.parse(v));
        }
      },
    );
  }

  /// 自定义提醒时刻：wait 面板 showTime 模式，日期+时分单面板一次选完
  Future<void> _pickCustomReminder() async {
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: _remindAt != null
          ? DateTime.fromMillisecondsSinceEpoch(_remindAt!)
          : null,
      showTime: true,
      accent: OrbitAccents.todoAccent,
    );
    // null = 取消或面板内清除；取消不动值，清空走字段行叉号（语义与桌面一致）
    if (picked == null || !mounted) return;
    setState(() => _remindAt = picked.millisecondsSinceEpoch);
  }

  /// 预计时长行 → 常用档位单选抽屉 + 自定义分钟（对齐桌面数字输入）；
  /// 0 = 不设置清空
  Future<void> _pickDuration() async {
    await showSelectBottomSheet<String>(
      context,
      title: '预计时长',
      items: const [
        SelectItem<String>(value: '15', label: '15 分钟'),
        SelectItem<String>(value: '30', label: '30 分钟'),
        SelectItem<String>(value: '45', label: '45 分钟'),
        SelectItem<String>(value: '60', label: '1 小时'),
        SelectItem<String>(value: '90', label: '1.5 小时'),
        SelectItem<String>(value: '120', label: '2 小时'),
        SelectItem<String>(value: '180', label: '3 小时'),
        SelectItem<String>(value: 'custom', label: '自定义分钟数…'),
        SelectItem<String>(value: '0', label: '不设置'),
      ],
      current: _durationMinutes?.toString(),
      onSelect: (v) {
        if (v == 'custom') {
          _pickCustomDuration();
          return;
        }
        final n = int.tryParse(v) ?? 0;
        if (!mounted) return;
        setState(() => _durationMinutes = n == 0 ? null : n);
      },
    );
  }

  /// 自定义时长输入（1–10080 分钟；超出桌面同字段的合理跨度按无效处理）
  Future<void> _pickCustomDuration() async {
    final colors = AppColors.ofContext(context);
    _durationCtl.text = _durationMinutes?.toString() ?? '';
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (sheetCtx) => OrbitSheetScaffold(
        title: '自定义时长',
        content: TextField(
          controller: _durationCtl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '分钟数（如 25、240）'),
        ),
        actions: OrbitSheetActions(
          cancelLabel: '取消',
          onCancel: () => Navigator.pop(sheetCtx),
          confirmLabel: '确定',
          onConfirm: () => Navigator.pop(sheetCtx, true),
        ),
      ),
    );
    final text = _durationCtl.text.trim();
    if (confirmed != true || !mounted) return;
    final n = int.tryParse(text);
    if (n == null || n <= 0 || n > 10080) {
      WaitToast.destructive('请输入 1–10080 之间的分钟数');
      return;
    }
    setState(() => _durationMinutes = n);
  }

  // ── 字段行 → 底部选择抽屉（与详情页信息区同口径：行只显值，点行再选）──

  /// 项目行 → 单选抽屉（未分组 + 项目列表带色点）
  Future<void> _pickProject() async {
    final projects = ref.read(todoProjectsProvider).value ?? [];
    await showSelectBottomSheet<String>(
      context,
      title: '项目',
      items: [
        const SelectItem<String>(value: '', label: '未分组'),
        for (final project in projects)
          SelectItem(
            value: '${project.id}',
            label: project.title,
            colorDot: hexToColor(
              project.hexColor,
              fallback: OrbitAccents.todoAccent,
            ),
          ),
      ],
      current: _projectId == null ? '' : '$_projectId',
      onSelect: (v) {
        if (!mounted) return;
        setState(() => _projectId = v.isEmpty ? null : int.parse(v));
      },
    );
  }

  /// 优先级行 → 六档单选抽屉（P0「无」浅灰点，与列表/日历同源）
  Future<void> _pickPriority() async {
    await showSelectBottomSheet<int>(
      context,
      title: '优先级',
      items: [
        for (var i = 0; i <= 5; i++)
          SelectItem(
            value: i,
            label: priorityLabel(i),
            colorDot: hexToColor(priorityColorHex(i)),
          ),
      ],
      current: _priority,
      onSelect: (v) {
        if (!mounted) return;
        setState(() => _priority = v);
      },
    );
  }

  /// 状态行 → 三档单选抽屉（新建口径：只落 status，不补 done_at）
  Future<void> _pickStatus() async {
    await showSelectBottomSheet<String>(
      context,
      title: '状态',
      items: [
        for (final s in const [
          ('pending', '待办', '#6B7280'),
          ('doing', '进行中', '#3B82F6'),
          ('done', '已完成', '#22C55E'),
        ])
          SelectItem(value: s.$1, label: s.$2, colorDot: hexToColor(s.$3)),
      ],
      current: _status,
      onSelect: (v) {
        if (!mounted) return;
        setState(() => _status = v);
      },
    );
  }

  /// 重复行 → 重复规则抽屉（预设点选即回填，自定义面板「确定」一次提交）
  Future<void> _pickRepeat() async {
    final value = await showRepeatEditSheet(
      context,
      mode: _repeatMode,
      after: _repeatAfter,
      weekdays: _repeatWeekdays,
      endType: _repeatEndType,
      endParam: _repeatEndParam,
      fromDone: _repeatFromDone,
      // 「下次 M月d日」预览锚点 = 表单当前截止日期（与完成引擎同源）
      dueMs: _dueDate,
      monthMode: _repeatMonthMode,
      nthWeek: _repeatNthWeek,
    );
    if (value == null || !mounted) return;
    setState(() {
      _repeatMode = value.mode;
      _repeatAfter = value.after;
      _repeatWeekdays = value.weekdays;
      _repeatEndType = value.endType;
      _repeatEndParam = value.endParam;
      _repeatFromDone = value.fromDone;
      _repeatMonthMode = value.monthMode;
      _repeatNthWeek = value.nthWeek;
      _repeatMonthWeekday =
          value.weekdays != 0 && (value.weekdays & (value.weekdays - 1)) == 0
          ? value.weekdays
          : 0;
    });
  }

  /// 行间分隔线（日期与提醒卡片内）
  Widget _tileDivider(AppColorSet colors) =>
      Container(height: 1, color: colors.divider);

  /// 标题/描述输入框装饰：背景走 surface（亮色 #F9F9F9），
  /// 边框与信息卡片同口径（divider@30%、radius 12）。
  ///
  /// 四态边框全部显式给出：主题的 `border` 是 `BorderSide.none`，只覆盖
  /// enabledBorder 会让错误态回退到无边框（校验失败时框直接消失）。
  InputDecoration _fieldDecoration({
    required String label,
    required String hint,
    bool alignLabelWithHint = false,
  }) {
    final colors = AppColors.ofContext(context);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: alignLabelWithHint,
      counterText: '',
      filled: true,
      fillColor: colors.surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: OrbitAccents.themeAccent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colors.destructive),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colors.destructive, width: 1.5),
      ),
    );
  }

  // ── 截止日期快捷项（本地时区自然日零点；下周＝下周一，与桌面同口径）──

  int _midnightOf(int offsetDays) {
    final now = DateTime.now();
    return dateToMidnightMs(
      DateTime(now.year, now.month, now.day + offsetDays),
    );
  }

  Future<void> _pickCustomDate() async {
    final picked = await showTodoDatePicker(
      context,
      initialDate: _dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(_dueDate!)
          : null,
    );
    if (picked != null && mounted) {
      setState(() => _dueDate = dateToMidnightMs(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final projects = ref.watch(todoProjectsProvider).value ?? [];
    final project = _projectId == null
        ? null
        : projects.where((p) => p.id == _projectId).firstOrNull;
    final isEdit = widget.editingTaskId != null;

    // 键盘避让：底部 padding 跟随 viewInsets
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: colors.popup,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: !_loaded
              ? (_loadError != null ? _errorView(colors) : _loadingView())
              : Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 标题行：添加待办/编辑待办 + 保存钮
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppDimens.space16,
                          AppDimens.space12,
                          AppDimens.space8,
                          0,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isEdit ? '编辑待办' : '添加待办',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: colors.titleText,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '保存',
                              icon: _saving
                                  ? OrbitSpinner(
                                      size: 20,
                                      color: OrbitAccents.themeAccent,
                                    )
                                  : Icon(
                                      OrbitIcons.check,
                                      size: AppDimens.iconSizeLg,
                                      color: OrbitAccents.todoAccent,
                                    ),
                              onPressed: _saving ? null : _save,
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(
                            AppDimens.space16,
                            AppDimens.space8,
                            AppDimens.space16,
                            AppDimens.gestureInsetFallback / 2,
                          ),
                          children: [
                            // 1. 标题*（新建态实时 NLP 解析：明天/!3/#项目/@标签）
                            TextFormField(
                              controller: _titleController,
                              maxLength: 200,
                              style: TextStyle(
                                fontSize: 15,
                                color: colors.bodyText,
                              ),
                              decoration: _fieldDecoration(
                                label: '标题 *',
                                hint: '请输入标题',
                              ),
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? '请输入标题'
                                  : null,
                              onChanged: _onTitleChanged,
                            ),
                            // NLP 命中预览 chips（对齐桌面 QuickAddBar 形制 + F4 可取消）
                            if (_titleParse != null) ...[
                              const SizedBox(height: AppDimens.space8),
                              _TitleParseChips(
                                parse: _titleParse!,
                                dismissedDueMs: _dismissDueMs,
                                dismissedPriority: _dismissPriority,
                                dismissedProjectId: _dismissProjectId,
                                dismissedLabelIds: _dismissLabelIds,
                                dismissedDuration: _dismissDuration,
                                dismissedRepeatKey: _dismissRepeatKey,
                                labels:
                                    ref.watch(todoLabelsProvider).value ??
                                    const <TodoLabel>[],
                                onDismiss: (dim) => setState(() {
                                  final tp = _titleParse;
                                  if (tp == null) return;
                                  switch (dim) {
                                    case _ParseDim.due:
                                      _dismissDueMs =
                                          tp.dueDate?.millisecondsSinceEpoch;
                                    case _ParseDim.priority:
                                      _dismissPriority = tp.priority;
                                    case _ParseDim.project:
                                      _dismissProjectId = tp.projectId;
                                    case _ParseDim.duration:
                                      _dismissDuration = tp.durationMinutes;
                                    case _ParseDim.repeat:
                                      _dismissRepeatKey = tp.repeat == null
                                          ? null
                                          : _repeatKeyOf(tp.repeat!);
                                  }
                                }),
                                onDismissLabel: (id) => setState(
                                  () => _dismissLabelIds = [
                                    ..._dismissLabelIds,
                                    id,
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: AppDimens.space12),
                            // 2. 描述：默认 3 行起随内容长高，封顶 8 行后内部滚动
                            // （minLines+maxLines 而非固定行数——与桌面端 min-h/max-h 口径一致）
                            TextFormField(
                              controller: _descriptionController,
                              minLines: 3,
                              maxLines: 8,
                              // 与桌面端 task-form-sheet description(5000) 统一
                              maxLength: 5000,
                              style: TextStyle(
                                fontSize: 15,
                                color: colors.bodyText,
                              ),
                              decoration: _fieldDecoration(
                                label: '描述',
                                hint: '请输入描述',
                                alignLabelWithHint: true,
                              ),
                            ),
                            const SizedBox(height: AppDimens.space12),
                            // 3-6. 基本信息（与详情页信息区同形制：行显值，
                            // 点行弹底部选择抽屉——字段不在行内直改）
                            SectionCard(
                              title: '信息',
                              child: Column(
                                children: [
                                  InfoTile(
                                    label: '项目',
                                    value: project?.title ?? '未分组',
                                    // #36：项目名按项目色着字
                                    valueColor: project != null
                                        ? hexToColor(
                                            project.hexColor,
                                            fallback: colors.bodyText,
                                          )
                                        : null,
                                    onClick: _pickProject,
                                  ),
                                  InfoTile(
                                    label: '优先级',
                                    value: priorityLabel(_priority),
                                    dotColorHex: priorityColorHex(_priority),
                                    onClick: _pickPriority,
                                  ),
                                  InfoTile(
                                    label: '状态',
                                    value: statusLabel(_status),
                                    dotColorHex: statusColorHex(_status),
                                    onClick: _pickStatus,
                                  ),
                                  InfoTile(
                                    label: '重复',
                                    value: rep.repeatLabelExt(
                                      _repeatMode,
                                      _repeatAfter,
                                      weekdays: _repeatWeekdays,
                                      endType: _repeatEndType,
                                      endParam: _repeatEndParam,
                                      fromDone: _repeatFromDone ? 1 : 0,
                                      monthMode: _repeatMonthMode,
                                      nthWeek: _repeatNthWeek,
                                    ),
                                    onClick: _pickRepeat,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppDimens.space16),
                            // 7-9. 日期与提醒（卡片信息行：与详情页 _InfoTile 同设计语言）
                            SectionCard(
                              title: '日期与提醒',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // 截止日期：未设 → 行内快捷胶囊；已设 → 值 + 清除
                                  _FormDateTile(
                                    icon: OrbitIcons.flag,
                                    label: '截止日期',
                                    value: _dueDate != null
                                        ? formatDueShort(_dueDate!)
                                        : null,
                                    onTap: _pickCustomDate,
                                    onClear: _dueDate == null
                                        ? null
                                        : () => setState(() => _dueDate = null),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _QuickCapsule(
                                          label: '今天',
                                          onTap: () => setState(
                                            () => _dueDate = _midnightOf(0),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _QuickCapsule(
                                          label: '明天',
                                          onTap: () => setState(
                                            () => _dueDate = _midnightOf(1),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _QuickCapsule(
                                          label: '下周',
                                          onTap: () => setState(
                                            () => _dueDate =
                                                nextMondayMidnightMs(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  _tileDivider(colors),
                                  _FormDateTile(
                                    icon: OrbitIcons.playCircle,
                                    label: '开始日期',
                                    value: _startDate != null
                                        ? formatDueShort(_startDate!)
                                        : null,
                                    onTap: () => _pickDateField(
                                      current: _startDate,
                                      onPicked: (ms) =>
                                          setState(() => _startDate = ms),
                                    ),
                                    onClear: _startDate == null
                                        ? null
                                        : () =>
                                              setState(() => _startDate = null),
                                  ),
                                  _tileDivider(colors),
                                  // 提醒时间（虚拟字段：提交时同步 todo_reminders）
                                  _FormDateTile(
                                    icon: OrbitIcons.notification,
                                    label: '提醒时间',
                                    value: _remindAt != null
                                        ? formatStampLabel(_remindAt!)
                                        : null,
                                    onTap: _pickReminder,
                                    onClear: _remindAt == null
                                        ? null
                                        : () =>
                                              setState(() => _remindAt = null),
                                  ),
                                  _tileDivider(colors),
                                  // 预计时长（M9 阶段一）：常用档位单选抽屉
                                  _FormDateTile(
                                    icon: OrbitIcons.clock,
                                    label: '预计时长',
                                    value: _durationMinutes != null
                                        ? formatDurationMinutes(
                                            _durationMinutes,
                                          )
                                        : null,
                                    onTap: _pickDuration,
                                    onClear: _durationMinutes == null
                                        ? null
                                        : () => setState(
                                            () => _durationMinutes = null,
                                          ),
                                  ),
                                  // 持续提醒（G2）：仅在已设提醒时出现——
                                  // 无提醒时刻时该开关无意义
                                  if (_remindAt != null) ...[
                                    _tileDivider(colors),
                                    SizedBox(
                                      height: AppDimens.touchTarget,
                                      child: Row(
                                        children: [
                                          Icon(
                                            OrbitIcons.notification,
                                            size: 18,
                                            color: colors.bodyText.withValues(
                                              alpha: 0.7,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              '持续提醒（响到完成为止）',
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: colors.bodyText,
                                              ),
                                            ),
                                          ),
                                          Switch(
                                            value: _remindConstant,
                                            onChanged: (v) => setState(
                                              () => _remindConstant = v,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            // 标签 / 子任务（G5）：仅新建态（对齐桌面 footerContent
                            // 的 `!task` 条件；编辑态标签在详情区、子任务在详情区树）
                            if (widget.editingTaskId == null) ...[
                              const SizedBox(height: AppDimens.space16),
                              SectionCard(
                                title: '标签',
                                trailing: TextButton(
                                  onPressed: _pickFormLabels,
                                  child: const Text('选择'),
                                ),
                                child: _pickedLabels.isEmpty
                                    ? Text(
                                        '暂未选择标签',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: colors.secondaryText
                                              .withValues(alpha: 0.5),
                                        ),
                                      )
                                    : Wrap(
                                        spacing: AppDimens.space8,
                                        runSpacing: AppDimens.space8,
                                        children: [
                                          for (final label in _pickedLabels)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal:
                                                        AppDimens.space8 + 2,
                                                    vertical: AppDimens.space4,
                                                  ),
                                              decoration: BoxDecoration(
                                                borderRadius: AppShapes.small,
                                                border: Border.all(
                                                  color: colors.divider,
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Container(
                                                    width:
                                                        AppDimens.colorDotSize -
                                                        2,
                                                    height:
                                                        AppDimens.colorDotSize -
                                                        2,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: hexToColor(
                                                        label.hexColor,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(
                                                    width: AppDimens.space8,
                                                  ),
                                                  Text(
                                                    label.title,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: colors.bodyText,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                              ),
                              const SizedBox(height: AppDimens.space16),
                              SectionCard(
                                title: '子任务',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (final title in _subtaskTitles)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: AppDimens.space4,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                title,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: colors.bodyText,
                                                ),
                                              ),
                                            ),
                                            IconButton(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              tooltip: '移除子任务',
                                              icon: Icon(
                                                OrbitIcons.close,
                                                size: AppDimens.iconSizeSm + 2,
                                                color: colors.secondaryText,
                                              ),
                                              onPressed: () => setState(
                                                () => _subtaskTitles.remove(
                                                  title,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _subtaskController,
                                            style: const TextStyle(
                                              fontSize: 14,
                                            ),
                                            decoration: const InputDecoration(
                                              hintText: '添加子任务',
                                            ),
                                            onSubmitted: (_) =>
                                                _addSubtaskTitle(),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _addSubtaskTitle,
                                          child: const Text('添加'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  /// 标签多选抽屉（G5）：勾选即进 [_pickedLabels]（不落库——任务尚未创建，
  /// 保存链统一挂载）；抽屉内可连选
  Future<void> _pickFormLabels() async {
    var labels = <TodoLabel>[...?ref.read(todoLabelsProvider).value];
    if (labels.isEmpty) {
      try {
        labels = [...await ref.read(todoLabelsProvider.future)];
      } catch (_) {
        labels = <TodoLabel>[];
      }
    }
    if (!mounted) return;
    final colors = AppColors.ofContext(context);
    final picked = {for (final l in _pickedLabels) l.id};
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 就地新建标签（对齐桌面 TagsField）：建完即选中，无需转去设置页
          Future<void> createLabel() async {
            final title = _newLabelCtl.text.trim();
            if (title.isEmpty) return;
            try {
              final created = await ref
                  .read(orbitBridgeProvider)
                  .todoLabelCreate(TodoLabelCreateInput(title: title));
              if (!ctx.mounted) return;
              ref.invalidate(todoLabelsProvider);
              setSheet(() {
                labels.add(created);
                picked.add(created.id);
              });
              _newLabelCtl.clear();
            } catch (_) {
              if (ctx.mounted) WaitToast.destructive('创建标签失败');
            }
          }

          return OrbitSheetScaffold(
            title: '选择标签',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppDimens.space16,
                    AppDimens.space4,
                    AppDimens.space16,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _newLabelCtl,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => createLabel(),
                          decoration: const InputDecoration(
                            hintText: '新建标签…',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      TextButton(
                        onPressed: createLabel,
                        child: const Text('新建'),
                      ),
                    ],
                  ),
                ),
                if (labels.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppDimens.space16),
                    child: Text(
                      '还没有标签，可在上方输入名称新建',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.secondaryText,
                      ),
                    ),
                  ),
                for (final label in labels)
                  InkWell(
                    onTap: () => setSheet(() {
                      picked.contains(label.id)
                          ? picked.remove(label.id)
                          : picked.add(label.id);
                    }),
                    child: SizedBox(
                      height: AppDimens.touchTarget,
                      child: Row(
                        children: [
                          const SizedBox(width: AppDimens.space16),
                          Icon(
                            picked.contains(label.id)
                                ? OrbitIcons.success
                                : OrbitIcons.circle,
                            size: AppDimens.iconSizeMd,
                            color: picked.contains(label.id)
                                ? OrbitAccents.todoAccent
                                : colors.secondaryText,
                          ),
                          const SizedBox(width: AppDimens.space12),
                          Container(
                            width: AppDimens.colorDotSize,
                            height: AppDimens.colorDotSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: hexToColor(label.hexColor),
                            ),
                          ),
                          const SizedBox(width: AppDimens.space8),
                          Expanded(
                            child: Text(
                              label.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: colors.bodyText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            actions: OrbitSheetActions(
              confirmLabel: '完成',
              onConfirm: () {
                setState(
                  () => _pickedLabels
                    ..clear()
                    ..addAll(labels.where((l) => picked.contains(l.id))),
                );
                Navigator.pop(sheetCtx);
              },
              cancelLabel: '取消',
              onCancel: () => Navigator.pop(sheetCtx),
            ),
          );
        },
      ),
    );
  }

  /// 追加子任务标题（G5）：trim 非空且不重复才入列；输入框即清
  void _addSubtaskTitle() {
    final title = _subtaskController.text.trim();
    if (title.isEmpty || _subtaskTitles.contains(title)) return;
    setState(() {
      _subtaskTitles.add(title);
      _subtaskController.clear();
    });
  }

  Widget _loadingView() => Padding(
    padding: const EdgeInsets.all(AppDimens.space32),
    child: Center(
      child: OrbitSpinner(
        size: AppDimens.iconSizeLg,
        color: OrbitAccents.themeAccent,
      ),
    ),
  );

  Widget _errorView(AppColorSet colors) => Padding(
    padding: const EdgeInsets.all(AppDimens.space32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _loadError!,
          style: TextStyle(fontSize: 14, color: colors.secondaryText),
        ),
        const SizedBox(height: AppDimens.space16),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
      ],
    ),
  );
}

/// 日期/提醒信息行（与详情页 _InfoTile 同设计语言，表单版）
///
/// 结构：图标 + 标签 → Spacer → 值区（已设：值+清除叉；未设：trailing
/// 快捷胶囊或「无」占位）→ 尾箭头。整行可点唤起选择面板。
class _FormDateTile extends StatelessWidget {
  const _FormDateTile({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.onClear,
    this.trailing,
  });

  final IconData icon;

  /// 行标签（截止日期/开始日期/结束日期/提醒时间）
  final String label;

  /// 已设值文本；null = 未设（显示 trailing 或「无」占位）
  final String? value;

  final VoidCallback? onTap;

  /// 已设值的清除回调；null 不渲染清除叉
  final VoidCallback? onClear;

  /// 未设值时的行内快捷胶囊组（仅截止日期行使用）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hasValue = value != null;

    final row = Row(
      children: [
        Icon(icon, size: AppDimens.iconSizeSm + 2, color: colors.secondaryText),
        const SizedBox(width: AppDimens.space12),
        Text(label, style: TextStyle(fontSize: 14, color: colors.bodyText)),
        const Spacer(),
        if (!hasValue && trailing != null)
          trailing!
        else if (!hasValue)
          Text(
            '无',
            style: TextStyle(
              fontSize: 14,
              color: colors.secondaryText.withValues(alpha: 0.5),
            ),
          ),
        if (hasValue) ...[
          Flexible(
            child: Text(
              value!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.bodyText),
            ),
          ),
          if (onClear != null) ...[
            const SizedBox(width: AppDimens.space8),
            // 裸 Icon 热区不足：换 IconButton（48 约束 + 波纹 + 读屏语义），
            // 视觉仍是小叉（口径同 orbit_info_row 的清除钮）
            IconButton(
              tooltip: '清除',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: AppDimens.touchTarget,
                minHeight: AppDimens.touchTarget,
              ),
              onPressed: onClear,
              icon: Icon(
                OrbitIcons.close,
                size: AppDimens.iconSizeSm,
                color: colors.secondaryText,
              ),
            ),
          ],
        ],
        if (onTap != null) ...[
          const SizedBox(width: AppDimens.space4),
          Icon(
            OrbitIcons.chevronRight,
            size: AppDimens.iconSizeSm + 2,
            color: colors.secondaryText,
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
      child: onTap == null
          ? row
          : InkWell(borderRadius: AppShapes.small, onTap: onTap, child: row),
    );
  }
}

/// 行内快捷胶囊（截止日期未设时：今天/明天/下周，点选即设）
class _QuickCapsule extends StatelessWidget {
  const _QuickCapsule({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // 4pt 网格口径（10→12 / 4 不变）
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space12,
          vertical: AppDimens.space4,
        ),
        decoration: BoxDecoration(
          borderRadius: AppShapes.full,
          border: Border.all(color: colors.outline),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
      ),
    );
  }
}

/// 标题 NLP 命中的可取消维度（F4「用户可逐项取消」）
enum _ParseDim { due, priority, project, duration, repeat }

/// 重复规则 → 取消态键（token 改动后取消态自动失效）
String _repeatKeyOf(ParsedRepeat r) => '${r.mode}:${r.after}:${r.weekdays}';

/// 时长 chip 文案：整小时收敛为「N 小时」（与桌面 QuickAddBar 同口径）
String _durationChipLabel(int minutes) =>
    minutes >= 60 && minutes % 60 == 0 ? '${minutes ~/ 60} 小时' : '$minutes 分钟';

/// 标题 NLP 命中预览 chips（对齐桌面 QuickAddBar 形制）：
/// 截止日期(含时刻) / P1-P5 优先级 / 项目 / 标签 / 时长 / 重复 逐项小胶囊，
/// 点 × 取消该维度（保存时不再应用；token 改动后取消态自动失效）
class _TitleParseChips extends StatelessWidget {
  const _TitleParseChips({
    required this.parse,
    required this.dismissedDueMs,
    required this.dismissedPriority,
    required this.dismissedProjectId,
    required this.dismissedLabelIds,
    required this.dismissedDuration,
    required this.dismissedRepeatKey,
    required this.labels,
    required this.onDismiss,
    required this.onDismissLabel,
  });

  final ParsedQuickInput parse;

  /// 逐项取消状态：与解析值相等即视为已取消（不渲染该 chip）
  final int? dismissedDueMs;
  final int dismissedPriority;
  final int? dismissedProjectId;
  final List<int> dismissedLabelIds;
  final int? dismissedDuration;
  final String? dismissedRepeatKey;

  /// 标签标题解析（chip 文案用）
  final List<TodoLabel> labels;

  final ValueChanged<_ParseDim> onDismiss;
  final ValueChanged<int> onDismissLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final dueMs = parse.dueDate?.millisecondsSinceEpoch;
    return Wrap(
      spacing: AppDimens.space8,
      runSpacing: AppDimens.space4,
      children: [
        if (dueMs != null && dueMs != dismissedDueMs)
          _parseChip(
            context,
            icon: OrbitIcons.calendar,
            // formatDueShort 对带时刻的时间戳自动补 HH:mm（F4 显式时刻）
            label: '截止 ${formatDueShort(dueMs)}',
            color: colors.secondaryText,
            onDismiss: () => onDismiss(_ParseDim.due),
          ),
        if (parse.priority > 0 && parse.priority != dismissedPriority)
          _parseChip(
            context,
            icon: OrbitIcons.flag,
            label: 'P${parse.priority} ${priorityLabel(parse.priority)}',
            color: hexToColor(priorityColorHex(parse.priority)),
            onDismiss: () => onDismiss(_ParseDim.priority),
          ),
        if (parse.projectId != null && parse.projectId != dismissedProjectId)
          _parseChip(
            context,
            icon: OrbitIcons.folder,
            label: '项目已识别',
            color: colors.secondaryText,
            onDismiss: () => onDismiss(_ParseDim.project),
          ),
        for (final id in parse.labelIds)
          if (!dismissedLabelIds.contains(id))
            _parseChip(
              context,
              icon: OrbitIcons.tag,
              label: labels.where((l) => l.id == id).firstOrNull?.title ?? '标签',
              color: colors.secondaryText,
              onDismiss: () => onDismissLabel(id),
            ),
        if (parse.durationMinutes != null &&
            parse.durationMinutes != dismissedDuration)
          _parseChip(
            context,
            icon: OrbitIcons.clock,
            label: '时长 ${_durationChipLabel(parse.durationMinutes!)}',
            color: colors.secondaryText,
            onDismiss: () => onDismiss(_ParseDim.duration),
          ),
        if (parse.repeat != null &&
            _repeatKeyOf(parse.repeat!) != dismissedRepeatKey)
          _parseChip(
            context,
            icon: OrbitIcons.repeat,
            label: rep.repeatLabelExt(
              parse.repeat!.mode,
              parse.repeat!.after,
              weekdays: parse.repeat!.weekdays,
            ),
            color: colors.secondaryText,
            onDismiss: () => onDismiss(_ParseDim.repeat),
          ),
      ],
    );
  }

  Widget _parseChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onDismiss,
  }) {
    final colors = AppColors.ofContext(context);
    return Container(
      // 4pt 网格口径（3→4）
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space8,
        vertical: AppDimens.space4,
      ),
      decoration: BoxDecoration(
        borderRadius: AppShapes.full,
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: AppDimens.space4),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
          if (onDismiss != null) ...[
            const SizedBox(width: AppDimens.space2),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: Icon(
                OrbitIcons.close,
                size: 12,
                color: color.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
