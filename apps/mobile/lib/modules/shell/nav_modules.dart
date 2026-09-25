import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/icon_map.dart';
import '../../services/local_prefs.dart';

/// 底部导航可配置模块池（对齐竞品「功能模块」：模块可启用/停用/排序）
///
/// **枚举序 = 路由分支序**：`app_router.dart` 的 `StatefulShellRoute.branches`
/// 必须按本枚举顺序声明（`goBranch` 按下标寻分支，见 [branchIndex]），两端
/// 改动必须同步，`nav_modules_test.dart` 有序数不变量测试兜底。
enum OrbitNavModule {
  today('今天', OrbitIcons.sun, '聚焦今日待办。', '/today'),
  sidebar('清单', OrbitIcons.list, '用清单和项目管理任务。', '/todo'),
  calendar('日历', OrbitIcons.calendarDays, '在月历与年视图中规划任务。', '/todo/calendar'),
  matrix('四象限', OrbitIcons.grid, '关注重要且紧急的事情。', '/todo/matrix'),
  stats('统计', OrbitIcons.trending, '完成趋势与热力图。', '/todo/stats'),
  search('搜索', OrbitIcons.search, '快速搜索任务、项目与评论。', '/todo/search'),
  trash('回收站', OrbitIcons.archive, '已删除任务可恢复或彻底清除。', '/todo/trash'),
  settings('设置', OrbitIcons.settings, '查看和修改设置项。', '/settings');

  const OrbitNavModule(this.label, this.icon, this.description, this.path);

  /// 页签文案
  final String label;

  /// 页签 / 面板 / 配置页共用的图标
  final IconData icon;

  /// 配置页里的一行简介（竞品同款）
  final String description;

  /// 模块根路由（页签分支根）
  final String path;

  /// 路由分支下标（枚举序 = 分支序，见枚举文档）
  int get branchIndex => index;

  /// 落盘 id 解析（脏数据返回 null 由调用方剔除）
  static OrbitNavModule? tryParse(String id) {
    for (final m in values) {
      if (m.name == id) return m;
    }
    return null;
  }
}

/// 底部导航配置状态：启用区 / 停用区两段各自有序（竞品「功能模块」同款）
///
/// 规则：底栏 = 启用序前 [bottomTabLimit] 个模块 + 固定「更多」动作位；
/// 启用序剩余模块收进「更多」面板；至少保留一个启用模块。
class NavModulesState {
  const NavModulesState({required this.enabled, required this.disabled});

  /// 底栏页签容量（对齐竞品：底栏最多 4 个模块页签）
  static const int bottomTabLimit = 4;

  /// 启用模块（有序；前 [bottomTabLimit] 个进底栏）
  final List<OrbitNavModule> enabled;

  /// 停用模块（有序；不出现在任何导航入口，配置页可再启用）
  final List<OrbitNavModule> disabled;

  /// 底栏模块页签（启用序前 [bottomTabLimit] 个）
  List<OrbitNavModule> get bottomTabs =>
      enabled.take(bottomTabLimit).toList(growable: false);

  /// 「更多」面板条目（启用序 [bottomTabLimit] 位之后）
  List<OrbitNavModule> get morePanelItems =>
      enabled.skip(bottomTabLimit).toList(growable: false);

  /// 默认配置：**八模块全启用**（存量升级口径）——底栏 = 启用序前 4 个
  /// （今天/清单/日历/四象限），「更多」面板 = 其余 4 个（统计/搜索/回收站/
  /// 设置），与可配置前的固定导航完全一致；停用区空。
  static NavModulesState fallback() {
    const enabled = [
      OrbitNavModule.today,
      OrbitNavModule.sidebar,
      OrbitNavModule.calendar,
      OrbitNavModule.matrix,
      OrbitNavModule.stats,
      OrbitNavModule.search,
      OrbitNavModule.trash,
      OrbitNavModule.settings,
    ];
    return const NavModulesState(enabled: enabled, disabled: []);
  }

