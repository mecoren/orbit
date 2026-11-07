/// 滚轮选择弹层（单列数值 / 双列年份范围）
///
/// **2026-11-05 新增**：年份这类「从一长串里挑一个」不再走长列表浮层——
/// 十几项要滚、当前值离首项很远时用户得先滑很久才看见自己；统一改用 miuix
/// 滚轮 [MiuixNumberPicker]（正中选中、上下渐隐缩放、逐项触感、弹簧吸附），
/// 与 `orbit_date_picker.dart` 的时分滚轮同档（44 行高 / 5 项视窗 / 17 号字）。
///
/// 三个入口：
/// - [showOrbitNumberWheelSheet]：单列数值（档位等，值即整数）；
/// - [showOrbitTimeWheelSheet]：时:分双列（24×60，环绕滚动）；
/// - [showOrbitYearRangeWheelSheet]：双列年份范围（起始 / 结束互相钳制，
///   结束年不得早于起始年），返回 [OrbitYearRange]。
///
/// 承载与骨架同全项目底部弹层口径：Material `showModalBottomSheet`
/// （透明底 + 形状/动效常量）+ [OrbitSheetScaffold]（浮起圆角卡片 + 固定尾栏）。
/// 滚轮**不能**包在滚动容器里（垂直拖动会被 `SingleChildScrollView` 抢走），
/// 故内容区一律 `contentScrollable: false`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import 'orbit_sheet_scaffold.dart';
import 'orbit_sheets.dart' show bottomSheetMotion, bottomSheetTopShape;

/// 年份范围（含端点；`start <= end` 由弹层保证）
typedef OrbitYearRange = ({int start, int end});

/// 单列滚轮（app 统一口径：行高 / 视窗 / 字号 / 语义配色）
///
/// 后续新增选择器一律用它，不要在页面里裸用 `MiuixNumberPicker`——
/// 否则字号与配色口径会逐页漂移。
class OrbitWheelColumn extends StatelessWidget {
  const OrbitWheelColumn({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.label,
    this.wrapAround = false,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int>? onChanged;

  /// 每项文案（默认原始数字）；年份传 `(v) => '$v 年'`
  final String Function(int)? label;

  /// 首尾环绕（时分这类周期值传 true：23→0 / 59→0 不用反向滑回来）
  final bool wrapAround;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return MiuixNumberPicker(
      value: value,
      min: min,
      max: max,
      itemHeight: 44,
      visibleItemCount: 5,
      wrapAround: wrapAround,
      label: label,
      textStyle: const TextStyle(fontSize: 17),
      colors: MiuixNumberPickerColors(
        selectedTextColor: colors.titleText,
        unselectedTextColor: colors.secondaryText,
        disabledSelectedTextColor: colors.secondaryText,
        disabledUnselectedTextColor: colors.secondaryText,
      ),
      onValueChanged: onChanged,
    );
  }
}

/// 单列数值滚轮弹层；返回选中值，取消 / 下滑 / 点遮罩返回 `null`
///
/// **滑动即选中**（2026-11-07）：滚轮停稳就自动确认回传并收起抽屉，不需要
/// 再点一次「确认」——单列只有「一个值」这一个自由度，手指离开 + 弹簧吸附到
/// 中心项时选择就已经完成。此前「滑完还得点确认」与项目其它选择器
/// 「点一下即生效」的肌肉记忆冲突（快速添加 → 提醒 → 自定义时间，点开
/// 「时」/「分」各要再点一次确认）。双列 [showOrbitTimeWheelSheet] /
/// [showOrbitYearRangeWheelSheet] 仍保留确认：它们要连着调两列，
/// 自动收起会把第二列打断。
Future<int?> showOrbitNumberWheelSheet(
  BuildContext context, {
  required String title,
  required int value,
  required int min,
  required int max,
  String Function(int)? label,
}) {
  return showModalBottomSheet<int>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // 卡片由骨架自绘，承载必须透明（同 orbit_sheets.dart 口径）
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    elevation: 0,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _SingleWheelSheet(
      title: title,
      value: value,
      min: min,
      max: max,
      label: label,
      onConfirm: (picked) => Navigator.of(sheetContext).pop(picked),
    ),
  );
}

/// 时:分双列滚轮弹层；确认返回 `(hour, minute)`，取消 / 下滑 / 点遮罩返回 `null`
///
/// 两列首尾环绕（23→0 / 59→0）；用于替代 Material `showTimePicker` 的
/// 钟面弹窗（2026-11-05：钟面是裸露的系统外观，与项目弹层口径完全不搭）。
Future<({int hour, int minute})?> showOrbitTimeWheelSheet(
  BuildContext context, {
  required String title,
  required int hour,
  required int minute,
}) {
  return showModalBottomSheet<({int hour, int minute})>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    elevation: 0,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _HourMinuteWheelSheet(
      title: title,
      hour: hour,
      minute: minute,
      onConfirm: (picked) => Navigator.of(sheetContext).pop(picked),
    ),
  );
}

