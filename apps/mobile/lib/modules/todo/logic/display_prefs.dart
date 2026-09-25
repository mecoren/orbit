import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/local_prefs.dart';

/// 任务行的显示偏好（对齐竞品「显示详细 / 显示设置」）
///
/// 三位开关控制列表行副标题（标签 / 项目名）的渲染粒度：
/// - [detail]：主开关——关闭后行内只剩标题 + 右列时刻（竞品「显示详细」
///   关闭即单行紧凑形态）；关着时另外两位不生效；
/// - [project]：副标题里的所属清单名；
/// - [tags]：副标题里的标签色点。
///
/// 落盘键走 [LocalPrefs]（与桌面 localStorage 视图态同口径，不进 DB），
/// 值 '1'/'0'，读取脏数据回落默认（全开）。
class DisplayPrefsState {
  const DisplayPrefsState({
    required this.detail,
    required this.project,
    required this.tags,
  });

  final bool detail;
  final bool project;
  final bool tags;

  static const fallback =
      DisplayPrefsState(detail: true, project: true, tags: true);

  Map<String, bool> toJson() =>
      {'detail': detail, 'project': project, 'tags': tags};

  @override
  bool operator ==(Object other) =>
      other is DisplayPrefsState &&
      other.detail == detail &&
      other.project == project &&
      other.tags == tags;

  @override
  int get hashCode => Object.hash(detail, project, tags);
}

/// 本机偏好键（LocalPrefs 承载；键名沿用 `todo_*` 视图态命名族）
const _kDetail = 'todo_show_detail';
const _kProject = 'todo_show_project';
const _kTags = 'todo_show_tags';

/// 显示偏好控制器：开关即写即落盘（失败静默），行渲染经 provider 跟随重建
class DisplayPrefsController extends Notifier<DisplayPrefsState> {
  @override
  DisplayPrefsState build() => DisplayPrefsState(
        detail: LocalPrefs.getBool(_kDetail, fallback: true),
        project: LocalPrefs.getBool(_kProject, fallback: true),
        tags: LocalPrefs.getBool(_kTags, fallback: true),
      );

  Future<void> setDetail(bool value) => _set((s) =>
      DisplayPrefsState(detail: value, project: s.project, tags: s.tags));

  Future<void> setProject(bool value) => _set((s) =>
      DisplayPrefsState(detail: s.detail, project: value, tags: s.tags));

  Future<void> setTags(bool value) => _set((s) =>
      DisplayPrefsState(detail: s.detail, project: s.project, tags: value));

  Future<void> _set(DisplayPrefsState Function(DisplayPrefsState) reducer) async {
    state = reducer(state);
    await LocalPrefs.setBool(_kDetail, state.detail);
    await LocalPrefs.setBool(_kProject, state.project);
    await LocalPrefs.setBool(_kTags, state.tags);
  }
}

/// 显示偏好 Provider（清单页面板 / 显示设置抽屉 / 任务行共用）
final displayPrefsProvider =
    NotifierProvider<DisplayPrefsController, DisplayPrefsState>(
  DisplayPrefsController.new,
);
