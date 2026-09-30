# 设计文档：桌面端工具栏收拢——右上角「排序 ↑↓」+「更多 ···」双菜单

## 一、需求理解

把任务面板工具栏 12 控件收拢为 5（搜索框 + ↑↓ + ··· + 新增 + 模板），低频功能全部进菜单，数据语义零变化、纯入口搬家；参照 TickTick Web 的「排序 ↑↓」与「···」双菜单形态（详见同目录 requirements.md）。

## 二、关键技术决策

1. **新组件承载两个菜单**（`features/todo/desktop/toolbar-menus.tsx`）：`SortMenuButton` 与 `MoreMenuButton` 两个导出，全部状态经 props 传入（statusFilter/sortKey/sortDir/viewMode/kanbanGroupBy/hideDone 及各 setter、回调）——task-panel.tsx 已 600+ 行，菜单 UI 约新增 200 行，拆文件防继续膨胀；任务面板仍是唯一状态源（与现「状态提升在 panel、UI 只转发」结构一致）。
2. **原语选型**：`DropdownMenu` + `DropdownMenuSub`（shadcn 原语既有导出，实现前核对 `ui/dropdown-menu.tsx` 缺则补齐）做就地展开子菜单——对应移动端 `orbit_dropdown_panel` 的「子项就地展开」交互口径；**不用** Popover 嵌 Popover（犯禁，docs 桌面端 PopoverContent 内禁嵌弹层）。
3. **视图图标排不关菜单**：五个视图按钮用普通 `<button>`（非 `DropdownMenuItem`），Radix 不会因点击普通按钮关闭菜单；当前视图 `bg-primary/10 text-primary` 高亮（复用现五联钮类名）。
4. **排序方向语义**（唯一的行为新增）：
   - `TaskSortDir = "asc" | "desc"`；LS 键 `todo_sort_dir`，未存过 = 各档位**现状默认方向**（due/title=升序，priority/created=降序——首次升级用户可见顺序零变化）；
   - `sortTasks(tasks, sortKey, dir?)` 把 dir 折进主比较符号：截止时间档**无截止恒排最后**（升/降序都不变）；平局回落键（created_at/position）方向不随 dir 翻转；`manual` 档忽略 dir；
   - 菜单「顺序」行显示当前生效方向，点按在升/降间切换并写入 LS。
5. **收纳映射**（工具栏 → 菜单，aria-label 保持原文案以便 e2e 平移）：
   - ↑↓：排序 Select（→「排序」子菜单）、看板分组 Select（→「分组」子菜单，仅看板显示）；
   - ···：视图五联钮（→图标排）、状态/优先级 Select（→子菜单）、隐藏已完成（→CheckboxItem，disabled 条件原样保留：isLogbook || statusFilter==="done"）、存为视图（→MenuItem，buildConditions 预填链路原样）、Ctrl+P（→MenuItem）、标签管理（→MenuItem）。
   - 保留：搜索框、新增、模板、完成进度线。
6. **可发现性兜底**：收拢后菜单触发钮带常显 Tooltip（「排序」「更多」）；「···」菜单各子菜单标题行右侧回显当前档位文案（对应图 2「时间 >」的回显样式），不开菜单也能从 Tooltip 知道入口。

## 三、实现步骤

1. `ui/dropdown-menu.tsx` 核对/补齐 `DropdownMenuSub` 族导出（Sub/SubTrigger/SubContent/CheckboxItem）。
2. `task-filters.ts`：`sortTasks` 加 `dir` 参数（含无截止恒最后、回落键不翻转、manual 忽略的注释口径），补同目录 `task-filters.test.ts` 用例（due 档降序仍无截止最后、created 升序从旧到新、priority 升序低在前）。
3. `task-panel.tsx`：新增 `sortDir` state（LS 读写同 `loadSortKey` 风格），删除 9 个被收拢控件的 JSX，向 `toolbar-menus.tsx` 传 props。
4. 新建 `toolbar-menus.tsx` 实现 `SortMenuButton` / `MoreMenuButton`（中文块注释头部写口径）。
5. e2e：改 `showDoneTasks` 等 5 处按钮路径为菜单路径，新增「↑↓ 方向切换」「··· 图标排切视图」用例；跑 typecheck + vitest + 全量 e2e。

## 四、边界与风险

- **e2e 选择器批量失效**（已知最重成本）：`showDoneTasks`（显示已完成任务钮）、日历/看板视图钮、存为视图钮、标签管理钮共 5 处需改走菜单——菜单路径 `getByRole("menuitem")` 定位，先开菜单再点项。
- **排序方向语义扩散**：`sortTasks` 调用方不止工具栏（列表/表格/矩阵视图都可能直接调）——实现时 grep 全部调用点，dir 只从工具栏注入，其余调用点不传（吃默认 = 现状），避免方向概念渗入日历/看板分组。
- **Radix 子菜单键盘导航**：Sub 菜单方向键语义与移动端面板不同（桌面=悬停/右键展开），属原语既定行为不额外定制。
- **localStorage 新键**：`todo_sort_dir` 需补进 docs/04 §七键全集清单。
- 顺带改动禁令：不重构工具栏其余 JSX、不动搜索/新增/模板链路，防噪音 diff。