/// 双列年份范围滚轮弹层；确认返回 `(start, end)`，取消 / 下滑 / 点遮罩返回 `null`
///
/// 两列共用 [min]~[max] 的可选区间，且实时互相钳制：起始列上界 = 当前结束年、
/// 结束列下界 = 当前起始年（拖动一格就知道「范围」的边界在哪，不必先选完再撞错）。
Future<OrbitYearRange?> showOrbitYearRangeWheelSheet(
  BuildContext context, {
  required String title,
  required int start,
  required int end,
  required int min,
  required int max,
}) {
  return showModalBottomSheet<OrbitYearRange>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    elevation: 0,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _YearRangeWheelSheet(
      title: title,
      start: start,
      end: end,
      min: min,
      max: max,
      onConfirm: (range) => Navigator.of(sheetContext).pop(range),
    ),
  );
}

class _SingleWheelSheet extends StatefulWidget {
  const _SingleWheelSheet({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onConfirm,
    this.label,
  });

  final String title;
  final int value;
  final int min;
  final int max;
  final String Function(int)? label;
  final ValueChanged<int> onConfirm;

  @override
  State<_SingleWheelSheet> createState() => _SingleWheelSheetState();
}

class _SingleWheelSheetState extends State<_SingleWheelSheet> {
  late int _selected = widget.value.clamp(widget.min, widget.max).toInt();

  /// 滑停后的自动确认定时器
  Timer? _autoConfirm;

  /// 已提交（防定时器与手动「确认」重复 pop）
  bool _committed = false;

  @override
  void dispose() {
    _autoConfirm?.cancel();
    super.dispose();
  }

  /// 滚轮停稳 = 用户已选好，自动回传并收起抽屉
  ///
  /// 停 140ms 再提交：让「中心项放大 / 变主题色」这一帧先落屏，抽屉不会在
  /// 弹簧收尾的同一帧就滑走；这 140ms 内用户再碰一下滚轮即取消
  /// （[Listener.onPointerDown]），继续调值不会被抢走。
  void _scheduleAutoConfirm() {
    _autoConfirm?.cancel();
    _autoConfirm = Timer(const Duration(milliseconds: 140), _commit);
  }

  void _commit() {
    if (!mounted || _committed) return;
    _committed = true;
    widget.onConfirm(_selected);
  }

  void _cancel() {
    _autoConfirm?.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return OrbitSheetScaffold(
      title: widget.title,
      contentScrollable: false,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
      ),
      // `Listener` 只旁听指针按下（不参与手势竞技）：手指再落到滚轮上就撤销
      // 待执行的自动确认，避免「刚想微调就被收走抽屉」
      content: Listener(
        onPointerDown: (_) => _autoConfirm?.cancel(),
        child: OrbitWheelColumn(
          value: _selected,
          min: widget.min,
          max: widget.max,
          label: widget.label,
          onChanged: (v) {
            setState(() => _selected = v);
            _scheduleAutoConfirm();
          },
        ),
      ),
      actions: OrbitSheetActions(
        cancelLabel: '取消',
        onCancel: _cancel,
        confirmLabel: '确认',
        onConfirm: _commit,
      ),
    );
  }
}

class _HourMinuteWheelSheet extends StatefulWidget {
  const _HourMinuteWheelSheet({
    required this.title,
    required this.hour,
    required this.minute,
    required this.onConfirm,
  });

  final String title;
  final int hour;
  final int minute;
  final ValueChanged<({int hour, int minute})> onConfirm;

  @override
  State<_HourMinuteWheelSheet> createState() => _HourMinuteWheelSheetState();
}

class _HourMinuteWheelSheetState extends State<_HourMinuteWheelSheet> {
  /// 两个滚轮的固定 key（widget 测试读当前值 / 定位拖动目标用）
  static const Key hourWheelKey = ValueKey('orbit-time-wheel-hour');
  static const Key minuteWheelKey = ValueKey('orbit-time-wheel-minute');

