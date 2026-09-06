import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/glass_fab.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/wait_toast.dart';
import 'form_bottom_sheet.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';

/// 日历视图 /todo/calendar（用户需求 + docs/05 §4.x）
///
/// 月历网格（周一起始 7×6）：每个日期格内是当期待办的**小长条列表**——
/// 条内为待办标题（优先级色点 + HH:mm + 截断标题），**点击小长条进入任务
/// 详情页**；当日待办超出格子可视高度时**格子内可纵向滑动**查看全部。
/// 节假日徽标：放假「休」（绿）/ 调休补班「班」（橙），数据联网更新
/// （cfg_holidays 缓存；空库回落 Rust 预置 2026 表）。
///
/// 数据口径：与子列表同源 todoTasksProvider 全量任务，客户端按 due_date
/// 本地日聚合（无网络依赖）；月导航支持前后翻页与「今天」回位。
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// 当前展示的月份（year + month）
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  // ── 数据 ──

  List<TodoTask> _tasks() =>
      ref.watch(todoTasksProvider(const TaskListQuery())).value ?? [];

  Map<String, HolidayInfo> _holidayByDate() {
    final holidays = ref.watch(holidayProvider).value ?? const <HolidayInfo>[];
    return {for (final h in holidays) h.date: h};
  }

  /// due_date → 本地 YYYY-MM-DD 聚合（一天遍历；排序 position 升序 →
  /// created_at 降序，与列表/桌面日历同口径）
  Map<String, List<TodoTask>> _byDay(List<TodoTask> tasks) {
    final map = <String, List<TodoTask>>{};
    for (final t in tasks) {
      final due = t.dueDate;
      if (due == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(due);
      final key =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      (map[key] ??= []).add(t);
    }
    for (final list in map.values) {
      list.sort((a, b) {
        if (a.position != b.position) return a.position.compareTo(b.position);
        return b.createdAt.compareTo(a.createdAt);
      });
    }
    return map;
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

  // ── 月导航 ──

  void _prevMonth() =>
      setState(() => _month = _month.month == 1 ? DateTime(_month.year - 1, 12) : DateTime(_month.year, _month.month - 1));

  void _nextMonth() =>
      setState(() => _month = _month.month == 12 ? DateTime(_month.year + 1, 1) : DateTime(_month.year, _month.month + 1));

  void _today() =>
      setState(() => _month = DateTime(DateTime.now().year, DateTime.now().month));

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final byDay = _byDay(_tasks());
    final holidayByDate = _holidayByDate();
    final now = DateTime.now();
    final today = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // 7×6 网格（周一起始），含前后月补位
    final first = DateTime(_month.year, _month.month, 1);
    final offset = (first.weekday + 6) % 7;
    final gridStart = first.subtract(Duration(days: offset));
    final cells = List.generate(42, (i) => gridStart.add(Duration(days: i)));

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                SizedBox(height: LiquidGlassTitleBar.rowHeight),
                // 工具栏：月份标题 + 今天 + 翻页 + 节假日更新
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
                          onTap: _today,
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
                      _buildUpdateButton(),
                    ],
                  ),
                ),
                // 星期表头（周一始）
                Row(
                  children: [
                    for (final label in _weekdayLabels)
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              label,
                              style: themeSmall(context, colors.secondaryText),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                // 月格（占满剩余高度，每格内部任务条列表可滑动）
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.space8),
                    child: Row(
                      children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(
                            child: Column(
                              children: [
                                for (var row = 0; row < 6; row++)
                                  Expanded(
                                    child: _CalendarCell(
                                      date: cells[row * 7 + col],
                                      inMonth:
                                          cells[row * 7 + col].month == _month.month,
                                      isToday:
                                          _ymd(cells[row * 7 + col]) == today,
                                      tasks: byDay[_ymd(cells[row * 7 + col])] ??
                                          const <TodoTask>[],
                                      holiday: holidayByDate[
                                          _ymd(cells[row * 7 + col])],
                                      todayMs: DateTime(
                                              now.year, now.month, now.day)
                                          .millisecondsSinceEpoch,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
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
              title: '日历',
              showBack: true,
            ),
          ),
          // FAB：新建任务（默认截止日 = 点击那天不易获得，走通用表单自选）
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
}

TextStyle themeSmall(BuildContext context, Color color) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(color: color) ??
    TextStyle(fontSize: 12, color: color);

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 单个日期格：日期行（数字 + 节假日徽标 + 计数）+ 可滑动任务条列表
class _CalendarCell extends StatelessWidget {
  const _CalendarCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.tasks,
    required this.holiday,
    required this.todayMs,
  });

  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final List<TodoTask> tasks;
  final HolidayInfo? holiday;

  /// 今天零点 ms（逾期红判定口径：截止在今天内不算逾期）
  final int todayMs;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = !inMonth;

    return Padding(
      padding: const EdgeInsets.all(1.5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isToday
              ? scheme.primary.withValues(alpha: 0.06)
              : muted
                  ? colors.surface.withValues(alpha: 0.3)
                  : colors.surface.withValues(alpha: 0.5),
          borderRadius: AppShapes.of(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 日期行：数字（今天强调）+ 节假日徽标 + 任务数
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: isToday ? scheme.primary : null,
                      borderRadius: AppShapes.of(6),
                    ),
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                        color: isToday
                            ? Colors.white
                            : muted
                                ? colors.secondaryText.withValues(alpha: 0.45)
                                : date.weekday == DateTime.saturday ||
                                        date.weekday == DateTime.sunday
                                    ? const Color(0xFF4C7DF0)
                                    : colors.titleText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  if (holiday != null)
                    _HolidayBadge(holiday: holiday!),
                  const Spacer(),
                  if (tasks.isNotEmpty)
                    Text(
                      '${tasks.length}',
                      style: TextStyle(
                        fontSize: 10,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: colors.secondaryText.withValues(alpha: 0.7),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              // 可滑动任务条列表：超出可视高度时纵向滑动查看当日全部待办
              Expanded(
                child: tasks.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        physics: const ClampingScrollPhysics(),
                        itemCount: tasks.length,
                        itemBuilder: (context, i) =>
                            _TaskBar(task: tasks[i], todayMs: todayMs, muted: muted),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 节假日徽标：放假「休」（绿）/ 调休补班「班」（橙）
class _HolidayBadge extends StatelessWidget {
  const _HolidayBadge({required this.holiday});

  final HolidayInfo holiday;

  @override
  Widget build(BuildContext context) {
    final isOff = holiday.isHoliday;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      decoration: BoxDecoration(
        color: (isOff ? const Color(0xFF22C55E) : const Color(0xFFF59E0B))
            .withValues(alpha: 0.16),
        borderRadius: AppShapes.of(4),
      ),
      child: Text(
        isOff ? '休' : '班',
        style: TextStyle(
          fontSize: 9.5,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: isOff ? const Color(0xFF16A34A) : const Color(0xFFD97706),
        ),
      ),
    );
  }
}

/// 格内待办小长条：优先级色点 + HH:mm（逾期红）+ 截断标题；点击进详情
class _TaskBar extends StatelessWidget {
  const _TaskBar({required this.task, required this.todayMs, this.muted = false});

  final TodoTask task;
  final int todayMs;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final priorityHex = priorityColorHex(task.priority);
    final overdue = !task.isDone && task.dueDate != null && task.dueDate! < todayMs;
    final hasTime = task.dueDate != null &&
        (task.dueDate! % 86400000) != 0; // 零点=纯日期无具体时刻

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/todo/${task.id}'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: muted ? 0.25 : 0.7),
            borderRadius: AppShapes.of(5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
            child: Row(
              children: [
                // 优先级色点
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: priorityHex.isEmpty
                        ? colors.secondaryText.withValues(alpha: 0.4)
                        : hexToColor(priorityHex),
                  ),
                ),
                const SizedBox(width: 4),
                if (hasTime)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Text(
                      DateFormat('HH:mm')
                          .format(DateTime.fromMillisecondsSinceEpoch(task.dueDate!)),
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.2,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: overdue
                            ? OrbitAccents.overdueRed
                            : colors.secondaryText,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: overdue
                          ? OrbitAccents.overdueRed
                          : task.isDone
                              ? colors.secondaryText
                              : colors.titleText,
                      decoration:
                          task.isDone ? TextDecoration.lineThrough : null,
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
}
