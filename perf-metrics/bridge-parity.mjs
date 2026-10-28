#!/usr/bin/env node
/**
 * 双端桥一致性审计 —— 桌面 Tauri 命令 vs 移动 FRB 导出函数
 *
 * 为什么需要它：本仓的业务逻辑全量下沉 `orbit-core`，两个壳各自只做转发。于是
 * 「某个能力只接了一端」这类缺口不会让任何测试变红——它表现为「桌面有、移动端
 * 摸不到」（或反向），只能靠人工全仓普查发现。2026-10-28 那一批（docs/07
 * #114 孤儿数据桶回收、#117 同步进度流）就是这么找出来的，且每轮普查都要重做
 * 一次同样的对照。
 *
 * 本脚本把「对照」固化成门禁：列出桌面命令集与 FRB 函数集，按**归一化名**
 * （去掉 `holidays_`/`holiday_` 这类单复数前缀差异、去掉 `_cmd` 后缀）配对，
 * 配不上的必须落进下方白名单并写明「为什么单端合理」。
 *
 * 判据刻意宽松（只查「有没有对应物」，不查签名是否一致）：
 * - 签名一致性由既有契约测试守（`apps/desktop/src/test/ipc-contract.test.ts`
 *   的 mock 覆盖面、移动 `bridge_sync_methods_test` 等），本脚本不重复做；
 * - 只报「缺失对应物」这一种形态，误报率低，适合放进 CI 拦停。
 *
 * 退出码：0 = 无白名单外的单端命令；1 = 发现未登记的单端命令；2 = 读不到源文件。
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const ROOT = path.resolve(import.meta.dirname, "..");

const DESKTOP_LIB = path.join(ROOT, "apps/desktop/src-tauri/src/lib.rs");
const FRB_API_DIR = path.join(ROOT, "crates/orbit-flutter/src/api");

/**
 * 允许「只存在于桌面」的命令。
 *
 * 每条必须写清理由：桌面专有形态（托盘/窗口/系统集成）或移动端由别的机制覆盖。
 * 新增一条 = 承认「这个能力移动端不做」，需要能对用户解释。
 */
const DESKTOP_ONLY = new Map([
  // —— 桌面进程形态：托盘、窗口、开机自启、单实例 ——
  ["setup_tray", "桌面专有：托盘菜单（移动端无托盘概念）"],
  ["show_main_window_cmd", "桌面专有：窗口被回收后重建唤起"],
  ["schedule_recycle_on_hide", "桌面专有：窗口隐藏后回收 WebView 省内存（ADR 0006）"],
  ["set_memory_usage_level", "桌面专有：WebView2 内存档位（Windows 独有）"],
  ["register_aumid_identity", "桌面专有：Windows AUMID 任务栏身份"],
  ["register_global_encrypted_storage", "桌面专有：钥匙串 CEK 提供者（移动端无凭据库，走明文降级）"],
  ["startup_launched_hidden", "桌面专有：自启 --hidden 判定"],
  ["is_launched_hidden", "桌面专有：同上"],
  ["resolve_launch_mode", "桌面专有：同上"],
  ["is_quitting", "桌面专有：退出流程标志"],
  ["mark_quitting", "桌面专有：同上"],
  ["is_tray_available", "桌面专有：托盘可用性探针"],
  ["clear_schedule_on_startup", "桌面专有：启动期清理残留调度"],
  // —— Mica 云母材质：Windows 桌面窗口独有，移动端无窗口材质概念 ——
  ["apply_mica", "桌面专有：Windows 云母材质（移动端无窗口材质）"],
  ["apply_mica_dwm", "桌面专有：同上（DWM 直调路径）"],
  ["disable_mica", "桌面专有：同上"],
  ["mica_diagnostics", "桌面专有：同上（材质读数）"],
  // —— 桌面调度器：移动端用各自的守护（boot_gate / 系统闹钟 / FRB start_*）——
  ["backup_scheduler_start", "移动端由 boot_gate 编排，无独立备份调度器"],
  ["digest_scheduler_start", "移动端走系统闹钟每日重复（ADR 0002），无 60s tick"],
  ["holiday_scheduler_start", "移动端由 boot_gate 调 start_holiday_scheduler（FRB 同名不同名）"],
  ["holiday_progress_pump_start", "移动端进度经 FRB StreamSink，无需 pump"],
  ["sync_scheduler_start", "移动端由 sync_on_change_scheduler.dart 覆盖（docs/07 #58）"],
  ["sync_on_change_watcher_start", "同上"],
  ["trash_scheduler_start", "移动端由 boot_gate 调 start_trash_scheduler"],
  ["spawn_idle_maintenance", "移动端 boot_gate 直接跑 db_maintenance_routine（同名 FRB 函数）"],
  // —— 桌面工具/度量 ——
  ["perf_first_screen_mark", "桌面专有：冷启动 marker（移动端用 adb am start -W）"],
  ["log_overview", "桌面专有：日志文件入口（移动端日志走 logcat，无文件目录）"],
  // —— 结构体/常量误匹配（正则扫到 `commands::xxx::Type` 形态，非命令）——
  ["APP_IDENTIFIER", "常量非命令"],
  ["PendingDbKey", "类型非命令"],
  ["SyncRuntime", "类型非命令"],
]);

