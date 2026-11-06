/// 设置类页面分组卡（原语层：卡外分组标题 + 零内边距分组卡，2026-11-06 收口）
///
/// 设置主页面与**全部设置子页面**统一此版式，与 flutter_miuix
/// `example/lib/showcase/preferences.dart` 的「列表项 Item」逐像素同构：
/// - 分组标题 = 卡外 [MiuixSmallTitle]（28×8 内边距、14sp 加粗、
///   `onBackgroundVariant` 中性灰）；
/// - 卡体 = 水平 12 外距的 [MiuixCard]（squircle 圆角、零内边距）；
/// - 行件自带 16×14 内边距（[kSettingsRowMargin]），行间用
///   [OrbitSettingsDivider]（左缩进 56 对齐行标题），按压灰底横贯整卡；
/// - 说明段/尾注/按钮区由 [OrbitSettingsDesc]、[OrbitSettingsNote]、
///   [OrbitSettingsActions] 提供，水平 16 与行内边距同线。
///
/// 两种内容口径：
/// - 默认构造（块状）：说明段、表单流、按钮组等整块内容，内容区补
///   16/12/16/16 内边距；
/// - [OrbitSettingsGroup.rows]（行式）：下拉偏好行、开关行、跳转行，
///   零内边距，由行件自己撑内边距——**卡片不能有水平内边距**，否则
///   下拉行展开时的按压灰底会被缩成卡片中间一小块。
///
/// 与 `orbit_group_card.dart` 的 `OrbitGroupCard` 分工：那是详情/日志类
/// 「无标题 + 分隔线缩进 16」的分组卡（行首无图标槽），本原语面向设置项
/// （卡外分组标题 + 行式行件、分隔线缩进 56 对齐行标题）；两者卡体同口径，
/// 调用方按「有没有分组标题/图标槽」择一，不要各自再手搓卡片。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import 'orbit_switch.dart';

/// 行内边距：与 miuix 示例 `_itemMargin` / 外观页同值（16×14）
const EdgeInsets kSettingsRowMargin = EdgeInsets.symmetric(
  horizontal: 16,
  vertical: 14,
);

/// 分组卡（见文件头）
class OrbitSettingsGroup extends StatelessWidget {
  const OrbitSettingsGroup({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required Widget this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  }) : children = null;

  /// 行式构造：内容零内边距，行件自带 [kSettingsRowMargin]
  const OrbitSettingsGroup.rows({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required List<Widget> this.children,
  }) : child = null,
       padding = EdgeInsets.zero;

  /// 卡外分组标题；缺省只渲染卡片（标题由调用方另置时用）
  final String? title;

  /// 标题行副说明（如「近 5 次」「桶指纹与水位线」）
  final String? subtitle;

  /// 标题行尾随控件（如「刷新」文本钮）
  final Widget? trailing;

  /// 块状内容（默认构造）
  final Widget? child;

  /// 行式内容（[OrbitSettingsGroup.rows]）
  final List<Widget>? children;

  /// 内容区内边距（行式构造恒为零）
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final content =
        child ??
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children ?? const <Widget>[],
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) _SettingsGroupTitle(
          title: title!,
          subtitle: subtitle,
          trailing: trailing,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
          child: MiuixCard(
            child: Padding(padding: padding, child: content),
          ),
        ),
      ],
    );
  }
}

/// 卡外分组标题行（无副标题/尾随时直接走库内 [MiuixSmallTitle]，
/// 有则自绘同款：28×8 内边距、副说明 12px 灰、尾随贴右）
class _SettingsGroupTitle extends StatelessWidget {
  const _SettingsGroupTitle({
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    if (subtitle == null && trailing == null) return MiuixSmallTitle(title);
    final theme = MiuixTheme.of(context);
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space28,
        AppDimens.space8,
        AppDimens.space16,
        AppDimens.space8,
      ),
      child: Row(
        children: [
          Expanded(
            child: MiuixText(
              title,
              style: theme.textStyles.subtitle,
              color: theme.colors.onBackgroundVariant,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: AppDimens.space8),
            Flexible(
              child: MiuixText(
                subtitle!,
                fontSize: 12,
                color: colors.secondaryText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          ?trailing,
        ],
      ),
    );
  }
}

/// 按设置页口径给行列表插行间分隔线（首行前与末行后都不加）
///
/// 条件行较多（自动备份的频率/时刻/星期等）时用它，避免逐行手写
/// `if (i > 0) OrbitSettingsDivider()`。
List<Widget> orbitSettingsSeparated(List<Widget> rows) => [
  for (var i = 0; i < rows.length; i++) ...[
    if (i > 0) const OrbitSettingsDivider(),
    rows[i],
  ],
];

/// 行间分隔线（左缩进 56 对齐行标题，避开起始图标槽位）
class OrbitSettingsDivider extends StatelessWidget {
  const OrbitSettingsDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.only(left: 56), child: MiuixHorizontalDivider());
}

/// 卡内说明段（卡片顶部描述文字，水平 16 与行内边距同线）
class OrbitSettingsDesc extends StatelessWidget {
  const OrbitSettingsDesc(this.text, {super.key, this.faint = false});

