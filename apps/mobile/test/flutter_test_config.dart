import 'dart:async';

import 'package:intl/date_symbol_data_local.dart';

/// 全局测试引导（flutter test 约定文件：每个测试文件运行前执行一次）。
///
/// - **intl 日期语言数据**：设计系统 v3 的月历（`table_calendar`）与日期选择器
///   以 `locale: 'zh_CN'` 构建日格，`DateFormat` 也依赖语言数据。生产入口在
///   `main()` 里装载（`lib/main.dart`），而 widget 测试不经过 `main()`——
///   缺了会在首帧抛 `LocaleDataException`，所以在这里统一装载。
/// - `en_US` 一并装载：intl 的默认 locale 是 en_US，未装载时默认构造会报错。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await initializeDateFormatting('zh_CN');
  await initializeDateFormatting('en_US');
  await testMain();
}