/**
 * 允许「只存在于移动端」的桥函数。
 *
 * 反向缺口（移动端有、桌面没入口）同样是双端不对称，但桌面侧可能由其它命令
 * 覆盖（例如移动 `holiday_fetch_range` 对桌面 `holiday_fetch_range` 同名）。
 * 这里登记的是「移动端独有能力」或「桌面由别的名字覆盖」。
 */
const MOBILE_ONLY = new Map([
  ["dev_seed_demo_data", "开发专用：桌面走 dev_cmd 同名（已配对）"],
  ["dev_seed_clear", "同上"],
  ["subscribe_db_changes", "移动端专有：桌面走 Tauri event emit"],
  ["subscribe_holiday_progress", "移动端专有：桌面走 holiday-progress 事件"],
  ["subscribe_sync_progress", "移动端专有：桌面走 sync-progress 事件"],
  ["start_reminder_poller", "移动端专有：桌面 notification_scheduler.rs 常驻"],
  ["start_holiday_scheduler", "移动端专有：桌面 holiday_scheduler.rs 常驻"],
  ["start_trash_scheduler", "移动端专有：桌面 trash_scheduler.rs 常驻"],
  ["start_backup_scheduler", "移动端专有：桌面 backup_scheduler.rs 常驻"],
  ["init_app", "FRB 装载钩子（#[frb(init)]），桌面无对应物"],
  ["is_newer_version", "移动端专有：关于页版本比较（桌面 updater 插件自带）"],
  ["check_latest_release", "移动端专有：桌面 tauri-plugin-updater 自带检查"],
  ["db_reset_state", "迁移场景工具口（双端平价遗留，见 docs/10 §A-6）"],
  ["db_get_device_id", "同上"],
  // —— 桌面由同名不同名的入口覆盖（能力等价，命名不同）——
  ["digest_body", "桌面走 digest_summary（同一 core digest_api 的摘要载荷）"],
  [
    "db_maintenance_routine",
    "桌面走 db_maintenance（手动全量，含 VACUUM）；routine 是「轻维护」口径，" +
      "桌面由启动期 spawn_idle_maintenance 内部调用，不单独暴露命令",
  ],
  ["orbit_state_initialized", "桌面壳由 Rust 侧启动链自行判定，无 IPC 入口"],
  [
    "full_backup_import_path",
    "桌面备份导入走 plugin-dialog 选文件后由 Rust 读盘，不需要「传路径」变体" +
      "（移动端因 file_picker 返回路径才需要）",
  ],
  ["full_backup_peek_path", "同上：桌面预览也从选中的路径直接读"],
  ["full_backup_delete_local", "桌面备份卡按条目删除走 full_backup_import 同一入口的删除分支"],
  // —— 移动端独有平台能力 ——
  ["biometric_setup", "移动端专有：生物识别解锁（Android/iOS 平台 API，桌面无此形态）"],
  ["biometric_unlock", "同上"],
  ["biometric_disable", "同上"],
  ["widget_todo_query", "移动端专有：Android 桌面小组件数据源（桌面无小组件）"],
  ["widget_todo_toggle", "同上：小组件勾选回写"],
]);

