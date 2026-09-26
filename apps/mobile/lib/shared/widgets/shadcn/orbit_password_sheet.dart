/// 密码输入抽屉（设计系统 v3，2026-09-24 收口）
 ///
 /// **为什么收口**：此前 6 处密码输入（改主密码 / 开启加密 / 指纹密码确认 /
 /// 改同步密码 / 升 v2 / 密钥包密码）各写一套中央 `AlertDialog`，与「输入一律
 /// 走底部抽屉」口径相悖。本文件是密码类输入的唯一口径：
 /// - 承载与形状：`showModalBottomSheet` + [bottomSheetTopShape] +
 ///   [bottomSheetMotion]（与共享弹层族同源，见 `orbit_sheets.dart`）
 /// - 骨架：[OrbitSheetScaffold]（内容可滚、按钮固定底部、键盘避让）
 /// - 字段：1~3 个 `obscureText` 输入（`labels` 定标签，`hints` 可选占位）；
 ///   首个自动聚焦，末个回车即确认
 /// - 返回：确认 → 各字段原文的 `List<String>`（顺序同 `labels`）；取消 /
 ///   点遮罩 / 下滑 → `null`。合法性校验（空值 / 长度 / 两次一致）由调用方
 ///   在关闭后执行，与此前 `AlertDialog` 行为一致
 /// - 控制器交给抽屉子树释放（退出动画期间表单会重建一次，提前 dispose
 ///   会让那一帧读到已释放的 controller，见 `ControllerDisposer`）
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../controller_disposer.dart';
import 'orbit_sheet_scaffold.dart';
import 'orbit_sheets.dart' show bottomSheetMotion, bottomSheetTopShape;

/// 密码输入抽屉；[labels] 与返回列表等长且同序
Future<List<String>?> showPasswordSheet(
  BuildContext context, {
  required String title,
  String? message,
  required List<String> labels,
  List<String>? hints,
  required String confirmLabel,
}) async {
  assert(labels.isNotEmpty, '密码抽屉至少需要一个字段');
  assert(hints == null || hints.length == labels.length, 'hints 须与 labels 等长');
  final controllers = [for (var i = 0; i < labels.length; i++) TextEditingController()];
  final colors = AppColors.ofContext(context);
  return showModalBottomSheet<List<String>>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => ControllerDisposer(
      controllers: controllers,
      child: StatefulBuilder(
        builder: (ctx, setSheetState) {
          final sheetColors = AppColors.ofContext(ctx);
          void submit() => Navigator.of(ctx).pop(
                [for (final c in controllers) c.text],
              );

          return OrbitSheetScaffold(
            title: title,
            contentPadding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              0,
              AppDimens.space16,
              AppDimens.space16,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (message != null)
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: sheetColors.secondaryText,
                    ),
                  ),
                if (message != null) const SizedBox(height: AppDimens.space12),
                for (var i = 0; i < labels.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppDimens.space8),
                  TextField(
                    controller: controllers[i],
                    obscureText: true,
                    autofocus: i == 0,
                    textInputAction: i == labels.length - 1
                        ? TextInputAction.done
                        : TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: labels[i],
                      hintText: hints?[i],
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                ],
              ],
            ),
            actions: OrbitSheetActions(
              cancelLabel: '取消',
              onCancel: () => Navigator.of(ctx).pop(),
              confirmLabel: confirmLabel,
              onConfirm: submit,
            ),
          );
        },
      ),
    ),
  );
}
