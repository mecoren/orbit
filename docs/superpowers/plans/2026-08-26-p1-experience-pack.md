# P1 体验能力包实施计划（NLP 输入 / 键盘可达 / 全局搜索 / 重复引擎 / 列表拖拽 / 屏间转场）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地竞品分析报告(docs/07_竞品对比与改进机会分析.md)P1 清单中的六项可执行改进（#7 NLP 快速输入、#8 键盘可达性、#9 全局搜索、#10 重复任务真引擎、#11 列表拖拽排序、#12 移动端转场），并记录 #13 的勘误结论。

**Architecture:** 前端为主：新增两个纯逻辑模块（NLP 解析器、重复实例规划器，均 node 环境单测）；QuickAddBar 接入解析器；任务行补键盘可达性；命令面板经 zustand「意图计数器」跨层触发列表页动作；全局搜索走「orbit-core 新增 `search_all` 三路 LIKE 聚合 → tauri `global_search` 命令 → Ctrl+K CommandDialog」链路；重复任务在统一完成入口 `completeTask` 中先建下一实例再标记完成。列表拖拽复用看板的中值 position 语义并抽为共享模块。移动端转场因平台迁移改为 Flutter go_router `CustomTransitionPage`。

**Tech Stack:** pnpm(11 lockfile)、React 19、TanStack Query v5、@tanstack/react-virtual ^3、@dnd-kit/core ^6、cmdk ^1.1.1、sonner、date-fns ^4、vitest 4(node 环境)；Rust：orbit-core(sqlx/serde)、Tauri 2 command；Flutter：go_router ^17。

## 范围勘误（相对 07 报告原文，实施前必读）

07 报告写作后仓库发生了两次结构性变化，以下三项按现状修正：

| 07 编号 | 勘误 | 证据 |
|---|---|---|
| #13 同步触发改造 | **已实现，从本计划剔除**。db-change → 5s 防抖 → push_only(Background) 的 watcher 与 60s tick 兜底均已存在并接线，受设置项 `sync_on_change` 开关控制 | `apps/desktop/src-tauri/src/commands/sync_scheduler.rs:44-130`（`ON_CHANGE_DEBOUNCE_SECS = 5`）、`apps/desktop/src-tauri/src/lib.rs:81` |
| #9 「移除移动端假搜索按钮」子项 | **已失效**。React 移动端整体删除于 f7ed3d7；现行 Flutter 侧栏顶栏只有设置按钮，无搜索占位 | `git show f7ed3d7`；`apps/mobile/lib/modules/todo/sidebar_screen.dart:276-293`（actions 仅 settings） |
| #12 移动端屏间转场 | **目标平台改为 Flutter**。原方案针对已删除的 React 移动端 hash 路由；现三屏走 go_router 普通 builder，零自定义转场 | `apps/mobile/lib/core/routing/app_router.dart:22-45` |

因此本计划含 **8 个 Task**（#7 拆两步、#8 拆两步），覆盖 P1 六个有效项。

## Global Constraints

- 包管理器只用 pnpm；前端源码在 `apps/desktop/src/`，typecheck/test/build scripts 在 `apps/desktop/package.json`。
- vitest 仅 node 环境（`apps/desktop/vitest.config.ts`: `include: ["src/**/*.test.ts"]`）——**禁止引入 jsdom / 组件测试**；交互验证一律手工冒烟。
- Rust 单元测试写在被测文件尾部 `#[cfg(test)] mod tests`，orbit-core 不做连真实 DB 的集成测试。
- react-query queryKey：既有约定不变（`["todo_tasks", keyword]`、`["todo-project","list"]`、`["todo-label","list"]`、`["todo-task-detail", id]`）；本计划新增仅 `["global-search", keyword]`。
- 全部界面文案为中文；新增文件沿用仓库中文 JSDoc 文件头注释风格。
- 每个 Task 收尾必须全绿后才 Commit：
  - 前端 Task：`pnpm typecheck && pnpm test`（改构建产物的 Task 另加 `pnpm build`）；
  - 含 Rust 的 Task 另加：`cargo test -p orbit-core --lib`。
- 提交信息遵循近期惯例 `type(scope): 英文短描述`（参照 git log：`feat(desktop): undoable delete via delayed-commit (5s toast action)`）。
- **明确排除**：新重复实例克隆提醒（todo_reminders 不复制）；状态下拉以外路径的取消完成编排；NLP 时间点级解析（仅日期粒度）与数字日期 `MM-DD`（易歧义）；全局搜索高亮/搜索历史；Flutter 双页视差（iOS parallax，仅单页滑入）；看板列虚拟化（维持 07 报告的 P1 复核结论）。

---

### Task 1: NLP 快速输入解析器（纯函数 + TDD）

**Files:**
- Create: `apps/desktop/src/features/todo/shared/parse-quick-input.ts`
- Test: `apps/desktop/src/features/todo/shared/parse-quick-input.test.ts`

**Interfaces:**
- Consumes: 无（纯函数，零依赖）
- Produces:
  - `parseQuickInput(raw: string, ctx: QuickInputContext): ParsedQuickInput`
  - `interface QuickInputContext { projects: { id: number; title: string }[]; labels: { id: number; title: string }[]; now: Date }`
  - `interface ParsedQuickInput { title: string; dueDate: Date | null; priority: number; projectId: number | null; labelIds: number[] }`（`priority: 0` 表示输入未指定）

- [ ] **Step 1: 写失败测试**

基准时刻取 `2026-08-26（周三）`，全部断言确定性：

```ts
// apps/desktop/src/features/todo/shared/parse-quick-input.test.ts
// parseQuickInput 规则表驱动测试（07 报告 §五-P1#7）
// 基准时刻 2026-08-26 为周三；日期 token 一律落到当日零点（本地时区），
// 与 lib/quick-dates.ts 快捷菜单「今天」口径一致。
import { describe, expect, it } from "vitest";

import { parseQuickInput } from "./parse-quick-input";

const NOW = new Date(2026, 7, 26, 15, 30); // 周三
const day = (month1based: number, d: number) => new Date(2026, month1based - 1, d).getTime();

const CTX = {
  projects: [
    { id: 1, title: "工作" },
    { id: 2, title: "工作汇报" },
    { id: 7, title: "生活" },
  ],
  labels: [
    { id: 10, title: "家人" },
    { id: 11, title: "紧急跟进" },
  ],
  now: NOW,
};

describe("parseQuickInput · 日期", () => {
  it("明天 → 次日零点，正文剥离", () => {
    const r = parseQuickInput("明天开会", CTX);
    expect(r.title).toBe("开会");
    expect(r.dueDate!.getTime()).toBe(day(8, 27));
  });

  it("大后天 → +3 天", () => {
    const r = parseQuickInput("交周报 大后天", CTX);
    expect(r.dueDate!.getTime()).toBe(day(8, 29));
    expect(r.title).toBe("交周报");
  });

  it("周X → 未来最近（含今天）：周五聚餐", () => {
    const r = parseQuickInput("周五聚餐", CTX); // 周三→周五 = +2
    expect(r.dueDate!.getTime()).toBe(day(8, 28));
  });

  it("今天恰逢周X → 取今天", () => {
    const r = parseQuickInput("周三站会", CTX);
    expect(r.dueDate!.getTime()).toBe(day(8, 26));
  });

  it("下周X → 下周一为首日的下周对应日", () => {
    const r = parseQuickInput("下周三复查", CTX); // 下周一=08-31，+2 → 09-02
    expect(r.dueDate!.getTime()).toBe(day(9, 2));
  });

  it("M月d日 今年未过 → 今年；已过 → 顺延一年", () => {
    expect(parseQuickInput("9月10日体检", CTX).dueDate!.getTime()).toBe(day(9, 10));
    expect(parseQuickInput("1月5日续费", CTX).dueDate!.getTime()).toBe(
      new Date(2027, 0, 5).getTime(),
    );
  });

  it("多个日期 token：靠后者覆盖；下周X 不被内层 周X 二次命中", () => {
    const r = parseQuickInput("下周三复查 改明天", CTX);
    expect(r.dueDate!.getTime()).toBe(day(8, 27));
    expect(r.title).toBe("复查 改");
  });
});

describe("parseQuickInput · 优先级/项目/标签", () => {
  it("!1-!5 提取优先级", () => {
    expect(parseQuickInput("买菜 !3", CTX).priority).toBe(3);
    expect(parseQuickInput("买菜", CTX).priority).toBe(0);
  });

  it("#项目 精确优先于前缀；前缀唯一命中可用", () => {
    expect(parseQuickInput("#工作 计划", CTX).projectId).toBe(1);
    expect(parseQuickInput("#工作汇 计划", CTX).projectId).toBe(2);
  });

  it("@标签 可多个且去重", () => {
    const r = parseQuickInput("买礼物 @家人 @家人 @紧急跟进", CTX);
    expect(r.labelIds).toEqual([10, 11]);
  });

  it("项目名以标点收尾也能截断（中文无空格场景）", () => {
    const r = parseQuickInput("#生活，明天交电费", CTX);
    expect(r.projectId).toBe(7);
    expect(r.title).toBe("，交电费");
    expect(r.dueDate!.getTime()).toBe(day(8, 27));
  });
});

describe("parseQuickInput · 兜底语义", () => {
  it("未匹配的 #token 原样保留在标题", () => {
    const r = parseQuickInput("事项 #不存在", CTX);
    expect(r.projectId).toBeNull();
    expect(r.title).toBe("事项 #不存在");
  });

  it("无 token 时原样返回", () => {
    const r = parseQuickInput("纯文本任务", CTX);
    expect(r.title).toBe("纯文本任务");
    expect(r.dueDate).toBeNull();
    expect(r.priority).toBe(0);
    expect(r.labelIds).toEqual([]);
  });

  it("剥离后收敛多余空白", () => {
    expect(parseQuickInput("买 牛奶  明天", CTX).title).toBe("买 牛奶");
  });
});
```

- [ ] **Step 2: 运行确认失败**

Run（workdir `apps/desktop`）: `pnpm test -- parse-quick-input`
Expected: FAIL —— `Cannot find module './parse-quick-input'`。

- [ ] **Step 3: 写实现**

