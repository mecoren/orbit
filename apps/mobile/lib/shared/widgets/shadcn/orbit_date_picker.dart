import 'package:flutter/cupertino.dart'
    show CupertinoPicker, CupertinoPickerDefaultSelectionOverlay;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/lunar/chinese_almanac.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';
import '../../../data/api/dto.dart';
import '../../../modules/todo/providers/todo_providers.dart';
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
          // 关闭必须从**弹层内容内部**发起（`closeOverlay(sheetContext, …)`）：
          // `showOverlay` 返回的 `DrawerOverlayCompleter` 没有覆写
          // `closeWithResult`，落到基类实现 `async => remove()`——值被静默丢弃、
          // 弹层以 null 关闭（shadcn_flutter 0.0.53 行为，实测「点确认拿不回选中日」）。
          // `closeOverlay` 走内容侧注入的 completer 适配器，`closeDrawer(ctx, value)`
          // 才真正把结果带到 `completer.future`。
          onCancel: () => sh.closeOverlay(sheetContext),
          onConfirm: (value) => sh.closeOverlay(sheetContext, value),
          onClear: () => sh.closeOverlay(sheetContext),
        ),
      ),
    );
    return completer.future;
  }
}

class _DatePickerSheet extends ConsumerStatefulWidget {
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
  ConsumerState<_DatePickerSheet> createState() => _DatePickerSheetState();
}

class _DatePickerSheetState extends ConsumerState<_DatePickerSheet> {
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

  void _setTime({int? hours, int? minutes}) {
    setState(() {
      _draft = DateTime(_draft.year, _draft.month, _draft.day,
          hours ?? _draft.hour, minutes ?? _draft.minute);
    });
  }

  /// 时分滚轮弹层的二级弹层。
  ///
  /// **不能用 Material `showModalBottomSheet`**：日期面板本身挂在根 `DrawerOverlay`
  /// 上（Navigator 之外），弹层内容里没有 `Navigator` 祖先，Material 路由式弹层
  /// 唤不起来——二级面板同样走 shadcn `SheetConfiguration`（`DrawerOverlay` 支持
  /// 堆叠条目），确认值照旧从内容侧 `closeOverlay` 回传。
  Future<void> _pickTimeWheel({
    required String title,
    required int itemCount,
    required int current,
    required ValueChanged<int> onPicked,
  }) async {
    late final sh.OverlayCompleter<int?> completer;
    completer = sh.showOverlay<int>(
      context,
      sh.SheetConfiguration<int>(
        builder: (sheetContext) => _TimeWheelSheet(
          title: title,
          itemCount: itemCount,
          initialItem: current,
          accent: widget.accent ?? OrbitAccents.themeAccent,
          onConfirm: (value) => sh.closeOverlay(sheetContext, value),
        ),
      ),
    );
    final result = await completer.future;
    if (result != null) onPicked(result);
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
      ),
    );
  }

  Widget _buildDayView(Color accent) {
    // 节假日与日历视图共用同一份 holidayProvider 缓存（cfg_holidays，空库回落
    // Rust 预置表）——面板日格因此能显示休/班徽标，农历副标签同源同口径
    final holidayByDate =
        ref.watch(holidayProvider).value ?? const <HolidayInfo>[];
    return OrbitMonthCalendar(
      month: _month,
      size: AppCalendarSize.medium,
      // 头部由面板标题栏接管（标题可点切换 日/年月/年）
      showHeader: false,
      selected: _draft,
      accentColor: accent,
      weekendColor: ChineseCalendarColors.weekend,
      holidays: {
        for (final e in holidayByDate) e.date: e.isHoliday,
      },
      subLabelBuilder: ChineseAlmanac.daySubLabel,
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
        children: [
          Icon(OrbitIcons.clock, size: AppDimens.iconSizeSm, color: accent),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: _TimeDropdownField(
              valueKey: 'time_hour_value',
              value: _draft.hour,
              unit: '时',
              onTap: () => _pickTimeWheel(
                title: '选择小时',
                itemCount: 24,
                current: _draft.hour,
                onPicked: (h) => _setTime(hours: h),
              ),
            ),
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
          Expanded(
            child: _TimeDropdownField(
              valueKey: 'time_minute_value',
              value: _draft.minute,
              unit: '分',
              onTap: () => _pickTimeWheel(
                title: '选择分钟',
                itemCount: 60,
                current: _draft.minute,
                onPicked: (m) => _setTime(minutes: m),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 时/分下拉选择框：值 + 单位 + 下拉箭头，整框可点弹出滚轮。
///
/// 数值 Text 带 [valueKey]：测试用它精确定位并读值，避免与月历日期数字撞文本。
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
    final colors = AppColors.ofContext(context);
    return InkWell(
      borderRadius: AppShapes.medium,
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: AppShapes.medium,
          border: Border.all(color: colors.outline),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value.toString().padLeft(2, '0'),
              key: ValueKey(valueKey),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: AppDimens.space4),
            Text(
              unit,
              style: TextStyle(fontSize: 11, color: colors.secondaryText),
            ),
            const SizedBox(width: AppDimens.space4),
            // 右侧下拉箭头（与输入框下拉同视觉；弹层内不用 Material Tooltip——
            // 弹层挂在 Navigator 之外，Material 的 RawTooltip 找不到 Overlay 祖先）
            Icon(OrbitIcons.expandMore,
                size: AppDimens.iconSizeMd, color: colors.iconText),
          ],
        ),
      ),
    );
  }
}

/// 滚轮选择弹层：`CupertinoPicker` 滚动选值，确认回传选中项
///
/// 承载在 shadcn `SheetConfiguration` 上（二级弹层，见 `_pickTimeWheel` 说明）。
class _TimeWheelSheet extends StatefulWidget {
  const _TimeWheelSheet({
    required this.title,
    required this.itemCount,
    required this.initialItem,
    required this.accent,
    required this.onConfirm,
  });

  final String title;

  /// 可选值数量（小时 24 / 分钟 60），值 = index
  final int itemCount;

  /// 初始选中项（对应当前时/分值）
  final int initialItem;

  final Color accent;
  final ValueChanged<int> onConfirm;

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  late int _selected = widget.initialItem;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space20,
                  AppDimens.space16,
                  AppDimens.space12,
                  0,
                ),
                child: Row(
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.titleText,
                      ),
                    ),
                    const Spacer(),
                    sh.Button.ghost(
                      onPressed: () => widget.onConfirm(_selected),
                      child: const Text('确认'),
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
                          style: TextStyle(fontSize: 16, color: colors.bodyText),
                        ),
                      ),
                  ],
                ),
              ),
              // 占位色块避免弹层底部贴边突兀
              SizedBox(
                height: AppDimens.space8,
                child: ColoredBox(color: colors.popup),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
