import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_month_calendar.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../todo/logic/task_logic.dart' show formatDateTime;
import '../todo/providers/todo_providers.dart';

/// 节假日数据缓存查看页 /settings/holidays
///
/// 只读聚合：`cfg_holidays` 本地缓存（放假/补班行）+ `cfg_kv` 更新记账，
/// 与日历页徽标共用同一份 `holidayProvider` 数据。
/// 不进同步白名单。
///
/// 写入口共三处，全部显式联网（自动更新总开关关闭后仅剩这三处）：
/// 1. 「立即更新」——强制拉取自动更新范围内的年份（今年 / 12 月的明年），
///    与日历页手动更新同源 `holidayUpdate`；
/// 2. 「按年份范围获取」——2013 ~ 明年任意区间并发补写历史年份，
///    进度与取消由弹层承载（core 侧分片并发 + 连续失败熔断）；
/// 3. 年份分组标题的「更新该年」——单年整年替换。
class HolidayCachePage extends ConsumerStatefulWidget {
  const HolidayCachePage({super.key});

  @override
  ConsumerState<HolidayCachePage> createState() => _HolidayCachePageState();
}

class _HolidayCachePageState extends ConsumerState<HolidayCachePage> {
  bool _updating = false;

  /// 自动更新总开关交互中（防重复点击）
  bool _autoBusy = false;

  /// 正在补写的单年（null = 空闲；用于该年按钮转圈）
  int? _yearBusy;

  /// 范围补写进行中（防重复发起；进度/取消由 [_HolidayProgressDialog] 承载）
  bool _rangeBusy = false;

  /// 年份补写可选下界（与 core `HOLIDAY_FETCH_YEAR_MIN` 同口径）
  static const int _fetchYearMin = 2013;

  /// 年份补写可选上界（与 core `holiday_fetch_year_max` 同口径 = 明年）
  int get _fetchYearMax => DateTime.now().year + 1;

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

  /// 切换自动更新总开关（关闭后 Rust 调度器不再联网）
  Future<void> _toggleAuto(bool enabled) async {
    if (_autoBusy) return;
    setState(() => _autoBusy = true);
    try {
      await ref.read(orbitBridgeProvider).holidaySetAutoEnabled(enabled);
      ref.invalidate(holidayMetaProvider);
      if (mounted) {
        WaitToast.success(enabled ? '已开启每月自动更新' : '已关闭每月自动更新');
      }
    } catch (_) {
      if (mounted) WaitToast.destructive('保存失败');
    } finally {
      if (mounted) setState(() => _autoBusy = false);
    }
  }

  /// 单年补写：整年替换；`rowCount == 0` 表示线上无数据（AC-E7 按成功处理
  /// 但必须显式提示，不能静默当作「已更新」）
  Future<void> _updateYear(int year) async {
    if (_yearBusy != null || _rangeBusy) return;
    setState(() => _yearBusy = year);
    try {
      final outcome = await ref.read(orbitBridgeProvider).holidayFetchYear(year);
      ref.invalidate(holidayProvider);
      ref.invalidate(holidayMetaProvider);
      if (!mounted) return;
      if (outcome.rowCount == 0) {
        WaitToast.info('$year 年：线上无数据');
      } else {
        WaitToast.success('$year 年已更新（${outcome.rowCount} 条）');
      }
    } catch (e) {
      if (mounted) WaitToast.destructive('$year 年更新失败：$e');
    } finally {
      if (mounted) setState(() => _yearBusy = null);
    }
  }

  /// 选年份范围（先起始后结束；两次单选抽屉，零新原语）
  Future<void> _pickRange() async {
    if (_rangeBusy) return;
    final maxYear = _fetchYearMax;
    final years = [for (var y = _fetchYearMin; y <= maxYear; y++) y];
    int? start;
    await showSelectBottomSheet<int>(
      context,
      title: '起始年份',
      items: [for (final y in years) SelectItem(value: y, label: '$y 年')],
      current: maxYear,
      onSelect: (v) => start = v,
    );
    if (start == null || !mounted) return;
    final from = start!;
    int? end;
    await showSelectBottomSheet<int>(
      context,
      title: '结束年份',
      items: [
        for (final y in years)
          if (y >= from) SelectItem(value: y, label: '$y 年'),
      ],
      current: maxYear,
      onSelect: (v) => end = v,
    );
    if (end == null || !mounted) return;
    await _runRange(from, end!);
  }

