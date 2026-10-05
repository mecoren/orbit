import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart' show CalendarFormat;

import '../../core/lunar/chinese_almanac.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_month_calendar.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_timeline_day.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../services/local_prefs.dart';
import 'logic/task_logic.dart';
import 'logic/time_block.dart';
import 'providers/todo_providers.dart';
import 'quick_add_sheet.dart' show showQuickAddSheet;
import 'year_overview_page.dart';
import '../../core/theme/icon_map.dart';

/// 页内视图档（见 [_CalendarScreenState._viewMode]）
enum CalendarViewMode { month, agenda, timeline }

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
/// **视图档**（工具栏月/列表图标切换，对齐桌面 `CalendarSubMode`）：
/// 月档 = 上网格 + 下列表；**议程档** = 隐藏网格、整页本月按日分组列表，
/// 进入时一次性定位到今天、日期头带休/班徽标（桌面 agenda 档语义）；
/// 年档为标题点击进入的独立页（[YearOverviewPage]）。
///
/// **页头收敛**（竞品一屏操作）：「日历」文字标题已移除——月份导航
/// （`< 年月 >`，点标题进年视图）与回到今天 / 议程切换 / 节假日更新
/// 三个动作直接落在页头标题槽与动作槽；窄屏下标题等比缩字不断行
/// （FittedBox，页头行高恒定），图标保持 48 热区不压缩。
///
/// **选中日列表双样式**（月档，竞品同款切换）：卡片（默认：勾选 + 标题 +
/// 右列时刻/元信息）⇄ 时间线（时刻左置列 + 右侧卡片行）；切换钮在日期
/// 语义头右侧，档位落本机偏好 `todo_calendar_day_compact`（缺省卡片，
/// 零 DDL、不进同步），议程档分组列表不受影响。
///
/// 数据口径：与子列表同源 todoTasksProvider 全量任务，客户端按 due_date
/// 本地日聚合；节假日数据 cfg_holidays 缓存（空库回落 Rust 预置 2026 表）。
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// 当前展示的月份（year + month）：标题 / 议程分组 / 补位弱化口径
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// table_calendar 焦点日（onPageChanged 原样回传，**不归一化**）：月档下
  /// 只需与 [_month] 同月页；周档下逐字回传决定显示哪一周——归一化到 1 号
  /// 会把周条拽回月初那一周（table_calendar 周页粒度是「周」）
  DateTime _focusedDate = DateTime.now();

  /// 当前选中日期（默认今天；点击日格切换，右栏滚动定位）
  DateTime _selectedDate = DateTime.now();

  /// 月历档位：月（整月网格）⇄ 周（单行周条）。网格上滑收起、下滑展开
  /// （table_calendar 档位序 month → week，上滑 = 下一档），竞品同款
  CalendarFormat _calFormat = CalendarFormat.month;

  /// 页内视图档（年档不在此列——标题点击进独立页 [YearOverviewPage]）：
  /// - [CalendarViewMode.month]：月历网格 + 选中日任务列表（默认）；
  /// - [CalendarViewMode.agenda]：隐藏网格，整页当月按日分组列表，
  ///   进入时定位今天（对齐桌面 `CalendarSubMode.agenda`）；
  /// - [CalendarViewMode.timeline]：24 小时时段轴（#74，对标 TickTick 移动端
  ///   Timeline），跨度 [_timelineSpan] 天，从选中日当天起算。
  ///
  /// 档位切换入口是页头动作槽的**档位抽屉**（月历/议程/时间三选一）——
  /// 「从一组值里挑一个」按交互约定走底部抽屉，不用 PopupMenu。
  CalendarViewMode _viewMode = CalendarViewMode.month;

  /// 时间轴跨度（天）：1 = 聚焦当天，3 = 短周期（桌面跨度档的移动同构）
  int _timelineSpan = 1;

  /// 视图档切换（抽屉回调）：切到议程档时一次性定位今天（当月今天有分组时）
  void _setViewMode(CalendarViewMode mode) {
    setState(() => _viewMode = mode);
    if (mode != CalendarViewMode.agenda) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _groupKeys[_ymd(DateTime.now())]?.currentContext;
      if (node != null) {
        Scrollable.ensureVisible(node,
            duration: AppMotion.scrollSettle,
            curve: AppMotion.scrollSettleCurve);
      }
    });
  }

  /// 页头档位抽屉（月历 / 议程 / 时间）
  Future<void> _pickViewMode() => showSelectBottomSheet<CalendarViewMode>(
        context,
        title: '视图',
        current: _viewMode,
        items: const [
          SelectItem(value: CalendarViewMode.month, label: '月历'),
          SelectItem(value: CalendarViewMode.agenda, label: '议程'),
          SelectItem(value: CalendarViewMode.timeline, label: '时间'),
        ],
        onSelect: _setViewMode,
      );

  /// 时间轴跨度切换（1 天 / 3 天）
  void _setTimelineSpan(int span) => setState(() => _timelineSpan = span);

  bool get _agendaMode => _viewMode == CalendarViewMode.agenda;

  bool get _timelineMode => _viewMode == CalendarViewMode.timeline;

  /// 选中日列表样式：false = 卡片（默认），true = 时间线（时刻左置）。
  /// 本机偏好持久化（LocalPrefs，不进 DB 不进同步；读失败回落卡片）
  static const _dayCompactKey = 'todo_calendar_day_compact';
  bool _dayCompact = LocalPrefs.getBool(_dayCompactKey, fallback: false);

  /// 卡片 ⇄ 时间线切换（写即落盘，失败静默——偏好不是业务数据）
  void _toggleDayStyle() {
    final next = !_dayCompact;
    setState(() => _dayCompact = next);
    unawaited(LocalPrefs.setBool(_dayCompactKey, next));
  }

  /// 分组锚点注册表：ymd → 分组节点（点击日历滚动定位）
  final Map<String, GlobalKey> _groupKeys = {};

  /// 横向滑动累计位移（dragEnd 时与速度二选一判据，慢速长拖也能翻页）
  double _swipeDx = 0;

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

  /// 月档位下跳整月：焦点日必须同步落到目标月 1 号（focusedDay prop 驱动
  /// table_calendar 翻页），否则网格停在原月而标题已换
  void _setMonth(DateTime monthStart) => setState(() {
        _month = monthStart;
        _focusedDate = monthStart;
      });

  void _prevMonth() => _setMonth(_month.month == 1
      ? DateTime(_month.year - 1, 12)
      : DateTime(_month.year, _month.month - 1));

  void _nextMonth() => _setMonth(_month.month == 12
      ? DateTime(_month.year + 1, 1)
      : DateTime(_month.year, _month.month + 1));

  /// 页头相对天数小字：优先锚定**选中日**距今天（点日格即变：今天 →
  /// 「今天」、9/20 → 「N天前」）；选中日不在所看月份（翻月浏览未重新
  /// 选中）时回落为该月 1 号距今天（竞品月份口径「10月 5天后」）
  String _monthRelativeLabel() {
    final now = DateTime.now();
    final selected = _selectedDate;
    final inViewMonth =
        selected.year == _month.year && selected.month == _month.month;
    final anchor = inViewMonth
        ? DateTime(selected.year, selected.month, selected.day)
        : DateTime(_month.year, _month.month, 1);
    final diff = anchor.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (diff == 0) return '今天';
    return diff < 0 ? '${-diff}天前' : '$diff天后';
  }

  void _goToday() => setState(() {
        final now = DateTime.now();
        _month = DateTime(now.year, now.month);
        _selectedDate = DateTime(now.year, now.month, now.day);
        // 周档收起时同样跳回今天所在周
        _focusedDate = _selectedDate;
      });

  /// 月历收展（网格上滑收成单行周条 / 下滑展开整月）：收起对齐**选中日**
  /// 所在周（周条即「选中日 + 前后各几日」），展开回到当前周所在的整月页
  void _onCalFormatChange(CalendarFormat format) {
    setState(() {
      _calFormat = format;
      _focusedDate = format == CalendarFormat.week
          ? _selectedDate
          : DateTime(_focusedDate.year, _focusedDate.month, 1);
      _month = DateTime(_focusedDate.year, _focusedDate.month, 1);
    });
  }

  // ── 左右滑动翻月 ──

  void _onSwipeStart(DragStartDetails _) => _swipeDx = 0;

  void _onSwipeUpdate(DragUpdateDetails details) => _swipeDx += details.delta.dx;

  /// 左右滑动翻月（左滑 = 下月、右滑 = 上月）：与年视图 PageView 滑动切年
  /// 对称。速度或位移任一越阈即翻页——只判速度会漏掉慢速长拖
  void _onSwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final distance = MediaQuery.sizeOf(context).width * 0.15;
    final toNext = velocity < -_kSwipeVelocity || _swipeDx < -distance;
    final toPrev = velocity > _kSwipeVelocity || _swipeDx > distance;
    if (!toNext && !toPrev) return;
    HapticFeedback.selectionClick();
    (toNext ? _nextMonth : _prevMonth)();
  }

  void _selectDate(DateTime date) {
    setState(() => _selectedDate = date);
    // 滚动定位到当月列表中对应分组（存在时）
    final key = _groupKeys[_ymd(date)];
    final node = key?.currentContext;
    if (node != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(node,
              duration: AppMotion.scrollSettle,
              curve: AppMotion.scrollSettleCurve);
        }
      });
    }
  }

  /// 长按日历某天：以该天为截止日期快捷新增（与列表页同一快速添加面板，
  /// 截止预填该天；对应桌面右键）
  void _addOnDate(DateTime date) {
    showQuickAddSheet(
      context,
      initialDueDate:
          DateTime(date.year, date.month, date.day).millisecondsSinceEpoch,
    );
  }

  /// 打开任务详情（稳定方法引用：分组 build 不再逐组创建闭包）
  void _openTask(int id) => context.push('/todo/$id');

  /// 选中日任务卡勾选完成/取消（与列表档同口径：完成走 todoTaskComplete
  /// 单事务推进重复任务，取消走普通 patch）
  Future<void> _toggleDone(TodoTask task) async {
    try {
      if (task.isDone) {
        await ref.read(orbitBridgeProvider).todoTaskUpdate(
              task.id,
              encodePatch(buildDoneTogglePatch(task)),
            );
      } else {
        await ref.read(orbitBridgeProvider).todoTaskComplete(task.id);
      }
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
    } catch (_) {
      WaitToast.destructive('更新失败');
    }
  }

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
        _focusedDate = _selectedDate;
      });
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 派生聚合（calendarByDayProvider）：选中日等局部 setState 不再触发
    // 全量重聚合，仅任务数据变化时重算一次
    final byDay = ref.watch(calendarByDayProvider).value ??
        const <String, List<TodoTask>>{};
    final holidayByDate = _holidayByDate();
    // 提醒投影（A4 只读聚合）：选中日任务卡的行内提醒图标数据源，
    // 未就绪回落空表（不渲染图标，不阻塞列表）
    final reminderRows = ref.watch(taskRemindersProjectionProvider).value ??
        const <TaskRemindersProjection>[];
    final remindersByTask = {
      for (final r in reminderRows) r.taskId: r.reminders,
    };
    // 「有描述」任务 id 集（列表通道裁剪 description，图标位走行元信息投影）
    final descriptionIds = ref.watch(taskDescriptionFlagsProvider).value ??
        const <int>{};
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
            child: GestureDetector(
              // 左右滑动翻月（左滑 = 下月、右滑 = 上月），与年视图 PageView
              // 滑动切年对称；水平手势与整页纵向滚动不同向，互不抢占
              onHorizontalDragStart: _onSwipeStart,
              onHorizontalDragUpdate: _onSwipeUpdate,
              onHorizontalDragEnd: _onSwipeEnd,
              // 整页滚动（wait-home 同款）：月历 + 当月列表一起滚，
              // 小屏/横屏下列表不会被固定月历挤出视口
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: OrbitPageHeader.rowHeight),
                    // 页头下竖直留白（与 stats_screen 首内容上沿 space8 同口径）
                    const SizedBox(height: AppDimens.space8),
                    // ===== 月历（wait-home 完整版：农历副标签/休班徽标/任务圆点）=====
                    // 议程档隐藏网格：整页让给按日分组列表（桌面 agenda 档同语义）
                    // 去卡片化：月历不再包卡片，直接铺页面底色（间隔口径见下）
                    if (!_agendaMode && !_timelineMode) ...[
                      // 去卡片化（竞品同款）：月历直接铺页面底色，白卡描边/
                      // 圆角/内衬一并移除；左右 space12 与页头上方 space8
                      // 留白保留（周条收起态同口径）
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.space12),
                        child: OrbitMonthCalendar(
                          size: AppCalendarSize.large,
                          showHeader: false,
                          month: _month,
                          focusedDay: _focusedDate,
                          calendarFormat: _calFormat,
                          // 月 ⇄ 周两档：网格上滑收成单行周条、下滑展开
                          // （顺序必须大到小，上滑 = 档位序下一档 = 周）
                          availableCalendarFormats: const {
                            CalendarFormat.month: '月',
                            CalendarFormat.week: '周',
                          },
                          onFormatChange: _onCalFormatChange,
                          // 周条跨月周不弱化补位日期
                          dimOutsideMonth: _calFormat != CalendarFormat.week,
                          selected: _selectedDate,
                          onDayTap: _selectDate,
                          onDayLongPress: _addOnDate,
                          // 横滑翻月/翻周：月历网格自带 PageView（纵向收展走
                          // 月历的轴锁定门），必须把页码回调**原样**接回（周档
                          // 收到的是 ±7 天的逐字日期，归一化到 1 号会把周条拽回
                          // 月初周），否则网格翻页了而标题还停在旧月份
                          onMonthChange: (focused) => setState(() {
                            _focusedDate = focused;
                            _month = DateTime(focused.year, focused.month, 1);
                          }),
                          // 选中/今天强调色与桌面端日历同源（桌面月历 --primary 即
                          // themeAccent 体系）：不走 scheme.primary——M3 fromSeed
                          // 会把 #4E8CFF 派生成 #455E91 灰蓝，与桌面明显偏差
                          accentColor: OrbitAccents.themeAccent,
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
                    ],
                    // ===== 下方任务列表 =====
                    // 月档 = 选中日任务卡（竞品口径：点日格看当天任务）；
                    // 议程档 = 整月按日分组列表（桌面 agenda 档同语义，
                    // 月标题 + 分组块原样保留）
                    if (_agendaMode) ...[
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
                                color: colors.secondaryText
                                    .withValues(alpha: 0.12),
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
                              // 议程档无网格可长按，改为提示横滑翻月
                              '左右滑动切换月份',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (monthTotal == 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              AppDimens.space12,
                              AppDimens.space8,
                              AppDimens.space12,
                              0),
                          child: OrbitCardSegment(
                            edge: OrbitCardEdge.single,
                            child: Padding(
                              padding:
                                  const EdgeInsets.all(AppDimens.space16),
                              child: Row(
                                children: [
                                  Icon(OrbitIcons.calendarBlocked,
                                      size: 16,
                                      color: colors.secondaryText
                                          .withValues(alpha: 0.6)),
                                  const SizedBox(width: AppDimens.space8),
                                  Expanded(
                                    child: Text(
                                      '本月没有带截止日期的任务，切换月份或点底部「+」新增',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.secondaryText,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else ...[
                        const SizedBox(height: AppDimens.space8),
                        for (final group in monthGroups)
                          _MonthDayGroup(
                            key: _groupKeyFor(_ymd(group.date)),
                            date: group.date,
                            isSelectedDay: _ymd(group.date) == selectedYmd,
                            isToday: _ymd(group.date) == todayYmd,
                            // 议程档日期头带休/班徽标（桌面 VirtualGroupedList
                            // 的 showHolidayMark 同口径；月档右栏不带）
                            holidayMark: holidayByDate[_ymd(group.date)]
                                ?.isHoliday,
                            tasks: group.items,
                            onOpenTask: _openTask,
                          ),
                      ],
                    ] else if (_timelineMode)
                      _buildTimelineSection(
                        colors,
                        // 时段块按**起点日**分桶（timelineBlocksByDayProvider）：
                        // 显式排程块的视图日在 start 日，按 due 分桶会丢块
                        ref.watch(timelineBlocksByDayProvider).value ??
                            const <String, List<TodoTask>>{},
                      )
                    else
                      _SelectedDayList(
                        date: _selectedDate,
                        tasks: byDay[selectedYmd] ?? const <TodoTask>[],
                        isToday: selectedYmd == todayYmd,
                        holidayMark: holidayByDate[selectedYmd]?.isHoliday,
                        descriptionIds: descriptionIds,
                        remindersByTask: remindersByTask,
                        nowMs: now.millisecondsSinceEpoch,
                        compact: _dayCompact,
                        onToggleStyle: _toggleDayStyle,
                        onOpenTask: _openTask,
                        onToggleDone: _toggleDone,
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              // 页签根：无返回键（底部导航承担回退语义）；「日历」文字标题已收敛——
              // 月份导航（< 年月 >，点标题进年视图）走标题槽，回到今天 /
              // 议程切换 / 节假日更新走动作槽（竞品同款一屏操作）
              showBack: false,
              titleWidget: Row(
                children: [
                  IconButton(
                    icon: const Icon(OrbitIcons.chevronLeft,
                        size: AppDimens.iconSizeLg),
                    onPressed: _prevMonth,
                    tooltip: '上个月',
                  ),
                  Expanded(
                    child: GestureDetector(
                      // 标题点击 = 年视图
                      onTap: _openYearOverview,
                      // 竞品口径：月份大字 + 相对天数小字；小字锚定选中日
                      // （点日格即变），翻月未选中回落当月 1 号（见
                      // _monthRelativeLabel）。年份仅在跨年时以小字前缀补出
                      // （与月历表头同约定）。
                      // FittedBox 保单行：窄屏下标题可用宽变小，等比缩字不折行
                      // （页头行高恒 56，不断行是底线）
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            if (_month.year != now.year) ...[
                              Text(
                                '${_month.year}年',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: colors.secondaryText,
                                ),
                              ),
                              const SizedBox(width: 3),
                            ],
                            Text(
                              '${_month.month}月',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: colors.titleText,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              _monthRelativeLabel(),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: colors.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(OrbitIcons.chevronRight,
                        size: AppDimens.iconSizeLg),
                    onPressed: _nextMonth,
                    tooltip: '下个月',
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(OrbitIcons.calendarCheck,
                      size: AppDimens.iconSizeMd),
                  onPressed: _goToday,
                  tooltip: '回到今天',
                ),
                // 视图档抽屉（月历 / 议程 / 时间；年档由标题点击进入，
                // 见 _openYearOverview）——「从一组值里挑一个」走底部抽屉
                IconButton(
                  icon: Icon(_viewModeIcon, size: AppDimens.iconSizeMd),
                  onPressed: _pickViewMode,
                  tooltip: '切换视图（当前：$_viewModeLabel）',
                ),
                _buildUpdateButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 时间轴档区块（#74）：跨度天数的 24h 网格，竖向逐日铺开。
  ///
  /// 数据源是当月按日分桶（[calendarByDayProvider]）——**只看带时刻的时段**
  /// （`taskTimeBlock` 口径），纯日期任务不出块（它们属于月/议程的日格）。
  /// 跨度 3 天时每列各自独立竖向网格（窄屏横排三列会把块压到不可读）。
  Widget _buildTimelineSection(
    AppColorSet colors,
    Map<String, List<TodoTask>> byDay,
  ) {
    // 项目色表：任务 id → 项目 hex（无项目回落 todoAccent）
    final projectById = {
      for (final p
          in ref.watch(todoProjectsProvider).value ?? const <TodoProject>[])
        p.id: p,
    };
    final days = _timelineDays;
    // 跨度内任务 id → 任务（块渲染取项目色 + 拖拽落库取 DTO，同一份映射）
    final taskById = <int, TodoTask>{
      for (final date in days)
        for (final t in byDay[_ymd(date)] ?? const <TodoTask>[]) t.id: t,
    };
    final anyBlock = days.any((d) => _blocksOf(d, byDay).isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 档内工具条：跨度切换（1 天 / 3 天）+ 块数回显
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
          child: Row(
            children: [
              Text(
                '时间轴',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(width: AppDimens.space6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.secondaryText.withValues(alpha: 0.12),
                  borderRadius: AppShapes.of(999),
                ),
                child: Text(
                  anyBlock ? '${_totalBlocks(byDay)} 个时段' : '暂无时段',
                  style: TextStyle(fontSize: 11, color: colors.secondaryText),
                ),
              ),
              const Spacer(),
              for (final span in const [1, 3])
                Padding(
                  padding: const EdgeInsets.only(left: AppDimens.space6),
                  child: _SpanChip(
                    label: span == 1 ? '日' : '三日',
                    selected: _timelineSpan == span,
                    onTap: () => _setTimelineSpan(span),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.space8),
        if (!anyBlock)
          OrbitTimelineEmpty(dayLabel: _timelineEmptyLabel())
        else
          for (final date in days)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.space16,
                AppDimens.space8,
                AppDimens.space16,
                0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TimelineDayHeader(date: date),
                  const SizedBox(height: AppDimens.space4),
                  OrbitTimelineDay(
                    dayStart: DateTime(date.year, date.month, date.day),
                    entries: _blocksOf(date, byDay),
                    projectColorOf: (taskId) {
                      final pid = taskById[taskId]?.projectId;
                      final hex =
                          pid == null ? null : projectById[pid]?.hexColor;
                      return (hex == null || hex.isEmpty)
                          ? OrbitAccents.todoAccent
                          : hexToColor(hex);
                    },
                    onOpenTask: _openTask,
                    onMoveTimeslot: (id, ms) => _moveTimeslot(id, ms, taskById),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  /// 时间轴覆盖的日期（从选中日起 span 天）
  List<DateTime> get _timelineDays => [
        for (var i = 0; i < _timelineSpan; i++)
          DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day + i),
      ];

  /// 某日的时段块（已分车道；口径见 logic/time_block.dart）
  List<({TimeBlock block, BlockLayout layout, int lane, int laneCount})>
      _blocksOf(DateTime date, Map<String, List<TodoTask>> byDay) {
    final blocks = [
      for (final t in byDay[_ymd(date)] ?? const <TodoTask>[])
        ?taskTimeBlock(t),
    ];
    return blocksForDay(blocks, localDayStartMs(date));
  }

  /// 跨度内的时段总数（档内计数徽标）
  int _totalBlocks(Map<String, List<TodoTask>> byDay) => _timelineDays
      .fold<int>(0, (sum, d) => sum + _blocksOf(d, byDay).length);

  /// 长按拖拽时段落位（#75）：长按 500ms 拾起后纵向拖改起点，15 分钟吸附。
  ///
  /// **落库字段按块来源分**（`timeslotDropPatch` 唯一出口）：显式排程块改
  /// `start_date`；由带时刻 `due_date` 倒推的块**只改 `due_date`**（= 新起点
  /// + 时长），绝不种 `start_date`——种 start 会让任务从「截止向截止收拢」
  /// 漂移成「显式排程」，语义变了且与详情页显示打架。纯日期任务不渲染块，
  /// 拖不到这里。
  Future<void> _moveTimeslot(
    int taskId,
    int nextStartMs,
    Map<int, TodoTask> taskById,
  ) async {
    final task = taskById[taskId];
    if (task == null) return;
    final patch = timeslotDropPatch(task, nextStartMs);
    if (patch == null) return; // 无变化（同刻落回）不写库
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoTaskUpdate(taskId, encodePatch(patch));
      ref.invalidate(todoTasksProvider);
      WaitToast.warning(
        '时段已调整',
        description: patch.containsKey('due_date')
            ? '原为截止倒推块，已改截止时刻'
            : '开始时刻已更新',
      );
    } catch (e) {
      WaitToast.destructive('调整失败：$e');
    }
  }

  /// 空态主文案（「当天」/「三天」）
  String _timelineEmptyLabel() => _timelineSpan == 1 ? '当天' : '这三天';

  /// 分组锚点 key（懒创建，跨月复用）
  GlobalKey _groupKeyFor(String ymd) =>
      _groupKeys.putIfAbsent(ymd, () => GlobalKey());

  /// 当前档位的页头动作图标（进入抽屉前的回显）
  IconData get _viewModeIcon => switch (_viewMode) {
        CalendarViewMode.month => OrbitIcons.calendar,
        CalendarViewMode.agenda => OrbitIcons.list,
        CalendarViewMode.timeline => OrbitIcons.clock,
      };

  /// 当前档位中文名（tooltip 回显，与抽屉选项文案同源）
  String get _viewModeLabel => switch (_viewMode) {
        CalendarViewMode.month => '月历',
        CalendarViewMode.agenda => '议程',
        CalendarViewMode.timeline => '时间',
      };

  Widget _buildUpdateButton() {
    final meta = ref.watch(holidayMetaProvider).value;
    final lastUpdate = meta?.lastUpdateMs ?? 0;
    // 与设置页「日历与节假日」同一份记账（core 缺省开启自动更新）
    final auto = meta?.autoEnabled ?? true;
    final lastText = lastUpdate > 0
        ? '上次更新：${DateFormat('M月d日 HH:mm').format(DateTime.fromMillisecondsSinceEpoch(lastUpdate))}'
        : '尚未更新过';
    final tip = auto ? '$lastText（每月自动更新）' : '$lastText（自动更新已关闭）';
    return IconButton(
      icon: _updating
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(OrbitIcons.refresh, size: AppDimens.iconSizeMd),
      tooltip: tip,
      onPressed: _updating ? null : _updateHolidays,
    );
  }

  /// 任务优先级色（圆点用；P0「无」浅灰 #D1D5DB，六档全显）
  Color _priorityColor(TodoTask t) => hexToColor(priorityColorHex(t.priority));
}

/// 跨度切换 chip（时间轴档内工具条；样式取 repeat_edit_sheet 的档位 chip）
class _SpanChip extends StatelessWidget {
  const _SpanChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final accent = OrbitAccents.themeAccent;
    return Material(
      color: selected ? accent.withValues(alpha: 0.10) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.small,
        side: BorderSide(color: selected ? accent : colors.divider),
      ),
      child: InkWell(
        borderRadius: AppShapes.small,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space8,
            vertical: 5,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              color: selected ? accent : colors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}

/// 时间轴日头（日期 + 星期；今天带主色徽标，与月档今天强调同源）
class _TimelineDayHeader extends StatelessWidget {
  const _TimelineDayHeader({required this.date});

  final DateTime date;

  static const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final now = DateTime.now();
    final isToday = date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
    return Row(
      children: [
        Text(
          '${date.month}月${date.day}日',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colors.titleText,
          ),
        ),
        const SizedBox(width: AppDimens.space4),
        Text(
          '周${_weekdayNames[date.weekday - 1]}',
          style: TextStyle(fontSize: 11, color: colors.secondaryText),
        ),
        if (isToday) ...[
          const SizedBox(width: AppDimens.space6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: OrbitAccents.themeAccent.withValues(alpha: 0.12),
              borderRadius: AppShapes.small,
            ),
            child: Text(
              '今天',
              style: TextStyle(fontSize: 10, color: OrbitAccents.themeAccent),
            ),
          ),
        ],
      ],
    );
  }
}

/// 下方列表的按日分组块（对齐桌面右栏 DayGroupBlock）：
/// 日期头（今天强调 + 「今天」徽标，选中日高亮底）+ 任务行。
///
/// 卡片化（今天任务列表同款）：整组共拼一张卡——日期头是卡内首段，
/// 任务行是后续段（段位按「头 0 + 行 i+1」反算）；组间 cardGap 由外缘
/// 下垫承担。任务行不再自带灰底——卡面由段统一铺 surface。
class _MonthDayGroup extends StatelessWidget {
  const _MonthDayGroup({
    super.key,
    required this.date,
    required this.isSelectedDay,
    required this.isToday,
    required this.tasks,
    required this.onOpenTask,
    this.holidayMark,
  });

  final DateTime date;
  final bool isSelectedDay;
  final bool isToday;
  final List<TodoTask> tasks;
  final ValueChanged<int> onOpenTask;

  /// 节假日徽标：true 休 / false 班 / null 不渲染（议程档传入，月档为 null）
  final bool? holidayMark;

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
    final now = DateTime.now();
    // 今天零点 ms（逾期红判定口径：截止在今天内不算逾期）
    final todayMs = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    // 卡内段数：日期头首段 + 任务行
    final total = 1 + tasks.length;

    return Padding(
      // 组卡外缘：左右各让 space12（与任务子列表同口径），组间 cardGap 下垫
      padding: const EdgeInsets.fromLTRB(AppDimens.space12, 0,
          AppDimens.space12, AppDimens.cardGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 日期头（卡内首段）
          OrbitCardSegment(
            edge: OrbitCardEdge.of(0, total),
            child: Container(
              // 选中日高亮底：盖在卡面上（首段故只取上圆角，与卡片外缘同弧）
              decoration: isSelectedDay
                  ? BoxDecoration(
                      color: OrbitAccents.themeAccent.withValues(alpha: 0.10),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(AppShapes.radiusMedium - 1),
                      ),
                    )
                  : null,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space12, vertical: AppDimens.space8),
              child: Row(
                children: [
                  Text(
                    '${date.month}月${date.day}日',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isToday
                          ? OrbitAccents.themeAccent
                          : colors.titleText,
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
                  // 休/班徽标（议程档）：底色取值与月历日格徽标同源
                  if (holidayMark != null) ...[
                    const SizedBox(width: AppDimens.space6),
                    Container(
                      width: 16,
                      height: 16,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: holidayMark!
                            ? ChineseCalendarColors.weekend
                            : ChineseCalendarColors.workdayBadge,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        holidayMark! ? '休' : '班',
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                  if (isToday) ...[
                    const SizedBox(width: AppDimens.space8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(color: OrbitAccents.themeAccent),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '今天',
                        style: TextStyle(
                          fontSize: 10,
                          color: OrbitAccents.themeAccent,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 任务行（卡内续段：段位 = 头部 1 + 行下标）
          for (var i = 0; i < tasks.length; i++)
            _TaskCard(
              task: tasks[i],
              todayMs: todayMs,
              edge: OrbitCardEdge.of(i + 1, total),
              onTap: () => onOpenTask(tasks[i].id),
            ),
        ],
      ),
    );
  }
}

/// 单条任务行（卡内段：优先级色点 + 标题 + HH:mm 逾期红；对齐桌面右栏行）
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.todayMs,
    required this.onTap,
    this.edge = OrbitCardEdge.none,
  });

  final TodoTask task;
  final int todayMs;
  final VoidCallback onTap;

  /// 卡片段位（议程组卡内续段；默认扁平，复用面不受影响）
  final OrbitCardEdge edge;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hex = priorityColorHex(task.priority);
    final overdue = !task.isDone && task.dueDate != null && task.dueDate! < todayMs;
    final hasTime =
        task.dueDate != null && (task.dueDate! % 86400000) != 0; // 零点=纯日期

    return InkWell(
      onTap: onTap,
      // 卡内段（今天任务列表同款：卡面由段铺，行内只定内边距与最小行高）
      child: OrbitCardSegment(
        edge: edge,
        child: Container(
          constraints:
              const BoxConstraints(minHeight: AppDimens.touchTarget),
          padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space12, vertical: AppDimens.space8),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: hexToColor(hex),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Expanded(
                child: AnimatedStrikethrough(
                  text: task.title,
                  done: task.isDone,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                  doneColor: colors.secondaryText,
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
              Icon(OrbitIcons.chevronRight,
                  size: 18, color: colors.secondaryText),
            ],
          ),
        ),
      ),
    );
  }
}

/// 月档下方：选中日任务卡（竞品口径）
///
/// 点日格即看当天任务：头行 = 日期语义头（今天 / M月D日 周X + N天后/前 +
/// 农历/节日副标签 + 休/班徽标）+ 样式切换钮 +「长按日历快捷新增」提示；
/// 任务列同一张卡（[OrbitCardSegment] 分段描边），卡片行 = 勾选框
/// （优先级描边环）+ 标题 + 右列（时刻 + 元信息图标纵排），时间线行 =
/// 时刻左置列 + 右侧卡片行（无时刻留空对齐）。当天无任务时居中「当天没有任务」。
class _SelectedDayList extends StatelessWidget {
  const _SelectedDayList({
    required this.date,
    required this.tasks,
    required this.isToday,
    required this.holidayMark,
    required this.descriptionIds,
    required this.remindersByTask,
    required this.nowMs,
    required this.compact,
    required this.onToggleStyle,
    required this.onOpenTask,
    required this.onToggleDone,
  });

  final DateTime date;
  final List<TodoTask> tasks;
  final bool isToday;

  /// 休/班徽标：true 休 / false 班 / null 不渲染
  final bool? holidayMark;

  /// 「有描述」任务 id 集（列表通道裁剪 description 后的行内图标位）
  final Set<int> descriptionIds;
  final Map<int, List<ProjectedReminder>> remindersByTask;
  final int nowMs;

  /// 时间线样式（true = 时刻左置列 + 右侧卡片行；false = 卡片默认样式）
  final bool compact;

  /// 样式切换回调（落盘由调用方承担，本组件只发事件）
  final VoidCallback onToggleStyle;

  final ValueChanged<int> onOpenTask;
  final ValueChanged<TodoTask> onToggleDone;

  static const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final subLabel = ChineseAlmanac.daySubLabel(date);
    // 卡片外缘左右各让 space12（与任务子列表 cardListPadding 同口径）
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 日期语义头
          Padding(
            padding: const EdgeInsets.fromLTRB(
                0, AppDimens.space8, 0, AppDimens.space4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  isToday ? '今天' : '${date.month}月${date.day}日',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isToday ? OrbitAccents.themeAccent : colors.titleText,
                  ),
                ),
                if (!isToday) ...[
                  const SizedBox(width: AppDimens.space8),
                  Text(
                    '星期${_weekdayNames[date.weekday - 1]}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.secondaryText,
                    ),
                  ),
                ],
                if (subLabel != null) ...[
                  const SizedBox(width: AppDimens.space8),
                  Flexible(
                    child: Text(
                      subLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondaryText,
                      ),
                    ),
                  ),
                ],
                if (holidayMark != null) ...[
                  const SizedBox(width: AppDimens.space6),
                  Container(
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: holidayMark!
                          ? ChineseCalendarColors.weekend
                          : ChineseCalendarColors.workdayBadge,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      holidayMark! ? '休' : '班',
                      style: const TextStyle(
                        fontSize: 10,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  '长按日历快捷新增',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.secondaryText,
                  ),
                ),
                const SizedBox(width: AppDimens.space4),
                // 卡片 ⇄ 时间线切换（图标 = 切过去的目标样式，与议程切换钮同口径）
                IconButton(
                  // 内容行高 ~24：默认 48 热区会把头行撑高一倍，取 40 折中
                  // （图标 18 + 上下各 11，点按面积仍是视觉字形的四倍）
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  icon: Icon(
                    compact ? OrbitIcons.tableRows : OrbitIcons.clock,
                    size: AppDimens.iconSizeSm,
                    color: colors.secondaryText,
                  ),
                  tooltip: compact ? '切换为卡片样式' : '切换为时间线样式',
                  onPressed: onToggleStyle,
                ),
              ],
            ),
          ),
          // 任务卡：当天无任务居中提示，有任务按分段成卡。
          // 段间无缝（今天任务列表同款整卡：首段圆上角 / 末段圆下角，
          // 段间 1px divider 由上一段下沿画一次）
          if (tasks.isEmpty)
            OrbitCardSegment(
              edge: OrbitCardEdge.single,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: AppDimens.space20),
                child: Center(
                  child: Text(
                    '当天没有任务',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ),
              ),
            )
          else if (compact)
            for (var i = 0; i < tasks.length; i++)
              _DayTimelineRow(
                task: tasks[i],
                edge: OrbitCardEdge.of(i, tasks.length),
                hasDescription: descriptionIds.contains(tasks[i].id),
                reminder: displayReminder(
                  remindersByTask[tasks[i].id] ??
                      const <ProjectedReminder>[],
                  nowMs,
                  taskDone: tasks[i].isDone,
                ),
                onToggle: () => onToggleDone(tasks[i]),
                onOpen: () => onOpenTask(tasks[i].id),
              )
          else
            for (var i = 0; i < tasks.length; i++)
              OrbitCardSegment(
                edge: OrbitCardEdge.of(i, tasks.length),
                child: _DayTaskRow(
                  task: tasks[i],
                  hasDescription: descriptionIds.contains(tasks[i].id),
                  reminder: displayReminder(
                    remindersByTask[tasks[i].id] ??
                        const <ProjectedReminder>[],
                    nowMs,
                    taskDone: tasks[i].isDone,
                  ),
                  onToggle: () => onToggleDone(tasks[i]),
                  onOpen: () => onOpenTask(tasks[i].id),
                ),
              ),
        ],
      ),
    );
  }
}

/// 选中日任务卡的行：勾选框（优先级描边环）+ 标题 + 右列（时刻 / 元信息图标）
///
/// 与主列表行同一信息层级，但日期由头行表达——右列只出时刻（带时刻的任务），
/// 未来/今天主题蓝、逾期红；重复 / 提醒 / 描述元信息图标压在时刻下方右对齐
/// （图标档 12，与主列表行同源）。
class _DayTaskRow extends StatelessWidget {
  const _DayTaskRow({
    required this.task,
    required this.hasDescription,
    required this.reminder,
    required this.onToggle,
    required this.onOpen,
    this.showTimeColumn = true,
  });

  final TodoTask task;

  /// 有无描述（列表通道裁剪 description，位来自行元信息投影）
  final bool hasDescription;

  /// 行内提醒载荷；null（无存活提醒）不渲染
  final DisplayReminder? reminder;

  /// 右列时刻是否渲染：时间线样式传 false（时刻由外层左置列承载，
  /// 此处再渲染即一题两答）
  final bool showTimeColumn;

  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hex = priorityRingHex(task.priority);
    final d = task.dueDate == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(task.dueDate!);
    final hasTime = d != null &&
        (d.hour != 0 || d.minute != 0 || d.second != 0 || d.millisecond != 0);
    final meta = <Widget>[
      if (task.repeatMode > 0)
        Icon(OrbitIcons.repeat, size: 12, color: colors.iconText),
      if (reminder != null)
        Icon(
          OrbitIcons.notification,
          size: 12,
          color: reminder!.fired ? OrbitAccents.overdueRed : colors.iconText,
        ),
      if (hasDescription) Icon(OrbitIcons.fileText, size: 12, color: colors.iconText),
    ];

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space12,
          vertical: AppDimens.space8,
        ),
        child: Row(
          children: [
            OrbitCheckbox(
              checked: task.isDone,
              onToggle: onToggle,
              borderColor: hex == null ? null : hexToColor(hex),
            ),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: AnimatedStrikethrough(
                text: task.title,
                done: task.isDone,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: colors.titleText,
                ),
                doneColor: colors.secondaryText,
              ),
            ),
            if ((hasTime && showTimeColumn) || meta.isNotEmpty) ...[
              const SizedBox(width: AppDimens.space8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (hasTime && showTimeColumn)
                    Text(
                      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: isOverdue(task)
                            ? OrbitAccents.overdueRed
                            : OrbitAccents.themeAccent,
                      ),
                    ),
                  if (meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < meta.length; i++) ...[
                            if (i > 0) const SizedBox(width: AppDimens.space6),
                            meta[i],
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 选中日任务卡的时间线行（竞品第二种列表样式）：时刻左置列 + 右侧卡片。
///
/// 无时刻的任务左列留空（同宽占位，对齐有时刻的行）；卡片内容复用
/// [_DayTaskRow]（关掉右列时刻），勾选/标题/元信息图标行为与卡片样式一致。
class _DayTimelineRow extends StatelessWidget {
  const _DayTimelineRow({
    required this.task,
    required this.edge,
    required this.hasDescription,
    required this.reminder,
    required this.onToggle,
    required this.onOpen,
  });

  final TodoTask task;

  /// 卡片分段边（与卡片样式同规则：首段圆上角、末段圆下角）
  final OrbitCardEdge edge;

  /// 有无描述（列表通道裁剪 description，位来自行元信息投影）
  final bool hasDescription;

  /// 行内提醒载荷；null（无存活提醒）不渲染
  final DisplayReminder? reminder;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  /// 时刻列宽：`HH:mm` 12px tabular 约 36px，余量对齐卡片内边距
  static const _timeColumnWidth = 42.0;

  @override
  Widget build(BuildContext context) {
    final d = task.dueDate == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(task.dueDate!);
    final hasTime = d != null &&
        (d.hour != 0 || d.minute != 0 || d.second != 0 || d.millisecond != 0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _timeColumnWidth,
          child: Padding(
            // 与卡片首行对齐：卡片上下内边距 8 + 标题字形上沿余量
            padding: const EdgeInsets.only(top: 10),
            child: hasTime
                ? Text(
                    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: isOverdue(task)
                          ? OrbitAccents.overdueRed
                          : OrbitAccents.themeAccent,
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(width: AppDimens.space8),
        Expanded(
          child: OrbitCardSegment(
            edge: edge,
            child: _DayTaskRow(
              task: task,
              hasDescription: hasDescription,
              reminder: reminder,
              showTimeColumn: false,
              onToggle: onToggle,
              onOpen: onOpen,
            ),
          ),
        ),
      ],
    );
  }
}

/// 翻月滑动的速度阈值（px/s；位移判据另取屏宽 15%）
const double _kSwipeVelocity = 280;

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
