import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 将 [ScrollController] 的滚动偏移适配为 [ValueListenable<double>]，
/// 供 LiquidGlassTitleBar 的 scrollOffsetListenable 消费。
///
/// 未附着（hasClients=false）或尚未完成首次布局时返回 0，
/// 避免标题栏在首帧出现闪烁模糊。
class ScrollOffsetListenable extends ChangeNotifier
    implements ValueListenable<double> {
  ScrollOffsetListenable(this._controller) {
    _controller.addListener(_notify);
  }

  final ScrollController _controller;

  double get _offset =>
      _controller.hasClients && _controller.position.hasContentDimensions
          ? _controller.offset
          : 0.0;

  @override
  double get value => _offset;

  void _notify() => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_notify);
    super.dispose();
  }
}
