import 'package:flutter/widgets.dart' show IconData;
import 'package:shadcn_flutter/shadcn_flutter.dart' show LucideIcons;

/// 全应用图标单一取值口（设计系统 v3 —— shadcn 线性图标体系）
///
/// **为什么收口**：Material 图标按「填充/圆角」多套风格混用，笔画粗细与端点不一致；
/// shadcn（Lucide）是单一线性体系，笔画与端点统一，视觉更克制。
/// 视图内**禁止**直接引用 `LucideIcons` / `RadixIcons` / `BootstrapIcons`，
/// 也禁止再出现 Material 的 `Icons.*`——一律经本文件取语义名。
///
/// **命名口径**：按业务用途命名，不按形状命名（`back` 而非 `arrowLeft`）——
/// 换图标集或调形状时只改本文件，调用点语义不变。
///
/// **成员口径**：只保留仓库实际使用的成员（交叉校验 `OrbitIcons.<name>` 与本文件
/// 声明，缺失/冗余都视为破坏）——图标是语义常量不是素材库，留死常量只会让下一个人
/// 绕过语义口径直接引图标集。新增图标时先在此补语义名，再改调用点。
///
/// 尺寸不在这里定义（见 [AppDimens.iconSizeSm] / Md / Lg / Xl），
/// 主题级默认尺寸在 `buildShadcnTheme` 的 IconThemeProperties 中统一映射。
abstract final class OrbitIcons {
  // ── 导航与方向 ──

  static const IconData back = LucideIcons.arrowLeft;
  static const IconData menu = LucideIcons.menu;
  static const IconData chevronRight = LucideIcons.chevronRight;
  static const IconData chevronLeft = LucideIcons.chevronLeft;
  static const IconData expandMore = LucideIcons.chevronDown;
  static const IconData expandLess = LucideIcons.chevronUp;
  static const IconData expandVertical = LucideIcons.chevronsUpDown;

  // ── 通用动作 ──

  static const IconData add = LucideIcons.plus;
  static const IconData remove = LucideIcons.minus;
  static const IconData close = LucideIcons.x;
  static const IconData check = LucideIcons.check;
  static const IconData edit = LucideIcons.pencil;
  static const IconData delete = LucideIcons.trash2;
  static const IconData copy = LucideIcons.copy;
  static const IconData undo = LucideIcons.undo2;
  static const IconData refresh = LucideIcons.refreshCw;
  static const IconData download = LucideIcons.download;
  static const IconData upload = LucideIcons.fileUp;
  static const IconData send = LucideIcons.send;
  static const IconData openExternal = LucideIcons.externalLink;
  static const IconData drag = LucideIcons.gripVertical;
  static const IconData sort = LucideIcons.arrowUpDown;
  static const IconData search = LucideIcons.search;
  static const IconData searchEmpty = LucideIcons.searchX;
  static const IconData filter = LucideIcons.filter;
  static const IconData filterList = LucideIcons.listFilter;
  static const IconData settings = LucideIcons.settings;

  // ── 状态与反馈 ──

  static const IconData info = LucideIcons.info;
  static const IconData success = LucideIcons.circleCheck;
  static const IconData warning = LucideIcons.triangleAlert;
  static const IconData error = LucideIcons.circleAlert;

  /// 收藏态星标
  ///
  /// 线性图标集没有「实心/空心」两套字形，收藏态与未收藏态用同一字形，
  /// 差异由**颜色**表达（收藏 = `OrbitAccents.starYellow`，未收藏 = 次级文字色），
  /// 不再像 Material 图标那样换字形。
  static const IconData star = LucideIcons.star;

  /// 未收藏态星标（与 [star] 同字形，语义上成对，便于调用点自解释）
  static const IconData starOutline = LucideIcons.star;

  /// 可见性（隐藏/显示已完成任务开关）
  static const IconData eye = LucideIcons.eye;
  static const IconData eyeOff = LucideIcons.eyeOff;

  // ── 日历与时间 ──

  static const IconData calendar = LucideIcons.calendar;
  static const IconData calendarDays = LucideIcons.calendarDays;
  static const IconData calendarRange = LucideIcons.calendarRange;
  static const IconData calendarCheck = LucideIcons.calendarCheck;

  /// 事件冲突/到期失效（原 `event_busy_rounded`）
  static const IconData calendarBlocked = LucideIcons.calendarX;
  static const IconData clock = LucideIcons.clock;

  // ── 待办业务 ──

  static const IconData inbox = LucideIcons.inbox;
  static const IconData list = LucideIcons.list;
  static const IconData listChecks = LucideIcons.listChecks;
  static const IconData kanban = LucideIcons.squareKanban;
  static const IconData table = LucideIcons.table;
  static const IconData tableRows = LucideIcons.rows3;
  static const IconData grid = LucideIcons.grid2x2;
  static const IconData layoutGrid = LucideIcons.layoutGrid;
  static const IconData folder = LucideIcons.folder;
  static const IconData tag = LucideIcons.tag;
  static const IconData flag = LucideIcons.flag;
  static const IconData archive = LucideIcons.archive;

  /// 从回收站恢复（原 `restore_from_trash_outlined`）
  static const IconData archiveRestore = LucideIcons.archiveRestore;
  static const IconData circle = LucideIcons.circle;
  static const IconData playCircle = LucideIcons.circlePlay;

  // ── 统计与图表 ──

  static const IconData trending = LucideIcons.trendingUp;
  static const IconData flame = LucideIcons.flame;

  // ── 文件与数据 ──

  static const IconData file = LucideIcons.file;
  static const IconData fileText = LucideIcons.fileText;
  static const IconData image = LucideIcons.image;
  static const IconData braces = LucideIcons.braces;

  // ── 外观与主题 ──

  static const IconData sun = LucideIcons.sun;

  // ── 云同步与安全 ──

  static const IconData cloud = LucideIcons.cloud;
  static const IconData cloudSync = LucideIcons.cloudUpload;
  static const IconData cloudDownload = LucideIcons.cloudDownload;
  static const IconData lock = LucideIcons.lock;
  static const IconData lockOpen = LucideIcons.lockOpen;
  static const IconData shield = LucideIcons.shieldCheck;
  static const IconData fingerprint = LucideIcons.fingerprint;

  // ── 通知与消息 ──

  static const IconData notification = LucideIcons.bell;
  static const IconData notificationOff = LucideIcons.bellOff;
  static const IconData message = LucideIcons.messageSquare;
  static const IconData wrench = LucideIcons.wrench;
}
