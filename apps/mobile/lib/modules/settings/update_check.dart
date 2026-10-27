/// 版本比较纯函数（#107 检查更新）
///
/// 只比前三段数字：`0.6.0` vs `0.6.1`、`0.10.0` vs `0.9.9` 这类比较不能走字符串；
/// 预发布/构建元数据（`-beta.1` / `+42`）忽略——移动端只判断「清单版本是否更新」，
/// 不需要完整的 semver 优先级。
library;

/// 把 `v0.6.0-beta.1+42` 归一为 `[0, 6, 0]`（非法段按 0）
List<int> versionParts(String version) {
  final cleaned = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
  final head = cleaned.split(RegExp(r'[+-]')).first;
  final parts = head.split('.');
  return [
    for (var i = 0; i < 3; i++)
      i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
  ];
}

/// `latest` 是否比 `current` 新（严格大于；相等/更旧一律 false）
bool isNewerVersion(String latest, String current) {
  final l = versionParts(latest);
  final c = versionParts(current);
  for (var i = 0; i < 3; i++) {
    if (l[i] != c[i]) return l[i] > c[i];
  }
  return false;
}
