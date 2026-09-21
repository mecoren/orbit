import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';
import 'orbit_month_calendar.dart';

/// 日期选择器初始视图
enum OrbitDatePickerMode { day, month, year }

/// 日期（可选时间）选择器（设计系统 v3：shadcn `SheetConfiguration` 承载面板）。
///
/// 面板：顶部标题（可点切换 日 / 年月 / 年）+ 相对日期副标题 + 清除/确认；
/// 日视图复用 [OrbitMonthCalendar]（medium 档）——因此农历/节气/休班徽标与
/// 日历页**同源同口径**（同一份 `holidayProvider` 缓存传入）。
///
/// 与旧 `WaitDatePicker` 的差异（有意收敛）：
/// - 面板容器由 Material 的 `showModalBottomSheet` 改为 shadcn 的
///   `SheetConfiguration`（浮层机制统一，动画/遮罩/下滑关闭由 shadcn 负责）；
/// - 时分选择由「滚轮 + 下拉」合并为**步进器行**（`- / 数值 / +`），
///   触控目标更大、无需二级弹层，与紧凑表单场景更契合；
/// - 保留 [formatDate] / [formatDateTime] 两个静态格式化入口（调用方按需）。
class OrbitDatePicker {
  OrbitDatePicker._();

  /// `yyyy-MM-dd`
  static String formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// `yyyy-MM-dd HH:mm`
  static String formatDateTime(DateTime date) =>
      '${formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';

  /// 弹出选择器；返回 `null` 表示用户清除或直接关闭（取消）
  static Future<DateTime?> pick(
    BuildContext context, {
    DateTime? initialDate,
    bool showTime = false,
    OrbitDatePickerMode mode = OrbitDatePickerMode.day,
    Color? accent,
  }) async {
    late final sh.OverlayCompleter<DateTime?> completer;
    completer = sh.showOverlay<DateTime>(
      context,
      sh.SheetConfiguration<DateTime>(
        builder: (sheetContext) => _DatePickerSheet(
          initialDate: initialDate,
          showTime: showTime,
          initialMode: mode,
          accent: accent,
          onCancel: completer.close,
          onConfirm: (value) => completer.closeWithResult(value),
          onClear: () => completer.closeWithResult(null),
        ),
      ),
    );
    return completer.future;
  }
}

class _DatePickerSheet extends StatefulWidget {
  const _DatePickerSheet({
    required this.showTime,
    required this.initialMode,
    required this.onCancel,
    required this.onConfirm,
    required this.onClear,
    this.initialDate,
    this.accent,
  });

  final DateTime? initialDate;
  final bool showTime;
  final OrbitDatePickerMode initialMode;
  final Color? accent;
  final VoidCallback onCancel;
  final ValueChanged<DateTime> onConfirm;
  final VoidCallback onClear;

  @override
  State<_DatePickerSheet> createState() => _DatePickerSheetState();
}

class _DatePickerSheetState extends State<_DatePickerSheet> {
  late DateTime _draft = widget.initialDate ?? DateTime.now();
  late DateTime _month = DateTime(_draft.year, _draft.month, 1);
  late OrbitDatePickerMode _mode = widget.initialMode;

  void _cycleMode() {
    setState(() {
      _mode = switch (_mode) {
        OrbitDatePickerMode.day => OrbitDatePickerMode.month,
        OrbitDatePickerMode.month => OrbitDatePickerMode.year,
        OrbitDatePickerMode.year => OrbitDatePickerMode.day,
      };
    });
  }

  String get _title => switch (_mode) {
        OrbitDatePickerMode.day => '${_month.year}年${_month.month}月',
        OrbitDatePickerMode.month => '${_month.year}年',
        OrbitDatePickerMode.year => '选择年份',
      };

  String get _subtitle {
    final today = DateTime.now();
    final diff = DateTime(_draft.year, _draft.month, _draft.day)
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';
    return OrbitDatePicker.formatDate(_draft);
  }

