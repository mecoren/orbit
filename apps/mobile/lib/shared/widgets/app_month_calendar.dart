import 'package:flutter/material.dart';

/// 月历尺寸档位
enum AppCalendarSize { large, medium, small }

/// 日格渲染上下文（自定义 dayCellBuilder 使用）
class AppCalendarDayContext {
  const AppCalendarDayContext({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.isWeekend,
    required this.isRowStart,
    required this.isRowEnd,
    this.prevDate,
    this.nextDate,
  });

  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool isWeekend;

  /// 是否位于本周行首/行尾（连续区间跨行断开圆角判定）
  final bool isRowStart;
  final bool isRowEnd;

  /// 网格中前/后一格日期（越界为 null）
  final DateTime? prevDate;
  final DateTime? nextDate;
}

/// 中国假日日历标记色（Days Matter 风格装饰色，与桌面端 month-calendar 同源）
///
/// 周末/休班识别色缺省值；调用方可通过 [AppMonthCalendar.weekendColor]
/// 按模块强调色覆盖，此处的常量仅作回退。
class ChineseCalendarColors {
  ChineseCalendarColors._();

  /// 周末 / 休息日识别色（日期数字、「休」徽标底），
  /// 休息日整格底色由此派生 10% 透明度
  static const Color weekend = Color(0xFF4C7DF0);

  /// 春节（正月初一）标记红（年视图下划线 / 图例）
  static const Color lunarNewYear = Color(0xFFF43F5E);

  /// 农历每月初一标记蓝（年视图下划线 / 图例）
  static const Color lunarNewMoon = Color(0xFF0EA5E9);

  /// 调休上班日整格底色（浅色压暗 / 深色提亮，随亮度自适应）
  static Color workdayBackground(Brightness brightness) =>
      brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.08);
}

/// 通用月历组件（Days Matter 风格，三档尺寸；自 wait-home/mobile 完整移植）
///
/// - [AppCalendarSize.large]：完整版（农历副标签 + 事件圆点 + 休/班徽标），
///   日历视图使用
/// - [AppCalendarSize.medium]：紧凑版（半屏），预留
/// - [AppCalendarSize.small]：迷你版，日期选择面板使用
///
/// 标记口径：今天 = 强调色实心块白字；选中（非今天）= 强调色描边；
/// 周末数字着[weekendColor]（缺省固定周末蓝）；休息日浅识别色底 +
/// 「休」徽标；调休日压暗底 + 橙红「班」徽标。
///
/// 定制：[subLabelBuilder] / [eventDotsBuilder] 追加内容；
/// [dayCellBuilder] 完全接管日格。
/// 头部：可点击标题 + 副标题 + 翻月箭头 + 额外动作插槽。
class AppMonthCalendar extends StatelessWidget {
  const AppMonthCalendar({
    super.key,
    required this.month,
    this.size = AppCalendarSize.large,
    this.selected,
    this.onDayTap,
    this.onDayLongPress,
    this.onMonthChange,
    this.showHeader = true,
    this.showWeekdays = true,
    this.onTitleTap,
    this.headerSubtitle,
    this.headerActions = const <Widget>[],
    this.holidays,
    this.subLabelBuilder,
    this.eventDotsBuilder,
    this.dayCellBuilder,
    this.accentColor,
    this.weekendColor,
    this.selectableStart,
    this.selectableEnd,
  });

  /// 所处月份（取 year + month）
  final DateTime month;

  final AppCalendarSize size;
  final DateTime? selected;
  final ValueChanged<DateTime>? onDayTap;

  /// 长按日格（对应桌面端右键：如长按某天快捷新增任务）
  final ValueChanged<DateTime>? onDayLongPress;

  final ValueChanged<DateTime>? onMonthChange;
  final bool showHeader;
  final bool showWeekdays;

  /// 点击头部标题（如打开年视图）；不传则标题不可点
  final VoidCallback? onTitleTap;
  final Widget? headerSubtitle;
  final List<Widget> headerActions;

  /// ymd → 是否休息日（true=休，false=班；small 档不渲染徽标）
  final Map<String, bool>? holidays;

