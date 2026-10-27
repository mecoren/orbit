import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';

/// 三档规模：首屏联调 / 常规翻页与看板 / 统计与滚动压力（与桌面同档）
const _scales = [300, 1200, 5000];

/// 测试数据页 /settings/test-data（仅 debug 构建可见）
///
/// 口径与桌面「设置 → 测试数据」一致：
/// - **两道环境门禁**：入口由设置页按 [kDebugMode] 决定是否渲染，本页再自检一次
///   （兜住被别处直接 push 的情况）；Rust 桥层在 release 下返回「不可用」错误；
/// - **两步确认 + 冷静期**：与桌面 `test-data-confirm.ts` 同文案同步骤——第 1 步
///   说明影响范围（确认钮「继续」），第 2 步标题带「再次确认」并复述后果（确认钮
///   「确认生成 / 确认清除」）；两步都走 `holdSeconds: 3`（确认钮先禁用并倒数
///   「请阅读后果（Ns）」，与桌面 `DangerousConfirmDialog` 的 3 秒冷静期同口径）；
/// - **幂等**：生成前由 core 按 uuid 前缀（`dev-seed-`）清掉上一批，标题统一带
///   `【示例】` 前缀；手工数据不在操作范围内，重复点击不会叠数据；
/// - **写库后刷新**：core 提交后补发 db-change，壳层失效链（db_invalidation）
///   自动刷新列表与统计，本页不手工 refetch。
class TestDataPage extends ConsumerStatefulWidget {
  const TestDataPage({super.key});

  @override
  ConsumerState<TestDataPage> createState() => _TestDataPageState();
}

class _TestDataPageState extends ConsumerState<TestDataPage> {
  int _tasks = 1200;

  /// 进行中的动作（'seed' / 'clear'；null = 空闲），防重复点击
  String? _busy;

  DevSeedResult? _seeded;
  DevSeedClearResult? _cleared;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  OrbitPageHeader.rowHeight +
                  AppDimens.space16,
              left: AppDimens.pageInline,
              right: AppDimens.pageInline,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            children: kDebugMode
                ? _buildContent(colors)
                : [
                    SectionCard(
                      title: '测试数据',
                      child: Text(
                        '当前不是开发构建，测试数据功能不可用。',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.secondaryText,
                        ),
                      ),
                    ),
                  ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(title: '测试数据'),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildContent(AppColorSet colors) => [
        SectionCard(
          title: '生成规模',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '一键写入覆盖各读通道的示例项目 / 标签 / 任务 / 子任务 / 提醒 / '
                '评论 / 关联。子任务等按固定比例派生；日期档覆盖已完成、逾期、'
                '今天到期、未来 30 天与无日期。',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              const SizedBox(height: AppDimens.space12),
              Wrap(
                spacing: AppDimens.space8,
                runSpacing: AppDimens.space8,
                children: [
                  for (final n in _scales)
                    ChoiceChip(
                      label: Text('${_formatCount(n)} 条任务'),
                      selected: _tasks == n,
                      onSelected: _busy == null
                          ? (_) => setState(() => _tasks = n)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: AppDimens.space12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy == null ? _seed : null,
                      icon: _busy == 'seed'
                          ? _spinner()
                          : const Icon(OrbitIcons.add,
                              size: AppDimens.iconSizeSm),
                      label: const Text('一键生成'),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy == null ? _clear : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.destructive,
                      ),
                      icon: _busy == 'clear'
                          ? _spinner()
                          : const Icon(OrbitIcons.delete,
                              size: AppDimens.iconSizeSm),
                      label: const Text('清除示例'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.space8),
              Text(
                '生成与清除都需要连续确认两次（第 1 步说明范围，第 2 步再次确认），'
                '每步确认钮有 3 秒冷静期；示例数据可随时整批清除，与手工数据互不影响。',
                style: TextStyle(fontSize: 11, color: colors.secondaryText),
              ),
            ],
          ),
        ),
        if (_seeded != null) ...[
          const SizedBox(height: AppDimens.cardGap),
          SectionCard(
            title: '生成结果',
            child: _buildResult(
              colors,
              '已写入 ${_formatCount(_seeded!.created.total)} 行',
              '用时 ${_seeded!.elapsedMs} ms'
                  '${_seeded!.cleared.total > 0 ? '，先清掉上一批 ${_formatCount(_seeded!.cleared.total)} 行' : ''}',
              _seeded!.created,
            ),
          ),
        ],
        if (_cleared != null) ...[
          const SizedBox(height: AppDimens.cardGap),
          SectionCard(
            title: '清理结果',
            child: _buildResult(
              colors,
              '已清除 ${_formatCount(_cleared!.removed.total)} 行',
              '用时 ${_cleared!.elapsedMs} ms；手工数据不受影响',
              _cleared!.removed,
            ),
          ),
        ],
        const SizedBox(height: AppDimens.cardGap),
        Text(
          '示例数据的标题带「【示例】」前缀、uuid 以 dev-seed- 开头，便于与手工'
          '数据区分；生产构建不显示本页，桥层在 release 下也会拒绝执行。',
          style: TextStyle(fontSize: 11, color: colors.secondaryText),
        ),
      ];

