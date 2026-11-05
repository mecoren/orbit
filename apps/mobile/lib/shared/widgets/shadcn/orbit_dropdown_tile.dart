/// 下拉偏好行的旧入口（兼容别名，2026-11-05）
///
/// 实现已并入 [OrbitDropdownPreference]（弹层与「今天」页头 ⋮ 菜单同一套
/// 玻璃菜单口径）。本文件只留 re-export + 类型别名：存量 import 路径与
/// `OrbitDropdownTile` 名称继续可用，`orbitDropdownPopupKey` 也从新实现导出，
/// 不需要改任何调用点。
library;

import 'orbit_dropdown_preference.dart' show OrbitDropdownPreference;

export 'orbit_dropdown_preference.dart'
    show OrbitDropdownPreference, orbitDropdownPopupKey;

/// 旧名（等价于 [OrbitDropdownPreference]）
typedef OrbitDropdownTile<T> = OrbitDropdownPreference<T>;