  /// 落盘序列化：`{"on": [id…], "off": [id…]}`
  Map<String, dynamic> toJson() => {
        'on': [for (final m in enabled) m.name],
        'off': [for (final m in disabled) m.name],
      };

  /// 反序列化 + 消毒：未知 id 剔除、去重、池内缺员补进停用区、
  /// 启用区清空回落默认（配置页保证非空，脏数据不再二次兜底会出现空底栏）
  static NavModulesState parse(String raw) {
    if (raw.isEmpty) return fallback();
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return fallback();
      final enabled = <OrbitNavModule>[];
      final disabled = <OrbitNavModule>[];
      for (final section in [map['on'], map['off']]) {
        if (section is! List) continue;
        for (final id in section) {
          final module = OrbitNavModule.tryParse('$id');
          if (module == null) continue;
          if (enabled.contains(module) || disabled.contains(module)) continue;
          (section == map['on'] ? enabled : disabled).add(module);
        }
      }
      // 池内缺员（跨版本新增模块）：补进停用区，保证 8 模块全员可见可配
      for (final m in OrbitNavModule.values) {
        if (!enabled.contains(m) && !disabled.contains(m)) disabled.add(m);
      }
      if (enabled.isEmpty) return fallback();
      return NavModulesState(enabled: enabled, disabled: disabled);
    } catch (_) {
      return fallback();
    }
  }
}

/// 本机偏好键（[LocalPrefs] 承载，与桌面 localStorage 视图态同口径，不进 DB）
const navModulesPrefsKey = 'bottom_nav_modules';

/// 底部导航配置控制器：启停 / 两段区内重排，写后落盘（失败静默）
///
/// 纯壳层视图态（模块排布），不涉及业务数据——与排序档等 LocalPrefs 偏好
/// 同一承载口径，不走 Rust 核心。
class NavModulesController extends Notifier<NavModulesState> {
  @override
  NavModulesState build() =>
      NavModulesState.parse(LocalPrefs.getString(navModulesPrefsKey) ?? '');

  /// 启用 ↔ 停用切换（停用追加到停用区尾、启用追加到启用区尾；竞品同款；
  /// 最后一个启用模块不可停用）
  Future<void> toggle(OrbitNavModule module) async {
    final current = state;
    if (current.enabled.contains(module)) {
      if (current.enabled.length <= 1) return;
      state = NavModulesState(
        enabled: [...current.enabled]..remove(module),
        disabled: [...current.disabled, module],
      );
    } else {
      state = NavModulesState(
        enabled: [...current.enabled, module],
        disabled: [...current.disabled]..remove(module),
      );
    }
    await _persist();
  }

  /// 区内拖拽重排（页面 onReorderItem 直传；newIndex 已是「语义插入位」——
  /// Flutter 该回调对移除项做过位移补偿，这里不再二次归一化，与侧栏项目
  /// 重排同口径）
  Future<void> reorder({
    required bool enabledSection,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    final source = enabledSection ? state.enabled : state.disabled;
    final list = [...source];
    list.insert(newIndex, list.removeAt(oldIndex));
    state = enabledSection
        ? NavModulesState(enabled: list, disabled: state.disabled)
        : NavModulesState(enabled: state.enabled, disabled: list);
    await _persist();
  }

  Future<void> _persist() =>
      LocalPrefs.setString(navModulesPrefsKey, jsonEncode(state.toJson()));
}

/// 底部导航配置 Provider（HomeShell 底栏/面板 与 功能模块配置页共用）
final navModulesProvider =
    NotifierProvider<NavModulesController, NavModulesState>(
  NavModulesController.new,
);

/// 应用启动落点 = 启用序第一个模块的根路由
///
/// `appRouter` 是顶层 final（惰性求值一次），而 `LocalPrefs.load()` 在
/// `main()` 里先于 `runApp` 完成，此处读取时机安全；「今天」被停用时
/// 冷启动直接落到当前配置的第一个模块，不会落到不可达页签。
final String startupLocation =
    NavModulesState.parse(LocalPrefs.getString(navModulesPrefsKey) ?? '')
        .enabled
        .first
        .path;
