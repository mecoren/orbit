import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import 'orbit_sheet_scaffold.dart';
import 'orbit_sheets.dart';

/// 自定义取色抽屉（清单颜色行的「自定义」入口）
///
/// **2026-11-01 换承载**：取色本体从 shadcn `ColorPicker`（色域 + 滑杆 +
/// HEX 三档）换成 miuix `MiuixColorPicker`——HSV 三滑杆（渐变轨道 + 环形
/// 发光指示器 + 顶部预览条，Compose 版 1:1 移植）；HEX 精确输入旧口径
/// 由 shadcn 取色器自带，现由 [MiuixTextField] 浮动标签输入框承接
/// （「填一个色值」的意图保留：滑杆拖动回写文本、文本输入驱动滑杆，双向
/// 同步且不打断输入中的光标）。外壳沿用底部抽屉族——形状/动效常量取
/// [bottomSheetTopShape] / [bottomSheetMotion]，按钮行走 [OrbitSheetActions]，
/// 与全项目弹层同口径。
///
/// 返回 `null` = 取消（点遮罩 / 下滑 / 取消钮）。
Future<Color?> showOrbitColorPickerSheet(
  BuildContext context, {
  required Color initial,
}) async {
  var picked = initial;
  final result = await showModalBottomSheet<Color>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => OrbitSheetScaffold(
        title: '自定义颜色',
        contentPadding: const EdgeInsets.fromLTRB(
          AppDimens.space16,
          0,
          AppDimens.space16,
          AppDimens.space16,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HexField(
              color: picked,
              onColorPicked: (c) => setSheetState(() => picked = c),
            ),
            const SizedBox(height: AppDimens.space12),
            MiuixColorPicker(
              color: picked,
              onColorChanged: (c) => setSheetState(() => picked = c),
            ),
          ],
        ),
        actions: OrbitSheetActions(
          cancelLabel: '取消',
          onCancel: () => Navigator.of(sheetContext).pop(),
          confirmLabel: '确定',
          onConfirm: () => Navigator.of(sheetContext).pop(picked),
        ),
      ),
    ),
  );
  return result;
}

/// HEX 文本输入（`#RRGGBB`，兼容 3 位缩写）
///
/// 双向同步：外部（滑杆/预览）改色回写文本；输入解析成功即上报。输入框聚焦
/// 中不回写，避免光标被滑杆改动顶飞。控制器/焦点随本组件子树生命周期释放。
class _HexField extends StatefulWidget {
  const _HexField({required this.color, required this.onColorPicked});

  /// 当前选中色（变化时回写文本，聚焦中除外）
  final Color color;

  /// 输入解析成功回调
  final ValueChanged<Color> onColorPicked;

  @override
  State<_HexField> createState() => _HexFieldState();
}

class _HexFieldState extends State<_HexField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatHex(widget.color));
    _focus = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HexField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color != oldWidget.color &&
        !_focus.hasFocus &&
        _parseHex(_controller.text) != widget.color) {
      _controller.text = _formatHex(widget.color);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MiuixTextField(
      controller: _controller,
      focusNode: _focus,
      label: 'HEX 色值（#RRGGBB）',
      useLabelAsPlaceholder: true,
      singleLine: true,
      onChanged: (text) {
        final parsed = _parseHex(text);
        if (parsed != null) widget.onColorPicked(parsed);
      },
    );
  }
}

/// 解析 `#RRGGBB` / `RRGGBB` / `#RGB` 文本；非法输入返回 null（不打断输入，
/// 等 6 位凑齐再应用）
Color? _parseHex(String raw) {
  var s = raw.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 3) {
    s = s.split('').map((c) => '$c$c').join();
  }
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// 输出 `#RRGGBB`（大写）
String _formatHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';
