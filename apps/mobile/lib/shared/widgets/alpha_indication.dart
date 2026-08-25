import 'package:flutter/material.dart';

/// 统一的 Alpha 指示交互反馈（无 ripple）
///
/// 自 wait-home/mobile 移植。参考 SaltUI `AlphaIndication`：
/// 用叠加黑遮罩表达按压/悬停/聚焦态，不使用 Material `InkWell`，
/// 无 ripple，跨平台一致的"品牌手感"。
///
/// 视觉规范（与 SaltUI 对齐）：
/// - **pressed** → 黑遮罩 alpha [pressedAlpha]（默认 0.30）
/// - **hovered / focused** → 黑遮罩 alpha [hoverFocusAlpha]（默认 0.10）
/// - **disabled** → 整体 [Opacity] 为 [disabledOpacity]（默认 0.5），不响应手势
///
/// 内部包一层 [Material]（transparent）以兼容需要 Material 祖先的子组件。
class AlphaIndication extends StatefulWidget {
  const AlphaIndication({
    super.key,
    required this.onTap,
    required this.child,
    this.enabled = true,
    this.borderRadius,
    this.pressedAlpha = 0.30,
    this.hoverFocusAlpha = 0.10,
    this.disabledOpacity = 0.5,
  });

  /// 点击回调。为 null 且 [enabled] 为 true 时仍可显示按压反馈但不触发回调。
  final VoidCallback? onTap;

  /// 子组件
  final Widget child;

  /// 是否启用。false 时整体半透明且不响应手势。
  final bool enabled;

  /// 遮罩裁剪圆角，应与子组件圆角一致，避免遮罩溢出圆角区域。
  final BorderRadius? borderRadius;

  /// 按压态黑遮罩 alpha
  final double pressedAlpha;

  /// 悬停/聚焦态黑遮罩 alpha
  final double hoverFocusAlpha;

  /// 禁用态整体不透明度
  final double disabledOpacity;

  @override
  State<AlphaIndication> createState() => _AlphaIndicationState();
}

class _AlphaIndicationState extends State<AlphaIndication> {
  bool _isPressed = false;
  bool _isHovered = false;
  bool _isFocused = false;

  /// 当前应叠加的黑遮罩 alpha
  double get _overlayAlpha {
    if (!widget.enabled) return 0.0;
    if (_isPressed) return widget.pressedAlpha;
    if (_isHovered || _isFocused) return widget.hoverFocusAlpha;
    return 0.0;
  }

  void _setPressed(bool value) {
    if (_isPressed != value) {
      setState(() => _isPressed = value);
    }
  }

  void _setHovered(bool value) {
    if (_isHovered != value) {
      setState(() => _isHovered = value);
    }
  }

  void _setFocused(bool value) {
    if (_isFocused != value) {
      setState(() => _isFocused = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    if (!widget.enabled) {
      return Opacity(opacity: widget.disabledOpacity, child: content);
    }
    return content;
  }

  Widget _buildContent() {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.enabled ? widget.onTap : null,
        child: Focus(
          onFocusChange: _setFocused,
          child: MouseRegion(
            onEnter: (_) => _setHovered(true),
            onExit: (_) => _setHovered(false),
            child: _buildWithOverlay(),
          ),
        ),
      ),
    );
  }

  /// 在 child 之上叠加黑遮罩（仅当有按压/悬停/聚焦态时）
  Widget _buildWithOverlay() {
    final alpha = _overlayAlpha;
    if (alpha == 0.0) {
      return widget.child;
    }

    final overlay = Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: alpha),
        ),
      ),
    );

    final stack = Stack(
      children: [widget.child, overlay],
    );

    // 按圆角裁剪遮罩，避免遮罩溢出子组件圆角区域
    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: stack,
      );
    }
    return stack;
  }
}
