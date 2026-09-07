import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/lunar/chinese_almanac.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/app_month_calendar.dart';
import '../../shared/widgets/glass_fab.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/wait_toast.dart';
import 'form_bottom_sheet.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';
import 'year_overview_page.dart';

/// 日历视图 /todo/calendar（wait-home 重要日期风格重构）
///
/// 上下堆叠分栏（对齐桌面端左右分栏的信息架构，移动端纵向排布）：
/// - 上：Days Matter 风格月历（农历/节气/节日副标签、休/班圆徽标、
///   任务优先级色圆点 ≤4、今天强调块、选中描边；长按某天 = 快捷新增
///   并预填该日为截止日期——对应桌面右键）
/// - 下：当月带截止任务按日分组列表，点击日历某天滚动定位到对应分组
/// - 点击月份标题打开年视图（12 迷你月历 + 干支生肖 + 春节/初一下划线，
///   PageView 滑动切年），点任意日期回月历定位该日
///
/// 数据口径：与子列表同源 todoTasksProvider 全量任务，客户端按 due_date
/// 本地日聚合；节假日数据 cfg_holidays 缓存（空库回落 Rust 预置 2026 表）。
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// 当前展示的月份（year + month）
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// 当前选中日期（默认今天；点击日格切换，右栏滚动定位）
  DateTime _selectedDate = DateTime.now();

  /// 分组锚点注册表：ymd → 分组节点（点击日历滚动定位）
  final Map<String, GlobalKey> _groupKeys = {};

  // ── 数据 ──

  Map<String, HolidayInfo> _holidayByDate() {
    final holidays = ref.watch(holidayProvider).value ?? const <HolidayInfo>[];
    return {for (final h in holidays) h.date: h};
  }

  // ── 节假日手动更新 ──

  bool _updating = false;

  Future<void> _updateHolidays() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      await ref.read(orbitBridgeProvider).holidayUpdate();
      ref.invalidate(holidayProvider);
      ref.invalidate(holidayMetaProvider);
      WaitToast.success('节假日数据已更新');
    } catch (e) {
      WaitToast.destructive('节假日更新失败：$e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  // ── 月导航 / 选中 / 快捷新增 ──

  void _prevMonth() =>
      setState(() => _month = _month.month == 1 ? DateTime(_month.year - 1, 12) : DateTime(_month.year, _month.month - 1));

  void _nextMonth() =>
      setState(() => _month = _month.month == 12 ? DateTime(_month.year + 1, 1) : DateTime(_month.year, _month.month + 1));

  void _goToday() => setState(() {
        final now = DateTime.now();
        _month = DateTime(now.year, now.month);
        _selectedDate = DateTime(now.year, now.month, now.day);
      });

  void _selectDate(DateTime date) {
    setState(() => _selectedDate = date);
    // 滚动定位到当月列表中对应分组（存在时）
    final key = _groupKeys[_ymd(date)];
    final node = key?.currentContext;
    if (node != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(node,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic);
        }
      });
    }
  }

  /// 长按日历某天：以该天为截止日期快捷新增（对应桌面右键）
  void _addOnDate(DateTime date) {
    showTodoFormSheet(
      context,
      initialDueDate:
          DateTime(date.year, date.month, date.day).millisecondsSinceEpoch,
    );
  }

  /// 打开任务详情（稳定方法引用：分组 build 不再逐组创建闭包）
  void _openTask(int id) => context.push('/todo/$id');

  /// 月份标题点击：打开年视图，返回后定位到所选日期
  Future<void> _openYearOverview() async {
    final picked = await YearOverviewPage.push(
      context,
      initialYear: _month.year,
      initialMonth: _month.month,
    );
    if (picked != null && mounted) {
      setState(() {
        _month = DateTime(picked.year, picked.month);
        _selectedDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    // 派生聚合（calendarByDayProvider）：选中日等局部 setState 不再触发
    // 全量重聚合，仅任务数据变化时重算一次
    final byDay = ref.watch(calendarByDayProvider).value ??
        const <String, List<TodoTask>>{};
    final holidayByDate = _holidayByDate();
    final now = DateTime.now();
    final todayYmd = _ymd(now);
    final selectedYmd = _ymd(_selectedDate);

    // 当月有任务的日期升序分组（下方列表数据源）
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final monthGroups = <({DateTime date, List<TodoTask> items})>[];
    // 当月圆点颜色表（ymd → 优先级色列表）：一次构建，月历 42 格
    // eventDotsBuilder 直接查表——避免每格每帧重复 _ymd 拼接 + 列表遍历
    final monthDots = <String, List<Color>>{};
    for (var d = 1; d <= daysInMonth; d++) {
      final date = DateTime(_month.year, _month.month, d);
      final key = _ymd(date);
      final items = byDay[key] ?? const <TodoTask>[];
      if (items.isNotEmpty) {
        monthGroups.add((date: date, items: items));
        monthDots[key] = [for (final t in items) _priorityColor(t)];
      }
    }
    final monthTotal =
        monthGroups.fold<int>(0, (sum, g) => sum + g.items.length);

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            // 整页滚动（wait-home 同款）：月历 + 当月列表一起滚，
            // 小屏/横屏下列表不会被固定月历挤出视口
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: LiquidGlassTitleBar.rowHeight),
                  // ===== 头部：月份标题（点击开年视图）+ 今天 + 翻页 + 节假日更新 =====
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.space8, vertical: 2),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left_rounded,
                              size: AppDimens.iconSizeLg),
                          onPressed: _prevMonth,
                          tooltip: '上个月',
                          visualDensity: VisualDensity.compact,
                        ),
                        Expanded(
                          child: GestureDetector(
                            // 标题点击 = 年视图
                            onTap: _openYearOverview,
                            child: Text(
                              '${_month.year}年${_month.month}月',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: colors.titleText,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right_rounded,
                              size: AppDimens.iconSizeLg),
                          onPressed: _nextMonth,
                          tooltip: '下个月',
                          visualDensity: VisualDensity.compact,
                        ),
                        const SizedBox(width: AppDimens.space4),
                        IconButton(
                          icon: const Icon(Icons.today_rounded,
                              size: AppDimens.iconSizeMd),
                          onPressed: _goToday,
                          tooltip: '回到今天',
                          visualDensity: VisualDensity.compact,
                        ),
                        _buildUpdateButton(),
                      ],
                    ),
                  ),
                  // ===== 月历（wait-home 完整版：农历副标签/休班徽标/任务圆点）=====
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.space8),
                    child: AppMonthCalendar(
                      size: AppCalendarSize.large,
                      showHeader: false,
                      month: _month,
                      selected: _selectedDate,
                      onDayTap: _selectDate,
                      onDayLongPress: _addOnDate,
                      accentColor: scheme.primary,
                      weekendColor: ChineseCalendarColors.weekend,
                      holidays: {
                        for (final e in holidayByDate.entries)
                          e.key: e.value.isHoliday,
                      },
                      subLabelBuilder: ChineseAlmanac.daySubLabel,
                      eventDotsBuilder: (date) => monthDots[_ymd(date)] ??
                          const <Color>[],
                    ),
                  ),
                  const SizedBox(height: AppDimens.space4),
                  // ===== 当月任务列表标题行 =====
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.space16),
                    child: Row(
                      children: [
                        Text(
                          '${_month.year}年${_month.month}月的任务',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: colors.titleText,
                          ),
                        ),
                        const SizedBox(width: AppDimens.space6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color:
                                colors.secondaryText.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$monthTotal 条',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.secondaryText,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '长按日历快捷新增',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ===== 当月任务按日分组列表（与月历同页滚动） =====
                  if (monthTotal == 0)
                    Padding(
                      padding: const EdgeInsets.all(AppDimens.space16),
                      child: Row(
                        children: [
                          Icon(Icons.event_busy_rounded,
                              size: 16,
                              color: colors.secondaryText
                                  .withValues(alpha: 0.6)),
                          const SizedBox(width: AppDimens.space8),
                          Expanded(
                            child: Text(
                              '本月没有带截止日期的任务，切换月份或长按日历新增',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    for (final group in monthGroups)
                      _MonthDayGroup(
                        key: _groupKeyFor(_ymd(group.date)),
                        date: group.date,
                        isSelectedDay: _ymd(group.date) == selectedYmd,
                        isToday: _ymd(group.date) == todayYmd,
                        tasks: group.items,
                        onOpenTask: _openTask,
                      ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: '日历',
              showBack: true,
            ),
          ),
          // FAB：新建任务（通用表单自选日期；日格长按可预填日期）
          Positioned(
            right: AppDimens.space16,
            bottom: AppDimens.gestureInsetFallback + AppDimens.space16,
            child: GlassFab(
              accentColor: OrbitAccents.themeAccent,
              onPressed: () => showTodoFormSheet(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组锚点 key（懒创建，跨月复用）
  GlobalKey _groupKeyFor(String ymd) =>
      _groupKeys.putIfAbsent(ymd, () => GlobalKey());

  Widget _buildUpdateButton() {
    final meta = ref.watch(holidayMetaProvider).value;
    final lastUpdate = meta?.lastUpdateMs ?? 0;
    final tip = lastUpdate > 0
        ? '上次更新：${DateFormat('M月d日 HH:mm').format(DateTime.fromMillisecondsSinceEpoch(lastUpdate))}（每天自动更新一次）'
        : '每天自动更新一次，也可手动更新';
    return IconButton(
      icon: _updating
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded, size: AppDimens.iconSizeMd),
      tooltip: tip,
      onPressed: _updating ? null : _updateHolidays,
    );
  }

  /// 任务优先级色（圆点用；空优先级用半透明灰）
  Color _priorityColor(TodoTask t) {
    final hex = priorityColorHex(t.priority);
    if (hex.isEmpty) return Colors.grey.withValues(alpha: 0.4);
    return hexToColor(hex);
  }
}

/// 下方列表的按日分组块（对齐桌面右栏 DayGroupBlock）：
/// 日期头（今天强调 + 「今天」徽标，选中日高亮底）+ 任务行
/// （浅色圆角卡：优先级色点 + 标题 + HH:mm 逾期红）
class _MonthDayGroup extends StatelessWidget {
  const _MonthDayGroup({
    super.key,
    required this.date,
    required this.isSelectedDay,
    required this.isToday,
    required this.tasks,
    required this.onOpenTask,
  });

  final DateTime date;
  final bool isSelectedDay;
  final bool isToday;
  final List<TodoTask> tasks;
  final ValueChanged<int> onOpenTask;

  static const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

  /// 选中日距今天的口语化天数
  String get _relativeLabel {
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final diff = DateTime(date.year, date.month, date.day)
        .difference(todayStart)
        .inDays;
    if (diff == 0) return '今天';
    return diff > 0 ? '$diff天后' : '${-diff}天前';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    // 今天零点 ms（逾期红判定口径：截止在今天内不算逾期）
    final todayMs = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 日期头
        Padding(
          padding: const EdgeInsets.fromLTRB(AppDimens.space16,
              AppDimens.space8, AppDimens.space16, AppDimens.space4),
          child: Container(
            decoration: BoxDecoration(
              color: isSelectedDay
                  ? scheme.primary.withValues(alpha: 0.10)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space12, vertical: AppDimens.space4),
            child: Row(
              children: [
                Text(
                  '${date.month}月${date.day}日',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isToday ? scheme.primary : colors.titleText,
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
                Text(
                  '星期${_weekdayNames[date.weekday - 1]}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.secondaryText,
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
                Text(
                  _relativeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.secondaryText,
                  ),
                ),
                if (isToday) ...[
                  const SizedBox(width: AppDimens.space8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.primary),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '今天',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 任务行
        for (final t in tasks)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppDimens.space16, 0, AppDimens.space16, AppDimens.space6),
            child: _TaskCard(
              task: t,
              todayMs: todayMs,
              onTap: () => onOpenTask(t.id),
            ),
          ),
      ],
    );
  }
}

/// 单条任务行（浅色圆角卡：优先级色点 + 标题 + HH:mm 逾期红；对齐桌面右栏行）
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.todayMs,
    required this.onTap,
  });

  final TodoTask task;
  final int todayMs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hex = priorityColorHex(task.priority);
    final overdue = !task.isDone && task.dueDate != null && task.dueDate! < todayMs;
    final hasTime =
        task.dueDate != null && (task.dueDate! % 86400000) != 0; // 零点=纯日期

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.secondaryText.withValues(alpha: 0.05),
          borderRadius: AppShapes.of(10),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: hex.isEmpty
                    ? colors.secondaryText.withValues(alpha: 0.4)
                    : hexToColor(hex),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            Expanded(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  decoration: task.isDone ? TextDecoration.lineThrough : null,
                  color: task.isDone ? colors.secondaryText : colors.titleText,
                ),
              ),
            ),
            if (hasTime)
              Padding(
                padding: const EdgeInsets.only(left: AppDimens.space8),
                child: Text(
                  DateFormat('HH:mm').format(
                      DateTime.fromMillisecondsSinceEpoch(task.dueDate!)),
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: overdue
                        ? OrbitAccents.overdueRed
                        : colors.secondaryText,
                  ),
                ),
              ),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: colors.secondaryText),
          ],
        ),
      ),
    );
  }
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
