import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_shapes.dart';

/// 图片附件行内缩略图（等宽正方形 + [AppShapes.xs] 圆角）
///
/// 与桌面端 `AttachmentThumb`（`h-8 w-8 object-cover`）同口径：只渲染**已在
/// 本机落地的压缩字节**，解码尺寸按 `size × devicePixelRatio` 降采样（与详情
/// 全屏预览同一 F4 内存策略）——4K 照片在进纹理前先缩到缩略图像素，不产生
/// 整图解码内存。
///
/// 无字节（云端未拉取 / 源文件超阈值不做缩略图 / 空字节流）与解码失败
/// （字节非图片）一律回落 [fallback]，尺寸不变，列表不闪布局。
class OrbitImageThumb extends StatelessWidget {
  const OrbitImageThumb({
    super.key,
    required this.size,
    required this.fallback,
    this.bytes,
  });

  /// 边长（含圆角区）；调用方与同行文件图标目视等高
  final double size;

  /// 压缩字节；null 或空即直接回落 [fallback]
  final Uint8List? bytes;

  /// 无缩略图时的占位（图片/文件类型图标）
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    if (data == null || data.isEmpty) return _placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = (size * dpr).round();
    return ClipRRect(
      borderRadius: AppShapes.xs,
      child: Image.memory(
        data,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: px,
        cacheHeight: px,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder,
      ),
    );
  }

  Widget get _placeholder =>
      SizedBox.square(dimension: size, child: Center(child: fallback));
}
