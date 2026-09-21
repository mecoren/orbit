import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart' show bottomSheetTopShape;
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突
import 'logic/repeat_logic.dart' as rep;

/// 重复规则编辑结果（抽屉返回值）
class RepeatRuleValue {
  const RepeatRuleValue({
    required this.mode,
    required this.after,
    this.weekdays = 0,
    this.endType = 0,
    this.endParam = 0,
    this.fromDone = false,
  });

  final int mode;
  final int after;

  /// 周档星期几掩码（bit0=周一…bit6=周日；仅 weekly 有意义）
  final int weekdays;

  /// 结束条件（0=永不 1=按日期 2=按次数）
  final int endType;

  /// 结束参数：次数型=剩余次数；日期型=结束日（本地日末毫秒时间戳）
  final int endParam;

  /// 按完成日推进（下次顺延一个完整周期）
  final bool fromDone;
}

/// 重复规则编辑抽屉（详情页信息区「重复」行 + 新建/编辑表单「重复」行共用）
///
/// 视觉与交互对齐桌面端 `task-form-sheet.tsx` 的 RepeatField：
/// - 预设 chips（含「不重复」档）点选即应用并关闭抽屉；
/// - 「自定义」展开面板：间隔 N × 单位（周档附星期几）＋ 结束条件
///   （永不/次数/日期）＋ 完成后推进口径，「确定」一次提交并关闭；
/// - [dueMs] 为当前截止日期锚点（无则不渲染「下次 M月d日」预览徽标）。
/// 两个调用方口径一致：抽屉只回结果，字段落库由调用侧决定（表单暂存 /
/// 详情整组 patch）。
Future<RepeatRuleValue?> showRepeatEditSheet(
  BuildContext context, {
  required int mode,
  required int after,
  int weekdays = 0,
  int endType = 0,
  int endParam = 0,
  bool fromDone = false,
  int? dueMs,
}) {
  final colors = AppColors.ofContext(context);
  return showModalBottomSheet<RepeatRuleValue>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    builder: (_) => _RepeatEditSheet(
      mode: mode,
      after: after,
      weekdays: weekdays,
      endType: endType,
      endParam: endParam,
      fromDone: fromDone,
      dueMs: dueMs,
    ),
  );
}

class _RepeatEditSheet extends StatefulWidget {
  const _RepeatEditSheet({
    required this.mode,
    required this.after,
    required this.weekdays,
    required this.endType,
    required this.endParam,
    required this.fromDone,
    required this.dueMs,
  });

  final int mode;
  final int after;
  final int weekdays;
  final int endType;
  final int endParam;
  final bool fromDone;

  /// 截止日期锚点（毫秒时间戳；「下次」预览与完成引擎同源）
  final int? dueMs;

  @override
  State<_RepeatEditSheet> createState() => _RepeatEditSheetState();
}

class _RepeatEditSheetState extends State<_RepeatEditSheet> {
  /// 既有规则是否非预设组合（如「每 3 天」）→ 「自定义」chip 选中并展开面板
  late final bool _custom = !_isPreset(widget.mode, widget.after);

  /// 自定义面板展开态（「自定义」chip 点按切换；确定后收起）
  late bool _panelOpen = _custom;

  late rep.RepeatUnit _unit = rep.unitForMode(widget.mode);
  late final TextEditingController _intervalController =
      TextEditingController(text: '${widget.after <= 0 ? 1 : widget.after}');
  late int _weekdays = widget.weekdays;
  late int _endOption = widget.endType;
  late final TextEditingController _endCountController = TextEditingController(
    text: widget.endType == rep.RepeatEnd.afterCount && widget.endParam > 0
        ? '${widget.endParam}'
        : '',
  );

  /// 结束日期（日期档的 endParam = 本地日末毫秒时间戳；0 = 未选）
  late int _endDateMs =
      widget.endType == rep.RepeatEnd.onDate && widget.endParam > 0
          ? widget.endParam
          : 0;
  late bool _fromDone = widget.fromDone;

  /// 预设档判定（mode+间隔双匹配；「不重复」不比间隔）
  static bool _isPreset(int mode, int after) => rep.repeatPresets.any(
        (p) => p.mode == mode && (p.mode == rep.RepeatMode.none || after == p.after),
      );

  @override
  void dispose() {
    _intervalController.dispose();
    _endCountController.dispose();
    super.dispose();
  }

  /// 预设档：点选即应用并关闭（扩展字段随预设清空）
  void _pickPreset(rep.RepeatPreset preset) {
    Navigator.of(context).pop(RepeatRuleValue(
      mode: preset.mode,
      after: preset.after,
    ));
  }

  /// 结束条件切换：日期档顺带拉起日期选择（不选则退回未选态）
  Future<void> _pickEndOption(int option) async {
    setState(() => _endOption = option);
    if (option == rep.RepeatEnd.onDate) await _pickEndDate();
  }

