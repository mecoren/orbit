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
  // 无任何推拉且无错误 = 本轮无新变化（数据早已同步完成），
  // 直说“已是最新”，避免“推送 0 模块”被误读为同步失败（与桌面端同口径）
  if (pushedModules == 0 && pulledModules == 0 && errorCount == 0) {
    return '同步完成：已是最新，无需同步';
  }
  final base = '同步完成：推送 $pushedModules 模块 / 拉取 $pulledModules 模块';
  return errorCount > 0 ? '$base（$errorCount 个非致命错误）' : base;
}

/// 同步错误 tag → 用户处置通道（F44，与桌面 `syncErrorAction` 同口径）
enum SyncErrorAction { recovery, unlock, upgrade, none }

/// 从桥层错误串提取 tag（Rust 侧 `[tag] message` 前缀；无标签返回空串）
String syncErrorTag(String raw) {
  final m = RegExp(r'^\[(\w+)\]').firstMatch(raw.trim());
  return m?.group(1) ?? '';
}

/// 错误 tag 到处置动作的归类
///
/// - `recovery`（key_mismatch）：本地密钥解不开云端密文，引导密钥包恢复；
/// - `unlock`（password / not_unlocked）：引导重输同步密码；
/// - `upgrade`（payload_version）：云端载荷版本高于本端（ADR 0010 两拍升级），
///   处置动作是**升级应用**——若不单独归类而塌进 key_mismatch，用户会被
///   引到密钥恢复流程并可能放弃解不开的云端数据（误导且不可逆）；
/// - `none`：网络 / 数据库 / 认证 / 限流等普通失败，按原文提示。
SyncErrorAction syncErrorAction(String tag) => switch (tag) {
      'key_mismatch' => SyncErrorAction.recovery,
      'password' || 'not_unlocked' => SyncErrorAction.unlock,
      'payload_version' => SyncErrorAction.upgrade,
      _ => SyncErrorAction.none,
    };
