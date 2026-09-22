import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../core/theme/icon_map.dart';

/// 冲突记录页 /settings/conflicts（03 文档 §八 遗留项兑现）
///
/// 云同步 LWW 裁决只会留下一个「冲突数」，败方字段过去被静默覆盖丢弃。
/// 本页回看裁决现场：谁覆盖了谁、被覆盖的那一版长什么样，并可一键把败方
/// 内容**恢复为我方版本**（恢复会发起一次新的本地写入，下一轮同步胜出）。
///
/// 数据源 sync_conflicts 为纯本地表（各端各自记录各自的裁决现场，不随同步、
/// 不进备份），口径同桌面端「冲突记录」分区。
class SyncConflictsPage extends ConsumerStatefulWidget {
  const SyncConflictsPage({super.key});

  @override
  ConsumerState<SyncConflictsPage> createState() => _SyncConflictsPageState();
}

class _SyncConflictsPageState extends ConsumerState<SyncConflictsPage> {
  final _scrollController = ScrollController();

  /// null = 全部；'unresolved' = 仅待处理
  String? _resolution = 'unresolved';
  List<SyncConflict> _rows = const [];
  bool _loading = true;
  bool _busy = false;

  /// 展开查看差异的行 id（null = 全部收起）
  int? _expanded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await ref
          .read(orbitBridgeProvider)
          .syncConflictList(_resolution, 200, 0);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _switchFilter(String? resolution) {
    if (_resolution == resolution) return;
    setState(() {
      _resolution = resolution;
      _loading = true;
      _expanded = null;
    });
    _load();
  }