  Future<void> _pickEndDate() async {
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: _endDateMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(_endDateMs)
          : DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _endOption = rep.RepeatEnd.onDate;
      // 桌面端同口径：结束日取当日 23:59:59（引擎按「越过结束日即终结」判定）
      _endDateMs =
          DateTime(picked.year, picked.month, picked.day, 23, 59, 59)
              .millisecondsSinceEpoch;
    });
  }

  /// 面板「确定」：自定义组合一次提交并关闭抽屉
  void _applyCustom() {
    final mode = rep.modeForUnit(_unit);
    final n = int.tryParse(_intervalController.text.trim()) ?? 1;
    final count = int.tryParse(_endCountController.text.trim()) ?? 1;
    final hasRepeat = mode != rep.RepeatMode.none;
    // 日期档未选到日期时退化为「永不」，避免下发 0 结束时刻的即刻终结规则
    final endType = _endOption == rep.RepeatEnd.onDate && _endDateMs == 0
        ? rep.RepeatEnd.never
        : _endOption;
    final endParam = switch (endType) {
      rep.RepeatEnd.afterCount => count <= 0 ? 1 : count,
      rep.RepeatEnd.onDate => _endDateMs,
      _ => 0,
    };
    Navigator.of(context).pop(RepeatRuleValue(
      mode: mode,
      after: n <= 0 ? 1 : n,
      weekdays: mode == rep.RepeatMode.weekly ? _weekdays : 0,
      endType: hasRepeat ? endType : rep.RepeatEnd.never,
      endParam: hasRepeat ? endParam : 0,
      fromDone: hasRepeat && _fromDone,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 下次具体日期预览（Things 口径）：规则生效且截止日期已填时展示
    final nextLabel = rep.nextRepeatLabel(
      widget.mode,
      widget.after,
      widget.dueMs,
      DateTime.now().millisecondsSinceEpoch,
      fromDone: widget.fromDone ? 1 : 0,
    );
    return SafeArea(
      top: false,
      child: Padding(
        // 间隔/次数输入聚焦时抬升面板，避免被键盘遮挡
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppDimens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '重复',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(height: AppDimens.space12),
              Wrap(
                spacing: AppDimens.space8,
                runSpacing: AppDimens.space8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final preset in rep.repeatPresets)
                    _RepeatChip(
                      label: preset.label,
                      selected: !_custom &&
                          !_panelOpen &&
                          preset.mode == widget.mode,
                      onTap: () => _pickPreset(preset),
                    ),
                  _RepeatChip(
                    label: _custom
                        ? rep.repeatLabelExt(
                            widget.mode,
                            widget.after,
                            weekdays: widget.weekdays,
                            endType: widget.endType,
                            endParam: widget.endParam,
                            fromDone: widget.fromDone ? 1 : 0,
                          )
                        : '自定义',
                    selected: _custom || _panelOpen,
                    onTap: () => setState(() => _panelOpen = !_panelOpen),
                  ),
                  if (nextLabel != null) _NextBadge(label: '下次 $nextLabel'),
                ],
              ),
              if (_panelOpen) ...[
                const SizedBox(height: AppDimens.space8),
                _buildCustomPanel(colors),
              ],
              SizedBox(height: AppDimens.gestureInsetFallback / 2),
            ],
          ),
        ),
      ),
    );
  }

  /// 自定义面板（对应桌面端 RepeatField 的 customOpen 区）
  Widget _buildCustomPanel(AppColorSet colors) {
    return Container(
      padding: const EdgeInsets.all(AppDimens.space8),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 间隔 N × 单位
          Wrap(
            spacing: AppDimens.space8,
            runSpacing: AppDimens.space8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _NumberBox(
                controller: _intervalController,
                hint: '间隔',
                fieldKey: const ValueKey('repeat_interval_field'),
              ),
              for (final unit in rep.RepeatUnit.values)
                _RepeatChip(
                  label: unit.label,
                  selected: _unit == unit,
                  onTap: () => setState(() => _unit = unit),
                ),
            ],
          ),
          // 周档：星期几多选（bit0=周一…bit6=周日，与 Rust weekday_bit 对齐）
          if (_unit == rep.RepeatUnit.week) ...[
            const SizedBox(height: AppDimens.space8),
            Wrap(
              spacing: AppDimens.space4,
              runSpacing: AppDimens.space4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _RowLabel(text: '星期几', colors: colors),
                for (final (i, name) in rep.weekdayNames.indexed)
                  _RepeatChip(
                    label: name,
                    dense: true,
                    selected: (_weekdays & (1 << i)) != 0,
                    onTap: () => setState(() => _weekdays ^= 1 << i),
                  ),
                if (_weekdays != 0)
                  _RowLabel(text: '（周档 N 周 + 多选星期几）', colors: colors),
              ],
            ),
          ],
          const SizedBox(height: AppDimens.space8),
          // 结束条件：永不 / 次数（余 N 次）/ 日期（结束日）
          Wrap(
            spacing: AppDimens.space8,
            runSpacing: AppDimens.space8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _RowLabel(text: '结束', colors: colors),
              _RepeatChip(
                label: '永不',
                dense: true,
                selected: _endOption == rep.RepeatEnd.never,
                onTap: () => setState(() => _endOption = rep.RepeatEnd.never),
              ),
              _RepeatChip(
                label: '次数',
                dense: true,
                selected: _endOption == rep.RepeatEnd.afterCount,
                onTap: () => _pickEndOption(rep.RepeatEnd.afterCount),
              ),
              _RepeatChip(
                label: '日期',
                dense: true,
                selected: _endOption == rep.RepeatEnd.onDate,
                onTap: () => _pickEndOption(rep.RepeatEnd.onDate),
              ),
              if (_endOption == rep.RepeatEnd.afterCount)
                _NumberBox(
                  controller: _endCountController,
                  hint: '次数',
                  width: 56,
                  fieldKey: const ValueKey('repeat_end_count_field'),
                ),
              if (_endOption == rep.RepeatEnd.onDate)
                _RepeatChip(
                  label: _endDateMs > 0 ? _formatDay(_endDateMs) : '选择日期',
                  dense: true,
                  selected: _endDateMs > 0,
                  onTap: _pickEndDate,
                ),
            ],
          ),
          const SizedBox(height: AppDimens.space8),
          // 完成后推进口径（默认按原排程节奏，勾选后按实际完成日顺延）
          Wrap(
            spacing: AppDimens.space8,
            runSpacing: AppDimens.space8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _RowLabel(text: '完成后', colors: colors),
              _RepeatChip(
                label: '按完成日推进',
                dense: true,
                selected: _fromDone,
                onTap: () => setState(() => _fromDone = !_fromDone),
              ),
              _RowLabel(
                text: _fromDone ? '下次 = 完成后一个完整周期' : '下次 = 按原排程节奏',
                colors: colors,
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space4),
          // 确定：仅收自定义面板（左侧对齐，对齐桌面端 ghost 按钮位）
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _applyCustom,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space12,
                  vertical: AppDimens.space6,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: OrbitAccents.themeAccent,
              ),
              child: const Text(
                '确定',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 毫秒时间戳 → 「yyyy/M/d」（结束日期 chip 回显）
  static String _formatDay(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}/${d.month}/${d.day}';
  }
}