```ts
// apps/desktop/src/features/todo/shared/parse-quick-input.ts
/**
 * NLP 快速输入规则解析器 v1（07 报告 §五-P1#7）
 *
 * 纯函数、零框架依赖。语法（中文优先，大小写敏感仅限拉丁 token）：
 *   日期：今天/明天/后天/大后天 | 周X·星期X·礼拜X（未来最近，含今天）|
 *         下周X·下星期X·下礼拜X（下周一为首周的对应日）|
 *         M月d日·M月d号（今年已过则顺延一年）
 *   优先级：!1 ~ !5（!6+ 不识别，原样保留）
 *   项目：#名称 —— 项目标题精确匹配优先，其次第一个前缀命中
 *   标签：@名称 —— 同上，可出现多个（去重）
 *
 * 边界规则：日期/优先级为封闭词形，文本任意位置可命中；
 * #/@ 名称以空白或中英文常用标点收尾。所有命中区间互斥——先命中的
 * 长词保护内部短词不被二次解析（如下周三 中的 周三）。
 * 未匹配的 #/@ token 原样保留在标题中，避免误删用户文字。
 */

export interface QuickInputContext {
  projects: { id: number; title: string }[];
  labels: { id: number; title: string }[];
  now: Date;
}

export interface ParsedQuickInput {
  /** 剥离全部命中 token 并收敛空白后的标题 */
  title: string;
  dueDate: Date | null;
  /** 1-5；0 = 输入中未指定 */
  priority: number;
  projectId: number | null;
  labelIds: number[];
}

const WEEKDAY_CN: Record<string, number> = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 0, 天: 0 };
const RELATIVE_DAYS: Record<string, number> = { 今天: 0, 明天: 1, 大后天: 3, 后天: 2 };

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function addDays(d: Date, n: number): Date {
  const x = startOfDay(d);
  x.setDate(x.getDate() + n);
  return x;
}

/** 距下一个周一的天数（今天为周一也取下周一），与 quick-dates.nextMonday 同口径 */
function nextMondayDelta(now: Date): number {
  return ((8 - now.getDay()) % 7) || 7;
}

/** 下周的周 X（周一为首日；wd 为 JS 星期 0=周日） */
function nextWeekWeekday(now: Date, wd: number): Date {
  const posFromMonday = (wd + 6) % 7; // 周一=0 … 周日=6
  return addDays(now, nextMondayDelta(now) + posFromMonday);
}

export function parseQuickInput(raw: string, ctx: QuickInputContext): ParsedQuickInput {
  interface Strip { start: number; end: number }
  const strips: Strip[] = [];
  let dueDate: Date | null = null;
  let priority = 0;
  let projectId: number | null = null;
  const labelIds: number[] = [];

  const overlaps = (start: number, end: number) =>
    strips.some((s) => start < s.end && s.start < end);

  /** 依次消费 re 的每个匹配：consume 返回 true 才剥离该区间 */
  const take = (re: RegExp, consume: (m: RegExpExecArray) => boolean): void => {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(raw)) !== null) {
      const end = m.index + m[0].length;
      if (overlaps(m.index, end)) continue;
      if (!consume(m)) continue;
      strips.push({ start: m.index, end });
      if (m[0].length === 0) re.lastIndex++; // 防空匹配死循环
    }
  };

  // ---- 相对日词（大后天 必须列在 后天 前，保证长词优先）----
  take(/(大后天|后天|明天|今天)/g, (m) => {
    dueDate = addDays(ctx.now, RELATIVE_DAYS[m[1]]);
    return true;
  });
  // ---- 下周X ----
  take(/(?:下周|下星期|下礼拜)([一二三四五六日天])/g, (m) => {
    dueDate = nextWeekWeekday(ctx.now, WEEKDAY_CN[m[1]]);
    return true;
  });
  // ---- 周X（未来最近，含今天）----
  take(/(?:周|星期|礼拜)([一二三四五六日天])/g, (m) => {
    const delta = (WEEKDAY_CN[m[1]] - ctx.now.getDay() + 7) % 7;
    dueDate = addDays(ctx.now, delta);
    return true;
  });
  // ---- M月d日 / M月d号 ----
  take(/(\d{1,2})月(\d{1,2})[日号]/g, (m) => {
    const month = Number(m[1]) - 1;
    const dayOfMonth = Number(m[2]);
    if (month < 0 || month > 11 || dayOfMonth < 1 || dayOfMonth > 31) return false;
    const cand = new Date(ctx.now.getFullYear(), month, dayOfMonth);
    if (cand.getTime() < startOfDay(ctx.now).getTime()) {
      cand.setFullYear(cand.getFullYear() + 1);
    }
    dueDate = cand;
    return true;
  });
  // ---- 优先级 !1-!5 ----
  take(/!([1-5])/g, (m) => {
    priority = Number(m[1]);
    return true;
  });
  // ---- 项目 #名称（名称不含空白、#@! 与常用标点）----
  take(/#([^\s#!@，。；、！？,.;;!?()（）[\]【】""''"]+)/g, (m) => {
    const name = m[1];
    const hit =
      ctx.projects.find((p) => p.title === name) ??
      ctx.projects.find((p) => p.title.startsWith(name));
    if (!hit) return false; // 未匹配：保留原文
    projectId = hit.id;
    return true;
  });
  // ---- 标签 @名称（可多个）----
  take(/@([^\s#!@，。；、！？,.;;!?()（）[\]【】""''"]+)/g, (m) => {
    const name = m[1];
    const hit =
      ctx.labels.find((l) => l.title === name) ??
      ctx.labels.find((l) => l.title.startsWith(name));
    if (!hit) return false;
    if (!labelIds.includes(hit.id)) labelIds.push(hit.id);
    return true;
  });

  // ---- 剥离命中区间并收敛空白 ----
  let title = "";
  let cursor = 0;
  for (const s of [...strips].sort((a, b) => a.start - b.start)) {
    title += raw.slice(cursor, s.start);
    cursor = s.end;
  }
  title += raw.slice(cursor);

  return {
    title: title.replace(/\s{2,}/g, " ").trim(),
    dueDate,
    priority,
    projectId,
    labelIds,
  };
}
```

- [ ] **Step 4: 运行确认通过**

Run（workdir `apps/desktop`）: `pnpm test -- parse-quick-input`
Expected: 13 passed。

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/src/features/todo/shared/parse-quick-input.ts apps/desktop/src/features/todo/shared/parse-quick-input.test.ts
git commit -m "feat(todo): nlp quick-input parser with tests"
```

---

### Task 2: QuickAddBar 接入 NLP 解析

**Files:**
- Modify: `apps/desktop/src/features/todo/desktop/quick-add-bar.tsx`（imports、labels 查询、parsed memo、submit 重写、预览 chips 行）

**Interfaces:**
- Consumes: Task 1 的 `parseQuickInput / QuickInputContext / ParsedQuickInput`；`todoLabelList(filter)` / `todoTaskLabelCreate({task_id,label_id})`（`lib/tauri.ts:300,324`）；queryKey `["todo-label","list"]`
- Produces: QuickAddBar 行为升级——提交前解析、token 显式值覆盖手动选择、创建后挂标签、输入框上方实时解析预览 chips。对外 props 不变。

- [ ] **Step 1: 补 imports**

`quick-add-bar.tsx` 头部改为（新增 useMemo、Tag 图标、标签 API、解析器）：

```tsx
import { useEffect, useMemo, useRef, useState } from "react";
import { format } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useQuery } from "@tanstack/react-query";
import { Calendar, CalendarPlus, Clock, Flag, Folder, Plus, Tag } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { WaitCalendar } from "@/components/ui/wait-calendar";
import { DateTimePicker } from "@/components/business/date-picker";
import { QuickDateMenu } from "@/components/business/quick-date-options";
import {
  todoLabelList,
  todoReminderCreate,
  todoTaskCreate,
  todoTaskLabelCreate,
  type TodoProject,
} from "@/lib/tauri";
import { parseQuickInput } from "../shared/parse-quick-input";
import { PRIORITY_COLOR, TODO_ACCENT } from "../shared/constants";
```

- [ ] **Step 2: 加标签查询与 parsed memo**

组件体内 `hasInput` 之后插入：

```tsx
  // 标签清单：有输入才拉取（@标签 解析与预览需要）
  const labelsQuery = useQuery({
    queryKey: ["todo-label", "list"],
    queryFn: () => todoLabelList({ page: 1, page_size: 500 }),
    enabled: hasInput,
    staleTime: 60_000,
  });

  // 实时解析结果（预览 chips 与提示用；提交时以最新输入重算一次为准）
  const parsed = useMemo(
    () =>
      parseQuickInput(title, {
        projects: projects.map((p) => ({ id: p.id, title: p.title })),
        labels: (labelsQuery.data ?? []).map((l) => ({ id: l.id, title: l.title })),
        now: new Date(),
      }),
    [title, projects, labelsQuery.data],
  );
  const hasHits =
    parsed.dueDate != null ||
    parsed.priority > 0 ||
    parsed.projectId != null ||
    parsed.labelIds.length > 0;
```

同时把 `reset()` 保持不变（无需清 parsed，派生值随 title 清空）。

- [ ] **Step 3: 重写 submit()**

将现有 `submit`（L58-81）整段替换为：

```tsx
  const submit = async () => {
    // 用提交瞬间最新输入重算（避免 memo 时差）；token 显式值优先于手动 Popover 选择
    const p = parseQuickInput(title, {
      projects: projects.map((pr) => ({ id: pr.id, title: pr.title })),
      labels: (labelsQuery.data ?? []).map((l) => ({ id: l.id, title: l.title })),
      now: new Date(),
    });
    const t = p.title.trim();
    if (!t) return;
    try {
      const created = await todoTaskCreate({
        title: t,
        priority: p.priority || priority,
        due_date: p.dueDate ? p.dueDate.getTime() : dueDate ? dueDate.getTime() : null,
        project_id: p.projectId ?? effectiveProjectId,
      });
      // 标签挂载：单个失败不阻断任务本身
      for (const labelId of p.labelIds) {
        try {
          await todoTaskLabelCreate({ task_id: created.id, label_id: labelId });
        } catch {
          /* 忽略单个标签失败 */
        }
      }
      // 提醒为独立实体：任务创建成功后追加；失败不影响任务本身
      if (remindDraft) {
        const ms = new Date(remindDraft).getTime();
        if (!Number.isNaN(ms)) {
          await todoReminderCreate({ task_id: created.id, remind_at: ms });
        }
      }
      // 连续录入：清空并保持焦点（04 §3.5）
      reset();
      requestAnimationFrame(() => inputRef.current?.focus());
    } catch (err) {
      console.error("创建任务失败:", err);
    }
  };
```

- [ ] **Step 4: 预览 chips 行 + placeholder**

最外层 `<div className="border-t border-border px-4 py-2.5">` 内、输入行 `<div className="flex items-center gap-2 rounded-md ...">` 之前插入：

```tsx
      {/* NLP 解析预览 chips（07 §五-P1#7）：仅展示命中项 */}
      {hasInput && hasHits && (
        <div className="mb-1.5 flex flex-wrap items-center gap-1.5 px-1 text-xs text-muted-foreground">
          {parsed.dueDate && (
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary">
              <Calendar className="size-3" />
              {format(parsed.dueDate, "M月d日 EEEE", { locale: zhCN })}
            </span>
          )}
          {parsed.priority > 0 && (
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary">
              <Flag className="size-3" />
              {PRIORITY_LABELS[parsed.priority]}
            </span>
          )}
          {parsed.projectId != null && (
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary">
              <Folder className="size-3" />
              {projects.find((pr) => pr.id === parsed.projectId)?.title}
            </span>
          )}
          {parsed.labelIds.map((id) => (
            <span
              key={id}
              className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-primary"
            >
              <Tag className="size-3" />
              {(labelsQuery.data ?? []).find((l) => l.id === id)?.title}
            </span>
          ))}
        </div>
      )}
```

并把 Input 的 `placeholder="添加任务"` 改为：

```tsx
          placeholder="添加任务…支持「明天 #项目 @标签 !3」"
