// 排程作息编辑抽屉（F3 阶段三，docs/13 §五 F3）——工作窗/午休/粒度/兜底
// 时长的逐项选档（选择类交互统一底部抽屉口径）；返回草稿偏好（null = 取消），
// 持久化由调用方经 dayPlanPrefsSet 完成（core 校验钳制并返回存后生效值）。
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';

/// 时间档位（半小时粒度 00:00–23:30）
const List<int> _kTimeOptions = [
  0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 360, 390, 420, 450,
  480, 510, 540, 570, 600, 630, 660, 690, 720, 750, 780, 810, 840, 870, 900,
  930, 960, 990, 1020, 1050, 1080, 1110, 1140, 1170, 1200, 1230, 1260, 1290,
  1320, 1350, 1380, 1410,
];

const List<int> _kGranularityOptions = [5, 10, 15, 30, 60];
const List<int> _kDefaultTaskOptions = [15, 30, 45, 60, 90, 120];

String _hhmm(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

/// 作息编辑抽屉：返回草稿偏好（null = 取消/下滑），持久化由调用方完成
Future<DayPlanPrefs?> showPlanPrefsSheet(
  BuildContext context, {
  required DayPlanPrefs initial,
}) {
  return showModalBottomSheet<DayPlanPrefs>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _PrefsSheet(initial: initial),
  );
}

class _PrefsSheet extends StatefulWidget {
  const _PrefsSheet({required this.initial});

  final DayPlanPrefs initial;

  @override
  State<_PrefsSheet> createState() => _PrefsSheetState();
}

class _PrefsSheetState extends State<_PrefsSheet> {
  late DayPlanPrefs _draft = widget.initial;

  /// 单项选档（当前值描边 + 点选即回调）
  Future<void> _pick(String title, int current, List<int> options,
      String Function(int) label, ValueChanged<int> onPicked) async {
    await showSelectBottomSheet<int>(
      context,
      title: title,
      current: current,
      items: [
        for (final o in options)
          SelectItem(value: o, label: label(o)),
      ],
      onSelect: (v) => setState(() => onPicked(v)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final p = _draft;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.cardPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '排程作息',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '保存在本机（不参与云同步）；越界值保存时自动回落默认',
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
            const SizedBox(height: AppDimens.space8),
            _row(colors, OrbitIcons.calendar, '工作开始',
                _hhmm(p.workStartMinute), () async {
              await _pick('工作开始', p.workStartMinute, _kTimeOptions, _hhmm,
                  (v) => _draft = _copy(p, workStartMinute: v));
            }),
            _row(colors, OrbitIcons.calendar, '工作结束',
                _hhmm(p.workEndMinute), () async {
              await _pick('工作结束', p.workEndMinute, _kTimeOptions, _hhmm,
                  (v) => _draft = _copy(p, workEndMinute: v));
            }),
            _row(colors, OrbitIcons.calendar, '午休开始',
                _hhmm(p.lunchStartMinute), () async {
              await _pick('午休开始', p.lunchStartMinute, _kTimeOptions, _hhmm,
                  (v) => _draft = _copy(p, lunchStartMinute: v));
            }),
            _row(colors, OrbitIcons.calendar, '午休结束',
                _hhmm(p.lunchEndMinute), () async {
              await _pick('午休结束', p.lunchEndMinute, _kTimeOptions, _hhmm,
                  (v) => _draft = _copy(p, lunchEndMinute: v));
            }),
            _row(colors, OrbitIcons.sort, '排程粒度', '${p.granularityMinutes} 分钟',
                () async {
              await _pick('排程粒度', p.granularityMinutes, _kGranularityOptions,
                  (v) => '$v 分钟',
                  (v) => _draft = _copy(p, granularityMinutes: v));
            }),
            _row(colors, OrbitIcons.listChecks, '无时长兜底',
                '${p.defaultTaskMinutes} 分钟', () async {
              await _pick(
                  '无时长兜底', p.defaultTaskMinutes, _kDefaultTaskOptions,
                  (v) => '$v 分钟',
                  (v) => _draft = _copy(p, defaultTaskMinutes: v));
            }),
            _row(colors, OrbitIcons.warning,
                p.includeOverdue ? '逾期任务：纳入排程' : '逾期任务：不排程', '点击切换',
                () async {
              setState(
                  () => _draft = _copy(p, includeOverdue: !p.includeOverdue));
            }),
            const SizedBox(height: AppDimens.space8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_draft),
              child: const Text('保存作息', textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }

  DayPlanPrefs _copy(
    DayPlanPrefs p, {
    int? workStartMinute,
    int? workEndMinute,
    int? lunchStartMinute,
    int? lunchEndMinute,
    int? granularityMinutes,
    int? defaultTaskMinutes,
    bool? includeOverdue,
  }) =>
      DayPlanPrefs(
        workStartMinute: workStartMinute ?? p.workStartMinute,
        workEndMinute: workEndMinute ?? p.workEndMinute,
        lunchStartMinute: lunchStartMinute ?? p.lunchStartMinute,
        lunchEndMinute: lunchEndMinute ?? p.lunchEndMinute,
        granularityMinutes: granularityMinutes ?? p.granularityMinutes,
        defaultTaskMinutes: defaultTaskMinutes ?? p.defaultTaskMinutes,
        includeOverdue: includeOverdue ?? p.includeOverdue,
      );

  Widget _row(AppColorSet colors, IconData icon, String label, String value,
      VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.small,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
        child: Row(
          children: [
            Icon(icon, size: AppDimens.iconSizeMd, color: colors.iconText),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 15, color: colors.titleText)),
            ),
            Text(value,
                style: TextStyle(fontSize: 13, color: colors.secondaryText)),
            const SizedBox(width: AppDimens.space8),
            Icon(OrbitIcons.expandMore,
                size: AppDimens.iconSizeMd, color: colors.secondaryText),
          ],
        ),
      ),
    );
  }
}