  late int _hour = widget.hour.clamp(0, 23).toInt();
  late int _minute = widget.minute.clamp(0, 59).toInt();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return OrbitSheetScaffold(
      title: widget.title,
      contentScrollable: false,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
      ),
      content: Row(
        children: [
          Expanded(
            child: OrbitWheelColumn(
              key: hourWheelKey,
              value: _hour,
              min: 0,
              max: 23,
              wrapAround: true,
              label: _twoDigits,
              onChanged: (v) => setState(() => _hour = v),
            ),
          ),
          // 分隔符**不能**用 `Center` 包：Row 的交叉轴约束是松的（上限 = 抽屉
          // 剩余空间），`Center` 无 heightFactor 时会一路撑到上限，反过来把整行
          // 抬成「屏高 85%」——滚轮被居中、上下各留一大片空白（2026-11-05 每日
          // 摘要时刻弹层实测）。文字自身高度即可，垂直居中交给 Row 的
          // crossAxisAlignment。
          SizedBox(
            width: AppDimens.space32,
            child: Text(
              ':',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, color: colors.secondaryText),
            ),
          ),
          Expanded(
            child: OrbitWheelColumn(
              key: minuteWheelKey,
              value: _minute,
              min: 0,
              max: 59,
              wrapAround: true,
              label: _twoDigits,
              onChanged: (v) => setState(() => _minute = v),
            ),
          ),
        ],
      ),
      actions: OrbitSheetActions(
        cancelLabel: '取消',
        onCancel: () => Navigator.of(context).pop(),
        confirmLabel: '确认',
        onConfirm: () => widget.onConfirm((hour: _hour, minute: _minute)),
      ),
    );
  }

  String _twoDigits(int v) => v.toString().padLeft(2, '0');
}

class _YearRangeWheelSheet extends StatefulWidget {
  const _YearRangeWheelSheet({
    required this.title,
    required this.start,
    required this.end,
    required this.min,
    required this.max,
    required this.onConfirm,
  });

  final String title;
  final int start;
  final int end;
  final int min;
  final int max;
  final ValueChanged<OrbitYearRange> onConfirm;

  @override
  State<_YearRangeWheelSheet> createState() => _YearRangeWheelSheetState();
}

class _YearRangeWheelSheetState extends State<_YearRangeWheelSheet> {
  /// 两个滚轮的固定 key（widget 测试读当前值 / 定位拖动目标用）
  static const Key startWheelKey = ValueKey('orbit-year-range-start-wheel');
  static const Key endWheelKey = ValueKey('orbit-year-range-end-wheel');

  late int _start;
  late int _end;

  @override
  void initState() {
    super.initState();
    // 入参先归一到合法区间：结束年不得早于起始年（越界 / 倒挂都钳住）
    _start = widget.start.clamp(widget.min, widget.max).toInt();
    _end = widget.end.clamp(_start, widget.max).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final captionStyle = TextStyle(fontSize: 12, color: colors.secondaryText);
    return OrbitSheetScaffold(
      title: widget.title,
      contentScrollable: false,
      contentPadding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        0,
        AppDimens.space16,
        AppDimens.space8,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 列标签行与滚轮行共用同一三段结构，保证「起始 / 至 / 结束」上下对齐
          Row(
            children: [
              Expanded(
                child: Text(
                  '起始年份',
                  textAlign: TextAlign.center,
                  style: captionStyle,
                ),
              ),
              const SizedBox(width: AppDimens.space32),
              Expanded(
                child: Text(
                  '结束年份',
                  textAlign: TextAlign.center,
                  style: captionStyle,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: OrbitWheelColumn(
                  key: startWheelKey,
                  value: _start,
                  min: widget.min,
                  max: _end,
                  label: _yearLabel,
                  onChanged: (v) => setState(() => _start = v),
                ),
              ),
              // 同 `_HourMinuteWheelSheet` 的 `:`：分隔符不挂 `Center`，否则
              // 会把滚轮行撑到抽屉剩余高度上限（整屉变高、滚轮悬在正中）
              SizedBox(
                width: AppDimens.space32,
                child: Text(
                  '至',
                  textAlign: TextAlign.center,
                  style: captionStyle,
                ),
              ),
              Expanded(
                child: OrbitWheelColumn(
                  key: endWheelKey,
                  value: _end,
                  min: _start,
                  max: widget.max,
                  label: _yearLabel,
                  onChanged: (v) => setState(() => _end = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space12),
          Text(
            '可选 ${widget.min}–${widget.max} 年',
            textAlign: TextAlign.center,
            style: captionStyle,
          ),
        ],
      ),
      actions: OrbitSheetActions(
        cancelLabel: '取消',
        onCancel: () => Navigator.of(context).pop(),
        confirmLabel: '确认',
        onConfirm: () => widget.onConfirm((start: _start, end: _end)),
      ),
    );
  }

  String _yearLabel(int v) => '$v 年';
}
