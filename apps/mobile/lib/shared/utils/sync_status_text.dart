/// 云同步状态展示口径（移动端；与桌面 apps/desktop/src/lib/sync-status.ts 同构）
///
/// 纯函数集合：状态派生、时间文案、「下次自动同步」估算、结果摘要。口径约定：
/// - 状态优先级：未配置 > 未就绪（未设置密码或已锁定）> 运行态；
/// - 时间戳为毫秒，展示一律走本地时区（复用 task_logic.formatDateTime，
///   格式 yyyy-MM-dd HH:mm，与设置页同步卡同口径）；
/// - 移动端无后台调度器（配置只存档，手动触发为准），估算值仅供展示；
/// - 与备份链路无关：自动备份 / 全量备份卡片在设置页，本文件不涉及。
library;

import '../../modules/todo/logic/task_logic.dart' show formatDateTime;

/// 云图标展示状态
enum SyncUiStatus { unconfigured, locked, idle, syncing, success, error }

/// 派生展示状态（优先级：未配置 > 未就绪 > 运行态）
SyncUiStatus deriveSyncUiStatus({
  required bool hasConfig,
  required bool hasPassword,
  required bool isUnlocked,
  required SyncUiStatus runStatus,
}) {
  if (!hasConfig) return SyncUiStatus.unconfigured;
  if (!hasPassword || !isUnlocked) return SyncUiStatus.locked;
  return runStatus;
}

/// 状态行文案（locked 区分「未设置密码」与「已锁定」）
String syncStatusLabel(SyncUiStatus status, {bool hasPassword = true}) {
  switch (status) {
    case SyncUiStatus.unconfigured:
      return '未配置云同步';
    case SyncUiStatus.locked:
      return hasPassword ? '同步密码已锁定' : '未设置同步密码';
    case SyncUiStatus.syncing:
      return '正在同步…';
    case SyncUiStatus.success:
      return '同步完成';
    case SyncUiStatus.error:
      return '同步失败';
    case SyncUiStatus.idle:
      return '已就绪';
  }
}

/// 上次同步时间文案；null / <= 0（从未成功记账）→「从未同步」
String formatLastSynced(int? lastSyncedAtMs) {
  if (lastSyncedAtMs == null || lastSyncedAtMs <= 0) return '从未同步';
  return formatDateTime(lastSyncedAtMs);
}

/// 下次自动同步估算时间戳；未启用定时 / 间隔非法 / 无上次同步时间 → null
int? estimateNextSyncAt({
  required bool autoSyncEnabled,
  required int intervalMinutes,
  int? lastSyncedAtMs,
}) {
  if (!autoSyncEnabled || intervalMinutes <= 0) return null;
  if (lastSyncedAtMs == null || lastSyncedAtMs <= 0) return null;
  return lastSyncedAtMs + intervalMinutes * 60000;
}

/// 下次自动同步展示文案
String formatNextSync(int? nextAtMs) =>
    nextAtMs == null ? '未启用定时同步' : '约 ${formatDateTime(nextAtMs)}';

/// 同步结果摘要（成功 toast / 信息面板文案）
String syncResultSummary({
  required int pushedModules,
  required int pulledModules,
  required bool skipped,
  int errorCount = 0,
}) {
  if (skipped) return '已有同步任务在进行中';
  final base = '同步完成：推送 $pushedModules 模块 / 拉取 $pulledModules 模块';
  return errorCount > 0 ? '$base（$errorCount 个非致命错误）' : base;
}