  /// 结果明细（生成与清理共用；只显示非零项，顺序与阅读习惯一致）
  Widget _buildResult(
    AppColorSet colors,
    String title,
    String subtitle,
    DevSeedCounts counts,
  ) {
    final rows = [
      ('项目', counts.projects),
      ('标签', counts.labels),
      ('任务（含回收站）', counts.tasks),
      ('子任务', counts.subtasks),
      ('提醒', counts.reminders),
      ('评论', counts.comments),
      ('标签关联', counts.taskLabels),
      ('任务关联', counts.taskRelations),
    ].where((row) => row.$2 > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colors.bodyText,
          ),
        ),
        const SizedBox(height: AppDimens.space4),
        Text(subtitle, style: TextStyle(fontSize: 11, color: colors.secondaryText)),
        const SizedBox(height: AppDimens.space8),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.secondaryText,
                    ),
                  ),
                ),
                Text(
                  _formatCount(value),
                  style: TextStyle(
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: colors.bodyText,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 两步确认文案（与桌面 `test-data-confirm.ts` 同步步骤与标题口径；
  /// 第二步提到的按钮名跟随移动端实际标签「清除示例」）
  ({String title, String message, String confirmLabel}) _confirmCopy(
    String action,
    int step,
  ) {
    final isSeed = action == 'seed';
    if (step == 1) {
      return (
        title: isSeed ? '生成示例数据（第 1 步 / 共 2 步）' : '清除示例数据（第 1 步 / 共 2 步）',
        message: isSeed
            ? '将写入约 ${_formatCount(_tasks)} 条示例任务，以及按固定比例派生的'
                '子任务、提醒、评论、标签关联与任务关联；生成前会先清掉上一批'
                '示例数据，手工数据不受影响。'
            : '将删除库中 uuid 以 dev-seed- 开头的全部示例行（项目、标签、任务、'
                '子任务、提醒、评论、关联），手工数据不受影响。',
        confirmLabel: '继续',
      );
    }
    return (
      title: isSeed ? '再次确认生成（第 2 步 / 共 2 步）' : '再次确认清除（第 2 步 / 共 2 步）',
      message: isSeed
          ? '再确认一次：本次会先删掉上一批示例数据，再写入 ${_formatCount(_tasks)} '
              '条任务；写入后可在本页用「清除示例」撤销。'
          : '再确认一次：删除是物理删除、不可撤销，确认后需重新生成才能恢复示例数据。',
      confirmLabel: isSeed ? '确认生成' : '确认清除',
    );
  }

  /// 连续两次独立确认；任一步取消/页面已退出都停止（不做写库）
  Future<bool> _confirmTwice(String action, {required bool destructive}) async {
    for (var step = 1; step <= 2; step++) {
      final copy = _confirmCopy(action, step);
      final ok = await showConfirmBottomSheet(
        context,
        title: copy.title,
        message: copy.message,
        confirmLabel: copy.confirmLabel,
        // 每步都强制 3 秒冷静期（与桌面 holdSeconds=3 同口径）
        holdSeconds: 3,
        // 破坏性色只用在第二步：第一步是「说明」，不该看起来已经在删
        destructive: destructive && step == 2,
      );
      if (!ok || !mounted) return false;
    }
    return true;
  }

  Future<void> _seed() async {
    if (!await _confirmTwice('seed', destructive: false)) return;

    setState(() => _busy = 'seed');
    try {
      final result = await ref
          .read(orbitBridgeProvider)
          .devSeedDemoData(DevSeedPlan(tasks: _tasks));
      if (!mounted) return;
      setState(() {
        _seeded = result;
        _cleared = null;
      });
      WaitToast.global(
        '已写入 ${_formatCount(result.created.total)} 行示例数据',
        variant: WaitToastVariant.success,
        description: '用时 ${result.elapsedMs} ms；列表与统计已自动刷新',
      );
    } catch (e) {
      if (!mounted) return;
      WaitToast.global(
        '生成测试数据失败',
        variant: WaitToastVariant.destructive,
        description: _errorText(e),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _clear() async {
    if (!await _confirmTwice('clear', destructive: true)) return;

    setState(() => _busy = 'clear');
    try {
      final result = await ref.read(orbitBridgeProvider).devSeedClear();
      if (!mounted) return;
      setState(() {
        _cleared = result;
        _seeded = null;
      });
      WaitToast.global(
        '已清除 ${_formatCount(result.removed.total)} 行示例数据',
        variant: WaitToastVariant.success,
        description: '用时 ${result.elapsedMs} ms；手工数据不受影响',
      );
    } catch (e) {
      if (!mounted) return;
      WaitToast.global(
        '清除测试数据失败',
        variant: WaitToastVariant.destructive,
        description: _errorText(e),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _spinner() => SizedBox(
        width: AppDimens.iconSizeSm,
        height: AppDimens.iconSizeSm,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );

  /// 桥层异常文案（去掉 Dart 的 `Exception: ` 前缀，与设置页其他错误提示同口径）
  String _errorText(Object e) {
    final text = e.toString();
    const prefix = 'Exception: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}

/// 行数格式化（千分位；与诊断页 `formatCount` 同口径）
String _formatCount(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
