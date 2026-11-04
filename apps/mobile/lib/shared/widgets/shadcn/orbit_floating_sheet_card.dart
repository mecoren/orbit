/// 底部弹层的浮起圆角卡片（2026-11-04 全量收口）
///
/// 此前只有 `showConfirmBottomSheet` 是「脱离屏幕边缘、四周留白」的浮起卡片，
/// 其余抽屉贴边顶圆角。现在所有 `showModalBottomSheet` 的内容统一套这一层：
/// - 左/右/下各 `space16` 留白，底边不贴屏幕、四角圆角完整可见
/// - 四角 `AppShapes.xl`（28），不是贴边抽屉的顶圆角
/// - 底色取语义色 `popup`；`Material(type: transparency)` 兜底水波纹
///
/// **承载必须透明**：调用点 `backgroundColor: Colors.transparent`，否则
/// BottomSheet 自带的贴边背景会从卡片外圈露出来。遮罩统一 0.32（见
/// `app_theme.dart` 的 `bottomSheetTheme.modalBarrierColor`）。
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';

class OrbitFloatingSheetCard extends StatelessWidget {
  const OrbitFloatingSheetCard({super.key, required this.child, this.cardKey});

  final Widget child;

  /// 挂到卡片 `Container` 上的 key（确认弹层形态回归靠它定位卡片）
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Container(
      key: cardKey,
      width: double.infinity,
      margin: const EdgeInsets.only(
        left: AppDimens.space16,
        right: AppDimens.space16,
        bottom: AppDimens.space16,
      ),
      decoration: BoxDecoration(
        color: colors.popup,
        borderRadius: AppShapes.xl,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
