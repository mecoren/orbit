// apps/desktop/src/features/todo/shared/shortcut-help.ts
/**
 * 快捷键帮助数据（常量表 + 分组）——快捷键帮助面板（? 呼出）的唯一口径源。
 *
 * 收录原则：面板只列用户需要主动发现的快捷键——全局命令键 + 视图内
 * 键盘可达性（j/k 导航）+ 多选/撤销等高频操作；输入框内 IME/Enter 等
 * 表单惯例不收（帮助面板不是按键字典）。
 *
 * 展示层（shortcut-help-dialog.tsx）按 group 顺序渲染；本表为纯数据，
 * 同目录 shortcut-help.test.ts 锁定分组结构与键位格式。
 */

export interface ShortcutEntry {
  /** 键位展示（⌘/Ctrl 前缀 + 主键；如 "Ctrl+P"） */
  keys: string;
  /** 动作说明 */
  action: string;
}

export interface ShortcutGroup {
  /** 分组标题 */
  title: string;
  entries: ShortcutEntry[];
}

/** 是否命中「? 呼出帮助」（Shift+/；帮助面板自身打开时不再触发） */
export function isHelpShortcut(e: { shiftKey?: boolean; ctrlKey?: boolean; metaKey?: boolean; key: string }): boolean {
  return e.shiftKey === true && !e.ctrlKey && !e.metaKey && (e.key === "?" || e.key === "/");
}

export const SHORTCUT_GROUPS: ShortcutGroup[] = [
  {
    title: "全局",
    entries: [
      { keys: "Ctrl+P", action: "命令面板（搜索或跳转）" },
      { keys: "Ctrl+K", action: "全局搜索（任务 / 项目 / 评论）" },
      { keys: "Ctrl+Z", action: "撤销最近的删除 / 清空等操作" },
      { keys: "?", action: "打开本帮助面板" },
    ],
  },
  {
    title: "任务列表",
    entries: [
      { keys: "j / ↓", action: "下移焦点（列表 / 表格视图）" },
      { keys: "k / ↑", action: "上移焦点（列表 / 表格视图）" },
      { keys: "Enter / Space", action: "打开焦点任务详情" },
      { keys: "Shift+点击勾选框", action: "以上一次勾选为锚做区间多选" },
    ],
  },
  {
    title: "任务详情",
    entries: [
      { keys: "Ctrl+Enter", action: "评论输入框内直接提交" },
      { keys: "Esc", action: "关闭详情抽屉 / 弹层" },
    ],
  },
];