  /// 副标签（large/medium；日历视图传 ChineseAlmanac.daySubLabel）
  final String? Function(DateTime date)? subLabelBuilder;

  /// 事件圆点颜色（仅 large；≤4 个，无事件也保持等高防跳动）
  final List<Color> Function(DateTime date)? eventDotsBuilder;

  /// 完全接管日格渲染
  final Widget? Function(AppCalendarDayContext ctx)? dayCellBuilder;

  /// 今天/选中强调色（缺省为主题主色）
  final Color? accentColor;

  /// 周末/休息日识别色，数字与「休」徽标同源（缺省为固定周末蓝）
  final Color? weekendColor;

  /// 可选范围（small 档表单选择用，范围外禁用）
  final DateTime? selectableStart;
  final DateTime? selectableEnd;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  double get _cellHeight => switch (size) {
        AppCalendarSize.large => 64,
        AppCalendarSize.medium => 48,
        AppCalendarSize.small => 36,
      };

  double get _numberFont => switch (size) {
        AppCalendarSize.large => 17,
        AppCalendarSize.medium => 14,
        AppCalendarSize.small => 12.5,
      };

  double get _titleFont => switch (size) {
        AppCalendarSize.large => 22,
        AppCalendarSize.medium => 18,
        AppCalendarSize.small => 14,
      };

