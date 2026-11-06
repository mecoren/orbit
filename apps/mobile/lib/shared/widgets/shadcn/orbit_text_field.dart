/// 文本输入（设计系统原语层，2026-11-02 收口）
///
/// **唯一入口**：全项目输入框一律走本原语，底层是 flutter_miuix 的
/// [MiuixTextField]（HyperOS 悬浮标签 + 聚焦 squircle 描边 + 16 圆角灰底）。
/// 业务层**不再**直接 new `TextField` / `TextFormField`——裸 Material 输入框
/// （OutlineInputBorder + 浮动 label）与 OS4 观感脱节，视觉上像个外来控件。
///
/// 两种形态：
/// - 默认 `filled`：标准表单输入（16 内边距 / 16 圆角 / 灰底 / 标签浮动）。
/// - `inline: true`：内联编辑器（详情页标题原地编辑、子任务行、评论框、项目名
///   行、周期数值格）——透明底、零内边距、标签降级为占位符，边框/布局交给宿主
///   容器。
///
/// **补齐 MiuixTextField 没有的三件事**（组件库精确锁版，不能改上游）：
/// - `maxLength`：库不暴露 `inputFormatters`，改在 onChanged 里按 grapheme 截断
///   （emoji/组合字符不会被切成半个）；不画 Material 的 `0/200` 计数器——OS4
///   输入框没有这个配件。
/// - `validator`：包一层 [FormField]，`Form.validate()` 照常生效；miuix 没有
///   错误态样式，错误文案画在输入框下方并把标签/描边染成 [AppColorSet.destructive]。
/// - `onTapOutside`：库不暴露，包 [TapRegion]（详情页标题「点空白处提交」用）。
///
/// 键盘避让/焦点管理沿用 miuix：整块可点聚焦、`obscureText` 强制单行。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';

/// 标准表单输入 / 内联编辑器（见文件头）
class OrbitTextField extends StatelessWidget {
  const OrbitTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.label,
    this.hintText,
    this.helperText,
    this.errorText,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.onTapOutside,
    this.leadingIcon,
    this.trailingIcon,
    this.style,
    this.validator,
    this.autovalidateMode,
    this.inline = false,
    this.insideMargin,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// 浮动标签（filled）；[inline] 下作为占位符
  final String? label;

  /// 无 [label] 时作为占位符；两者都传时以 [label] 为准（占位不叠加）
  final String? hintText;

  /// 输入框下方的说明文字（如「已保存，留空沿用」）
  final String? helperText;

  /// 外部错误态（表单校验之外的一次性提示，如解锁失败）
  final String? errorText;

  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final bool obscureText;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;

  /// 限长（按 grapheme 截断；null = 不限）
  final int? maxLength;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// 点击输入框之外（内联编辑器提交用）
  final VoidCallback? onTapOutside;

  final Widget? leadingIcon;
  final Widget? trailingIcon;

  /// 正文样式（字号/字重；颜色由主题统一）
  final TextStyle? style;

  /// 表单校验（为空/空串时返回错误文案）
  final FormFieldValidator<String>? validator;
  final AutovalidateMode? autovalidateMode;

  /// 内联形态（透明底、零内边距、占位符标签）
  final bool inline;

  /// 内联态内边距覆写（默认 0；行内需要触控高度时给 vertical: 8）
  final EdgeInsets? insideMargin;

  @override
  Widget build(BuildContext context) {
    if (validator == null) {
      return _field(context, errorText, onChanged);
    }
    // FormField 只借校验状态：校验源是 controller 当前文本（与 Material
    // TextFormField 的取值口径一致），错误文案由 _field 画在框下方
    return FormField<String>(
      initialValue: controller?.text ?? '',
      autovalidateMode: autovalidateMode,
      validator: (_) => validator!(controller?.text),
      builder: (field) {
        final error = field.errorText ?? errorText;
        return _field(context, error, (value) {
          field.didChange(value);
          onChanged?.call(value);
        });
      },
    );
  }

