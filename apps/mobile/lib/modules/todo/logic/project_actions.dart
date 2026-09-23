/// 项目（清单）写路径与保护流：侧栏长按菜单与「编辑项目」整页共用一份实现
///
/// 2026-09-23 抽出：编辑项目由对话框升级为整页后，归档 / 删除 / 保存三条路径
/// 两处调用（侧栏长按菜单、编辑页 ⋮ 更多）——各写一份必然漂移，故上收到本文件，
/// 页面只负责收集输入与 toast 之外的状态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/api/dto.dart';
import '../../../data/providers/bridge_provider.dart';
import '../../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../../shared/widgets/shadcn/orbit_toast.dart';
import '../providers/todo_providers.dart';

/// 归档 / 取消归档（桌面右键同口径）：is_archived 翻转经 patchJson；
/// 双失效（主列表 + 归档区）——两处入口都必须让两个列表同时收敛
Future<void> toggleProjectArchive(WidgetRef ref, TodoProject project) async {
  final next = project.isArchived == 1 ? 0 : 1;
  try {
    await ref
        .read(orbitBridgeProvider)
        .todoProjectUpdate(project.id, encodePatch({'is_archived': next}));
    ref.invalidate(todoProjectsProvider);
    ref.invalidate(todoArchivedProjectsProvider);
    WaitToast.success(next == 1 ? '项目已归档' : '已恢复到项目列表');
  } catch (_) {
    WaitToast.destructive('操作失败');
  }
}

/// 删除保护双流（docs/05 §4.1 文案）：有未完成任务拒绝；否则 destructive 确认。
/// 返回是否真的删掉了（调用方据此决定关不关页面）
Future<bool> deleteProject(
  WidgetRef ref,
  BuildContext context,
  TodoProject project,
  int undoneCount,
) async {
  if (undoneCount > 0) {
    // 单按钮信息抽屉（cancelLabel: null）：只告知，没有可点的「取消」
    await showConfirmBottomSheet(
      context,
      title: '无法删除',
      message: '该项目下还有 $undoneCount 条未完成任务，请先清空或移走任务后再删除。',
      confirmLabel: '我知道了',
      cancelLabel: null,
    );
    return false;
  }
  final confirmed = await showConfirmBottomSheet(
    context,
    title: '删除项目',
    message: '确定要删除项目「${project.title}」吗？该操作不可撤销。',
    confirmLabel: '删除',
    destructive: true,
  );
  if (!confirmed) return false;
  try {
    await ref.read(orbitBridgeProvider).todoProjectDelete(project.id);
    ref.invalidate(todoProjectsProvider);
    WaitToast.success('项目已删除');
    return true;
  } catch (_) {
    WaitToast.destructive('删除失败');
    return false;
  }
}

/// 保存名称 / 颜色（无变化不写库）。返回是否成功落库（失败已 toast，调用方
/// 只需决定是否关页面）。空标题拒绝——与新建同口径（trim 后为空即无效）
Future<bool> saveProject(
  WidgetRef ref, {
  required TodoProject project,
  required String title,
  required String hexColor,
}) async {
  final trimmed = title.trim();
  if (trimmed.isEmpty) {
    WaitToast.destructive('项目名称不能为空');
    return false;
  }
  final patch = <String, Object?>{
    if (trimmed != project.title) 'title': trimmed,
    if (hexColor != project.hexColor) 'hex_color': hexColor,
  };
  if (patch.isEmpty) return true;
  try {
    await ref
        .read(orbitBridgeProvider)
        .todoProjectUpdate(project.id, encodePatch(patch));
    ref.invalidate(todoProjectsProvider);
    WaitToast.success('已保存');
    return true;
  } catch (_) {
    WaitToast.destructive('保存失败');
    return false;
  }
}
