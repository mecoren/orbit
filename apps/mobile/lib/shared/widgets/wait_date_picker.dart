import 'package:flutter/cupertino.dart'
    show CupertinoPicker, CupertinoPickerDefaultSelectionOverlay;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import 'app_month_calendar.dart';
import 'more_actions_sheet.dart' show bottomSheetTopShape;

/// 日期选择器精度模式
enum WaitDatePickerMode { day, month, year }

/// 底部面板返回结果包装，用于区分「用户点击确认/清除」与「滑动关闭/点击蒙层取消」
class _PickerResult {
  const _PickerResult(this.date);
  final DateTime? date;
}

/// iOS 风格的日期选择器（自 wait-home/mobile 移植，编程式入口版）。
///
/// 底部弹出日历面板：头部标题/相对日期副标题，标题栏可在日/年月/年视图间
/// 切换，[showTime] 开启时附带时分步进器（日期+时间单面板一次选完）。
/// 选中日期使用调用方传入的强调色圆形高亮。
///
/// 裁剪说明：原版还带表单字段形态的 WaitDatePicker widget（依赖 wait-home
/// 的 colorThemeProvider/WaitFieldLabel），orbit 表单用 chip 行 + pick()，
/// 未移植该形态。
class WaitDatePicker {
  WaitDatePicker._();

  static String formatDate(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// 带时分的格式化：YYYY-MM-DD HH:mm
  static String formatDateTime(DateTime date) {
    final dateStr = formatDate(date);
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$dateStr $hour:$minute';
  }

  /// 编程式弹出日期选择面板，返回用户选择的日期（取消返回 null）
  ///
  /// 注意：面板内点「清除」与滑动关闭同样返回 null——调用侧需自行
  /// 维持「null 不动、清空走字段自身叉号」的语义。
  static Future<DateTime?> pick(
    BuildContext context, {
    DateTime? initialDate,
    bool showTime = false,
    WaitDatePickerMode mode = WaitDatePickerMode.day,
    Color? accent,
  }) async {
    final colors = AppColors.ofContext(context);
    final color = accent ?? colors.accent;
    final result = await showModalBottomSheet<_PickerResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (context) => _DatePickerSheet(
        initialDate: initialDate,
        accent: color,
        showTime: showTime,
        mode: mode,
      ),
    );
    return result?.date;
  }
}

/// 日期选择器视图模式
enum _DatePickerViewMode { day, yearMonth, year }

class _DatePickerSheet extends StatefulWidget {
  const _DatePickerSheet({
    required this.accent,
    this.initialDate,
    this.showTime = false,
    this.mode = WaitDatePickerMode.day,
  });

  final DateTime? initialDate;
  final Color accent;
  final bool showTime;
  final WaitDatePickerMode mode;

  @override
  State<_DatePickerSheet> createState() => _DatePickerSheetState();
}

class _DatePickerSheetState extends State<_DatePickerSheet> {
  late DateTime _currentMonth;
  DateTime? _selectedDate;
  TimeOfDay _selectedTime = const TimeOfDay(hour: 0, minute: 0);
  _DatePickerViewMode _viewMode = _DatePickerViewMode.day;

  final firstDate = DateTime(2000, 1, 1);
  final lastDate = DateTime(2100, 12, 31);

