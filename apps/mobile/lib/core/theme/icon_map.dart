import 'package:flutter/widgets.dart' show IconData;
import 'package:shadcn_flutter/shadcn_flutter.dart' show LucideIcons;

/// 全应用图标单一取值口（设计系�?v3 —�?shadcn 线性图标体系）
///
/// 为什么收口：Material 图标按「填�?圆角」多套风格混用，笔画粗细与端点不一致，
/// �?shadcn（Lucide）是单一线性体系、笔画与端点统一，视觉上更克制�?
/// 视图�?*禁止**直接引用 `LucideIcons` / `RadixIcons` / `BootstrapIcons`�?
/// 也禁止再出现 Material �?`Icons.*`——一律经本文件取语义名�?
///
/// 命名口径�?*按业务用途命名，不按形状命名**（`back` 而非 `arrowLeft`）—�?
/// 换图标集或调形状时只改本文件，调用点语义不变�?
///
/// 尺寸不在这里定义（见 [AppDimens.iconSizeSm] / Md / Lg / Xl），
/// 主题级默认尺寸在 [buildShadcnTheme] �?IconThemeProperties 中统一映射�?
abstract final class OrbitIcons {
  // ── 导航与方�?──

  static const IconData back = LucideIcons.arrowLeft;
  static const IconData forward = LucideIcons.arrowRight;
  static const IconData menu = LucideIcons.menu;
  static const IconData chevronRight = LucideIcons.chevronRight;
  static const IconData chevronLeft = LucideIcons.chevronLeft;
  static const IconData expandMore = LucideIcons.chevronDown;
  static const IconData expandLess = LucideIcons.chevronUp;
  static const IconData expandVertical = LucideIcons.chevronsUpDown;
  static const IconData arrowUp = LucideIcons.arrowUp;
  static const IconData arrowDown = LucideIcons.arrowDown;

  // ── 通用动作 ──

  static const IconData add = LucideIcons.plus;
  static const IconData remove = LucideIcons.minus;
  static const IconData close = LucideIcons.x;
  static const IconData check = LucideIcons.check;
  static const IconData checkAll = LucideIcons.checkCheck;
  static const IconData edit = LucideIcons.pencil;
  static const IconData editBox = LucideIcons.squarePen;
  static const IconData delete = LucideIcons.trash2;
  static const IconData copy = LucideIcons.copy;
  static const IconData undo = LucideIcons.undo2;
  static const IconData restore = LucideIcons.rotateCcw;
  static const IconData refresh = LucideIcons.refreshCw;
  static const IconData download = LucideIcons.download;
  static const IconData upload = LucideIcons.fileUp;
  static const IconData send = LucideIcons.send;
  static const IconData openExternal = LucideIcons.externalLink;
  static const IconData more = LucideIcons.ellipsisVertical;
  static const IconData moreHorizontal = LucideIcons.ellipsis;
  static const IconData drag = LucideIcons.gripVertical;
  static const IconData sort = LucideIcons.arrowUpDown;
  static const IconData search = LucideIcons.search;
  static const IconData searchEmpty = LucideIcons.searchX;
  static const IconData filter = LucideIcons.filter;
  static const IconData filterList = LucideIcons.listFilter;
  static const IconData settings = LucideIcons.settings;
  static const IconData pin = LucideIcons.pin;
  static const IconData palette = LucideIcons.palette;
  static const IconData fontSize = LucideIcons.type;
  static const IconData attach = LucideIcons.paperclip;
  static const IconData camera = LucideIcons.camera;
  static const IconData image = LucideIcons.image;
  static const IconData link = LucideIcons.link;
  static const IconData scan = LucideIcons.scan;
  static const IconData presentation = LucideIcons.presentation;

  // ── 状态与反馈 ──

  static const IconData info = LucideIcons.info;
  static const IconData success = LucideIcons.circleCheck;
  static const IconData warning = LucideIcons.triangleAlert;
  static const IconData error = LucideIcons.circleAlert;
  static const IconData loading = LucideIcons.loaderCircle;
  static const IconData star = LucideIcons.star;
  static const IconData starOutline = LucideIcons.starOff;

  // ── 日历与时�?──

