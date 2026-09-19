import 'package:flutter/material.dart';

/// 随子树释放一组 `TextEditingController`（把控制器的生命周期绑到弹层上）
///
/// 为什么不能在外面 `await showModalBottomSheet(...)` / `showDialog(...)`
/// 之后直接 `controller.dispose()`：
/// 弹层 pop 之后还有一段退出动画，动画期间表单会重建一次并重新给 TextField
/// 挂上这些 controller —— 已释放的 controller 会让 debug 断言直接崩溃
/// （release 下则是未定义行为）。挂在弹层子树里释放，生命周期天然对齐。
class ControllerDisposer extends StatefulWidget {
  const ControllerDisposer({
    super.key,
    required this.controllers,
    required this.child,
  });

  final List<TextEditingController> controllers;
  final Widget child;

  @override
  State<ControllerDisposer> createState() => _ControllerDisposerState();
}

class _ControllerDisposerState extends State<ControllerDisposer> {
  @override
  void dispose() {
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