  @override
  void initState() {
    super.initState();
    // 无值时自动选中当天，方便用户直接确认
    _selectedDate = widget.initialDate ?? DateTime.now();
    _selectedTime = TimeOfDay.fromDateTime(_selectedDate!);
    _currentMonth = _monthOnly(_selectedDate!);
    // 仅年月/仅年份模式：直接进入对应视图，选中即确认
    if (widget.mode == WaitDatePickerMode.month) {
      _viewMode = _DatePickerViewMode.yearMonth;
    } else if (widget.mode == WaitDatePickerMode.year) {
      _viewMode = _DatePickerViewMode.year;
    }
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateUtils.addMonthsToMonthDate(_currentMonth, -1);
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateUtils.addMonthsToMonthDate(_currentMonth, 1);
    });
  }

  void _selectDate(DateTime date) {
    setState(() {
      // 选日保留已选时分（showTime 场景下时间不因换日丢失）
      _selectedDate = DateTime(
        date.year,
        date.month,
        date.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );
    });
  }

  /// 时间（时分）变化：同步到 _selectedDate，并保留已选日期
  void _onTimeChanged(TimeOfDay time) {
    setState(() {
      _selectedTime = time;
      if (_selectedDate != null) {
        _selectedDate = DateTime(
          _selectedDate!.year,
          _selectedDate!.month,
          _selectedDate!.day,
          time.hour,
          time.minute,
        );
      }
    });
  }

  /// 选中年月：仅年月模式直接确认（返回 day=1 的 DateTime），否则切回日视图
  void _selectYearMonth(int year, int month) {
    if (widget.mode == WaitDatePickerMode.month) {
      Navigator.of(context).pop(_PickerResult(DateTime(year, month, 1)));
      return;
    }
    setState(() {
      _currentMonth = DateTime(year, month);
      _viewMode = _DatePickerViewMode.day;
    });
  }

  /// 选中年份：仅年份模式直接确认（返回该年 1 月 1 日的 DateTime）
  void _selectYear(int year) {
    if (widget.mode == WaitDatePickerMode.year) {
      Navigator.of(context).pop(_PickerResult(DateTime(year, 1, 1)));
      return;
    }
    setState(() {
      _currentMonth = DateTime(year, _currentMonth.month);
      _viewMode = _DatePickerViewMode.yearMonth;
    });
  }

  void _toggleViewMode() {
    if (widget.mode == WaitDatePickerMode.month) return;
    if (widget.mode == WaitDatePickerMode.year) return;
    setState(() {
      _viewMode = _viewMode == _DatePickerViewMode.day
          ? _DatePickerViewMode.yearMonth
          : _DatePickerViewMode.day;
    });
  }

  void _previousYear() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year - 1, _currentMonth.month);
    });
  }

  void _nextYear() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year + 1, _currentMonth.month);
    });
  }

  /// 年视图翻页：一次前进/后退 12 年（与桌面端 YearPicker 一致）
  void _previousYearBlock() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year - 12, _currentMonth.month);
    });
  }

  void _nextYearBlock() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year + 12, _currentMonth.month);
    });
  }

  DateTime _monthOnly(DateTime date) => DateTime(date.year, date.month);

  void _confirm() {
    Navigator.of(context).pop(_PickerResult(_selectedDate));
  }

  void _clear() {
    Navigator.of(context).pop(const _PickerResult(null));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 仅保留系统 Home Indicator 安全区，让面板底部排满屏幕
    // （模态底部面板本身已覆盖浮动导航栏，无需再为其预留空间）
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              0, AppDimens.space16, 0, AppDimens.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖拽手柄
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: AppDimens.space16),
              // iOS 风格头部
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space20),
                child: _SheetHeader(
                  selectedDate: _selectedDate,
                  accent: widget.accent,
                  showTime: widget.showTime,
                  time: _selectedTime,
                ),
              ),
              const Divider(height: 24),
              // 标题栏：点击切换年月/日视图
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space20),
                child: _HeaderBar(
                  currentMonth: _currentMonth,
                  viewMode: _viewMode,
                  accent: widget.accent,
                  onTitleTap: _toggleViewMode,
                  onPrevious: _viewMode == _DatePickerViewMode.day
                      ? _previousMonth
                      : _viewMode == _DatePickerViewMode.year
                          ? _previousYearBlock
                          : _previousYear,
                  onNext: _viewMode == _DatePickerViewMode.day
                      ? _nextMonth
                      : _viewMode == _DatePickerViewMode.year
                          ? _nextYearBlock
                          : _nextYear,
                ),
              ),
              const SizedBox(height: AppDimens.space16),
              // 内容区：日视图、年月视图或年视图
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _viewMode == _DatePickerViewMode.day
                    ? AppMonthCalendar(
                        key: const ValueKey('day'),
                        size: AppCalendarSize.small,
                        showHeader: false,
                        month: _currentMonth,
                        selected: _selectedDate,
                        accentColor: widget.accent,
                        selectableStart: firstDate,
                        selectableEnd: lastDate,
                        onDayTap: _selectDate,
                      )
                    : _viewMode == _DatePickerViewMode.year
                        ? _YearGrid(
                            key: const ValueKey('year'),
                            currentYear: _currentMonth.year,
                            selectedYear: _selectedDate?.year,
                            accent: widget.accent,
                            onSelect: _selectYear,
                          )
                        : _YearMonthGrid(
                            key: const ValueKey('yearMonth'),
                            currentYear: _currentMonth.year,
                            selectedMonth: _selectedDate != null &&
                                    _selectedDate!.year == _currentMonth.year
                                ? _selectedDate!.month
                                : null,
                            accent: widget.accent,
                            onSelect: _selectYearMonth,
                          ),
              ),
              if (widget.showTime) ...[
                const SizedBox(height: AppDimens.space12),
                _TimeSelector(
                  time: _selectedTime,
                  accent: widget.accent,
                  onChanged: _onTimeChanged,
                ),
              ],
              const SizedBox(height: AppDimens.space20),
              // 底部按钮
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _clear,
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              theme.colorScheme.onSurfaceVariant,
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space12),
                        ),
                        child: const Text('清除'),
                      ),
                    ),
                    const SizedBox(width: AppDimens.space12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _confirm,
                        style: FilledButton.styleFrom(
                          backgroundColor: widget.accent,
                          foregroundColor: theme.colorScheme.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space12),
                        ),
                        child: const Text('确认'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板顶部 iOS 风格头部：图标 + 标题/相对日期副标题
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.selectedDate,
    required this.accent,
    this.showTime = false,
    this.time,
  });

  final DateTime? selectedDate;
  final Color accent;
  final bool showTime;
  final TimeOfDay? time;

  /// 根据选中日期与今天的关系生成副标题
  static String _relativeLabel(DateTime date) {
    final today = DateUtils.dateOnly(DateTime.now());
    final target = DateUtils.dateOnly(date);
    final diff = target.difference(today).inDays;

    if (diff == 0) return '今天';
    if (diff == -1) return '昨天';
    if (diff == 1) return '明天';
    if (diff < 0) return '${-diff}天前';
    return '$diff天后';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final subtitle = selectedDate != null
        ? (showTime && time != null
            ? '${_relativeLabel(selectedDate!)} ${time!.format(context)}'
            : _relativeLabel(selectedDate!))
        : (showTime ? '选择日期时间' : '选择日期');

    return Row(
      children: [
        // 主题强调色日历图标
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.calendar_today_rounded,
            color: accent,
            size: AppDimens.iconSizeMd,
          ),
        ),
        const SizedBox(width: AppDimens.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                showTime ? '日期时间' : '日期',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 标题栏：显示当前年月，点击可切换视图，左右箭头翻页
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.currentMonth,
    required this.viewMode,
    required this.accent,
    required this.onTitleTap,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime currentMonth;
  final _DatePickerViewMode viewMode;
  final Color accent;
  final VoidCallback onTitleTap;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isYear = viewMode == _DatePickerViewMode.year;
    // 年视图：标题显示当前 12 年块范围（与 _YearGrid 网格一致）
    final yearBlockStart = (currentMonth.year ~/ 12) * 12;
    final title = viewMode == _DatePickerViewMode.day
        ? '${currentMonth.year}年${currentMonth.month}月'
        : (isYear
            ? '$yearBlockStart - ${yearBlockStart + 11} 年'
            : '${currentMonth.year}年');

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 可点击的标题：切换年月/日视图
        InkWell(
          onTap: onTitleTap,
          borderRadius: AppShapes.small,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: AppDimens.space4),
                Icon(
                  viewMode == _DatePickerViewMode.day
                      ? Icons.chevron_right_rounded
                      : Icons.expand_less_rounded,
                  size: 20,
                  color: accent,
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            _IconButton(
              icon: Icons.chevron_left_rounded,
              accent: accent,
              onTap: onPrevious,
            ),
            const SizedBox(width: AppDimens.space8),
            _IconButton(
              icon: Icons.chevron_right_rounded,
              accent: accent,
              onTap: onNext,
            ),
          ],
        ),
      ],
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent.withValues(alpha: 0.1),
      borderRadius: AppShapes.small,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShapes.small,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 20, color: accent),
        ),
      ),
    );
  }
}