  void _bumpTime({int hours = 0, int minutes = 0}) {
    setState(() {
      _draft = DateTime(_draft.year, _draft.month, _draft.day,
          (_draft.hour + hours) % 24, (_draft.minute + minutes) % 60);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final accent = widget.accent ?? OrbitAccents.themeAccent;
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colors.popup,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppShapes.radiusXl),
          ),
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 拖拽手柄
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: AppDimens.space8),
                    decoration: BoxDecoration(
                      color: colors.deactivatedText.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // 头部：标题（可点切换视图）+ 相对日期副标题 + 清除
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppDimens.space16,
                    AppDimens.space12,
                    AppDimens.space16,
                    AppDimens.space8,
                  ),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: _cycleMode,
                        borderRadius: AppShapes.small,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.space6,
                            vertical: AppDimens.space4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _title,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: colors.titleText,
                                ),
                              ),
                              const SizedBox(width: AppDimens.space4),
                              Icon(
                                OrbitIcons.expandVertical,
                                size: AppDimens.iconSizeSm,
                                color: colors.iconText,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Text(
                        _subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                      const Spacer(),
                      sh.Button.ghost(
                        onPressed: widget.onClear,
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.space12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        switch (_mode) {
                          OrbitDatePickerMode.day => _buildDayView(accent),
                          OrbitDatePickerMode.month => _buildMonthView(accent),
                          OrbitDatePickerMode.year => _buildYearView(accent),
                        },
                        if (widget.showTime) ...[
                          const SizedBox(height: AppDimens.space12),
                          _buildTimeRow(colors, accent),
                        ],
                        const SizedBox(height: AppDimens.space12),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: colors.divider),
                Padding(
                  padding: const EdgeInsets.all(AppDimens.space12),
                  child: Row(
                    children: [
                      Expanded(
                        child: sh.Button.outline(
                          onPressed: widget.onCancel,
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space12),
                      Expanded(
                        child: sh.Button.primary(
                          onPressed: () => widget.onConfirm(_draft),
                          child: const Text('确定'),
                        ),
                      ),
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

  Widget _buildDayView(Color accent) {
    return OrbitMonthCalendar(
      month: _month,
      size: AppCalendarSize.medium,
      selected: _draft,
      accentColor: accent,
      onDayTap: (date) => setState(() {
        _draft = DateTime(
            date.year, date.month, date.day, _draft.hour, _draft.minute);
      }),
      onMonthChange: (focused) => setState(() {
        _month = DateTime(focused.year, focused.month, 1);
      }),
    );
  }

  Widget _buildMonthView(Color accent) {
    final colors = AppColors.ofContext(context);
    final currentMonth =
        (DateTime.now().year == _month.year) ? DateTime.now().month : -1;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 12,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.2,
        mainAxisSpacing: AppDimens.space8,
        crossAxisSpacing: AppDimens.space8,
      ),
      itemBuilder: (context, index) {
        final month = index + 1;
        final selected = month == _month.month;
        final isCurrent = month == currentMonth;
        return InkWell(
          borderRadius: AppShapes.small,
          onTap: () => setState(() {
            _month = DateTime(_month.year, month, 1);
            _mode = OrbitDatePickerMode.day;
          }),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.12) : null,
              borderRadius: AppShapes.small,
              border: Border.all(
                color: selected
                    ? accent
                    : isCurrent
                        ? colors.outline
                        : Colors.transparent,
              ),
            ),
            child: Text(
              '$month月',
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? accent : colors.bodyText,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildYearView(Color accent) {
    final colors = AppColors.ofContext(context);
    final currentYear = DateTime.now().year;
    // 以当前选中年前后各 6 年为一屏，避免无限滚动
    final start = _month.year - 6;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 12,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.2,
        mainAxisSpacing: AppDimens.space8,
        crossAxisSpacing: AppDimens.space8,
      ),
      itemBuilder: (context, index) {
        final year = start + index;
        final selected = year == _month.year;
        return InkWell(
          borderRadius: AppShapes.small,
          onTap: () => setState(() {
            _month = DateTime(year, _month.month, 1);
            _mode = OrbitDatePickerMode.month;
          }),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.12) : null,
              borderRadius: AppShapes.small,
              border: Border.all(
                color: selected
                    ? accent
                    : year == currentYear
                        ? colors.outline
                        : Colors.transparent,
              ),
            ),
            child: Text(
              '$year年',
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? accent : colors.bodyText,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTimeRow(AppColorSet colors, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space12,
        vertical: AppDimens.space8,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: AppShapes.medium,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(OrbitIcons.clock, size: AppDimens.iconSizeSm, color: accent),
          const SizedBox(width: AppDimens.space12),
          _TimeStepper(
            value: _draft.hour,
            onDelta: (d) => _bumpTime(hours: d),
            semanticPrefix: '时',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8),
            child: Text(
              ':',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
              ),
            ),
          ),
          _TimeStepper(
            value: _draft.minute,
            onDelta: (d) => _bumpTime(minutes: d * 5),
            semanticPrefix: '分',
          ),
        ],
      ),
    );
  }
}

/// 时分步进器（- 数值 +；分档步进 5 分钟）
class _TimeStepper extends StatelessWidget {
  const _TimeStepper({
    required this.value,
    required this.onDelta,
    required this.semanticPrefix,
  });

  final int value;
  final ValueChanged<int> onDelta;
  final String semanticPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () => onDelta(-1),
          icon: Icon(
            OrbitIcons.remove,
            size: AppDimens.iconSizeSm,
            color: colors.iconText,
          ),
          tooltip: '$semanticPrefix -1',
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(
          width: 32,
          child: Text(
            value.toString().padLeft(2, '0'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.titleText,
            ),
          ),
        ),
        IconButton(
          onPressed: () => onDelta(1),
          icon: Icon(
            OrbitIcons.add,
            size: AppDimens.iconSizeSm,
            color: colors.iconText,
          ),
          tooltip: '$semanticPrefix +1',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
