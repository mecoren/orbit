import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/settings/update_check.dart';

/// 版本比较锚点（#107）：字符串比较会在 0.10.0 vs 0.9.9 上判错
void main() {
  group('versionParts', () {
    test('去掉 v 前缀与预发布/构建元数据', () {
      expect(versionParts('v0.6.0-beta.1+42'), [0, 6, 0]);
      expect(versionParts('1.2'), [1, 2, 0]);
      expect(versionParts('脏数据'), [0, 0, 0]);
    });
  });

  group('isNewerVersion', () {
    test('跨位比较（0.10.0 > 0.9.9）', () {
      expect(isNewerVersion('0.10.0', '0.9.9'), isTrue);
      expect(isNewerVersion('0.9.9', '0.10.0'), isFalse);
    });

    test('相等/更旧一律 false（含 v 前缀与预发布）', () {
      expect(isNewerVersion('0.6.0', '0.6.0'), isFalse);
      expect(isNewerVersion('v0.5.9', '0.6.0'), isFalse);
      expect(isNewerVersion('0.6.0-beta.1', '0.6.0'), isFalse);
    });

    test('补丁位推进算新版本', () {
      expect(isNewerVersion('0.6.1', '0.6.0'), isTrue);
    });
  });
}