/// 年月网格视图：4列3行展示12个月份
class _YearMonthGrid extends StatelessWidget {
  const _YearMonthGrid({
    super.key,
    required this.currentYear,
    this.selectedMonth,
    required this.accent,
    required this.onSelect,
  });

  final int currentYear;
  final int? selectedMonth;
  final Color accent;
  final void Function(int year, int month) onSelect;

  static const _monthLabels = [
    '1月',
    '2月',
    '3月',
    '4月',
    '5月',
    '6月',
    '7月',
    '8月',
    '9月',
    '10月',
    '11月',
    '12月',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // wait-home 为响应式列宽（AppBreakpoint）；orbit 仅手机端，取 compact 档 90
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 90,
        childAspectRatio: 1.8,
      ),
      itemCount: 12,
      itemBuilder: (context, index) {
        final month = index + 1;
        final isCurrentMonth = now.year == currentYear && now.month == month;
        final isSelected = selectedMonth == month;

        Color textColor;
        Color bgColor;
        if (isSelected) {
          textColor = theme.colorScheme.surface;
          bgColor = accent;
        } else if (isCurrentMonth) {
          textColor = accent;
          bgColor = accent.withValues(alpha: 0.08);
        } else {
          textColor = theme.colorScheme.onSurface;
          bgColor = Colors.transparent;
        }

        return Center(
          child: InkWell(
            onTap: () => onSelect(currentYear, month),
            borderRadius: AppShapes.full,
            child: Container(
              width: 64,
              height: 36,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: AppShapes.full,
                border: isCurrentMonth && !isSelected
                    ? Border.all(color: accent, width: 1.5)
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                _monthLabels[index],
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: textColor,
                  fontWeight: isSelected || isCurrentMonth
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 年网格视图：3列4行展示以当前年份所在 12 年块（blockStart..blockStart+11）
class _YearGrid extends StatelessWidget {
  const _YearGrid({
    super.key,
    required this.currentYear,
    this.selectedYear,
    required this.accent,
    required this.onSelect,
  });

  final int currentYear;
  final int? selectedYear;
  final Color accent;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final blockStart = (currentYear ~/ 12) * 12;
    final years = List.generate(12, (i) => blockStart + i);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.2,
      ),
      itemCount: years.length,
      itemBuilder: (context, index) {
        final year = years[index];
        final isCurrentYear = now.year == year;
        final isSelected = selectedYear == year;

        Color textColor;
        Color bgColor;
        if (isSelected) {
          textColor = theme.colorScheme.surface;
          bgColor = accent;
        } else if (isCurrentYear) {
          textColor = accent;
          bgColor = accent.withValues(alpha: 0.08);
        } else {
          textColor = theme.colorScheme.onSurface;
          bgColor = Colors.transparent;
        }

        return Center(
          child: InkWell(
            onTap: () => onSelect(year),
            borderRadius: AppShapes.full,
            child: Container(
              width: 84,
              height: 36,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: AppShapes.full,
                border: isCurrentYear && !isSelected
                    ? Border.all(color: accent, width: 1.5)
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                '$year年',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: textColor,
                  fontWeight: isSelected || isCurrentYear
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 时分选择区：时/分两个下拉选择框，点按弹出滚轮弹层选择。
class _TimeSelector extends StatelessWidget {
  const _TimeSelector({
    required this.time,
    required this.accent,
    required this.onChanged,
  });

  final TimeOfDay time;
  final Color accent;
  final ValueChanged<TimeOfDay> onChanged;

  Future<void> _pick(
    BuildContext context, {
    required String title,
    required int itemCount,
    required int current,
    required void Function(int) onPicked,
  }) async {
    final result = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.ofContext(context).popup,
      shape: bottomSheetTopShape,
      builder: (_) => _TimeWheelSheet(
        title: title,
        itemCount: itemCount,
        initialItem: current,
        accent: accent,
      ),
    );
    if (result != null) onPicked(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space20),
      child: Row(
        children: [
          Expanded(
            child: _TimeDropdownField(
              valueKey: 'time_hour_value',
              value: time.hour,
              unit: '时',
              onTap: () => _pick(
                context,
                title: '选择小时',
                itemCount: 24,
                current: time.hour,
                onPicked: (h) => onChanged(TimeOfDay(hour: h, minute: time.minute)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8),
            child: Text(
              ':',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: _TimeDropdownField(
              valueKey: 'time_minute_value',
              value: time.minute,
              unit: '分',
              onTap: () => _pick(
                context,
                title: '选择分钟',
                itemCount: 60,
                current: time.minute,
                onPicked: (m) =>
                    onChanged(TimeOfDay(hour: time.hour, minute: m)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 时/分下拉选择框：值 + 单位 + 下拉箭头，整框可点弹出滚轮。
/// 数值 Text 带 ValueKey：测试用它精确定位，避免与月历日期数字撞文本。
class _TimeDropdownField extends StatelessWidget {
  const _TimeDropdownField({
    required this.valueKey,
    required this.value,
    required this.unit,
    required this.onTap,
  });

  final String valueKey;
  final int value;
  final String unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: AppShapes.medium,
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.35),
          borderRadius: AppShapes.medium,
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    value.toString().padLeft(2, '0'),
                    key: ValueKey(valueKey),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 右侧下拉箭头（视觉上与输入框下拉一致）
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Icon(
                Icons.expand_more_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 滚轮选择弹层：CupertinoPicker 滚动选值，确认返回选中项 index
class _TimeWheelSheet extends StatefulWidget {
  const _TimeWheelSheet({
    required this.title,
    required this.itemCount,
    required this.initialItem,
    required this.accent,
  });

  final String title;

  /// 可选值数量（小时 24 / 分钟 60），值 = index
  final int itemCount;

  /// 初始选中项（对应当前时/分值）
  final int initialItem;

  final Color accent;

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  late int _selected = widget.initialItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.ofContext(context);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppDimens.space20, AppDimens.space16, AppDimens.space8, 0),
            child: Row(
              children: [
                Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: Text(
                    '确认',
                    style: TextStyle(
                      color: widget.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 216,
            child: CupertinoPicker(
              itemExtent: 44,
              scrollController: FixedExtentScrollController(
                initialItem: widget.initialItem,
              ),
              selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
                background: widget.accent.withValues(alpha: 0.08),
              ),
              onSelectedItemChanged: (i) => _selected = i,
              children: [
                for (var i = 0; i < widget.itemCount; i++)
                  Center(
                    child: Text(
                      i.toString().padLeft(2, '0'),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
              ],
            ),
          ),
          // 占位色块避免弹层底部贴边突兀
          Container(height: 8, color: colors.popup),
        ],
      ),
    );
  }
}