```

- [ ] **Step 5: 验证**

Run（workdir `apps/desktop`）: `pnpm typecheck && pnpm test && pnpm build`
Expected: 全绿。
手工冒烟（`pnpm dev`，需 Tauri 宿主或接受 invoke 报错仅验证 UI）：
1. 底部输入 `明天交周报 #工作 @家人 !3` → 上方出现 明天/高/工作/家人 四枚 chips，标题预览剩「交周报」；
2. Enter 提交 → 列表出现新任务：优先级色点、截止「明天」、所属「工作」；详情抽屉标签区含「家人」；
3. 输入 `事项 #不存在` → 无 chips，提交后标题保留 `#不存在`。

- [ ] **Step 6: Commit**

```bash
git add apps/desktop/src/features/todo/desktop/quick-add-bar.tsx
git commit -m "feat(todo): wire nlp parsing into quick-add bar"
```

---

### Task 3: 任务行键盘可达性（j/k · Enter/Space）

**Files:**
- Create: `apps/desktop/src/features/todo/shared/list-keyboard.ts`
- Test: `apps/desktop/src/features/todo/shared/list-keyboard.test.ts`
- Modify: `apps/desktop/src/features/todo/desktop/task-list-view.tsx`（imports、rowRefs/focusRow、行 div 属性）

**Interfaces:**
- Consumes: TaskListView 现有虚拟化结构（`virtualizer.scrollToIndex`，L49-55）
- Produces:
  - `listNavDirection(key: string): "up" | "down" | null`（j/↓、k/↑）
  - `isListActivationKey(key: string): boolean`（Enter、Space）
  - 任务行获得 `role="button"` + `tabIndex={0}` + Enter/Space 打开详情 + j/k 焦点移动（滚动跟随）。Task 7 重构此文件时必须原样保留这些属性。

- [ ] **Step 1: 写失败测试**

```ts
// apps/desktop/src/features/todo/shared/list-keyboard.test.ts
// 列表键盘导航语义（07 报告 §五-P1#8）
import { describe, expect, it } from "vitest";

import { isListActivationKey, listNavDirection } from "./list-keyboard";

describe("listNavDirection", () => {
  it("j/ArrowDown → down；k/ArrowUp → up；其余 null", () => {
    expect(listNavDirection("j")).toBe("down");
    expect(listNavDirection("ArrowDown")).toBe("down");
    expect(listNavDirection("k")).toBe("up");
    expect(listNavDirection("ArrowUp")).toBe("up");
    expect(listNavDirection("Enter")).toBeNull();
    expect(listNavDirection("a")).toBeNull();
  });
});

describe("isListActivationKey", () => {
  it("Enter 与空格激活；其余否", () => {
    expect(isListActivationKey("Enter")).toBe(true);
    expect(isListActivationKey(" ")).toBe(true);
    expect(isListActivationKey("Spacebar")).toBe(false);
    expect(isListActivationKey("j")).toBe(false);
  });
});
```

- [ ] **Step 2: 运行确认失败**

Run（workdir `apps/desktop`）: `pnpm test -- list-keyboard`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 写最小实现**

```ts
// apps/desktop/src/features/todo/shared/list-keyboard.ts
/**
 * 任务列表键盘导航语义（07 报告 §五-P1#8）
 *
 * j/k 或 ↑/↓ 移动焦点（滚动跟随由调用方 scrollToIndex 实现）；
 * Enter/Space 激活当前行（打开详情抽屉）。纯函数便于 node 环境单测。
 */
export type ListNavDirection = "up" | "down";

export function listNavDirection(key: string): ListNavDirection | null {
  if (key === "j" || key === "ArrowDown") return "down";
  if (key === "k" || key === "ArrowUp") return "up";
  return null;
}

export function isListActivationKey(key: string): boolean {
  return key === "Enter" || key === " ";
}
```

Run（workdir `apps/desktop`）: `pnpm test -- list-keyboard`
Expected: 2 passed。

- [ ] **Step 4: TaskListView 行接线**

`task-list-view.tsx` 顶部 import 区补：

```tsx
import { isListActivationKey, listNavDirection } from "../shared/list-keyboard";
```

组件体内、`const virtualizer = useVirtualizer({...})`（L49-55）之后插入：

```tsx
  // 键盘导航（P1#8）：行 DOM 注册表（task id → 元素）；j/k 移动焦点并由
  // scrollToIndex 让可视窗跟随，避免焦点行滚出屏幕丢失
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const focusRow = (index: number) => {
    if (index < 0 || index >= tasks.length) return;
    virtualizer.scrollToIndex(index, { align: "auto" });
    requestAnimationFrame(() => rowRefs.current.get(tasks[index]?.id)?.focus());
  };
```

行内容 `<div className="group flex items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30" onClick={...}>`（L142-145）替换为：

```tsx
                <div
                  ref={(el) => {
                    if (el) rowRefs.current.set(t.id, el);
                    else rowRefs.current.delete(t.id);
                  }}
                  role="button"
                  tabIndex={0}
                  aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
                  className="group flex cursor-default items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30 focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
                  onClick={() => onOpenDetail(t.id)}
                  onKeyDown={(e) => {
                    if (e.nativeEvent.isComposing) return; // IME 组合期不响应
                    if (isListActivationKey(e.key)) {
                      e.preventDefault();
                      onOpenDetail(t.id);
                      return;
                    }
                    const dir = listNavDirection(e.key);
                    if (!dir) return;
                    e.preventDefault();
                    focusRow(vi.index + (dir === "down" ? 1 : -1));
                  }}
                >
```

（行内 checkbox/星标的 JSX 不动；它们自身 stopPropagation，不会与行级 onKeyDown 冲突。）

- [ ] **Step 5: 验证**

Run（workdir `apps/desktop`）: `pnpm typecheck && pnpm test`
Expected: 全绿。
手工冒烟（`pnpm dev`）：打开 /todo → Tab 聚焦首行（出现 inset 焦点环）→ j/k 连续下移/上移，长列表自动滚动跟随 → Enter 打开详情抽屉 → Esc 关闭 → Space 同效。Tab 序：行 → 行内 checkbox → 星标。

- [ ] **Step 6: Commit**

```bash
git add apps/desktop/src/features/todo/shared/list-keyboard.ts apps/desktop/src/features/todo/shared/list-keyboard.test.ts apps/desktop/src/features/todo/desktop/task-list-view.tsx
git commit -m "feat(desktop): keyboard-accessible task rows (j/k, enter/space)"
```

---

### Task 4: 命令面板扩容（新建任务 / 切换主题 / 切换视图）

**Files:**
- Modify: `apps/desktop/src/stores/app-store.ts`（新增两个意图计数器）
- Modify: `apps/desktop/src/components/layout/command-palette.tsx`（新增「命令」组）
- Modify: `apps/desktop/src/features/todo/desktop/list-page.tsx`（监听意图计数器）

**Interfaces:**
- Consumes: `getStoredThemeMode()/setThemeMode(mode)`（`lib/color-theme.ts:363` 及导出）；list-page 既有 `formOpen/viewMode` state（L59-64）
- Produces:
  - `useAppStore` 新字段：`taskFormIntent: number` + `bumpTaskFormIntent(): void`、`viewToggleIntent: number` + `bumpViewToggleIntent(): void`（意图计数器模式：壳层命令面板 bump，页面 effect 监听增量执行动作）
  - 命令面板新增「命令」组三项；Task 5 将向同一 store 追加 `searchOpen`。

- [ ] **Step 1: 扩展 app-store**

`stores/app-store.ts` 全文替换为：

```ts
import { create } from "zustand";

interface AppState {
  commandOpen: boolean;
  setCommandOpen: (open: boolean) => void;
  toggleCommand: () => void;
  /**
   * 「新建任务」意图计数器（07 报告 §五-P1#8）：
   * 命令面板挂在 AppShell 壳层，而新建表单状态在 list-page 内部——
   * 用递增计数器跨层传递动作意图，页面 effect 监听增量后打开表单。
   */
  taskFormIntent: number;
  bumpTaskFormIntent: () => void;
  /** 「切换视图」意图计数器（list ⇄ kanban），机制同上 */
  viewToggleIntent: number;
  bumpViewToggleIntent: () => void;
}

export const useAppStore = create<AppState>((set) => ({
  commandOpen: false,
  setCommandOpen: (open) => set({ commandOpen: open }),
  toggleCommand: () => set((s) => ({ commandOpen: !s.commandOpen })),
  taskFormIntent: 0,
  bumpTaskFormIntent: () => set((s) => ({ taskFormIntent: s.taskFormIntent + 1 })),
  viewToggleIntent: 0,
  bumpViewToggleIntent: () => set((s) => ({ viewToggleIntent: s.viewToggleIntent + 1 })),
}));
```

- [ ] **Step 2: 命令面板加「命令」组**

`command-palette.tsx` imports 区改为（新增图标、主题工具、app-store）：

```tsx
import { useMemo } from "react";
import { useNavigate } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { CheckSquare, Clock, Info, LayoutGrid, Plus, Settings, SunMoon } from "lucide-react";

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { useTodoStore } from "@/features/todo/store";
import { useAppStore } from "@/stores/app-store";
import { getStoredThemeMode, setThemeMode, type ThemeMode } from "@/lib/color-theme";
import { todoTaskList } from "@/lib/tauri";
```

组件体内 `const setSelectedTaskId = ...` 之后加：

```tsx
  const bumpTaskFormIntent = useAppStore((s) => s.bumpTaskFormIntent);
  const bumpViewToggleIntent = useAppStore((s) => s.bumpViewToggleIntent);

  /** 与 components/theme-mode-toggle.tsx 相同的三态循环 */
  const cycleTheme = () => {
    const CYCLE: ThemeMode[] = ["system", "light", "dark"];
    const next = CYCLE[(CYCLE.indexOf(getStoredThemeMode()) + 1) % CYCLE.length];
    setThemeMode(next);
  };
```

JSX 中 `<CommandEmpty>无匹配结果</CommandEmpty>` 之后、`groupedRoutes.map(...)` 之前插入：

```tsx
        <CommandGroup heading="命令">
          <CommandItem
            value="新建任务 new task"
            onSelect={() => {
              onOpenChange(false);
              bumpTaskFormIntent();
            }}
          >
            <Plus className="size-4" />
            <span>新建任务</span>
          </CommandItem>
          <CommandItem
            value="切换主题 theme light dark system"
            onSelect={() => {
              cycleTheme();
              onOpenChange(false);
            }}
          >
            <SunMoon className="size-4" />
            <span>切换主题</span>
          </CommandItem>
          <CommandItem
            value="切换视图 view kanban list 看板 列表"
            onSelect={() => {
              onOpenChange(false);
              bumpViewToggleIntent();
            }}
          >
            <LayoutGrid className="size-4" />
            <span>切换列表/看板视图</span>
          </CommandItem>
        </CommandGroup>
```

- [ ] **Step 3: list-page 监听意图**

`list-page.tsx` 组件体内 `const setCommandOpen = ...`（L48）之后加：

```tsx
  const taskFormIntent = useAppStore((s) => s.taskFormIntent);
  const viewToggleIntent = useAppStore((s) => s.viewToggleIntent);
```

并在既有 `useEffect(() => { localStorage.setItem(LS_VIEW_MODE, viewMode); }, [viewMode]);`（L67-69）之后加：

