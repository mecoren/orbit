import 'package:flutter/material.dart';

/// 月历尺寸档位
enum AppCalendarSize { large, medium, small }

/// 通用月历组件（自 wait-home/mobile 移植，裁剪版）
///
/// - [AppCalendarSize.small]：迷你版，日期选择面板使用（当前唯一用途）
/// - [AppCalendarSize.medium]/[AppCalendarSize.large]：紧凑/完整版，预留
///
/// 标记口径：今天 = 强调色实心块白字；选中（非今天）= 强调色描边；
/// 周末数字着 [weekendColor]；[selectableStart]/[selectableEnd] 范围外禁用。
///
/// 裁剪说明：原版还带节假日徽标/农历副标签/事件圆点/dayCellBuilder，
/// 依赖 wait-home 的 chinese_calendar_colors 等模块，orbit 暂无此需求未移植。
class AppMonthCalendar extends StatelessWidget {
  const AppMonthCalendar({
    super.key,
    required this.month,
    this.size = AppCalendarSize.large,
    this.selected,
    this.onDayTap,
    this.onMonthChange,
    this.showHeader = true,
    this.showWeekdays = true,
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
  final ValueChanged<DateTime>? onMonthChange;
  final bool showHeader;
  final bool showWeekdays;

  /// 今天/选中强调色（缺省为主题主色）
  final Color? accentColor;

  /// 周末识别色（缺省为 wait-home 同款固定周末蓝）
  final Color? weekendColor;

  /// 可选范围（small 档表单选择用，范围外禁用）
  final DateTime? selectableStart;
  final DateTime? selectableEnd;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// wait-home ChineseCalendarColors.weekend 同值
  static const Color _defaultWeekend = Color(0xFF4C7DF0);

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
    final weekend = weekendColor ?? _defaultWeekend;
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                icon:
                    Icon(Icons.chevron_right_rounded, size: _navIconSize + 4),
                tooltip: '下个月',
                visualDensity: VisualDensity.compact,
              ),
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
                    date: cells[row * 7 + col],
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
    required DateTime date,
    required Color accent,
    required Color weekend,
    required String todayYmd,
    required String? selectedYmd,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ymd = _ymd(date);
    final inMonth = date.month == month.month;
    final isToday = ymd == todayYmd;
    final isSelected = selectedYmd != null && ymd == selectedYmd;
    final isWeekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    final outOfRange =
        (selectableStart != null && date.isBefore(selectableStart!)) ||
            (selectableEnd != null && date.isAfter(selectableEnd!));

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

    final isCircle = size == AppCalendarSize.small;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: outOfRange || onDayTap == null ? null : () => onDayTap!(date),
      child: SizedBox(
        height: _cellHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Container(
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: filled ? accent : null,
              borderRadius: isCircle
                  ? BorderRadius.circular(999)
                  : BorderRadius.circular(10),
              border: outlined ? Border.all(color: accent, width: 1.5) : null,
            ),
            child: Text(
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
          ),
        ),
      ),
    );
  }
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