  Widget _field(
    BuildContext context,
    String? error,
    ValueChanged<String>? onChanged,
  ) {
    final colors = AppColors.ofContext(context);
    final base = MiuixTextFieldDefaults.textFieldColors(context);
    final isPlaceholder = label == null || inline;
    final placeholder = isPlaceholder ? (label ?? hintText ?? '') : null;

    final field = Theme(
      // MiuixTextField 内部的 Material TextField 只覆盖了 isDense/零内边距/
      // 无边框，`filled` 仍回落到全局 `inputDecorationTheme`（本仓为
      // filled: true + 浅灰底），会在 miuix 自己的 squircle 之外再铺一块
      // 直角灰矩形——内联态（标题原地编辑）看着像叠了个老式输入框。
      // 底色统一交给 miuix 的背景，Material 那层恒关。
      data: Theme.of(context).copyWith(
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
              filled: false,
              fillColor: Colors.transparent,
            ),
      ),
      child: MiuixTextField(
        controller: controller,
        focusNode: focusNode,
        label: placeholder ?? label ?? '',
        useLabelAsPlaceholder: isPlaceholder,
        enabled: enabled,
        readOnly: readOnly,
        autofocus: autofocus,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        // 库内 `singleLine` 会强制 maxLines=1（obscureText 同理）
        singleLine: maxLines == 1,
        minLines: minLines,
        maxLines: maxLines,
        textStyle: style ?? TextStyle(fontSize: 15, color: colors.bodyText),
        // 内联态的 borderColor 是透明的（不能画出聚焦框），库内
        // `cursorColor ?? borderColor` 会连带把光标也画成透明——显式给
        // 主题强调色，否则原地编辑看不见光标。
        cursorColor: inline ? OrbitAccents.themeAccent : null,
        leadingIcon: leadingIcon,
        trailingIcon: trailingIcon,
        insideMargin: inline
            ? (insideMargin ?? EdgeInsets.zero)
            : const EdgeInsets.all(AppDimens.space16),
        cornerRadius: inline ? 8 : MiuixTextFieldDefaults.cornerRadius,
        colors: _colors(colors, base, error),
        onChanged: _limited(onChanged),
        onSubmitted: onSubmitted,
      ),
    );

    final withError = _withMessage(context, field, error);
    return onTapOutside == null
        ? withError
        : TapRegion(onTapOutside: (_) => onTapOutside!(), child: withError);
  }

  /// 错误态染色：标签与聚焦描边转破坏性色；内联态保持透明底
  ///
  /// 标签色统一走 [AppColorSet.secondaryText]（Miuix 主题的
  /// `onSecondaryContainer` 在本仓桥接为正文色，做占位/浮动标签偏黑）。
  MiuixTextFieldColors _colors(
    AppColorSet colors,
    MiuixTextFieldColors base,
    String? error,
  ) =>
      MiuixTextFieldColors(
        backgroundColor: inline ? Colors.transparent : base.backgroundColor,
        labelColor: error != null ? colors.destructive : colors.secondaryText,
        borderColor: error != null
            ? colors.destructive
            : (inline ? Colors.transparent : base.borderColor),
      );

  /// 限长：库没有 inputFormatters，按 grapheme 截断后回写 controller
  ValueChanged<String>? _limited(ValueChanged<String>? inner) {
    final max = maxLength;
    if (max == null) return inner;
    return (value) {
      final target = controller;
      if (target != null && value.characters.length > max) {
        final truncated = value.characters.take(max).toString();
        target.value = TextEditingValue(
          text: truncated,
          selection: TextSelection.collapsed(offset: truncated.length),
        );
        inner?.call(truncated);
        return;
      }
      inner?.call(value);
    };
  }

  /// 错误/说明文案（miuix 输入框没有内置这两行）
  Widget _withMessage(BuildContext context, Widget field, String? error) {
    final text = error ?? helperText;
    if (text == null || text.isEmpty) return field;
    final colors = AppColors.ofContext(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        Padding(
          padding: const EdgeInsets.only(
            top: AppDimens.space4,
            left: AppDimens.space4,
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: error != null ? colors.destructive : colors.secondaryText,
            ),
          ),
        ),
      ],
    );
  }
}