```tsx
  // 壳层命令面板的动作意图（07 §五-P1#8）；计数器为 0 视为初始挂载，跳过
  useEffect(() => {
    if (taskFormIntent === 0) return;
    setEditingTask(null);
    setFormOpen(true);
  }, [taskFormIntent]);

  useEffect(() => {
    if (viewToggleIntent === 0) return;
    setViewMode((m) => (m === "list" ? "kanban" : "list"));
  }, [viewToggleIntent]);
```

- [ ] **Step 4: 验证**

Run（workdir `apps/desktop`）: `pnpm typecheck && pnpm test && pnpm build`
Expected: 全绿。
手工冒烟（`pnpm dev`）：
1. Ctrl+P → 输入「新建」→ 回车：待办页弹出空白九字段表单 Sheet；
2. 再开面板选「切换主题」：亮↔暗↔跟随系统循环，TitleBar 图标同步；
3. 选「切换列表/看板视图」：中栏视图切换且刷新页面后保持（LS_VIEW_MODE 持久化不受影响）；
4. 在 /settings 页触发「新建任务」：无报错（list-page 未挂载，意图无人消费属预期）。

- [ ] **Step 5: Commit**

```bash
git add apps/desktop/src/stores/app-store.ts apps/desktop/src/components/layout/command-palette.tsx apps/desktop/src/features/todo/desktop/list-page.tsx
git commit -m "feat(desktop): expand command palette (new task/theme/view)"
```

---

### Task 5: 全局搜索 Ctrl+K（Rust 聚合 + 前端对话框）

**Files:**
- Modify: `crates/orbit-core/src/api/business_api.rs`（文件尾追加 search_all + 结果类型 + serde 测试）
- Modify: `apps/desktop/src-tauri/src/commands/todo_cmd.rs`（新增命令）
- Modify: `apps/desktop/src-tauri/src/lib.rs`（generate_handler 注册，清单在 L91-203）
- Modify: `apps/desktop/src/lib/tauri.ts`（comments 段 L346 之后追加绑定）
- Modify: `apps/desktop/src/stores/app-store.ts`（追加 searchOpen）
- Modify: `apps/desktop/src/components/layout/title-bar.tsx`（全局 keydown 增 Ctrl+K 分支，现 handler 在 L86-96）
- Modify: `apps/desktop/src/components/layout/app-shell.tsx`（挂载对话框）
- Create: `apps/desktop/src/components/layout/global-search-dialog.tsx`

**Interfaces:**
- Consumes: `searchable_fields` 白名单已有 todo_tasks(title/description)、todo_projects(title/description)、todo_comments(content)（generic_repo.rs:131-135）；AppState.pool 字段（sync_scheduler.rs:188 用法佐证）
- Produces:
  - Rust: `business_api::search_all(pool: &SqlitePool, keyword: &str, limit: i32) -> CoreResult<GlobalSearchResult>`；`GlobalSearchResult { tasks: Vec<TodoTask>, projects: Vec<TodoProject>, comments: Vec<CommentSearchHit> }`；`CommentSearchHit { comment_id, task_id, task_title, content, created_at }`（snake_case serde）
  - Tauri: `global_search(keyword: String, limit: Option<i32>) -> Result<GlobalSearchResult, String>`
  - TS: `globalSearch(keyword: string, limit?: number): Promise<GlobalSearchResult>`
  - Store: `searchOpen/setSearchOpen`；快捷键 Ctrl/Cmd+K

- [ ] **Step 1: orbit-core 新增聚合搜索**

`crates/orbit-core/src/api/business_api.rs` 顶部 import 区（`use sqlx::SqlitePool;` 附近）补一行：

```rust
use serde::{Deserialize, Serialize};
```

文件末尾（现有内容之后）追加：

```rust
// ---------- global search ----------
/// 全局搜索单条评论命中（附带所属任务标题，避免前端二次查询）
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CommentSearchHit {
    pub comment_id: i64,
    pub task_id: i64,
    pub task_title: String,
    pub content: String,
    pub created_at: i64,
}

/// 跨表聚合搜索结果（tasks/projects/comments 三路 LIKE，07 报告 §五-P1#9）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GlobalSearchResult {
    pub tasks: Vec<TodoTask>,
    pub projects: Vec<TodoProject>,
    pub comments: Vec<CommentSearchHit>,
}

/// 全局搜索：复用 generic_repo 同款 %kw% LIKE 口径，各表限 top limit 条。
/// 评论经 JOIN todo_tasks 带出任务标题；任务按 updated_at DESC、
/// 项目按 sort_order ASC（与各自列表页排序一致，保证命中顺序符合直觉）。
pub async fn search_all(pool: &SqlitePool, keyword: &str, limit: i32) -> CoreResult<GlobalSearchResult> {
    let kw = keyword.trim();
    if kw.is_empty() {
        return Ok(GlobalSearchResult::default());
    }
    let pattern = format!("%{}%", kw);
    let limit = if limit <= 0 { 20 } else { limit };

    let tasks = sqlx::query_as::<_, TodoTask>(
        "SELECT * FROM todo_tasks \
         WHERE is_deleted = 0 AND (title LIKE ? OR description LIKE ?) \
         ORDER BY updated_at DESC LIMIT ?",
    )
    .bind(&pattern)
    .bind(&pattern)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let projects = sqlx::query_as::<_, TodoProject>(
        "SELECT * FROM todo_projects \
         WHERE is_deleted = 0 AND (title LIKE ? OR description LIKE ?) \
         ORDER BY sort_order ASC, id ASC LIMIT ?",
    )
    .bind(&pattern)
    .bind(&pattern)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let comments = sqlx::query_as::<_, CommentSearchHit>(
        "SELECT c.id AS comment_id, c.task_id AS task_id, \
                t.title AS task_title, c.content AS content, c.created_at AS created_at \
         FROM todo_comments c \
         JOIN todo_tasks t ON t.id = c.task_id AND t.is_deleted = 0 \
         WHERE c.is_deleted = 0 AND c.content LIKE ? \
         ORDER BY c.created_at DESC LIMIT ?",
    )
    .bind(&pattern)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(GlobalSearchResult { tasks, projects, comments })
}

#[cfg(test)]
mod global_search_tests {
    use super::*;

    /// serde 往返：字段保持 snake_case（前端 typed invoke 依赖该形状）
    #[test]
    fn global_search_result_serializes_snake_case() {
        let r = GlobalSearchResult {
            tasks: vec![],
            projects: vec![],
            comments: vec![CommentSearchHit {
                comment_id: 1,
                task_id: 2,
                task_title: "写周报".into(),
                content: "记得带数据".into(),
                created_at: 3,
            }],
        };
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["comments"][0]["comment_id"], 1);
        assert_eq!(v["comments"][0]["task_title"], "写周报");
        assert_eq!(v["comments"][0]["created_at"], 3);
    }
}
```

- [ ] **Step 2: 跑 Rust 测试**

Run（repo 根）: `cargo test -p orbit-core --lib global_search`
Expected: `global_search_tests::global_search_result_serializes_snake_case ... ok`，其余既有测试不变绿。

- [ ] **Step 3: Tauri 命令 + 注册**

`apps/desktop/src-tauri/src/commands/todo_cmd.rs` 文件末尾追加（若顶部尚无对应 use，则把 `GlobalSearchResult` 并入现有 `orbit_core::models::business::*` 导入；glob 导入则无需改动）：

```rust
/// 全局跨表搜索（07 报告 §五-P1#9）：tasks/projects/comments 三路聚合
#[tauri::command]
pub async fn global_search(
    state: State<'_, AppState>,
    keyword: String,
    limit: Option<i32>,
) -> Result<GlobalSearchResult, String> {
    business_api::search_all(&state.pool, &keyword, limit.unwrap_or(20))
        .await
        .map_err(|e| e.to_string())
}
```

`apps/desktop/src-tauri/src/lib.rs` 的 `generate_handler![...]`（L91-203）中、其他 `commands::todo_cmd::*` 条目旁追加一行：

```rust
            commands::todo_cmd::global_search,
```

Run（repo 根）: 先读 `apps/desktop/src-tauri/Cargo.toml` 的 `[package] name`（记为 `<crate>`），然后 `cargo check -p <crate>`
Expected: 编译通过、无 warning 新增。

- [ ] **Step 4: 前端绑定 + store + 快捷键**

`apps/desktop/src/lib/tauri.ts` 在 `todoCommentDelete`（L346）之后插入：

```ts
// ========== global_search（07 报告 §五-P1#9）==========
export interface CommentSearchHit {
  comment_id: number;
  task_id: number;
  task_title: string;
  content: string;
  created_at: number;
}
export interface GlobalSearchResult {
  tasks: TodoTask[];
  projects: TodoProject[];
  comments: CommentSearchHit[];
}
export const globalSearch = (keyword: string, limit = 20) =>
  invoke<GlobalSearchResult>("global_search", { keyword, limit });
```

`stores/app-store.ts` 的 AppState 接口与 create 实现各追加（接 Task 4 之后）：

```ts
  /** 全局搜索对话框开关（Ctrl+K，07 §五-P1#9） */
  searchOpen: boolean;
  setSearchOpen: (open: boolean) => void;
```

```ts
  searchOpen: false,
  setSearchOpen: (open) => set({ searchOpen: open }),
```

`title-bar.tsx`：组件体内既有的 `toggleCommand` selector 附近补 `const setSearchOpen = useAppStore((s) => s.setSearchOpen);`，并将 L86-96 的快捷键 useEffect 整段替换为：

```ts
  // 全局快捷键：Ctrl/Cmd+P 命令面板；Ctrl/Cmd+K 全局搜索
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey)) return;
      if (e.key === "p") {
        e.preventDefault();
        toggleCommand();
      } else if (e.key === "k") {
        e.preventDefault();
        setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [toggleCommand, setSearchOpen]);
```

- [ ] **Step 5: 新建 GlobalSearchDialog**