/**
 * 名字归一化：把「同一能力、不同拼法」折叠成同一个键。
 *
 * 折叠的几类历史差异（都是本仓真实发生过的命名漂移，不是猜测）：
 * 1. `_cmd` 后缀——桌面命令文件常带；
 * 2. `holidays_` / `holiday_` 单复数前缀；
 * 3. 域前缀：桌面 `todo_tasks_create` vs 移动 `todo_task_create`（单复数），
 *    以及 `widget_todo_query` 这类壳层命名；
 * 4. 动词位置——桌面 `task_attachment_export` vs 移动 `export_task_attachment`
 *    （附件导出、路径挂载都是这一形态）；
 * 5. `from_path` / `path` 介词。
 *
 * **只折叠词序与虚词，不折叠实词**：`task_attachment_read` 与
 * `task_attachment_remove` 仍必须各配各的，否则门禁会把「读了」当成「删了」。
 *
 * 动词搬位只在「前导词是动词**且**剩余部分不是 `todo_*`/`widget_*` 域前缀」时
 * 进行——`todo_tasks_list` 的前导是域名词，把它搬成 `tasks_list_todo` 会让
 * 整张表崩掉（首版就踩了这个坑，一次冒出 20+ 假报）。
 */
function normalize(name) {
  let s = name.toLowerCase().replace(/_cmd$/, "");
  s = s.replace(/^holidays?_/, "holiday_");
  s = s.replace(/_from_/, "_");
  // 单复数折叠：逐段处理（`\b` 在 `todo_tasks_create` 里因下划线不是词边界而
  // 整段失效——首版踩过，桌面 `todo_tasks_create` 与移动 `todo_task_create`
  // 因此配不上，一次冒出 20+ 假报）
  const PLURAL = new Set([
    "tasks",
    "projects",
    "labels",
    "comments",
    "reminders",
    "subtasks",
    "attachments",
  ]);
  s = s
    .split("_")
    .map((seg) => (PLURAL.has(seg) ? seg.replace(/s$/, "") : seg))
    .join("_");

  const parts = s.split("_");
  const LEADING_VERBS = new Set([
    "export",
    "add",
    "read",
    "remove",
    "delete",
    "list",
    "update",
    "create",
    "get",
    "toggle",
    "query",
  ]);
  // 域前缀不算动词：`todo_` / `widget_` 开头一律不搬位
  const DOMAIN_PREFIXES = new Set(["todo", "widget", "cloud", "sync", "db", "holiday"]);
  if (
    parts.length > 2 &&
    LEADING_VERBS.has(parts[0]) &&
    !DOMAIN_PREFIXES.has(parts[0])
  ) {
    s = [...parts.slice(1), parts[0]].join("_");
  }
  return s;
}

function readOrDie(file) {
  try {
    return readFileSync(file, "utf8");
  } catch (e) {
    console.error(`[bridge-parity] 读不到 ${file}\n${e.message}`);
    process.exit(2);
  }
}

