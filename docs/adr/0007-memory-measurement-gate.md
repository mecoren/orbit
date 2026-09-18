# ADR 0007 — 内存度量口径与 CI 棘轮门禁

- **状态**：已采纳（Accepted）
- **日期**：2026-09-18
- **关联**：`docs/09_内存与性能治理专项-2026-09-18.md`（专项与进度）、ADR 0006（桌面驻留回收，本 ADR 不改动其决策）、实施为 `perf-metrics/{growth-curve,audit-unbounded}.mjs` + `perf-metrics/baselines.json` + `.github/workflows/ci.yml` 的 `perf-gate` job

## 一、背景

本仓库此前没有可复现的内存度量。已存在的两组数字口径互不相通，且其中一组已被证伪：

| 来源 | 数字 | 实际口径 |
| --- | --- | --- |
| `docs/性能与UX系统性优化报告-2026-09-12.md` | 万级 169MB used / 257MB total | **未强制 GC** 的 `usedJSHeapSize`——量的是「距上次 GC 以来分配了多少」，不是「还驻留多少」 |
| 同报告 | 操作峰 758MB | Chromium 进程树工作集，含 GPU/渲染器，与 JS 堆不同域 |
| ADR 0006 | 关窗驻留 330MB → 回收后 40MB | WebView 进程树视角，同样不可与 JS 堆互相换算 |

未 GC 口径直接导致了一次错误的归因：09-12 的结论认为「万行数组 + React Query
`placeholderData` 跨键保留」是驻留的线性项，据此把 A1（缓存驻留收敛）排为高收益。
09-18 用强制 GC 后的增长曲线实测：一份万行结果集只值 **2MB**（`heapMB_per_extra10kCopy`），
而真正的线性项是任务列表里**未虚拟化的逾期置顶段**（每行一份 DOM + 一份行对象）。
修掉它（A14）之后万级堆从 76MB 降到 37MB，DOM 节点数从 9980 降到 863 且在 1k/5k/10k
三档间变为平坦。也就是说：**口径错一位，优先级排反一批**。

同时，「加完优化再目测一遍任务管理器」不可复现也不可拦回退——内存治理需要的是一
个能在 PR 上判红的门禁，而不是一次性的探查报告。

## 二、决策

1. **JS 堆数字一律强制 GC 后再采**。启动参数固定
   `--js-flags=--expose-gc --enable-precise-memory-info`，每个采样点前后各一次
   `window.gc()`，采 `performance.memory.usedJSHeapSize` 的**差值**而非水位。没有 GC
   归零的数字不得作为决策输入，历史数字（09-12）已就地标注为「未强制 GC 口径」。
2. **阈值只准收紧，不准放松**。`perf-metrics/baselines.json` 三块语义分离：
   `thresholds` 是防回退线（超即判红）、`targets` 是 aspirational 目标（不判红）、
   `measured` 是最近一次实测。`thresholds` 来自实测乘 `BUFFER`，改它必须同批改
   `measured`，靠 diff 肉眼可见。
3. **有界性靠标记注释机验**。`audit-unbounded.mjs --gate` 扫无界容器（只 push 不
   clear/不删的 `Map`/`Set`/数组、无上限 LRU、`useRef` 累加等），豁免只有三种注释：
   `bounded:`（写明淘汰策略）、`bounded-by-lifecycle:`（写明清理时机）、
   `bounded-by-data:`（写明数据量天花板）。既有 5 处违例登记进 `knownUnbounded`
   逐文件逐规则计数，**只准降不准升**——不得靠加 `// eslint-disable` 式开关放行。
4. **CI 门禁跑 Linux headless Chromium，进程树 RSS 类指标在 Linux 上置 `null` 跳过**。
   Windows 的进程树（WebView2 多进程）与 Linux 的进程树成员不同，跨平台 RSS 不可比；
   故 `thresholdsByPlatform.linux.rssMB_10k = null`，只有堆内与 DOM 节点数这类
   平台无关口径参与判红。真机 RSS 由本地 `memory3.mjs --gate` 负责（桌面壳需真 exe）。

## 三、后果

- **正面**：内存回退在 CI 被拦；「先有数字再排优先级」成为可执行约束而非口号；
  A2/A6/A7 等后续项的验收有了统一口径（且 A2 已被判定不能只看 JS 堆，须看 IPC 字节）。
- **代价**：`perf-gate` 增加 CI 时长（构建 + 装 Chromium + 3 轮 ×3 档采样）；改动列表
  虚拟化结构、行高、`overscan` 都会移动基线，须显式重录 `baselines.json` 并在 commit
  message 里说明涨跌原因，否则等于偷偷放松阈值。
- **不影响产品口径**：门禁全部在 dev/CI 侧，无新外呼、无遥测、不改云端对象格式，
  `PRIVACY.md` 不变。

## 四、备选与否决

- **`Performance.measureUserAgentSpecificMemory()`**：数字更准（含跨域 iframe 与
  分离堆），但要求页面 `crossOriginIsolated`，即必须开 COOP/COEP 响应头——会为度量
  而扩大 Tauri 的隔离面并打断既有子资源加载路径。否决。
- **`--max-old-space-size` 类 V8 堆上限**：治标且可能把 OOM 变成用户可见崩溃，
  ADR 0006 §五 已否决过，本轮 A12 只负责把残留参数清掉。
- **纯人工目检（任务管理器 / `chrome://memory`）**：不可复现、不可拦回退，正是
  09-12 踩的坑。否决。
- **把口径写进 07 backlog**：07 是「用户影响 × 难度 × 目标一致性」排序的竞品
  backlog 唯一状态源，工程门禁塞进去会稀释其排序语义。故专项归 `docs/09`、决策归本
  ADR、约束摘要归 `AGENTS.md`。