  static const IconData calendar = LucideIcons.calendar;
  static const IconData calendarDays = LucideIcons.calendarDays;
  static const IconData calendarRange = LucideIcons.calendarRange;
  static const IconData calendarCheck = LucideIcons.calendarCheck;
  static const IconData calendarBlocked = LucideIcons.calendarX;
  static const IconData clock = LucideIcons.clock;
  static const IconData timer = LucideIcons.timer;
  static const IconData alarm = LucideIcons.alarmClock;
  static const IconData history = LucideIcons.history;
  static const IconData repeat = LucideIcons.repeat;

  // ── 待办业务 ──

  static const IconData inbox = LucideIcons.inbox;
  static const IconData list = LucideIcons.list;
  static const IconData listChecks = LucideIcons.listChecks;
  static const IconData listOrdered = LucideIcons.listOrdered;
  static const IconData listTodo = LucideIcons.listTodo;
  static const IconData listEmpty = LucideIcons.listX;
  static const IconData kanban = LucideIcons.squareKanban;
  static const IconData table = LucideIcons.table;
  static const IconData tableRows = LucideIcons.rows3;
  static const IconData columns = LucideIcons.columns3;
  static const IconData grid = LucideIcons.grid2x2;
  static const IconData layoutGrid = LucideIcons.layoutGrid;
  static const IconData folder = LucideIcons.folder;
  static const IconData folderOpen = LucideIcons.folderOpen;
  static const IconData tag = LucideIcons.tag;
  static const IconData flag = LucideIcons.flag;
  static const IconData ticket = LucideIcons.ticket;
  static const IconData hash = LucideIcons.hash;
  static const IconData sticker = LucideIcons.sticker;
  static const IconData archive = LucideIcons.archive;
  static const IconData archiveRestore = LucideIcons.archiveRestore;
  static const IconData clipboard = LucideIcons.clipboardList;
  static const IconData circle = LucideIcons.circle;
  static const IconData circleDot = LucideIcons.circleDot;
  static const IconData circleSmall = LucideIcons.circleSmall;
  static const IconData playCircle = LucideIcons.circlePlay;

  // ── 统计与图�?──

  static const IconData trending = LucideIcons.trendingUp;
  static const IconData chartLine = LucideIcons.chartLine;
  static const IconData chartColumn = LucideIcons.chartColumn;
  static const IconData chartPie = LucideIcons.chartPie;
  static const IconData activity = LucideIcons.activity;
  static const IconData flame = LucideIcons.flame;
  static const IconData target = LucideIcons.target;
  static const IconData gauge = LucideIcons.gauge;
  static const IconData scale = LucideIcons.scale;
  static const IconData ruler = LucideIcons.ruler;

  // ── 文件与数�?──

  static const IconData file = LucideIcons.file;
  static const IconData fileText = LucideIcons.fileText;
  static const IconData braces = LucideIcons.braces;
  static const IconData database = LucideIcons.database;
  static const IconData alignLeft = LucideIcons.alignLeft;
  static const IconData text = LucideIcons.text;

  // ── 外观与主�?──

  static const IconData sun = LucideIcons.sun;
  static const IconData sunMedium = LucideIcons.sunMedium;
  static const IconData moon = LucideIcons.moon;
  static const IconData moonStar = LucideIcons.moonStar;
  static const IconData contrast = LucideIcons.contrast;
  static const IconData sparkles = LucideIcons.sparkles;
  static const IconData wand = LucideIcons.wand;
  static const IconData wandSparkles = LucideIcons.wandSparkles;
  static const IconData zap = LucideIcons.zap;

  // ── 云同步与安全 ──

  static const IconData cloud = LucideIcons.cloud;
  static const IconData cloudSync = LucideIcons.cloudUpload;
  static const IconData cloudDownload = LucideIcons.cloudDownload;
  static const IconData cloudOff = LucideIcons.cloudOff;
  static const IconData lock = LucideIcons.lock;
  static const IconData lockOpen = LucideIcons.lockOpen;
  static const IconData key = LucideIcons.keyRound;
  static const IconData shield = LucideIcons.shieldCheck;
  static const IconData shieldAlert = LucideIcons.shieldAlert;
  static const IconData fingerprint = LucideIcons.fingerprint;
  static const IconData user = LucideIcons.userRound;
  static const IconData wifi = LucideIcons.wifi;
  static const IconData wifiOff = LucideIcons.wifiOff;

  // ── 通知与消�?──

  static const IconData notification = LucideIcons.bell;
  static const IconData notificationOff = LucideIcons.bellOff;
  static const IconData message = LucideIcons.messageSquare;
  static const IconData wrench = LucideIcons.wrench;
}
