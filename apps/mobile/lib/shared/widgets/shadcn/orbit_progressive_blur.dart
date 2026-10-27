import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:progressive_background_blur/progressive_background_blur.dart';

import '../../../core/theme/app_colors.dart';

/// 页头/玻璃表面的渐进磨砂底层（顶强底弱的真·渐变模糊）
///
/// 背景：普通 [BackdropFilter] 只能整块均匀模糊，内容从标题栏下方穿过时，
/// 栏底边界是一条生硬的「清晰/模糊」分界；这里改用 Impeller 的 fragment
/// shader（两遍可分离高斯 + sigma 沿垂直方向插值），顶部 [sigma] 最糊、
/// 底部收敛到 0，与系统级标题栏磨砂同观感。
///
/// 双路径：
/// - Impeller：[ProgressiveBlur] 真·渐进模糊（sigma 单位是物理像素，
///   必须乘 DPR 才与 [BackdropFilter] 的逻辑像素观感一致）；
/// - Skia：[BackdropFilter] 均匀模糊 + ShaderMask 渐隐 tint（模糊量不渐进，
///   观感降级但结构不塌），Skia 不支持 shader 背景滤镜。
///
/// 视觉构成 = ① 模糊层 + ② surface tint 垂直渐变（高不透明度 → 低）。
/// 两者缺一不可：只有模糊没有 tint 时，亮色页面上标题会浮在杂乱的滚动像素上，
/// 可读性差（docs/05 §三）。
///
/// 调用约定：本组件只画背景，必须叠在页面内容的**上层**（页头 Stack 第一层），
/// 且与内容同处一个合成层——祖先出现 [RepaintBoundary] 之类的隔离边界时，
/// 背景滤镜读不到下方内容，表现为「只有 tint 没有磨砂」。
class OrbitProgressiveBlur extends StatelessWidget {
  const OrbitProgressiveBlur({
    super.key,
    this.sigma = 5,
    this.tintTopOpacity = 0.32,
    this.tintBottomOpacity = 0.06,
  });

  /// 顶部高斯模糊 sigma（逻辑像素）；底部恒为 0（清晰）。
  ///
  /// 5 是手机密度的舒适档：再低看得清底层文字，再高磨砂感变「糊墙」。
  /// shader 有效上限约 42 物理像素，24 逻辑像素已顶满。
  final double sigma;

  /// 顶部 tint 不透明度（保证页头标题在滚动内容上的对比度）。
  final double tintTopOpacity;

  /// 底部 tint 不透明度；留一点底味，避免栏底完全裸奔到底色。
  final double tintBottomOpacity;

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0) return const SizedBox.shrink();

    // tint 底色跟表面色走：亮色是白玻璃，暗色是深灰玻璃（不叠主题色，
    // 主题色调由页头自己的 accent 渐变层负责）。
    final tintColor = AppColors.ofContext(context).surface;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tint = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tintColor.withValues(alpha: tintTopOpacity),
                tintColor.withValues(alpha: tintBottomOpacity),
              ],
            ),
          ),
        );

        // 无界高度（如被塞进纵向 ListView）：退化为单层均匀模糊，
        // 否则 ShaderMask / ProgressiveBlur 的渐变锚点没有确定高度可用。
        if (!constraints.maxHeight.isFinite) {
          return ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: tint,
            ),
          );
        }

        final Widget blurred;
        if (ui.ImageFilter.isShaderFilterSupported) {
          // shader 的 sigma 是物理像素（包文档），乘 DPR 才能与
          // BackdropFilter 的逻辑像素语义对齐；漏乘会让真机模糊弱 2~3 倍。
          final sigmaScale = MediaQuery.devicePixelRatioOf(context);
          blurred = ProgressiveBlur(
            sigmaStart: sigma * sigmaScale,
            sigmaEnd: 0,
            child: tint,
          );
        } else {
          blurred = BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: ShaderMask(
              // 只渐隐 tint：模糊层本身被 BackdropFilter 整块应用，
              // 遮罩不能反作用于背景滤镜（saveLayer 会让 backdrop 读不到下方内容）。
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white,
                  Color(0xD9FFFFFF),
                  Colors.transparent,
                ],
                stops: [0.0, 0.5, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: tint,
            ),
          );
        }

        // ClipRect 限制模糊区域，避免 GPU 对整屏做滤镜（性能关键）。
        return ClipRect(child: blurred);
      },
    );
  }
}
