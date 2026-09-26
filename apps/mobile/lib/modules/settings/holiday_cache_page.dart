import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_month_calendar.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../todo/logic/task_logic.dart' show formatDateTime;
import '../todo/providers/todo_providers.dart';

/// 节假日数据缓存查看页 /settings/holidays
///
/// 只读聚合：`cfg_holidays` 本地缓存（放假/补班行）+ `cfg_kv` 更新记账，
/// 与日历页徽标共用同一份 `holidayProvider` 数据。
/// 不进同步白名单、不写库——唯一的写入口是「立即更新」按钮，走既有
/// `holidayUpdate` 桥位（与日历页手动更新同源，成功后双失效刷新）。
class HolidayCachePage extends ConsumerStatefulWidget {
  const HolidayCachePage({super.key});

  @override
  ConsumerState<HolidayCachePage> createState() => _HolidayCachePageState();
}

class _HolidayCachePageState extends ConsumerState<HolidayCachePage> {
  bool _updating = false;

  /// 手动更新（与日历页更新按钮同口径：强制拉取整年，失败旧缓存保留）
  Future<void> _update() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      await ref.read(orbitBridgeProvider).holidayUpdate();
      ref.invalidate(holidayProvider);
      ref.invalidate(holidayMetaProvider);
      if (mounted) WaitToast.success('节假日数据已更新');
    } catch (e) {
      if (mounted) WaitToast.destructive('节假日更新失败：$e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final holidaysAsync = ref.watch(holidayProvider);
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              96,
              AppDimens.space16,
              AppDimens.space24,
            ),
            children: [
              holidaysAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => const EmptyState(
                  message: '节假日缓存加载失败',
                ),
                data: (holidays) {
                  if (holidays.isEmpty) {
                    return const EmptyState(
                      message: '暂无节假日缓存',
                    );
                  }
                  final years = _yearsOf(holidays);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _overviewCard(colors, holidays),
                      for (final year in years) ...[
                        const SizedBox(height: AppDimens.space12),
                        _yearCard(colors, year,
                            holidays.where((h) => h.year == year).toList()),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '节假日数据缓存',
            ),
          ),
        ],
      ),
    );
  }

  /// 缓存年份倒序（最新年在前，与完成日志分组同序）
  List<int> _yearsOf(List<HolidayInfo> holidays) {
    final years = {for (final h in holidays) h.year}.toList();
    years.sort((a, b) => b.compareTo(a));
    return years;
  }

  /// 缓存概览卡：总数（放假/补班拆分）+ 覆盖年份 + 更新记账 + 手动更新
  Widget _overviewCard(AppColorSet colors, List<HolidayInfo> holidays) {
    final meta = ref.watch(holidayMetaProvider).value;
    final off = holidays.where((h) => h.isHoliday).length;
    final work = holidays.length - off;
    final years = _yearsOf(holidays);
    final yearLabel =
        years.length == 1 ? '${years.first}' : '${years.last}–${years.first}';
    return SectionCard(
      title: '缓存概览',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '共 ${holidays.length} 条（放假 $off · 补班 $work）',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colors.bodyText,
            ),
          ),
          const SizedBox(height: AppDimens.space4),
          Text(
            '覆盖年份：$yearLabel · 每日更新时刻：${_hourLabel(meta?.fixedHour)}',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          Text(
            '上次成功更新：${_stampLabel(meta?.lastUpdateMs)}',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          if ((meta?.failureCount ?? 0) > 0)
            Text(
              '连续失败 ${meta!.failureCount} 次（旧缓存保留可用）',
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
          const SizedBox(height: AppDimens.space8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _updating ? null : _update,
              icon: _updating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(OrbitIcons.refresh, size: 16),
              label: Text(_updating ? '更新中…' : '立即更新'),
            ),
          ),
        ],
      ),
    );
  }

  /// 按年分组卡：行 = 日期 + 休/班徽标 + 假日名（徽标配色与日历页同源）
  Widget _yearCard(AppColorSet colors, int year, List<HolidayInfo> items) {
    return SectionCard(
      title: '$year 年（${items.length} 条）',
      child: Column(
        children: [
          for (final h in items) _holidayRow(colors, h),
        ],
      ),
    );
  }

  Widget _holidayRow(AppColorSet colors, HolidayInfo h) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              _mdLabel(h.date),
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            ),
          ),
          Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: h.isHoliday
                  ? ChineseCalendarColors.weekend
                  : ChineseCalendarColors.workdayBadge,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              h.isHoliday ? '休' : '班',
              style: const TextStyle(
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: AppDimens.space8),
          Expanded(
            child: Text(
              h.name,
              style: TextStyle(fontSize: 14, color: colors.bodyText),
            ),
          ),
        ],
      ),
    );
  }

  String _hourLabel(int? hour) =>
      '${(hour ?? 8).toString().padLeft(2, '0')}:00';

  String _stampLabel(int? ms) {
    if (ms == null || ms <= 0) return '从未成功';
    return formatDateTime(ms);
  }

  /// YYYY-MM-DD → M月D日（跨年行自带年份卡，无需重复年份）
  String _mdLabel(String date) {
    final parts = date.split('-');
    if (parts.length != 3) return date;
    return '${int.tryParse(parts[1]) ?? parts[1]}月'
        '${int.tryParse(parts[2]) ?? parts[2]}日';
  }
}