function main() {
  // 桌面：只扫 `generate_handler![...]` 宏体内注册的命令。
  //
  // 必须限定宏体：lib.rs 里还有大量非命令的 `a::b` 形态（`tauri::Builder`、
  // `std::thread::spawn`、`dirs::home_dir`、插件 `init`…），全文扫会把它们
  // 当成命令，双向假报（第三版踩过，一次冒出 20+ 无关符号）。
  //
  // 宏体内**三种**注册形态都出现过，模块名一律不限形态：
  //   `commands::todo_cmd::todo_task_create`（带 commands 前缀，多数域）
  //   `business_cmd::todo_tasks_list`（use 后直接模块名，任务域那批）
  //   `commands::backup_scheduler::backup_prefs_get`（模块不以 `_cmd` 结尾）
  const libSrc = readOrDie(DESKTOP_LIB);
  const handlerBody = extractHandlerBody(libSrc);
  const desktop = new Set(
    [...handlerBody.matchAll(/(?:[a-z0-9_]+::)+([a-z0-9_]+)\b/g)].map((m) => m[1]),
  );

  // 移动：crates/orbit-flutter/src/api/**.rs 的 `pub (async) fn`
  const frbFiles = readdirRs(FRB_API_DIR);
  const mobile = new Set();
  for (const file of frbFiles) {
    const src = readOrDie(file);
    for (const m of src.matchAll(/^pub (?:async )?fn (\w+)/gm)) mobile.add(m[1]);
  }

  const mobileNorm = new Set([...mobile].map(normalize));

  const desktopOrphans = [];
  for (const cmd of desktop) {
    if (MOBILE_ONLY.has(cmd)) continue;
    if (mobileNorm.has(normalize(cmd))) continue;
    if (DESKTOP_ONLY.has(cmd)) continue;
    desktopOrphans.push(cmd);
  }

  const desktopNorm = new Set([...desktop].map(normalize));
  const mobileOrphans = [];
  for (const fn of mobile) {
    if (MOBILE_ONLY.has(fn)) continue;
    if (desktopNorm.has(normalize(fn))) continue;
    mobileOrphans.push(fn);
  }

  // 白名单里已不再缺席的条目（可清理的陈旧登记）
  const stale = [
    ...DESKTOP_ONLY.keys(),
    ...MOBILE_ONLY.keys(),
  ].filter((k) => false); // 双向配对天然不判陈旧：白名单是「声明」而非「豁免计数」

  console.log(
    `[bridge-parity] 桌面命令 ${desktop.size} 个 / 移动 FRB 函数 ${mobile.size} 个`,
  );
  if (desktopOrphans.length > 0) {
    console.error(
      `\n✗ 以下桌面命令在移动端没有对应桥函数（也未登记为桌面专有）：`,
    );
    for (const c of desktopOrphans.sort()) console.error(`  - ${c}`);
    console.error(
      `\n若该能力移动端确实不做，请在 DESKTOP_ONLY 登记并写明理由；` +
        `若应当双端都有，补 FRB 桥（对齐 docs/07 #114/#117 的收口方式）。`,
    );
    process.exit(1);
  }
  if (mobileOrphans.length > 0) {
    console.error(`\n✗ 以下移动桥函数在桌面没有对应命令（也未登记为移动专有）：`);
    for (const c of mobileOrphans.sort()) console.error(`  - ${c}`);
    console.error(`\n请在 MOBILE_ONLY 登记理由，或补桌面命令。`);
    process.exit(1);
  }
  if (stale.length > 0) {
    console.warn(`[bridge-parity] 白名单中 ${stale.length} 条已不再缺席，可清理`);
  }
  console.log(`[bridge-parity] 通过：无未登记的单端能力`);
}

/**
 * 从 lib.rs 里截出 `generate_handler![ ... ]` 的宏体。
 *
 * 用括号配平而不是正则 `\[[\s\S]*?\]`：宏体里可能嵌套 `[...]`（属性/泛型），
 * 非贪婪正则会在第一个 `]` 处提前截断，把后半批命令静默漏掉——门禁的失败模式
 * 必须是「宁可多抓，绝不漏抓」。
 */
function extractHandlerBody(src) {
  const start = src.indexOf("generate_handler![");
  if (start < 0) {
    console.error("[bridge-parity] lib.rs 里找不到 generate_handler![，无法提取命令集");
    process.exit(2);
  }
  const open = src.indexOf("[", start);
  let depth = 0;
  for (let i = open; i < src.length; i += 1) {
    if (src[i] === "[") depth += 1;
    else if (src[i] === "]") {
      depth -= 1;
      if (depth === 0) return src.slice(open + 1, i);
    }
  }
  console.error("[bridge-parity] generate_handler![ 的括号未配平");
  process.exit(2);
}

/** 递归列出目录下的 .rs 文件 */
function readdirRs(dir) {  const out = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) out.push(...readdirRs(full));
    else if (name.endsWith(".rs")) out.push(full);
  }
  return out;
}

main();
