import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/services/app_update_service.dart';

/// 应用内更新（Android APK 下载/安装）纯函数锚点
///
/// 版本串来自网络清单，进入文件路径前必须净化；进度文案不应出现负数/NaN。
void main() {
  group('apkFileName', () {
    test('与 Release 资产命名同口径', () {
      expect(apkFileName('0.1.2'), 'Orbit_0.1.2.apk');
    });

    test('容忍 v 前缀与首尾空白', () {
      expect(apkFileName(' v0.1.2 '), 'Orbit_0.1.2.apk');
    });

    test('净化路径分隔符与 ..（防写出缓存目录）', () {
      for (final raw in ['../../evil', r'1.0\..\x', '..']) {
        final name = apkFileName(raw);
        expect(name, startsWith('Orbit_'));
        expect(name, endsWith('.apk'));
        expect(name.contains('/'), isFalse);
        expect(name.contains(r'\'), isFalse);
        expect(name.contains('..'), isFalse);
      }
    });

    test('空版本回落 unknown', () {
      expect(apkFileName('   '), 'Orbit_unknown.apk');
    });
  });

  group('formatDownloadBytes', () {
    test('MB/KB 分档与未知大小', () {
      expect(formatDownloadBytes(0), '0 KB');
      expect(formatDownloadBytes(2048), '2 KB');
      expect(formatDownloadBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatDownloadBytes(-1), '未知大小');
    });
  });
}
