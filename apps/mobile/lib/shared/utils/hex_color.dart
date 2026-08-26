import 'package:flutter/material.dart';

/// hex 颜色字符串解析（#RRGGBB / #AARRGGBB）
///
/// 数据层的 hex_color 字段为自由文本，解析失败回落 [fallback]，
/// 保证脏数据不致渲染崩溃。
Color hexToColor(String? hex, {Color fallback = const Color(0xFF3B82F6)}) {
  var value = hex?.trim() ?? '';
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 6) value = 'FF$value';
  if (value.length != 8) return fallback;
  final parsed = int.tryParse(value, radix: 16);
  if (parsed == null) return fallback;
  return Color(parsed);
}