```tsx
// apps/desktop/src/components/layout/global-search-dialog.tsx
/**
 * GlobalSearchDialog — 全局搜索（07 报告 §五-P1#9）
 *
 * Ctrl/Cmd+K 打开；输入防抖 250ms 后调用 Rust global_search 跨表聚合
 * （projects/tasks/comments 三组，各限 20 条）。条目 value 携带可检索文本，
 * 交给 cmdk 本地过滤做二次收敛；任务/评论命中写入 selectedTaskId 打开详情
 * 抽屉并回待办页，项目命中跳待办页（页内筛选仍由 list-page 自管）。
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { CheckSquare, Folder, MessageSquare } from "lucide-react";

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { useTodoStore } from "@/features/todo/store";
import { globalSearch } from "@/lib/tauri";

interface GlobalSearchDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

/** 输入防抖：停止击键 delayMs 后才更新 */
function useDebouncedValue(value: string, delayMs: number): string {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(id);
  }, [value, delayMs]);
  return debounced;
}

export function GlobalSearchDialog({ open, onOpenChange }: GlobalSearchDialogProps) {
  const navigate = useNavigate();
  const setSelectedTaskId = useTodoStore((s) => s.setSelectedTaskId);
  const [keyword, setKeyword] = useState("");
  const debounced = useDebouncedValue(keyword.trim(), 250);

  // 关闭即清词，下次打开是干净上下文
  useEffect(() => {
    if (!open) setKeyword("");
  }, [open]);

  const { data, isFetching } = useQuery({
    queryKey: ["global-search", debounced],
    queryFn: () => globalSearch(debounced, 20),
    enabled: open && debounced.length > 0,
    staleTime: 30_000,
  });

  const go = (path: string) => {
    navigate(path);
    onOpenChange(false);
  };
  const openTask = (taskId: number) => {
    setSelectedTaskId(taskId);
    go("/todo");
  };

  const tasks = data?.tasks ?? [];
  const projects = data?.projects ?? [];
  const comments = data?.comments ?? [];

  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <CommandInput
        value={keyword}
        onValueChange={setKeyword}
        placeholder={isFetching ? "搜索中…" : "搜索任务 / 项目 / 评论…"}
        autoFocus
      />
      <CommandList>
        <CommandEmpty>
          {debounced.length === 0 ? "输入关键词开始搜索" : isFetching ? "搜索中…" : "无匹配结果"}
        </CommandEmpty>

        {projects.length > 0 && (
          <CommandGroup heading="项目">
            {projects.map((p) => (
              <CommandItem key={p.id} value={`项目 ${p.title}`} onSelect={() => go("/todo")}>
                <Folder
                  className="size-4 shrink-0"
                  style={{ color: p.hex_color || undefined }}
                />
                <span className="truncate">{p.title}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}

        {tasks.length > 0 && (
          <CommandGroup heading="任务">
            {tasks.map((t) => (
              <CommandItem
                key={t.id}
                value={`任务 ${t.title} ${t.description ?? ""}`}
                onSelect={() => openTask(t.id)}
              >
                <CheckSquare className="size-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate">{t.title}</span>
                {t.done ? (
                  <span className="shrink-0 text-xs text-muted-foreground">已完成</span>
                ) : null}
              </CommandItem>
            ))}
          </CommandGroup>
        )}

        {comments.length > 0 && (
          <CommandGroup heading="评论">
            {comments.map((c) => (
              <CommandItem
                key={c.comment_id}
                value={`评论 ${c.content} ${c.task_title}`}
                onSelect={() => openTask(c.task_id)}
              >
                <MessageSquare className="size-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate">{c.content}</span>
                <span className="shrink-0 text-xs text-muted-foreground">{c.task_title}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}
      </CommandList>
    </CommandDialog>
  );
}
```

`app-shell.tsx`：import 区补 `import { GlobalSearchDialog } from "@/components/layout/global-search-dialog";`；组件体 `const setCommandOpen = ...` 之后补：

```ts
  const searchOpen = useAppStore((s) => s.searchOpen);
  const setSearchOpen = useAppStore((s) => s.setSearchOpen);
```

`<CommandPalette ... />` 之后补：

```tsx
      {/* 全局搜索（Ctrl+K，07 §五-P1#9）：与命令面板平级的壳层入口 */}
      <GlobalSearchDialog open={searchOpen} onOpenChange={setSearchOpen} />
```

- [ ] **Step 6: 验证**

Run（workdir `apps/desktop`）: `pnpm typecheck && pnpm test && pnpm build`
Run（repo 根）: `cargo test -p orbit-core --lib`
Expected: 全部绿色。
手工冒烟（`pnpm tauri dev`，需真实 IPC）：
1. 主界面 Ctrl+K → 输入任务标题片段 → 250ms 后出现「任务」分组，↑↓ 选择回车打开详情抽屉；
2. 输入项目名 → 「项目」分组命中，回车跳 /todo；
3. 给某任务添加一条含关键词的评论 → 搜索该词 → 「评论」分组显示内容+所属任务标题，回车打开对应详情；
4. 连续快速击键（如输入「abc」逐字）Network/日志确认只发出最后一次查询（防抖生效）；
5. Ctrl+P 原命令面板不受影响。

- [ ] **Step 7: Commit**

```bash
git add crates/orbit-core/src/api/business_api.rs apps/desktop/src-tauri/src/commands/todo_cmd.rs apps/desktop/src-tauri/src/lib.rs apps/desktop/src/lib/tauri.ts apps/desktop/src/stores/app-store.ts apps/desktop/src/components/layout/title-bar.tsx apps/desktop/src/components/layout/app-shell.tsx apps/desktop/src/components/layout/global-search-dialog.tsx
git commit -m "feat(search): global ctrl+k search across tasks/projects/comments"
```

---

### Task 6: 重复任务真引擎（完成时生成下一实例）

**Files:**
- Create: `apps/desktop/src/features/todo/shared/repeat-task.ts`
- Test: `apps/desktop/src/features/todo/shared/repeat-task.test.ts`
- Modify: `apps/desktop/src/features/todo/shared/task-actions.ts`（全文重写：applyDoneToggle → completeTask 编排）
- Modify: `apps/desktop/src/features/todo/desktop/task-list-view.tsx:101-108`（toggleDone 接线）
- Modify: `apps/desktop/src/features/todo/desktop/task-context-menu.tsx:166-174`（菜单完成项接线）
- Modify: `apps/desktop/src/features/todo/desktop/task-detail-drawer.tsx:210-216 与 327-330`（头部勾选 +状态下拉接线）
- Modify: `apps/desktop/src/features/todo/desktop/kanban-view.tsx:112-115`（拖入 done 列接线）
- Modify: `apps/desktop/src/hooks/use-todo-reminder-listener.ts:43-44`（已完成任务不再续排提醒）

**Interfaces:**
- Consumes: `nextRepeatAt(baseMs, mode, after, fromMs)`（repeat.ts:45，月/年日历语义、5000 步快进上限）；`todoSubtaskCreate({task_id,title,position?})`（tauri.ts:262-275）；detail 聚合含 `subtasks`（`TodoTaskDetail`，tauri.ts:392-406）；db-change 事件粗粒度失效（events.ts）负责刷新 UI
- Produces:
  - `planNextRecurringInstance(task: TodoTask, nowMs: number): NextInstancePlan | null`；`NextInstancePlan { input: TodoTaskCreateInput; deltaMs: number }`（due 序列锚定原 due_date，start/end 平移同一 delta）
  - `subtasksToClone(subtasks: TodoSubtask[]): { title: string; position: number }[]`（过滤软删、按 position 升序、完成态一律重置——由调用方建新行时不传 done 即默认未完成）
  - `completeTask(task: TodoTask): Promise<void>` —— 全应用唯一完成/取消完成编排入口
- 语义决策：完成逾期重复任务时，下一实例按**原排程序列**推进（非「今天+周期」）；旧实例归档保留历史；生成失败则中止完成并 toast 提示（宁可没完成，不可丢排程）。

- [ ] **Step 1: 写失败测试**

```ts
// apps/desktop/src/features/todo/shared/repeat-task.test.ts
// planNextRecurringInstance / subtasksToClone 纯逻辑测试（07 报告 §五-P1#10）
import { describe, expect, it } from "vitest";

import type { TodoSubtask, TodoTask } from "@/lib/tauri";
import { REPEAT_MODE } from "./repeat";
import { planNextRecurringInstance, subtasksToClone } from "./repeat-task";

const DAY = 86_400_000;

/** mk：补齐 TodoTask 必要字段的工厂（其余字段测试不关心，给安全默认值） */
function mk(partial: Partial<TodoTask>): TodoTask {
  return {
    id: 1, uuid: "u", title: "任务", description: null, project_id: null,
    priority: 0, status: "pending", done: 0, done_at: null,
    due_date: null, start_date: null, end_date: null,
    repeat_after: 1, repeat_mode: 0, hex_color: "", percent_done: 0,
    position: 0, is_favorite: 0, is_deleted: 0,
    created_at: 0, updated_at: 0, deleted_at: null, version: 1,
    ...partial,
  };
}

function sub(partial: Partial<TodoSubtask>): TodoSubtask {
  return {
    id: 1, uuid: "s", task_id: 1, title: "子任务", done: 0, done_at: null,
    position: 0, is_deleted: 0, created_at: 0, updated_at: 0,
    deleted_at: null, version: 1,
    ...partial,
  };
}

describe("planNextRecurringInstance", () => {
  it("每天：next = 原 due + 1 天；start/end 平移同一 delta", () => {
    const due = new Date(2026, 7, 27).getTime();
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.DAILY, repeat_after: 1, due_date: due, start_date: due - DAY }),
      new Date(2026, 7, 26, 12).getTime(),
    )!;
    expect(plan.input.due_date).toBe(due + DAY);
    expect(plan.deltaMs).toBe(DAY);
    expect(plan.input.start_date).toBe(due);
    expect(plan.input.status).toBe("pending");
    expect(plan.input.done).toBe(0);
    expect(plan.input.repeat_mode).toBe(REPEAT_MODE.DAILY);
  });

  it("提前完成仍按原排程推进（from=now 不影响第一步）", () => {
    const due = new Date(2026, 8, 1).getTime(); // 未来到期就提前勾完
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.WEEKLY, due_date: due }),
      new Date(2026, 7, 26).getTime(),
    )!;
    expect(plan.input.due_date).toBe(due + 7 * DAY);
  });

  it("长期逾期：快进到 now 之后最近的一次", () => {
    const due = new Date(2026, 7, 10).getTime(); // 已逾期 16 天
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.DAILY, due_date: due }),
      new Date(2026, 7, 26).getTime(),
    )!;
    expect(plan.input.due_date).toBe(new Date(2026, 7, 27).getTime()); // >now 的首个序列点
  });

  it("每月：月末截断由 nextRepeatAt 保证（1/31 → 2/28）", () => {
    const due = new Date(2026, 0, 31).getTime();
    const plan = planNextRecurringInstance(
      mk({ repeat_mode: REPEAT_MODE.MONTHLY, due_date: due }),
      new Date(2026, 1, 1).getTime(),
    )!;
    expect(new Date(plan.input.due_date!).getDate()).toBe(28);
    expect(new Date(plan.input.due_date!).getMonth()).toBe(1);
  });

  it("无规则 / 无 due → null", () => {
    expect(planNextRecurringInstance(mk({ repeat_mode: 0 }), Date.now())).toBeNull();
    expect(planNextRecurringInstance(mk({ repeat_mode: REPEAT_MODE.DAILY }), Date.now())).toBeNull();
  });

  it("克隆字段：标题/描述/项目/优先级/颜色/收藏带过去，uuid/id 不带", () => {
    const plan = planNextRecurringInstance(
      mk({
        repeat_mode: REPEAT_MODE.DAILY, due_date: Date.now() + DAY,
        title: "晨会", description: "站会", project_id: 5, priority: 2,
        hex_color: "#FF0000", is_favorite: 1,
      }),
      Date.now(),
    )!;
    expect(plan.input.title).toBe("晨会");
    expect(plan.input.description).toBe("站会");
    expect(plan.input.project_id).toBe(5);
    expect(plan.input.priority).toBe(2);
    expect(plan.input.hex_color).toBe("#FF0000");
    expect(plan.input.is_favorite).toBe(1);
    expect("id" in plan.input).toBe(false);
    expect("uuid" in plan.input).toBe(false);
  });
});

describe("subtasksToClone", () => {
  it("过滤软删、按 position 升序、只留标题与位置", () => {
    const rows = [
      sub({ id: 3, title: "丙", position: 2 }),
      sub({ id: 1, title: "甲", position: 0 }),
      sub({ id: 2, title: "乙", position: 1, is_deleted: 1 }),
    ];
    expect(subtasksToClone(rows)).toEqual([
      { title: "甲", position: 0 },
      { title: "丙", position: 2 },
    ]);
  });
});
```

