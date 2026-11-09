import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../modules/shell/nav_modules.dart';
import 'orbit_nav_history.dart';

export 'orbit_nav_history.dart';

/// 返回行为统一分发层（壳层 UI 语义，不进 Rust core）
///
/// **系统返回链路（已按 go_router 17.5.0 / Flutter 源码核实）**：
/// `GoRouterDelegate.popRoute()` 按「分支 Navigator → 根 Navigator」顺序
/// `maybePop()`；根路由 `RoutePopDisposition.bubble` 返回 false →
/// `WidgetsBinding.handlePopRoute()` 调 `SystemNavigator.pop()` 退系统桌面。
/// 故 `HomeShell` 的 `PopScope(canPop: !hasPrevious)` 只在**页级历史非空**
/// 时拦截（`doNotPop` 消费返回事件），无历史时放行交框架默认，不手写
/// `SystemNavigator`。
///
/// 根级 / 分支内 `push` 页由 go_router 原生栈先消费返回，壳层 `PopScope`
/// 只在它们都退到根时才被咨询 —— 不需要改动那 40+ 个 `context.push`。
/// **页内瞬态层**（Overlay 菜单无 PopEntry）不走壳层 `PopScope`，而由
/// [OrbitTransientPopGuard] 挂在每一个路由页上、优先消费返回。
final orbitNavHistoryProvider =
    NotifierProvider<OrbitNavHistoryController, OrbitNavHistory>(
  OrbitNavHistoryController.new,
);

/// 历史状态控制器：写历史 + 幂等出栈
class OrbitNavHistoryController extends Notifier<OrbitNavHistory> {
  @override
  OrbitNavHistory build() => OrbitNavHistory.empty;

  /// 同一事件循环内重复投递返回事件时只消费一条历史（快速连点去重）。
  /// 微任务后放行，下一次真实返回仍逐层回退。
  bool _popInFlight = false;

  void recordVisit(int branchIndex) => state = state.withVisit(branchIndex);

  void ensureBaseline(int homeBranch) =>
      state = state.withBaseline(homeBranch);

  /// 当前模块分支序（对外只读；`state` 是 Notifier 的 protected 成员）
  int? get current => state.current;

  int? get previous => state.previous;

  bool get hasPrevious => state.hasPrevious;

  /// 返回上一模块分支序；无上一页或同帧重复调用返回 null
  int? popPrevious() {
    if (_popInFlight) return null;
    final target = state.previous;
    if (target == null) return null;
    _popInFlight = true;
    state = state.withoutCurrent();
    Future.microtask(() {
      _popInFlight = false;
    });
    return target;
  }

  void reset() => state = OrbitNavHistory.empty;

  /// 模块被停用后的兜底：原分支已不可达，历史重置成新落点的基线，
  /// 避免返回跳进一个停用模块（此时不存在上一个操作页面）
  void resetToBaseline(int homeBranch) {
    state = OrbitNavHistory.empty.withBaseline(homeBranch);
  }
}

/// 页内瞬态层（Overlay 菜单）的返回消费登记表
///
/// `showOrbitMenuPopup` / `MiuixGlassTransformPopup` 这类菜单挂在根 Overlay，
/// 不是 route、不自带 PopEntry；玻璃形变菜单虽会往宿主 route 挂
/// `LocalHistoryEntry`，但宿主是壳层根路由，分支 Navigator 有子页时会先被
/// 咨询，导致「按返回先 pop 子页、菜单还开着」。故统一由各路由页上的
/// [OrbitTransientPopGuard] 在最顶层 route 优先消费返回。
final orbitTransientPopProvider =
    NotifierProvider<OrbitTransientPopController, List<VoidCallback>>(
  OrbitTransientPopController.new,
);

class OrbitTransientPopController extends Notifier<List<VoidCallback>> {
  @override
  List<VoidCallback> build() => const <VoidCallback>[];

  void register(VoidCallback close) {
    if (state.contains(close)) return;
    state = <VoidCallback>[...state, close];
  }

