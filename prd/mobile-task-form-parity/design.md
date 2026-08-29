# 设计文档：移动端新建/编辑待办表单全量对齐桌面端

## 一、需求理解

在移动端 `form_bottom_sheet.dart` 补齐桌面端九字段 + 重复规则，保存链路对齐桌面端语义（提醒虚拟字段的删旧建新、hex 正则拦截、日期零点时间戳）。

## 二、关键技术决策

1. **不改桥接层**：`TodoTaskCreateInput` 已含 `status/startDate/endDate/repeatAfter/repeatMode/hexColor`，`todoReminderCreate/Delete/List` 已在三个 bridge 实现中齐全，纯 UI 层扩展。
2. **重复规则常量独立成 `repeat_logic.dart`**（`modules/todo/logic/`）：镜像桌面端 `repeat.ts` 的 `REPEAT_MODE` 常量、预设与中文标签（`repeatLabel`）。移动端没有完成推进引擎，`nextRepeatAt` 不移植——重复规则写库即跨端生效。
3. **控件形态沿用移动端设计语言**（docs/05 §4.4）：
   - 状态：三枚 ChoiceChip 横排（待办/进行中/已完成）；
   - 开始/结束/提醒时间：字段行（label + 值 + 清除），点按唤起 `showTodoDatePicker`（提醒再加 `showTimePicker`）；
   - 重复：Wrap ChoiceChips（不重复/每天/每周/每月/每年/自定义），自定义展开 间隔输入 + 单位选择；
   - 颜色：TextFormField + 正则 `^#[0-9a-fA-F]{6}$` 校验（桌面 MVP 同口径）。
   - 所有新控件均放在有限宽度 ListView 内，不使用 flex 子件（规避上轮 DropdownMenuItem 无界宽度崩溃的教训）。
4. **提醒同步语义照抄桌面端**：新建→`todoTaskCreate` 后 `todoReminderCreate`；编辑→比对首条未删除提醒，「清空删 / 变更删旧建新 / 未动跳过」。
5. **编辑回填**：`_loadEditing` 增量读取 `todoReminderList` 取该任务首条未删除提醒回填 remind_at。

## 三、实现步骤（≤5）

1. 新建 `repeat_logic.dart`：mode 常量、预设、`repeatLabel`、单位↔mode 映射；配套单测。
2. `form_bottom_sheet.dart` 状态/日期/提醒/重复/颜色字段 UI + 编辑回填扩展。
3. 保存链路：create/update 载荷补齐新字段（patch 显式 null 清空）；提醒删旧建新。
4. 测试红→绿：字段存在性、重复落库、提醒创建/变更、颜色校验拦截。
5. `flutter test` 全量 + `flutter analyze` 收口。

## 四、边界与风险

- **移动端无重复推进引擎**：完成重复任务不生成下一实例（桌面端完成时生成）；字段写库后由桌面端消费。属已知边界，不在本次范围。
- 状态仅发 `status` 字符串（与桌面一致），不补写 done/done_at。
- 提醒到期呈现依赖既有 ReminderDueEvent → NotificationService 链路，表单只负责写库。
- 字段增多后抽屉高度：已有 maxHeight 0.85 + Flexible ListView 滚动兜底。
- 时区：全部沿用本地时区自然日零点（`dateToMidnightMs`）既有口径。