- [ ] **Step 2: 运行确认失败**

Run（workdir `apps/desktop`）: `pnpm test -- repeat-task`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 写实现**

```ts
// apps/desktop/src/features/todo/shared/repeat-task.ts
/**
 * 重复任务实例推进（07 报告 §五-P1#10）
 *
 * 语义：完成旧实例 → 以规则生成下一实例（替代旧的「重建 reminder」机制）。
 * due 序列始终锚定**原 due_date** 逐步推进（nextRepeatAt 内部快进越过 now），
 * 提前完成不改变节奏，长期逾期自动追赶到未来最近的序列点；
 * start/end 平移与 due 相同的 delta；子任务仅复制标题与顺序，完成态重置。
 * 不复制提醒（明确排除，见计划 Global Constraints）。
 */
import type { TodoSubtask, TodoTask, TodoTaskCreateInput } from "@/lib/tauri";
import { nextRepeatAt, REPEAT_MODE } from "./repeat";

export interface NextInstancePlan {
  input: TodoTaskCreateInput;
  /** 下一 due 与原 due 的差值(ms)，start/end 等派生时间用它对齐 */
  deltaMs: number;
}

/** 计算下一实例；无规则、无 due 或快进超限（>5000 步）返回 null */
export function planNextRecurringInstance(task: TodoTask, nowMs: number): NextInstancePlan | null {
  if (!task.repeat_mode || task.repeat_mode === REPEAT_MODE.NONE) return null;
  if (task.due_date == null) return null;
  const nextDue = nextRepeatAt(task.due_date, task.repeat_mode, task.repeat_after, nowMs);
  if (nextDue == null) return null;
  const deltaMs = nextDue - task.due_date;
  const shift = (ms: number | null): number | null => (ms == null ? null : ms + deltaMs);
  return {
    input: {
      title: task.title,
      description: task.description,
      project_id: task.project_id,
      priority: task.priority,
      status: "pending",
      done: 0,
      done_at: null,
      due_date: nextDue,
      start_date: shift(task.start_date),
      end_date: shift(task.end_date),
      repeat_after: task.repeat_after,
      repeat_mode: task.repeat_mode,
      hex_color: task.hex_color,
      is_favorite: task.is_favorite,
    },
    deltaMs,
  };
}

/** 待克隆到新实例的子任务：过滤软删、position 升序、完成态不带走 */
export function subtasksToClone(subtasks: TodoSubtask[]): { title: string; position: number }[] {
  return subtasks
    .filter((s) => !s.is_deleted)
    .sort((a, b) => a.position - b.position)
    .map((s) => ({ title: s.title, position: s.position }));
}
```

Run（workdir `apps/desktop`）: `pnpm test -- repeat-task`
Expected: 7 passed。

- [ ] **Step 4: 重写 task-actions.ts 为 completeTask 编排**

`features/todo/shared/task-actions.ts` 全文替换为：

```ts
/**
 * 任务操作共享助手
 *
 * completeTask — 全应用统一的完成/取消完成编排入口（07 报告 §五-P1#10）：
 * - 取消完成：回 pending 并清 done_at（历史语义不变）。
 * - 普通任务完成：done=1 + done_at=now + status="done"。
 * - 重复任务完成（repeat_mode>0 且有 due_date）：先按规则创建下一实例
 *   （克隆字段 + 平移 start/end + 复制未完成子任务），成功后才标记本实例；
 *   创建失败则中止并提示——宁可没完成，不可丢排程。
 * UI 刷新依赖 db-change 事件的全量失效（events.ts），此处不做局部缓存操作。
 */
import { toast } from "sonner";
import {
  todoSubtaskCreate,
  todoTaskCreate,
  todoTaskGetDetail,
  todoTaskUpdate,
  type TodoTask,
} from "@/lib/tauri";
import { planNextRecurringInstance, subtasksToClone } from "./repeat-task";

export async function completeTask(task: TodoTask): Promise<void> {
  // 取消完成
  if (task.done) {
    await todoTaskUpdate(task.id, { done: 0, done_at: null, status: "pending" });
    return;
  }
  // 重复任务：先推进下一实例，成功才标记完成
  if (task.repeat_mode && task.due_date != null) {
    try {
      const detail = await todoTaskGetDetail(task.id);
      const plan = planNextRecurringInstance(task, Date.now());
      if (plan) {
        const created = await todoTaskCreate(plan.input);
        for (const s of subtasksToClone(detail.subtasks)) {
          await todoSubtaskCreate({ task_id: created.id, title: s.title, position: s.position });
        }
      }
    } catch {
      toast.error("生成下一重复实例失败，本次未标记完成");
      return;
    }
  }
  await todoTaskUpdate(task.id, { done: 1, done_at: Date.now(), status: "done" });
}
```

（`applyDoneToggle` 全仓 grep 仅本文件定义、无外部导入者，直接移除不留死代码。）

- [ ] **Step 5: 五处完成入口接线**

**(a) task-list-view.tsx** — 顶部 import 补 `import { completeTask } from "../shared/task-actions";`；L101-108 `toggleDone` 整段替换为：

```ts
  const toggleDone = (t: TodoTask) => {
    void completeTask(t);
  };
```

（`todoTaskUpdate` 仍被 toggleFavorite 使用，import 保留。）

**(b) task-context-menu.tsx** — import 补 `import { completeTask } from "../shared/task-actions";`；L166-174「标记完成/未完成」菜单项替换为：

```tsx
            <DropdownMenuItem
              onSelect={() => {
                close();
                void completeTask(task);
              }}
            >
              <Check size={14} />
              {task.done ? "标记未完成" : "标记完成"}
            </DropdownMenuItem>
```

**(c) task-detail-drawer.tsx** — 顶部 import 补 `import { completeTask } from "@/features/todo/shared/task-actions";`；L210-216 头部勾选按钮 onClick 替换为：

```tsx
        onClick={() => void completeTask(task)}
```

L327-330 `PropertyGrid.setStatus` 替换为（状态切到 done 同样走引擎）：

```ts
  const setStatus = (key: string) => {
    if (key === "done") void completeTask(task);
    else void onPatch({ status: key, done: 0, done_at: null });
  };
```

**(d) kanban-view.tsx** — import 补 `import { completeTask } from "../shared/task-actions";`；L108-117 `moveAcross` 的 done 分支替换为：

```ts
    } else if (colKey === "done") {
      const task = tasks.find((t) => t.id === taskId);
      if (task) await completeTask(task);
    } else {
```

**(e) use-todo-reminder-listener.ts** — L43-44 取到 task 之后、计算 next 之前插守卫（重复任务完成后旧实例不再续排提醒，防止给已归档实例排未来的响铃）：

```ts
          const task = await todoTaskGet(r.task_id);
          if (task.done) return; // P1#10：真引擎接管后，已完成实例不再续排提醒
```

- [ ] **Step 6: 验证**

Run（workdir `apps/desktop`）: `pnpm typecheck && pnpm test && pnpm build`
Expected: 全绿（repeat-task 新增 7 条 + 既有 41 条不变）。
手工冒烟（`pnpm tauri dev`）：
1. 新建任务「喝水」，重复=每天，截止=明天，加两个子任务 → 列表勾选完成 → 出现新任务「喝水」（截止=后天、子任务未完成、优先级/项目一致），旧任务进「已完成」视图；
2. 详情抽屉状态下拉切「已完成」→ 同样生成下一实例；
3. 看板把每日任务卡拖进「待办→已完成」列 → 生成下一实例；
4. 右键普通（非重复）任务标记完成 → 行为与从前一致，无新任务产生；
5. 断网/停后端模拟失败路径困难，跳过（catch 分支由 code review 覆盖）。

- [ ] **Step 7: Commit**

```bash
git add apps/desktop/src/features/todo/shared/repeat-task.ts apps/desktop/src/features/todo/shared/repeat-task.test.ts apps/desktop/src/features/todo/shared/task-actions.ts apps/desktop/src/features/todo/desktop/task-list-view.tsx apps/desktop/src/features/todo/desktop/task-context-menu.tsx apps/desktop/src/features/todo/desktop/task-detail-drawer.tsx apps/desktop/src/features/todo/desktop/kanban-view.tsx apps/desktop/src/hooks/use-todo-reminder-listener.ts
git commit -m "feat(todo): recurring tasks spawn next instance on completion"
```

---

### Task 7: position 中值抽共享 + 列表视图拖拽排序

**Files:**
- Create: `apps/desktop/src/features/todo/shared/position.ts`
- Test: `apps/desktop/src/features/todo/shared/position.test.ts`
- Modify: `apps/desktop/src/features/todo/desktop/kanban-view.tsx:45-48`（删除本地 midpoint，改 import）
- Modify: `apps/desktop/src/features/todo/desktop/task-list-view.tsx`（整文件重写：提取 TaskRow 子组件挂 draggable/droppable + DragOverlay + 手柄）

**Interfaces:**
- Consumes: `todoTaskUpdatePosition(id, position)`（tauri.ts:245）；Task 3 的 `rowRefs/focusRow/isListActivationKey/listNavDirection`（重构必须原样保留）；`sortTasks` 固定 position 升序（task-filters.ts:90-97）——写库后 invalidate `["todo_tasks"]` 即可见序
- Produces:
  - `midpoint(prev?: number, next?: number): number`（缺省 0 / 100000，03 文档 §一 公式，看板/列表共用）
  - 列表行 hover 显现 GripVertical 手柄，仅从手柄发起拖拽（行点击仍打开详情）；落点语义与看板一致：落在某行 → 插到该行之前；落在容器空白 → 尾部追加

- [ ] **Step 1: 写失败测试**

```ts
// apps/desktop/src/features/todo/shared/position.test.ts
// midpoint 中值公式（03 文档 §一；看板 kanban-view 与列表拖拽共用）
import { describe, expect, it } from "vitest";

import { midpoint } from "./position";

describe("midpoint", () => {
  it("两侧齐全取中值", () => {
    expect(midpoint(10, 20)).toBe(15);
  });
  it("缺 prev → 0 与 next 的中值（置于列首）", () => {
    expect(midpoint(undefined, 100)).toBe(50);
  });
  it("缺 next → prev 与 100000 的中值（尾部追加）", () => {
    expect(midpoint(100)).toBe(50050);
  });
  it("双缺省 → 50000", () => {
    expect(midpoint()).toBe(50000);
  });
});
```

- [ ] **Step 2: 运行确认失败**

Run（workdir `apps/desktop`）: `pnpm test -- position`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 写 position.ts 并切换 kanban-view**

```ts
// apps/desktop/src/features/todo/shared/position.ts
/** position 取中值公式（03 文档 §一）：prev 缺省视为 0，next 缺省视为 100000。
 *  看板拖拽（kanban-view.tsx）与列表拖拽（task-list-view.tsx）共用。 */
export function midpoint(prev?: number, next?: number): number {
  return ((prev ?? 0) + (next ?? 100000)) / 2;
}
```

Run（workdir `apps/desktop`）: `pnpm test -- position`
Expected: 4 passed。

