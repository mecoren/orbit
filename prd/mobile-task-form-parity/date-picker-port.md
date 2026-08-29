# 设计文档：移植 wait-home 日期选择组件

## 一、需求理解

移动端表单的日期选择从系统 Material DatePicker 换成 wait-home 项目的 `WaitDatePicker`（底部面板：月历 + 年月/年视图 + 可选时分步进），提醒时间改为单面板日期+时间一次选完。

## 二、关键技术决策

1. **来源**：`wait-home/apps/mobile/lib/shared/widgets/wait_date_picker.dart` + `app_month_calendar.dart`。orbit 的 `AppDimens/AppShapes/AppColors` 本就自 wait-home 移植，同名常量可直接对上。
2. **裁剪移植**（只带表单所需能力）：
   - 月历：保留 6×7 网格、今天/选中/周末/范围禁用；去掉节假日徽标、农历副标签、事件圆点、dayCellBuilder（依赖 wait-home 的 chinese_calendar_colors 等，不引入）。
   - 选择器：保留 `WaitDatePicker.pick(context, ...)` 编程式入口与整个 `_DatePickerSheet`；去掉表单字段形态的 widget（依赖 wait-home 的 colorThemeProvider/WaitFieldLabel）。
3. **适配点**：弹层容器改用 orbit 口径（`colors.popup` + `bottomSheetTopShape`）；年月网格的响应式列宽（AppBreakpoint）改固定 `maxCrossAxisExtent: 90`；底部安全区用 `MediaQuery.viewPaddingOf`；强调色由调用方传入（`OrbitAccents.todoAccent`）。
4. **接入方式**：`showTodoDatePicker` 函数签名不变、内部改为委托 `WaitDatePicker.pick`——表单四处调用点与 detail_screen 自动切换，无需改动调用方。`_pickReminder` 改为 `pick(showTime: true)` 单面板。
5. **语义注意**：`pick` 取消与「清除」都返回 null，调用侧维持「null 不动、chip 叉清空」的既有语义不变。

## 三、实现步骤（≤5）

1. 移植 `shared/widgets/app_month_calendar.dart`（裁剪版）。
2. 移植 `shared/widgets/wait_date_picker.dart`（pick + sheet）。
3. `form_bottom_sheet.dart`：`showTodoDatePicker` 委托 pick；`_pickReminder` 单面板 showTime。
4. 红测试：点「选择日期」→ 断言 wait 面板出现（确认/清除按钮、周标签），选日确认后 chip 回显；绿后跑全量。
5. `flutter analyze` 收口。

## 四、边界与风险

- Material 弹窗全局消失于该链路（符合预期）；detail_screen 截止日期修改同样换新面板。
- `pick` 的取消/清除同为 null：不引入行为回归（原 showTodoDatePicker 取消也是 null）。
- 时分步进按钮较小（wait-home 原设计），触达面积 44px 达标（padding 4 + icon 18 + Material 包裹）。
- 主题文字样式走 orbit `ThemeData.textTheme`，与 wait-home 同为 Material 3，无需改。