  String _errMsg(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^\[\w+\]\s*'), '');

  Future<void> _restore(SyncConflict row) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '恢复为败方版本？',
      message: '将把「${row.recordTitle.isEmpty ? row.recordUuid : row.recordTitle}」'
          '的内容回放为被覆盖的那一版，并作为一次新的本端修改参与同步。'
          '当前内容会被覆盖，且不会另存副本。',
      confirmLabel: '确认恢复',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).syncConflictRestore(row.id);
      WaitToast.success('已恢复为败方版本；下次同步会以该版本为准');
      await _load();
    } catch (e) {
      WaitToast.destructive('恢复失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss(SyncConflict row) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(orbitBridgeProvider).syncConflictDismiss(row.id);
      await _load();
    } catch (e) {
      WaitToast.destructive('忽略失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '清空冲突记录？',
      message: '将删除全部 ${_rows.length} 条本地冲突记录，此操作不可撤销。'
          '记录仅存于本机，不影响任务数据与云同步。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(orbitBridgeProvider).syncConflictClear(null);
      WaitToast.success('已清空冲突记录（$n 条）');
      await _load();
    } catch (e) {
      WaitToast.destructive('清空失败：${_errMsg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final pending = _rows.where((r) => r.resolution == 'unresolved').length;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              controller: _scrollController,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top +
                    OrbitPageHeader.rowHeight +
                    AppDimens.space16,
                left: AppDimens.space16,
                right: AppDimens.space16,
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                SectionCard(
                  title: '冲突记录',
                  subtitle: _loading ? null : '待处理 $pending 条',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '多端同时改同一条数据时，本端会保留被覆盖的那一版。'
                        '恢复后该版本会作为一次新的本端修改参与同步。本表仅存本机。',
                        style:
                            TextStyle(fontSize: 12, color: colors.secondaryText),
                      ),
                      const SizedBox(height: AppDimens.space12),
                      Row(
                        children: [
                          _filterChip('待处理', 'unresolved'),
                          const SizedBox(width: AppDimens.space8),
                          _filterChip('全部', null),
                          const Spacer(),
                          TextButton(
                            onPressed: (_busy || _rows.isEmpty) ? null : _clear,
                            child: Text('清空',
                                style: TextStyle(color: colors.destructive)),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppDimens.space4),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(AppDimens.space16),
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: OrbitAccents.themeAccent,
                              ),
                            ),
                          ),
                        )
                      else if (_rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppDimens.space16),
                          child: Center(
                            child: Text(
                              '暂无冲突；多端并发修改同一记录后会在这里留档。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12, color: colors.secondaryText),
                            ),
                          ),
                        )
                      else
                        ..._rows.map(_row),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '冲突记录',
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String? value) {
    final selected = _resolution == value;
    return GestureDetector(
      onTap: () => _switchFilter(value),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12, vertical: AppDimens.space6),
        decoration: BoxDecoration(
          color: selected
              ? OrbitAccents.themeAccent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: AppShapes.small,
          border: Border.all(
            color: selected
                ? OrbitAccents.themeAccent
                : AppColors.ofContext(context).divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected
                ? OrbitAccents.themeAccent
                : AppColors.ofContext(context).bodyText,
          ),
        ),
      ),
    );
  }

  Widget _row(SyncConflict r) {
    final colors = AppColors.ofContext(context);
    final loser = _parse(r.loserPayload);
    final winner = _parse(r.winnerPayload);
    final diffs = _diff(loser, winner);
    final open = _expanded == r.id;

    return Padding(
      padding: const EdgeInsets.only(top: AppDimens.space8),
      child: OrbitCard(
        fillColor: colors.surfaceSecondary,
        padding: const EdgeInsets.all(AppDimens.space12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Row(
            children: [
              Icon(OrbitIcons.warning,
                  size: AppDimens.iconSizeMd, color: colors.warning),
              const SizedBox(width: AppDimens.space8),
              Expanded(
                child: Text(
                  r.recordTitle.isEmpty ? r.recordUuid : r.recordTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: colors.bodyText),
                ),
              ),
              if (r.resolution == 'restored')
                Text('已恢复',
                    style: TextStyle(fontSize: 11, color: colors.success))
              else if (r.resolution == 'dismissed')
                Text('已忽略',
                    style: TextStyle(fontSize: 11, color: colors.secondaryText)),
            ],
          ),
          const SizedBox(height: AppDimens.space4),
          Text(
            '${_tableLabel(r.tableName)} · '
            '${r.loserSide == 'local' ? '本端版本被他端覆盖' : '他端版本被本端丢弃'} · '
            '${r.decision == 'tie_version' ? '同毫秒按版本号裁决' : '按修改时间裁决'} · '
            '${_fmtWhen(r.createdAt)}',
            style: TextStyle(fontSize: 11, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space8),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _expanded = open ? null : r.id),
                child: Text(open ? '收起' : '查看差异（${diffs.length}）'),
              ),
              const Spacer(),
              if (r.resolution == 'unresolved') ...[
                OutlinedButton(
                  onPressed: _busy ? null : () => _restore(r),
                  child: const Text('恢复'),
                ),
                const SizedBox(width: AppDimens.space8),
                TextButton(
                  onPressed: _busy ? null : () => _dismiss(r),
                  child: const Text('忽略'),
                ),
              ],
            ],
          ),
          if (open) ...[
            const SizedBox(height: AppDimens.space4),
            OrbitCard(
              fillColor: colors.background,
              padding: const EdgeInsets.all(AppDimens.space8),
              borderRadius: AppShapes.small,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: diffs.isEmpty
                    ? [
                        Text('两侧业务字段无可见差异（差异可能只存在于记录元数据）。',
                            style: TextStyle(
                                fontSize: 11, color: colors.secondaryText)),
                      ]
                    : diffs.map((d) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _fieldLabel(d.key),
                                style: TextStyle(
                                    fontSize: 11, color: colors.secondaryText),
                              ),
                              Text(
                                '当前：${_fmtValue(d.key, d.after)}',
                                style:
                                    TextStyle(fontSize: 12, color: colors.bodyText),
                              ),
                              Text(
                                '被覆盖：${_fmtValue(d.key, d.before)}',
                                style:
                                    TextStyle(fontSize: 12, color: colors.warning),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }

  /// 表名 → 中文（与桌面端 SyncConflictSection 同口径）
  static const _tableLabels = {
    'todo_projects': '项目',
    'todo_tasks': '任务',
    'todo_subtasks': '子任务',
    'todo_labels': '标签',
    'todo_task_labels': '任务标签',
    'todo_comments': '评论',
    'todo_task_relations': '任务关系',
    'todo_reminders': '提醒',
    'todo_task_attachments': '附件关联',
    'todo_saved_filters': '筛选器',
    'todo_templates': '任务模板',
  };

  /// 常见字段 → 中文（未收录的回落原始列名，不隐藏信息）
  static const _fieldLabels = {
    'title': '标题',
    'name': '名称',
    'content': '内容',
    'description': '描述',
    'priority': '优先级',
    'status': '状态',
    'done': '已完成',
    'done_at': '完成时间',
    'due_date': '截止日期',
    'start_date': '开始日期',
    'my_day_date': '我的一天',
    'is_favorite': '收藏',
    'percent_done': '完成度',
    'hex_color': '颜色',
    'is_archived': '已归档',
    'project_id': '所属项目',
    'sort_order': '排序',
    'position': '排序',
    'payload': '模板内容',
    'conditions': '筛选条件',
    'remind_at': '提醒时间',
    'relation_type': '关系类型',
    'hash': '附件',
    'repeat_mode': '重复模式',
    'repeat_after': '重复间隔',
  };

  static String _tableLabel(String table) => _tableLabels[table] ?? table;

  static String _fieldLabel(String key) => _fieldLabels[key] ?? key;

  static String _fmtWhen(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// 值渲染：时间戳类列转本地时间，对象转 JSON，长字符串截断
  static String _fmtValue(String key, Object? v) {

    if (v == null) return '（空）';
    if (v is num &&
        (key.endsWith('_at') || key.endsWith('_date')) &&
        v > 1e11) {
      return _fmtWhen(v.toInt());
    }
    final s = v is Map || v is List ? jsonEncode(v) : '$v';
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  static Map<String, Object?> _parse(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : <String, Object?>{};
    } catch (_) {
      return <String, Object?>{};
    }
  }

  /// 计算「当前（胜方）/ 被覆盖（败方）」的差异字段
  ///
  /// 只看两侧都存在的业务字段（缺键=该侧没有这一列，属列裁剪差异，不作展示）；
  /// 同步元字段（uuid/updated_at/version 等）不展示。
  static List<_FieldDiff> _diff(
    Map<String, Object?> loser,
    Map<String, Object?> winner,
  ) {
    const skip = {
      'uuid',
      'updated_at',
      'version',
      'deleted_at',
      'is_deleted',
      'id',
    };
    final keys = {...loser.keys, ...winner.keys};
    final out = <_FieldDiff>[];
    for (final key in keys) {
      if (skip.contains(key)) continue;
      // 单侧缺键说明是 schema 差异（旧版本同步包少一列），不是用户可见改动
      if (!loser.containsKey(key) || !winner.containsKey(key)) continue;
      if (jsonEncode(loser[key]) == jsonEncode(winner[key])) continue;
      out.add(_FieldDiff(key, winner[key], loser[key]));
    }
    return out;
  }
}

/// 单个差异字段（after = 当前胜方值；before = 被覆盖的败方值）
class _FieldDiff {
  final String key;
  final Object? after;
  final Object? before;

  const _FieldDiff(this.key, this.after, this.before);
}