  /// 执行范围补写：进度弹层透明承载 core 广播，终态由本方法收口关闭
  ///
  /// 不由弹层自行 pop——弹层与「范围调用返回」是两个独立事件源，
  /// 各自 pop 会撞车（双重 pop 会误关页面上层路由）；统一在此处按调用
  /// 返回时机关闭，语义等价且无竞态。
  ///
  /// 另订阅一份进度流收集**失败年份**：终态 `done` 只带失败计数，「哪一年失败」
  /// 只存在于逐年事件里，汇总 toast 据此如实报出（熔断中止时未尝试年份不发事件，
  /// 故该列表可能短于 `failed` 计数，不得反推「已全部列出」）。
  Future<void> _runRange(int start, int end) async {
    if (_rangeBusy) return;
    setState(() => _rangeBusy = true);
    final navigator = Navigator.of(context, rootNavigator: true);
    final bridge = ref.read(orbitBridgeProvider);
    final failedYears = <int>[];
    final progressSub = bridge.holidayProgress.listen((p) {
      if (p.phase == 'year' && !p.yearOk && !failedYears.contains(p.year)) {
        failedYears.add(p.year);
      }
    });
    final dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _HolidayProgressDialog(),
    );
    HolidayRangeSummary? summary;
    Object? failure;
    try {
      summary = await bridge.holidayFetchRange(start, end);
    } catch (e) {
      failure = e;
    }
    // 广播流事件是**异步投递**的：fetch 返回时「逐年失败年份」的尾包可能还在
    // 投递队列里——先排空一拍再收口，否则此处若立即取消订阅会把未投递的
    // year 事件一起丢掉，部分成功副文案缺失败年份（原实现 await cancel 则
    // 在 widget 测试的 FakeAsync 下把恢复链悬停到树销毁，进度弹层永不收口，
    // 是 holiday_cache_page 两个范围补写用例假红的根因）。
    await Future<void>.delayed(Duration.zero);
    navigator.pop();
    await dialogClosed;
    ref.invalidate(holidayProvider);
    ref.invalidate(holidayMetaProvider);
    if (!mounted) return;
    setState(() => _rangeBusy = false);
    if (failure != null) {
      WaitToast.destructive('范围补写失败：$failure');
      return;
    }
    final s = summary!;
    if (s.cancelled) {
      WaitToast.info('已取消（成功 ${s.ok} 年 · 无数据 ${s.empty} 年）');
    } else if (s.failed > 0) {
      // 部分成功不是错误：warning 级 + 三个计数如实报出，失败年份走副文案
      final parts = ['成功 ${s.ok} 年', '失败 ${s.failed} 年'];
      if (s.empty > 0) parts.add('无数据 ${s.empty} 年');
      final label = _failedYearsLabel(failedYears);
      WaitToast.warning(
        '补写完成：${parts.join(' · ')}',
        description: label.isEmpty ? '失败年份沿用原缓存' : '失败年份：$label（沿用原缓存）',
      );
    } else {
      WaitToast.success('补写完成：成功 ${s.ok} 年 · 无数据 ${s.empty} 年');
    }
    // 订阅清理放收尾（toast 文案已取到 failedYears 快照，取消时机不再敏感）
    unawaited(progressSub.cancel());
  }

  /// 失败年份列表文案（升序、顿号分隔）；空列表返回空串
  String _failedYearsLabel(List<int> years) {
    final sorted = [...years]..sort();
    return sorted.join('、');
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

  /// 缓存概览卡：总数（放假/补班拆分）+ 覆盖年份 + 更新记账 +
  /// 每月自动更新开关 + 立即更新 + 按年份范围获取
  Widget _overviewCard(AppColorSet colors, List<HolidayInfo> holidays) {
    final meta = ref.watch(holidayMetaProvider).value;
    final autoEnabled = meta?.autoEnabled ?? true;
    final off = holidays.where((h) => h.isHoliday).length;
    final work = holidays.length - off;
    final years = _yearsOf(holidays);
    final yearLabel =
        years.length == 1 ? '${years.first}' : '${years.last}–${years.first}';
    final busy = _rangeBusy || _yearBusy != null;
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
            '覆盖年份：$yearLabel',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          Text(
            '上次成功更新：${_stampLabel(meta?.lastUpdateMs)}',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          // 失败态才亮出「上次尝试 + 连续失败」（core 成功一次即清零）：只有失败计数
          // 而没有尝试时刻，用户分不清调度器还在重试还是早已放弃；计数用警示色
          // （与桌面设置页概览同口径：时间戳 muted，计数 warning）
          if ((meta?.failureCount ?? 0) > 0) ...[
            if ((meta?.lastAttemptMs ?? 0) > 0)
              Text(
                '上次尝试：${_stampLabel(meta!.lastAttemptMs)}',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            Text(
              '连续失败 ${meta!.failureCount} 次（旧缓存保留可用）',
              style: TextStyle(fontSize: 12, color: colors.warning),
            ),
          ],
          const Divider(height: AppDimens.space24),
          Row(
            children: [
              Expanded(
                child: Text(
                  '每月自动更新',
                  style: TextStyle(fontSize: 14, color: colors.bodyText),
                ),
              ),
              Switch(
                value: autoEnabled,
                onChanged: _autoBusy ? null : _toggleAuto,
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space4),
          Text(
            autoEnabled
                ? '跨月后下次启动自动补更（今年 / 12 月起的明年）；历史年份用下方按年补写。'
                : '已关闭：仅保留下面的手动更新与按年补写。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space12),
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
          const SizedBox(height: AppDimens.space8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : _pickRange,
              icon: const Icon(OrbitIcons.calendarRange, size: 16),
              label: const Text('按年份范围获取'),
            ),
          ),
          const SizedBox(height: AppDimens.space4),
          Text(
            '可选 $_fetchYearMin–$_fetchYearMax 年；分片并发拉取，连续失败 '
            '3 次自动中止，过程中可随时取消。',
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
        ],
      ),
    );
  }

  /// 按年分组卡：行 = 日期 + 休/班徽标 + 假日名（徽标配色与日历页同源）；
  /// 标题右侧「更新该年」= 单年整年替换
  Widget _yearCard(AppColorSet colors, int year, List<HolidayInfo> items) {
    return SectionCard(
      title: '$year 年（${items.length} 条）',
      trailing: TextButton(
        onPressed:
            (_yearBusy != null || _rangeBusy) ? null : () => _updateYear(year),
        child: _yearBusy == year
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('更新该年'),
      ),
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

/// 范围补写进度弹层（不可点击遮罩关闭；关闭时机由调用方收口）
///
/// 单点消费 `holidayProgressProvider`——bridge 的 `holidayProgress` 每次
/// 订阅都会新建一条 Rust→Dart 流，多处 `watch` 会产生多份监听。
class _HolidayProgressDialog extends ConsumerWidget {
  const _HolidayProgressDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.ofContext(context);
    final progress = ref.watch(holidayProgressProvider).value;
    final total = progress?.total ?? 0;
    final done = progress?.done ?? 0;
    final phase = progress?.phase ?? 'starting';
    final ratio = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
    final label = _phaseLabel(progress);
    return Dialog(
      backgroundColor: colors.popup,
      insetPadding: const EdgeInsets.all(AppDimens.space24),
      shape: const RoundedRectangleBorder(borderRadius: AppShapes.large),
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.space20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '正在补写节假日',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
              ),
            ),
            const SizedBox(height: AppDimens.space8),
            Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.bodyText),
            ),
            const SizedBox(height: AppDimens.space12),
            ClipRRect(
              borderRadius: AppShapes.full,
              child: LinearProgressIndicator(
                value: phase == 'starting' ? null : ratio,
                minHeight: 6,
                backgroundColor: colors.surfaceSecondary,
              ),
            ),
            const SizedBox(height: AppDimens.space16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    ref.read(orbitBridgeProvider).holidayCancelFetch(),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段文案：year 阶段给出「第 n/total 年」+ 该年结果（含空数据提示）
  String _phaseLabel(HolidayProgress? p) {
    if (p == null) return '准备中…';
    switch (p.phase) {
      case 'year':
        final tail = p.yearEmpty ? '（该年无数据）' : '';
        return '第 ${p.done}/${p.total} 年 · ${p.year} 年$tail';
      case 'done':
        // 注意：done 阶段没有 empty 计数（core 的 Done 只带 ok/failed/cancelled），
        // 空数据年份数由终态 toast 的 HolidayRangeSummary 给出
        return p.cancelled
            ? '已取消：成功 ${p.okCount} 年'
            : '完成：成功 ${p.okCount} 年 · 失败 ${p.failed} 年';
      case 'error':
        return p.message.isEmpty ? '补写失败' : p.message;
      default:
        return '共 ${p.total} 年待补写…';
    }
  }
}