`kanban-view.tsx`：删除 L45-48 的本地定义：

```ts
/** position 取中值（03 文档 §一 公式） */
function midpoint(prev: number | undefined, next: number | undefined): number {
  return ((prev ?? 0) + (next ?? 100000)) / 2;
}
```

import 区补：

```tsx
import { midpoint } from "../shared/position";
```

- [ ] **Step 4: 重写 task-list-view.tsx（拖拽 + 保留键盘可达）**

整文件替换为：

```tsx
/**
 * TaskListView — 任务列表行（04 文档 §3.2 复刻）
 *
 * 行规格：圆形 checkbox（done 联动 status/done_at）+ 标题（划线）+
 * 元信息行（优先级色点/项目名/截止时间，逾期整段红）+ hover 星标。
 * P1 增强：
 * - 虚拟化（P0）：仅渲染可视窗 ± overscan；绝对定位行必须用 top 定位，
 *   transform 会成为 fixed 后代（ContextMenuBase 哨兵）的 containing block。
 * - 键盘可达（P1#8）：行 role=button/tabIndex，Enter/Space 打开详情，j/k 移动焦点。
 * - 拖拽排序（P1#11）：GripVertical 手柄发起（行点击仍是打开详情），
 *   落在某行 → 插其前；落容器空白 → 尾部追加；position 中值写入后失效任务缓存。
 */
import { useRef, useState } from "react";
import { formatDistanceToNow } from "date-fns";
import { zhCN } from "date-fns/locale";
import { useQueryClient } from "@tanstack/react-query";
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  pointerWithin,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { Clock, GripVertical, Inbox, Plus, Star } from "lucide-react";
import { useVirtualizer } from "@tanstack/react-virtual";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorState } from "@/components/business/error-state";
import { EmptyState } from "@/components/business/empty-state";
import { completeTask } from "../shared/task-actions";
import { isListActivationKey, listNavDirection } from "../shared/list-keyboard";
import { midpoint } from "../shared/position";
import { todoTaskUpdate, todoTaskUpdatePosition, type TodoProject, type TodoTask } from "@/lib/tauri";
import { FAVORITE_COLOR, OVERDUE_COLOR_CLASS, PRIORITY_COLOR } from "../shared/constants";
import { TaskContextMenu } from "./task-context-menu";

interface TaskListViewProps {
  tasks: TodoTask[];
  projects: TodoProject[];
  loading?: boolean;
  /** 列表查询错误文案；非空时整块渲染 ErrorState */
  error?: string | null;
  /** 空态"新建任务"动作回调（由 list-page 注入打开表单） */
  onCreateClick?: () => void;
  onOpenDetail: (id: number) => void;
}

/** 截止文案：±15 天内相对时间，否则 MM-dd（04 §3.2） */
function dueText(dueDate: number | null): string | null {
  if (!dueDate) return null;
  const ms = dueDate;
  const diff = Math.abs(ms - Date.now());
  if (diff <= 15 * 24 * 3600 * 1000) {
    return formatDistanceToNow(new Date(ms), { addSuffix: true, locale: zhCN });
  }
  const d = new Date(ms);
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** dnd-kit id 形如 "row:<taskId>"，提取数字任务 id */
function rowIdOf(raw: string | number): number {
  const s = String(raw);
  return s.startsWith("row:") ? Number(s.slice(4)) : Number.NaN;
}

export function TaskListView({ tasks, projects, loading, error, onCreateClick, onOpenDetail }: TaskListViewProps) {
  const qc = useQueryClient();
  const scrollRef = useRef<HTMLDivElement>(null);

  // 键盘导航（P1#8）：行 DOM 注册表 + 焦点移动（scrollToIndex 跟随）
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const focusRow = (index: number) => {
    if (index < 0 || index >= tasks.length) return;
    virtualizer.scrollToIndex(index, { align: "auto" });
    requestAnimationFrame(() => rowRefs.current.get(tasks[index]?.id)?.focus());
  };

  // P0 虚拟化：仅渲染可视窗 ± overscan。行高估算 57（py-3×2 + 标题20 + meta16 + 边框）
  const virtualizer = useVirtualizer({
    count: tasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 57,
    overscan: 8,
    getItemKey: (i) => tasks[i].id,
  });

  // 拖拽（P1#11）：PointerSensor distance:6 —— 小位移不算拖拽，保证行点击；
  // hooks 全部集中在早退分支之前，保证无条件执行
  const [draggingId, setDraggingId] = useState<number | null>(null);
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
  );

  const handleDragStart = (e: DragStartEvent) => {
    const id = rowIdOf(e.active.id);
    if (!Number.isNaN(id)) setDraggingId(id);
  };

  const handleDragEnd = async (e: DragEndEvent) => {
    const { active, over } = e;
    setDraggingId(null);
    if (!over) return;
    const draggedId = rowIdOf(active.id);
    const idx = tasks.findIndex((t) => t.id === draggedId);
    if (Number.isNaN(draggedId) || idx < 0) return;

    if (String(over.id) === "rows-container") {
      // 容器空白 → 尾部追加
      const last = tasks[tasks.length - 1];
      if (!last || last.id === draggedId) return;
      await todoTaskUpdatePosition(draggedId, midpoint(last.position));
    } else {
      const targetId = rowIdOf(over.id);
      const targetIdx = tasks.findIndex((t) => t.id === targetId);
      if (targetIdx < 0 || targetId === draggedId) return;
      // 目标的前一张已是拖拽行 → 位置未变，免写库
      const prev = tasks[targetIdx - 1];
      if (prev && prev.id === draggedId) return;
      const prevPos = prev && prev.id !== draggedId ? prev.position : undefined;
      await todoTaskUpdatePosition(draggedId, midpoint(prevPos, tasks[targetIdx].position));
    }
    // 排序展示口径在前端 sortTasks(position 升序)，失效后按新 position 重排
    void qc.invalidateQueries({ queryKey: ["todo_tasks"] });
  };

  if (loading) {
    return (
      <div className="flex-1 divide-y divide-border/30 overflow-y-auto" aria-busy="true">
        {Array.from({ length: 8 }, (_, i) => (
          <div key={i} className="flex items-center gap-3 px-4 py-3">
            <Skeleton className="h-5 w-5 shrink-0 rounded-full" />
            <div className="min-w-0 flex-1 space-y-2">
              <Skeleton className="h-4 w-2/5" />
              <Skeleton className="h-3 w-1/5" />
            </div>
          </div>
        ))}
      </div>
    );
  }
  if (error) {
    return (
      <div className="flex-1 overflow-y-auto p-4">
        <ErrorState message={error} />
      </div>
    );
  }
  if (tasks.length === 0) {
    return (
      <div className="flex flex-1 items-center justify-center overflow-y-auto">
        <EmptyState
          icon={Inbox}
          title="暂无任务"
          hint="用底部输入栏快速记录，或点击下方按钮"
          action={
            onCreateClick ? (
              <Button size="sm" variant="outline" onClick={onCreateClick}>
                <Plus size={14} className="mr-1" />
                新建任务
              </Button>
            ) : undefined
          }
        />
      </div>
    );
  }

  const projectById = new Map(projects.map((p) => [p.id, p]));
  const toggleFavorite = (t: TodoTask) => {
    void todoTaskUpdate(t.id, { is_favorite: t.is_favorite ? 0 : 1 });
  };
  const draggingTask = draggingId != null ? tasks.find((t) => t.id === draggingId) : undefined;

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={pointerWithin}
      onDragStart={handleDragStart}
      onDragEnd={(e) => void handleDragEnd(e)}
    >
      <div ref={scrollRef} className="flex-1 overflow-y-auto">
        <RowContainerDropZone totalSize={virtualizer.getTotalSize()}>
          {virtualizer.getVirtualItems().map((vi) => {
            const t = tasks[vi.index];
            const overdue = !!t.due_date && !t.done && t.due_date < Date.now();
            const due = dueText(t.due_date);
            const projectName = t.project_id != null ? projectById.get(t.project_id)?.title : undefined;
            return (
              // 绝对定位行容器：divide-y 在脱离文档流的兄弟间不生效，改每行自带 border-b。
              // 用 top 而非 transform 定位（见文件头注释）
              <div
                key={t.id}
                data-index={vi.index}
                ref={virtualizer.measureElement}
                style={{ position: "absolute", top: vi.start, left: 0, width: "100%" }}
              >
                <TaskContextMenu task={t} projects={projects} onOpenDetail={() => onOpenDetail(t.id)}>
                  <TaskRow
                    task={t}
                    index={vi.index}
                    count={tasks.length}
                    projectName={projectName}
                    due={due}
                    overdue={overdue}
                    dragging={draggingId === t.id}
                    registerRef={(el) => {
                      if (el) rowRefs.current.set(t.id, el);
                      else rowRefs.current.delete(t.id);
                    }}
                    onActivate={() => onOpenDetail(t.id)}
                    onFocusMove={(dir) => focusRow(vi.index + (dir === "down" ? 1 : -1))}
                    onToggleDone={() => void completeTask(t)}
                    onToggleFavorite={() => toggleFavorite(t)}
                  />
                </TaskContextMenu>
              </div>
            );
          })}
        </RowContainerDropZone>
      </div>

      {/* 拖拽浮层：简化行副本 */}
      <DragOverlay dropAnimation={null}>
        {draggingTask ? (
          <div className="flex items-center gap-3 rounded-md border bg-background px-4 py-3 shadow-lg">
            <span className="h-5 w-5 shrink-0 rounded-full border-2 border-muted-foreground/30" />
            <span className="max-w-[320px] truncate text-sm">{draggingTask.title}</span>
          </div>
        ) : null}
      </DragOverlay>
    </DndContext>
  );
}

/** 容器 droppable：承接落在行间隙/空白处的拖拽（尾部追加） */
function RowContainerDropZone({ totalSize, children }: { totalSize: number; children: React.ReactNode }) {
  const { setNodeRef } = useDroppable({ id: "rows-container" });
  return (
    <div ref={setNodeRef} style={{ height: totalSize, position: "relative" }}>
      {children}
    </div>
  );
}

interface TaskRowProps {
  task: TodoTask;
  index: number;
  count: number;
  projectName?: string;
  due: string | null;
  overdue: boolean;
  /** 本行正被拖拽（原始行降透明度，浮层由 DragOverlay 渲染） */
  dragging: boolean;
  registerRef: (el: HTMLDivElement | null) => void;
  onActivate: () => void;
  onFocusMove: (dir: "up" | "down") => void;
  onToggleDone: () => void;
  onToggleFavorite: () => void;
}

function TaskRow({
  task: t,
  index,
  count,
  projectName,
  due,
  overdue,
  dragging,
  registerRef,
  onActivate,
  onFocusMove,
  onToggleDone,
  onToggleFavorite,
}: TaskRowProps) {
  const { attributes, listeners, setNodeRef: setDragRef, isDragging } = useDraggable({
    id: `row:${t.id}`,
    // 浮层副本不再作为拖拽源；边界行禁拖无意义故不处理
    disabled: isDragging,
  });
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id: `row:${t.id}` });

  return (
    <div
      ref={(el) => {
        setDragRef(el);
        setDropRef(el);
        registerRef(el);
      }}
      role="button"
      tabIndex={0}
      aria-label={`${t.done ? "已完成" : "未完成"}任务：${t.title}`}
      className={cn(
        "group flex cursor-default items-center gap-3 border-b border-border/30 px-4 py-3 hover:bg-accent/30",
        "focus-visible:bg-accent/40 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring",
        isOver && "bg-accent/40",
        dragging && "opacity-40",
      )}
      onClick={onActivate}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return; // IME 组合期不响应
        if (isListActivationKey(e.key)) {
          e.preventDefault();
          onActivate();
          return;
        }
        const dir = listNavDirection(e.key);
        if (!dir) return;
        if (index === 0 && dir === "up") return;
        if (index === count - 1 && dir === "down") return;
        e.preventDefault();
        onFocusMove(dir);
      }}
    >
      {/* 拖拽手柄：hover 显现；点击不冒泡（避免误触打开详情） */}
      <button
        type="button"
        aria-label="拖拽排序"
        className="shrink-0 cursor-grab touch-none text-muted-foreground/40 opacity-0 transition-opacity hover:text-muted-foreground group-hover:opacity-100 active:cursor-grabbing"
        onClick={(e) => e.stopPropagation()}
        {...listeners}
        {...attributes}
      >
        <GripVertical size={14} />
      </button>

      {/* 完成 checkbox：圆环 */}
      <button
        type="button"
        aria-label={t.done ? "标记未完成" : "标记完成"}
        className={cn(
          "h-5 w-5 shrink-0 rounded-full border-2 transition-colors",
          t.done ? "border-primary bg-primary" : "border-muted-foreground/30 hover:border-primary",
        )}
        onClick={(e) => {
          e.stopPropagation();
          onToggleDone();
        }}
      >
        {t.done ? <CheckSvg /> : null}
      </button>

      {/* 标题 + 元信息 */}
      <div className="min-w-0 flex-1">
        <div
          className={cn(
            "truncate text-[15px] leading-5",
            t.done && "text-muted-foreground line-through",
          )}
        >
          {t.title}
        </div>
        {(t.priority > 0 || projectName || due) && (
          <div
            className={cn(
              "mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground",
              overdue && OVERDUE_COLOR_CLASS,
            )}
          >
            {t.priority > 0 && (
              <span
                className="h-1.5 w-1.5 rounded-full"
                style={{ background: PRIORITY_COLOR[t.priority] }}
              />
            )}
            {projectName && <span>{projectName}</span>}
            {due && (
              <span className="inline-flex items-center gap-0.5">
                <Clock size={11} />
                {due}
              </span>
            )}
          </div>
        )}
      </div>

      {/* 星标：hover 显现 */}
      <button
        type="button"
        aria-label={t.is_favorite ? "取消收藏" : "收藏"}
        className={cn(
          "shrink-0",
          t.is_favorite ? "opacity-100" : "opacity-0 group-hover:opacity-100",
        )}
        style={{ color: FAVORITE_COLOR }}
        onClick={(e) => {
          e.stopPropagation();
          onToggleFavorite();
        }}
      >
        <Star size={16} fill={t.is_favorite ? "currentColor" : "none"} />
      </button>
    </div>
  );
}

/** 完成态白色对勾（04 §3.2：白勾 SVG） */
function CheckSvg() {
  return (
    <svg
      viewBox="0 0 24 24"
      className="m-auto size-3 text-white"
      fill="none"
      stroke="currentColor"
      strokeWidth={3}
    >
      <path d="M20 6L9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
```