/// 下次日期预览徽标（强调色底 10% + 强调色字，对齐桌面端 RepeatField 的
/// `bg-primary/10 text-primary` 小徽标；无描边、不可点）
class _NextBadge extends StatelessWidget {
  const _NextBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space8,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: OrbitAccents.themeAccent.withValues(alpha: 0.1),
        borderRadius: AppShapes.small,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: OrbitAccents.themeAccent,
        ),
      ),
    );
  }
}

/// 选项 chip：选中 = 主题强调色描边 + 10% 底色（对齐桌面端 primary 档式样）
///
/// [dense] 用于面板内的次级档（星期几/结束/完成后），字号与内边距各收一档。
class _RepeatChip extends StatelessWidget {
  const _RepeatChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final accent = OrbitAccents.themeAccent;
    return Material(
      color: selected ? accent.withValues(alpha: 0.1) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.small,
        side: BorderSide(color: selected ? accent : colors.divider),
      ),
      child: InkWell(
        borderRadius: AppShapes.small,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? AppDimens.space8 : 10,
            vertical: dense ? 5 : 6,
          ),
          // 收缩包裹（width/heightFactor=1）：Wrap 给的是宽松约束，
          // 裸 Align/Container(alignment) 会撑满整行导致每个 chip 独占一行
          child: Align(
            alignment: Alignment.center,
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: dense ? 12 : 13,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                color: selected ? accent : colors.secondaryText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板内数字输入框（间隔 / 次数）：与 chip 同高的窄盒，无边框样式由外层容器给
class _NumberBox extends StatelessWidget {
  const _NumberBox({
    required this.controller,
    required this.hint,
    this.width = 64,
    this.fieldKey,
  });

  final TextEditingController controller;
  final String hint;
  final double width;

  /// 输入框 ValueKey（测试精确定位用；表单自身也有 TextField，不能靠顺序取）
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Container(
      width: width,
      height: 32,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.small,
        border: Border.all(color: colors.divider),
      ),
      child: TextField(
        key: fieldKey,
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: colors.bodyText),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontSize: 13, color: colors.deactivatedText),
          filled: false,
          isDense: true,
          counterText: '',
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }
}

/// 面板内行前缀标签（星期几 / 结束 / 完成后）与灰字说明
class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.text, required this.colors});

  final String text;
  final AppColorSet colors;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: colors.secondaryText),
    );
  }
}