  double get _navIconSize => switch (size) {
        AppCalendarSize.large => 22,
        AppCalendarSize.medium => 18,
        AppCalendarSize.small => 16,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = accentColor ?? scheme.primary;
    // 周末识别色可由调用方按模块强调色覆盖
    final weekend = weekendColor ?? ChineseCalendarColors.weekend;
    final today = DateTime.now();
    final todayYmd = _ymd(today);
    final selectedYmd = selected == null ? null : _ymd(selected!);

    // 6×7 网格（周一起始），含前后月补位
    final first = DateTime(month.year, month.month, 1);
    final offset = (first.weekday + 6) % 7;
    final gridStart = first.subtract(Duration(days: offset));
    final cells = List.generate(42, (i) => gridStart.add(Duration(days: i)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              InkWell(
                onTap: onTitleTap,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      if (month.year != today.year) ...[
                        Text(
                          '${month.year}年',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        '${month.month}月',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: _titleFont,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ?headerSubtitle,
              const Spacer(),
              IconButton(
                onPressed: onMonthChange == null
                    ? null
                    : () => onMonthChange!(
                          month.month == 1
                              ? DateTime(month.year - 1, 12)
                              : DateTime(month.year, month.month - 1),
                        ),
                icon: Icon(Icons.chevron_left_rounded, size: _navIconSize + 4),
                tooltip: '上个月',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: onMonthChange == null
                    ? null
                    : () => onMonthChange!(
                          month.month == 12
                              ? DateTime(month.year + 1, 1)
                              : DateTime(month.year, month.month + 1),
                        ),
                icon: Icon(Icons.chevron_right_rounded, size: _navIconSize + 4),
                tooltip: '下个月',
                visualDensity: VisualDensity.compact,
              ),
              ...headerActions,
            ],
          ),
          const SizedBox(height: 4),
        ],
        if (showWeekdays)
          Row(
            children: [
              for (final label in _weekdayLabels)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: size == AppCalendarSize.small ? 10 : null,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        for (var row = 0; row < 6; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: _buildCell(
                    context,
                    index: row * 7 + col,
                    cells: cells,
                    accent: accent,
                    weekend: weekend,
                    todayYmd: todayYmd,
                    selectedYmd: selectedYmd,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildCell(
    BuildContext context, {
    required int index,
    required List<DateTime> cells,
    required Color accent,
    required Color weekend,
    required String todayYmd,
    required String? selectedYmd,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = cells[index];
    final ymd = _ymd(date);
    final inMonth = date.month == month.month;
    final isToday = ymd == todayYmd;
    final isSelected = selectedYmd != null && ymd == selectedYmd;
    final isWeekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    final isOffDay = holidays?[ymd] == true;
    final isWorkday = holidays?[ymd] == false;
    final outOfRange =
        (selectableStart != null && date.isBefore(selectableStart!)) ||
            (selectableEnd != null && date.isAfter(selectableEnd!));

    final ctx = AppCalendarDayContext(
      date: date,
      inMonth: inMonth,
      isToday: isToday,
      isSelected: isSelected,
      isWeekend: isWeekend,
      isRowStart: index % 7 == 0,
      isRowEnd: index % 7 == 6,
      prevDate: index > 0 ? cells[index - 1] : null,
      nextDate: index < cells.length - 1 ? cells[index + 1] : null,
    );

    // 完全接管模式
    if (dayCellBuilder != null) {
      final custom = dayCellBuilder!(ctx);
      if (custom != null) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDayTap == null ? null : () => onDayTap!(date),
          onLongPress:
              onDayLongPress == null ? null : () => onDayLongPress!(date),
          child: SizedBox(height: _cellHeight, child: custom),
        );
      }
    }

    // ===== 默认日格 =====
    // 今天 = 实心强调块；选中（非今天）= 描边
    final filled = isToday;
    final outlined = !isToday && isSelected;
    final numberColor = outOfRange
        ? scheme.onSurfaceVariant.withValues(alpha: 0.3)
        : filled
            ? Colors.white
            : !inMonth
                ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
                : isWeekend
                    ? weekend
                    : scheme.onSurface;

    final showBadge = holidays != null &&
        holidays!.containsKey(ymd) &&
        size != AppCalendarSize.small;

    final sub = size != AppCalendarSize.small && subLabelBuilder != null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              subLabelBuilder!(date) ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: size == AppCalendarSize.large ? 10 : 9,
                height: 1.1,
                color: scheme.onSurfaceVariant
                    .withValues(alpha: inMonth ? 1 : 0.5),
              ),
            ),
          )
        : null;

    final dots = size == AppCalendarSize.large && eventDotsBuilder != null
        ? SizedBox(
            // 固定高度占位（无事件也保持等高，避免选中/今天时格子内容跳动）
            height: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final color in eventDotsBuilder!(date).take(4))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
          )
        : null;

    final isCircle = size == AppCalendarSize.small;

    // 日格底色：今天强调块 > 休息日浅识别底（同源派生） > 调休压暗底
    final Color? cellBackground;
    if (filled) {
      cellBackground = accent;
    } else if (isOffDay) {
      cellBackground = weekend.withValues(alpha: 0.10);
    } else if (isWorkday) {
      cellBackground =
          ChineseCalendarColors.workdayBackground(scheme.brightness);
    } else {
      cellBackground = null;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: outOfRange || onDayTap == null ? null : () => onDayTap!(date),
      onLongPress: outOfRange || onDayLongPress == null
          ? null
          : () => onDayLongPress!(date),
      child: SizedBox(
        height: _cellHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Container(
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cellBackground,
              borderRadius: isCircle
                  ? BorderRadius.circular(999)
                  : BorderRadius.circular(10),
              border: outlined ? Border.all(color: accent, width: 1.5) : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${date.day}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: _numberFont,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: filled || outlined
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: numberColor,
                  ),
                ),
                ?sub,
                ?dots,
                if (dots != null) const SizedBox(height: 2),
              ],
            ),
          ),
        ),
      ),
    ).maybeBadge(
      context,
      show: showBadge,
      isOffDay: isOffDay,
      weekend: weekend,
    );
  }
}

/// 休/班徽标扩展：色块右上角独立圆标（对齐桌面端口径——
/// 休=周末蓝底、「班」=橙红底，位于日格右上角而非数字上）
extension _HolidayBadge on Widget {
  Widget maybeBadge(
    BuildContext context, {
    required bool show,
    required bool isOffDay,
    required Color weekend,
  }) {
    if (!show) return this;
    final size = MediaQuery.sizeOf(context);
    // 屏幕极窄时徽标易与数字重叠，仅在横向有余量时展示
    if (size.width < 320) return this;
    const badge = Color(0xFFFF7043);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        this,
        Positioned(
          right: -3,
          top: -2,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOffDay ? weekend : badge,
            ),
            child: Text(
              isOffDay ? '休' : '班',
              style: const TextStyle(
                fontSize: 8,
                height: 1,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