注意两点实施纪律：
1. `React.ReactNode` 类型引用需顶部 `import type { ReactNode } from "react"` 或写成 `import { useRef, useState, type ReactNode } from "react"` 并在 `RowContainerDropZone` 使用 `ReactNode`（与本仓其它文件的显式类型导入风格一致）。
2. 手柄按钮上的 `{...listeners}` 会注入 onPointerDown 等，必须放在 onClick 之后展开以免覆盖；`touch-none` 是 dnd-kit 触屏前提。

- [ ] **Step 5: 验证**

Run（workdir `apps/desktop`）: `pnpm typecheck && pnpm test && pnpm build`
Expected: 全绿。
手工冒烟（`pnpm dev`）：
1. hover 任一行左侧出现 ⠿ 手柄；按下拖动 6px 内松开 → 视为点击打开详情（activationConstraint 生效）；
2. 从手柄拖动行 A 到行 C 上释放 → 刷新后 A 位于 C 之前；拖到列表空白处 → A 到末尾；
3. 拖动过程中原始行半透明、浮层副本跟随指针；右键菜单、checkbox、星标行为不变；
4. 键盘回归：Tab/j/k/Enter 与 Task 3 冒烟完全一致；
5. DevTools Elements：滚动到底 DOM 行数恒定（虚拟化未被破坏）。

- [ ] **Step 6: Commit**

```bash
git add apps/desktop/src/features/todo/shared/position.ts apps/desktop/src/features/todo/shared/position.test.ts apps/desktop/src/features/todo/desktop/kanban-view.tsx apps/desktop/src/features/todo/desktop/task-list-view.tsx
git commit -m "feat(desktop): drag-to-reorder in list view (shared midpoint)"
```

---

### Task 8: Flutter 屏间转场（方向随入栈/出栈）

**Files:**
- Modify: `apps/mobile/lib/core/routing/app_router.dart`（三个 GoRoute 改 pageBuilder + 公共转场助手）
- Create: `apps/mobile/test/router_transition_test.dart`

**Interfaces:**
- Consumes: go_router ^17 `CustomTransitionPage`；现路由表 `/todo`、`/todo/tasks`、`/todo/:id`、`/settings`（app_router.dart:22-45，均为普通 builder）
- Produces:
  - 顶层函数 `CustomTransitionPage<void> pageSlideFromRight(Widget child, { LocalKey? key })` —— 入栈自右滑入 280ms easeOutCubic，返回时反向播放 220ms easeInCubic（方向随入栈/出栈）
  - `/todo/tasks`、`/todo/:id`、`/settings` 三路由启用该转场；`/todo` 根屏保持默认

- [ ] **Step 1: 写失败测试**

```dart
// apps/mobile/test/router_transition_test.dart
// 转场路由冒烟：pageSlideFromRight 构建的页面可正常入栈、动画收敛后渲染目标内容。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:orbit/core/routing/app_router.dart';

void main() {
  testWidgets('pageSlideFromRight 页面入栈后渲染目标内容', (tester) async {
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(path: '/a', builder: (_, __) => const Scaffold(body: Text('A 页'))),
        GoRoute(
          path: '/b',
          pageBuilder: (_, __) =>
              pageSlideFromRight(const Scaffold(body: Text('B 页'))),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.text('A 页'), findsOneWidget);

    final context = tester.element(find.text('A 页'));
    context.push('/b');
    await tester.pumpAndSettle(); // 等滑入动画收敛

    expect(find.text('B 页'), findsOneWidget);

    context.pop();
    await tester.pumpAndSettle(); // 反向播放同样收敛无异常
    expect(find.text('A 页'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run（workdir `apps/mobile`）: `flutter test test/router_transition_test.dart`
Expected: FAIL —— `pageSlideFromRight` 未定义。

- [ ] **Step 3: 实现 pageSlideFromRight 并接入路由**

`apps/mobile/lib/core/routing/app_router.dart` 顶层（`appRouter` 定义之前）加：

```dart
/// 入栈自右滑入（07 报告 §五-P1#12：方向随入栈/出栈，pop 时反向播放）。
/// 三屏 todo 栈与设置页共用；时长/曲线集中在此，后续调手感只改一处。
CustomTransitionPage<void> pageSlideFromRight(Widget child, {LocalKey? key}) =>
    CustomTransitionPage<void>(
      key: key,
      child: child,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(curved),
          child: child,
        );
      },
    );
```

然后把 `/todo/tasks`、`/todo/:id`、`/settings` 三个 GoRoute 由 `builder:` 改为 `pageBuilder:`，原 builder 的返回 widget 原样包进助手。以 `/todo/tasks` 为例（保持现有参数解析逻辑不动，仅示意包裹形态）：

```dart
    GoRoute(
      path: '/todo/tasks',
      pageBuilder: (context, state) => pageSlideFromRight(
        SubListScreen(
          view: /* ← 原builder中已有的 view 解析表达式，原样搬入 */,
          projectId: /* ← 同上 */,
          ungrouped: /* ← 同上 */,
        ),
      ),
    ),
```

`/todo/:id`（包 `DetailScreen(taskId: …)`）与 `/settings`（包其现有目标 widget）同法改造。`/todo` 根屏不改（首屏无入栈方向语义）。

- [ ] **Step 4: 运行测试**

Run（workdir `apps/mobile`）: `flutter test`
Expected: 既有 smoke/logic 测试 + 新增 router_transition_test 全部 passed。

- [ ] **Step 5: 真机/模拟器冒烟（可选但建议）**

Run（workdir `apps/mobile`）: `flutter run`
人工核对：侧栏 → 任一快捷视图（滑入）→ 点任务卡片进详情（再滑入）→ 连续返回两级（逐级反向滑出）；快速连点返回无动画错乱。

- [ ] **Step 6: Commit**

```bash
git add apps/mobile/lib/core/routing/app_router.dart apps/mobile/test/router_transition_test.dart
git commit -m "feat(mobile): directional screen transitions via go_router"
```

---

## Self-Review 记录

1. **Spec coverage**：07 报告 P1 表 ↔ Task 映射——#7→Task 1+2；#8（行可达+面板扩容）→Task 3+4；#9（全局搜索+假搜索按钮）→Task 5（按钮子项见范围勘误，已随 React 移动端删除而失效）；#10→Task 6；#11→Task 7；#12→Task 8（平台改 Flutter，见范围勘误）；#13→范围勘误（已实现，剔除）。七项全部闭环，无遗漏。
2. **Placeholder scan**：Task 8 Step 3 中 `/todo/tasks` 的 view/projectId/ungrouped 表达式标注为「原 builder 表达式原样搬入」——这是对现存代码的指认性搬移（同 P0 计划 Task 5 的实施注记做法），不是 TBD；其余步骤均含完整代码与确切行号锚点。
3. **Type consistency**：
   - `parseQuickInput` 的 ctx/返回形状在 Task 1 定义、Task 2 两处消费一致；
   - `planNextRecurringInstance(task, nowMs)` 双参签名在测试与 completeTask 调用一致（子任务克隆走独立的 `subtasksToClone`）；
   - `midpoint(prev?, next?)` 可选参数形态与 kanban-view 现调用 `midpoint(prev?.position, next?.position)` 及列表尾追 `midpoint(last.position)` 兼容；
   - Rust `GlobalSearchResult/CommentSearchHit` 字段 snake_case ↔ TS 接口逐一对照；tauri 命令参数 `keyword/limit` 与 JS invoke 键一致；
   - store 字段命名：Task 4 引入 `taskFormIntent/viewToggleIntent`，Task 5 只追加 `searchOpen/setSearchOpen`，两 Task 对 app-store 的修改互不重叠。
4. **Hook 安全**：Task 7 重写后的 TaskListView 将全部 hooks（useQueryClient/useRef/virtualizer/useState/useSensors）置于早退分支之前；TaskRow 的 useDraggable/useDroppable 位于独立组件内，规避 map 内 hook 违规。
