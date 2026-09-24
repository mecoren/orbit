/**
 * 应用内更新日志数据源（「关于 → 更新日志」）
 *
 * 与仓库根 `CHANGELOG.md` **同源双写**：发版时两处必须在同一次提交内一起补，
 * 只写其中一处会让应用内关于页永久缺失该版本（qraft 0.2.7 的既有教训）。
 * 头部条目版本必须等于 `apps/desktop/package.json#version`——
 * `src/test/release-consistency.test.ts` 强制校验，防版本与日志两头漂移。
 *
 * 提炼口径：`git log v<上一 tag>..HEAD --oneline` 按功能合并同类提交，
 * 忽略 docs/chore/style 等过程性噪声。首版 0.1.0 由 2026-08-23 初始提交至
 * 2026-09-24 的全部 543 次提交归并总结（222 feat / 130 fix / 32 perf / 84 docs，
 * 明细见 CHANGELOG.md）。
 */

export type ChangeCategory = "feature" | "fix" | "refactor" | "chore";

export interface ChangeEntry {
  category: ChangeCategory;
  description: string;
}

export interface ChangelogVersion {
  version: string;
  date: string;
  summary: string;
  changes: ChangeEntry[];
}

/** 新版本发布时在数组头部追加（与 CHANGELOG.md 同一次提交） */
export const CHANGELOG_VERSIONS: ChangelogVersion[] = [
  {
    version: "0.1.0",
    date: "2026-09-24",
    summary:
      "首个版本：本地优先 + 端到端加密的跨平台待办——桌面与移动双端全功能、云同步/备份、附件、统计与 ICS/CSV 数据出口一次到位",
    changes: [
      {
        category: "feature",
        description:
          "任务核心：项目 / 子任务 / 标签 / 评论 / 任务关联 / 六档优先级 / 多提醒 / 开始日期 / 完成进度 / 收藏",
      },
      {
        category: "feature",
        description:
          "五套视图：列表 / 看板 / 日历（月·议程·年，含农历与节假日）/ 表格 / Logbook（完成历史按日分组回看）",
      },
      {
        category: "feature",
        description:
          "重复任务：每周几、结束条件、when done 三档规则 + 「下次 M月d日」具体日预览 + 完成后自动推进（三端同一入口，滚周期留痕可溯源）",
      },
      {
        category: "feature",
        description:
          "效率入口：「我的一天」置顶视图、NLP 快速输入（明天/周X/!3/#项目/@标签）、全局搜索 Ctrl+K（FTS5 全文）、命令面板、快捷键面板",
      },
      {
        category: "feature",
        description: "批量与撤销：shift 区间多选 + 批量改期/优先级/项目 + Ctrl+Z 全局撤销 + 删除 5s 撤销窗口",
      },
      {
        category: "feature",
        description: "回收站：软删墓碑 → 恢复 / 彻底删除 / TTL 清理，彻底删除与清空同样可撤销",
      },
      {
        category: "feature",
        description:
          "任务资产管理：任务模板、保存的筛选器（可视化构建器）、一键复制任务（含子任务）、子任务转独立任务、项目归档与项目颜色",
      },
      {
        category: "feature",
        description:
          "提醒与通知：桌面系统通知三平台 + 推迟 10/30/60 分钟 + 点击直达详情 + Windows 计划通知；移动后台闹钟 + 通知推迟/完成按钮 + 桌面小组件/磁贴/图标角标",
      },
      {
        category: "feature",
        description:
          "可回看轨迹：通知历史中心 + 任务活动日志（更新变更集、子任务/评论/关联/提醒/附件独立轨迹、重复规则单条快照）+ 双端历史区块满档展档",
      },
      {
        category: "feature",
        description: "附件：内容寻址 + 端到端加密同步，桌面拖放直添 / Ctrl+V 粘贴截图 / 行内缩略图 / 应用内预览",
      },
      {
        category: "feature",
        description:
          "日期选择器与日历视图统一（双端）：同一套日格（农历/休班/今天/选中）+ 共用节假日缓存；日历与日期弹层滚轮步进翻月翻年",
      },
      {
        category: "feature",
        description:
          "安全：SQLCipher 本地加密 + 主密码体系 + 移动端生物识别解锁；云同步 AES-256-GCM 端到端加密（密钥不出本机，PBKDF2 600k 强度下限 guard）",
      },
      {
        category: "feature",
        description:
          "云同步：WebDAV / S3（含 OSS）三协议，表级分桶差量 + 单一清单 CAS（单行编辑只重传 1 个分桶），大附件分片断点续传，进入/退出应用强制同步，密钥方案 v2（结构性消除 KeyMismatch）",
      },
      {
        category: "feature",
        description: "冲突可见：LWW 败方整行快照留档 + 双端「冲突记录」字段级差异对照与一键恢复",
      },
      {
        category: "feature",
        description:
          "同步状态：左上角云图标（同步中/成功/失败 + 悬浮详情 + 点击立即同步），替换原右下角悬浮指示条",
      },
      {
        category: "feature",
        description:
          "备份与恢复：本地/云端全量备份融合为单入口（云端为准）+ 恢复预览与两段式确认 + AES-GCM 加密包（.orsync）",
      },
      {
        category: "feature",
        description:
          "数据出口：CSV 导入（orbit/Todoist/TickTick 预设）、CSV/JSON 导出（UTF-8 BOM）、ICS 导出与导入（VTODO）、明文导出",
      },
      {
        category: "feature",
        description: "统计面板：完成热力图（按年视图 + 年份切换）、连续完成天数、项目/优先级分布条；节假日数据层与日历徽标",
      },
      {
        category: "feature",
        description:
          "移动端（Flutter + FRB）功能对齐桌面：列表/详情/表单/日历/统计/搜索/侧滑手势/长按拖拽重排/NLP 输入/历史与冲突记录页",
      },
      {
        category: "feature",
        description: "应用内更新（手动检查 → 下载 → 安装重启）与关于页（应用信息 / 更新日志 / 开源许可 / 开源组件）",
      },
      {
        category: "feature",
        description: "桌面常驻：托盘 + 关窗驻留、窄窗侧栏自适应折叠、开机自启动（--hidden 静默驻留托盘，不弹主窗）",
      },
      {
        category: "feature",
        description:
          "移动端快速添加面板：底部抽屉统一新建入口（侧栏/日历/快捷方式同源），档位锚点卡片 + 选中态落图标 + 「编辑操作」设置页（跨段直拖、拖拽实时预览）",
      },
      {
        category: "feature",
        description:
          "移动端页头下拉面板 + 「编辑项目」整页 + 每项目视图档；任务列表重排（左右两列、优先级勾选框描边、卡片化、已完成折叠卡、长按整行拖拽）",
      },
      {
        category: "feature",
        description:
          "移动端 TickTick 对标：ICS 导入、提醒相对档、任务行元信息、密钥治理、日历议程档、修改后立即同步、日历更新时刻可配、附件缩略图、静态快捷方式",
      },
      {
        category: "feature",
        description:
          "移动端抽屉口径收口：确认/输入/密码/日期选择器统一底部抽屉（AlertDialog 清零）；字号档改全局 TextScaler，下拉刷新、骨架屏与动效对齐微软 To-Do",
      },
      {
        category: "feature",
        description:
          "桌面补齐：设置页「日历」分类、提醒相对档、更新兜底出口、备份设备标识、同步账本卡、关联徽标、重复完成推进提示",
      },
      {
        category: "refactor",
        description:
          "性能：双端全量虚拟化 + 路由懒加载 + vendor 分包（首屏 chunk 985KB → 63KB）+ 图标字体子集化（5.1MB → 7KB）；逾期置顶段并入虚拟流，万级驻留 76MB → 37MB",
      },
      {
        category: "refactor",
        description:
          "数据层：谓词下推 SQL + 列表通道列裁剪（万级 IPC 体积 -47%）+ FTS5 全文索引 + 软删前缀组合索引 + core 侧瘦投影 + db-change 表级精确失效",
      },
      {
        category: "refactor",
        description:
          "资源占用：驻留内存降档与超时回收、release profile（LTO/strip）、连接池收紧与 PRAGMA 逐连接、日志 TTL、附件缓存上限、数据库维护一键化",
      },
      {
        category: "refactor",
        description: "统一口径：tooltip 主题色底白字、滚动条标准、空状态居中、行高与溢出全库排查",
      },
      {
        category: "fix",
        description:
          "云同步五轮系统性探查收口：清单条件写曾未生效、WebDAV 大附件分片从未执行、回收站守卫线被非干净轮次推进、附件首传死锁、pull 漏拉窗口、rekey 后增量全跳",
      },
      {
        category: "fix",
        description:
          "两个上线阻塞修复：首同步补传 crypto/config（第二台设备无法入环）与 Android release 构建补 INTERNET 权限（真机云同步静默失败）",
      },
      {
        category: "fix",
        description:
          "本地与通知链：SQLCipher 多连接读取密文隐患（PRAGMA 逐连接注入）、KeyMismatch 恢复引导失效、Windows 通知身份（AUMID）、附件图片预览 blob 泄漏",
      },
      {
        category: "fix",
        description:
          "移动端修复：提醒推迟落库（推迟后提醒不再丢失）、撤销浮层到期自动收、多选崩屏与逾期行重复、长按拖拽误弹菜单、日历翻月错位",
      },
      {
        category: "chore",
        description: "质量门禁：CI 四 job（含 FRB codegen 一致性 + 内存门禁）+ Playwright 冒烟 + 发版一致性护栏（版本/日志不漂移）",
      },
      {
        category: "chore",
        description: "发布工程：tag 触发的三平台 + APK 发布流水线、应用内更新清单单点合成、版本单一来源与 bump 脚本",
      },
      {
        category: "chore",
        description: "文档体系：AGENTS.md 单一真相源、docs/01-09 编号文档、ADR 0001-0007/0010、7 份专项审查报告",
      },
    ],
  },
];
