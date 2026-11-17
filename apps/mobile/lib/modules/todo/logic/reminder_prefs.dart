import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/local_prefs.dart';
import 'constant_interval.dart';

/// 本机偏好键：与桌面 `todo_constant_interval_default` 同键名同语义
const _kConstantIntervalDefault = 'todo_constant_interval_default';

/// 持续提醒默认间隔（毫秒）
///
/// 只作**新建提醒**的初值：单条提醒开启「持续提醒」时可在详情页单独调整，
/// 改这个设置不会回改已有提醒（避免设置页一改、全库静默变更）。
/// 本机偏好，不进 DB、不进云同步。
class ConstantIntervalDefaultController extends Notifier<int> {
  @override
  int build() {
    final raw = LocalPrefs.getString(_kConstantIntervalDefault);
    final parsed = raw == null ? null : int.tryParse(raw);
    return normalizeConstantIntervalMs(parsed);
  }

  Future<void> set(int ms) async {
    final value = normalizeConstantIntervalMs(ms);
    state = value;
    await LocalPrefs.setString(_kConstantIntervalDefault, '$value');
  }
}

/// 设置页 / 新建表单 / 详情页共用的默认间隔 Provider
final constantIntervalDefaultProvider =
    NotifierProvider<ConstantIntervalDefaultController, int>(
      ConstantIntervalDefaultController.new,
    );