  final String text;

  /// 弱化（0.7 透明度；用于排障/技术性说明）
  final bool faint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: _SettingsHintText(text, faint: faint),
  );
}

/// 卡内尾注（行区之下的补充说明）
class OrbitSettingsNote extends StatelessWidget {
  const OrbitSettingsNote(this.text, {super.key, this.faint = false});

  final String text;
  final bool faint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: _SettingsHintText(text, faint: faint),
  );
}

class _SettingsHintText extends StatelessWidget {
  const _SettingsHintText(this.text, {required this.faint});

  final String text;
  final bool faint;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: colors.secondaryText.withValues(alpha: faint ? 0.7 : 1),
      ),
    );
  }
}

/// 卡内按钮区（水平 16，与行内边距同线）
class OrbitSettingsActions extends StatelessWidget {
  const OrbitSettingsActions(this.child, {super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: child,
  );
}

/// 跳转/取值行（标题 + 可选摘要在左，尾随值 + 箭头在右）
///
/// [trailing] 排在内置箭头之前（角标/转环等小件）；[titleColor] 供
/// 危险操作行（红字）覆写标题色。
class OrbitSettingsRow extends StatelessWidget {
  const OrbitSettingsRow(
    this.title, {
    super.key,
    this.summary,
    this.value,
    this.titleColor,
    this.onClick,
    this.enabled = true,
    this.trailing,
    this.leading,
  });

  final String title;
  final String? summary;
  final String? value;
  final Color? titleColor;
  final VoidCallback? onClick;
  final bool enabled;
  final Widget? trailing;

  /// 行首图标位（如「从本地文件恢复」的文档图标）
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return MiuixArrowPreference(
      title: title,
      summary: summary,
      titleColor: titleColor == null
          ? null
          : MiuixBasicComponentColors(
              color: titleColor!,
              disabledColor: theme.colors.disabledOnSecondaryVariant,
            ),
      insideMargin: kSettingsRowMargin,
      onClick: onClick,
      enabled: enabled,
      startAction: leading,
      endActions: [
        if (value != null)
          MiuixText(
            value!,
            fontSize: theme.textStyles.body2.fontSize,
            color: enabled
                ? theme.colors.onSurfaceVariantActions
                : theme.colors.disabledOnSecondaryVariant,
          ),
        ?trailing,
      ],
    );
  }
}

/// 开关行（标题/摘要在左、[OrbitSwitch] 贴右；整行可点切换）
///
/// [onChanged] 为 null 即禁用（标题/摘要同转灰，开关不可用，miuix 禁用项口径）。
class OrbitSettingsSwitchRow extends StatelessWidget {
  const OrbitSettingsSwitchRow(
    this.title, {
    super.key,
    this.summary,
    required this.value,
    required this.onChanged,
    this.switchFirst = false,
  });

  final String title;
  final String? summary;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 开关置于行首（少数「总开关 + 其下紧跟子项」的分组用；缺省贴右）
  final bool switchFirst;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final toggle = OrbitSwitch(
      value: value,
      onChanged: onChanged,
      semanticLabel: title,
    );
    return MiuixBasicComponent(
      title: title,
      summary: summary,
      insideMargin: kSettingsRowMargin,
      onClick: onChanged == null ? null : () => onChanged(!value),
      startAction: switchFirst ? toggle : null,
      endActions: [if (!switchFirst) toggle],
    );
  }
}
