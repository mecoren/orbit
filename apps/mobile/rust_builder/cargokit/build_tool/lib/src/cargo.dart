/// This is copied from Cargokit (which is the official way to use it currently)
/// Details: https://fzyzcjy.github.io/flutter_rust_bridge/manual/integrate/builtin

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:toml/toml.dart';

class ManifestException {
  ManifestException(this.message, {required this.fileName});

  final String? fileName;
  final String message;

  @override
  String toString() {
    if (fileName != null) {
      return 'Failed to parse package manifest at $fileName: $message';
    } else {
      return 'Failed to parse package manifest: $message';
    }
  }
}

class CrateInfo {
  CrateInfo({required this.packageName, required this.libName});

  final String packageName;

  /// [lib] name（实际产物文件名前缀）。与 packageName 分离：当 crate 自定义
  /// [lib] name（如 orbit-flutter → orbit_flutter）时，cargo 产物为
  /// liborbit_flutter.so，而按 packageName 查找会静默失配、什么都不拷贝。
  final String libName;

  static CrateInfo parseManifest(String manifest, {final String? fileName}) {
    final toml = TomlDocument.parse(manifest);
    final package = toml.toMap()['package'];
    if (package == null) {
      throw ManifestException('Missing package section', fileName: fileName);
    }
    final name = package['name'];
    if (name == null) {
      throw ManifestException('Missing package name', fileName: fileName);
    }
    // 与 cargo 命名规则一致：未声明 [lib] name 时，默认取包名并把 '-' 换成 '_'
    final lib = toml.toMap()['lib'];
    final libName = (lib?['name'] as String?) ?? name.replaceAll('-', '_');
    return CrateInfo(packageName: name, libName: libName);
  }

  static CrateInfo load(String manifestDir) {
    final manifestFile = File(path.join(manifestDir, 'Cargo.toml'));
    final manifest = manifestFile.readAsStringSync();
    return parseManifest(manifest, fileName: manifestFile.path);
  }
}
