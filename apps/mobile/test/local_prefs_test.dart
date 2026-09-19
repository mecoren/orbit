// 本机 UI 偏好存储（移动端对应物 = 桌面 localStorage）单测
//
// flutter_test 无 path_provider handler（getApplicationSupportDirectory 抛
// MissingPluginException），恰好覆盖「落盘失败静默」这条红线；内存态语义
// 与默认值口径在此验证。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/services/local_prefs.dart';

void main() {
  test('未载入：按 fallback 读取（桌面口径隐藏已完成默认开）', () {
    expect(LocalPrefs.getBool('todo_hide_done', fallback: true), isTrue);
    expect(LocalPrefs.getBool('todo_hide_done', fallback: false), isFalse);
    expect(LocalPrefs.getBool('never_saved', fallback: false), isFalse);
  });

  test('setBool：内存态即时生效，落盘失败静默不抛', () async {
    await LocalPrefs.setBool('todo_hide_done', false);
    expect(LocalPrefs.getBool('todo_hide_done', fallback: true), isFalse);

    await LocalPrefs.setBool('todo_hide_done', true);
    expect(LocalPrefs.getBool('todo_hide_done', fallback: true), isTrue);
  });
}
