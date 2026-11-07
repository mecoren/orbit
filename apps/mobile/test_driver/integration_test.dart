// `flutter drive` 的测试驱动入口（integration_test 官方口径）。
//
// 为什么需要这一层：`flutter drive --profile` 必须有一个 driver 侧入口来
// 接收用例上报的数据并落盘（默认写 `build/integration_response_data.json`）。
// `perf-metrics/mobile-jank.mjs` 就是读这份文件取帧耗时。
//
// **只在 profile 档跑**：`watchPerformance` 依赖引擎真实帧调度与 timeline
// 上报，debug 档下 integration_test 会直接抛错（见 `perf_jank_test.dart` 的
// `skip: !kProfileMode` 守卫）。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