  void unregister(VoidCallback close) {
    if (!state.contains(close)) return;
    state = <VoidCallback>[...state]..remove(close);
  }

  /// 关闭最上层瞬态（回调内部负责 unregister）
  void closeTop() {
    if (state.isEmpty) return;
    state.last.call();
  }
}

/// 挂在**每个路由页**上的瞬态返回守卫
///
/// 无瞬态时 `canPop: true`，对 go_router 原生 pop 完全不干预；有瞬态时
/// `doNotPop` 消费返回并关掉最上层瞬态，页栈保持不变。放在页级而非壳级，
/// 才能保证「分支内 push 页 + 菜单」组合下菜单也是第一顺位。
class OrbitTransientPopGuard extends ConsumerWidget {
  const OrbitTransientPopGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTransient = ref.watch(orbitTransientPopProvider).isNotEmpty;
    return PopScope(
      canPop: !hasTransient,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ref.read(orbitTransientPopProvider.notifier).closeTop();
      },
      child: child,
    );
  }
}

/// 换模块目的地（底栏 /「更多」/ 侧栏 / 设置 / 快捷方式统一入口）
///
/// `goBranch` 与 `context.go(模块根)` 都**不入任何 Navigator 栈**，故在这里
/// 显式写历史：先补基线 + 校准当前分支（自愈未走本助手的旧跳转），再记目标。
/// [initialLocation] 仅用于「重复点当前页签回该页签根」这一既有惯例。
void goToModule(
  BuildContext context,
  OrbitNavModule module, {
  StatefulNavigationShell? shell,
  bool initialLocation = false,
}) {
  if (!context.mounted) return;
  // `maybeOf` 返回的是 State，统一归一到 widget（两者都有 currentIndex/goBranch）
  final effectiveShell =
      shell ?? StatefulNavigationShell.maybeOf(context)?.widget;
  final notifier = ProviderScope.containerOf(context, listen: false)
      .read(orbitNavHistoryProvider.notifier);

  if (effectiveShell != null) {
    final current = effectiveShell.currentIndex;
    notifier.ensureBaseline(current);
    notifier.recordVisit(current);
    notifier.recordVisit(module.branchIndex);
    effectiveShell.goBranch(
      module.branchIndex,
      initialLocation: initialLocation,
    );
    return;
  }

  // 无壳上下文（如宽屏常驻侧栏）只能退 location 替换：整条根级栈会被清掉，
  // 此时不存在「上一个操作页面」，历史重置为目标模块基线而非伪造访问序列。
  notifier.resetToBaseline(module.branchIndex);
  GoRouter.of(context).go(module.path);
}

/// 回到上一个操作页面；返回是否已在应用内消费这次返回
///
/// `hasPrevious == false` 时返回 false，由调用方（`HomeShell` 的 `PopScope`）
/// 放行给框架退系统桌面。`current` 与真实分支不一致时先校准再出栈，保证
/// 未经 [goToModule] 的跳转（配置兜底 / 遗留 `context.go`）也能正确回退。
bool goBack(BuildContext context, {StatefulNavigationShell? shell}) {
  if (!context.mounted) return false;
  final effectiveShell =
      shell ?? StatefulNavigationShell.maybeOf(context)?.widget;
  if (effectiveShell == null) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  final notifier = container.read(orbitNavHistoryProvider.notifier);
  final current = effectiveShell.currentIndex;
  if (notifier.current != current) notifier.recordVisit(current);

  // 停用当前模块的配置兜底切分支后，历史里可能还留着已停用的前驱。
  // 这一帧不能跳过去（页面已不可达），重置成新基线即可。
  final enabled = <int>{
    for (final m in container.read(navModulesProvider).enabled)
      m.branchIndex,
  };
  final previous = notifier.previous;
  if (previous == null) return false;
  if (!enabled.contains(previous)) {
    notifier.resetToBaseline(current);
    return false;
  }

  final target = notifier.popPrevious();
  if (target == null) return false;
  effectiveShell.goBranch(target);
  return true;
}
