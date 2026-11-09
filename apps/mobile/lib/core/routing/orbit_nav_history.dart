/// 页级返回历史（纯 Dart，无 Flutter 依赖，可脱离壳层单测）
///
/// 只记 **模块分支访问序列**：末位 = 当前模块，倒数第二位 = 「上一个操作页面」。
/// 根级 / 分支内的 `push` 页由 go_router 原生栈承载，不进这里，避免双份真值。
///
/// 为什么不可变：Riverpod `Notifier` 靠 `state` 引用变化通知 [HomeShell] 重建
/// （`PopScope.canPop` 随 `hasPrevious` 变化）。原地改 List 会让 `canPop` 停在
/// 旧值，返回键要么失效穿透、要么误退系统桌面。
class OrbitNavHistory {
  const OrbitNavHistory._(this._branches);

  /// 冷启动：尚未记录任何模块访问（此时返回即交框架退系统桌面）
  static const OrbitNavHistory empty = OrbitNavHistory._(<int>[]);

  /// 栈深上限：会话内访问序列只增不减，必须封顶（对齐无界累加容器审计口径）。
  /// 32 远大于实际可操作深度，超限裁最老条目、保留最近序列。
  static const int maxDepth = 32;

  /// 访问序列（只读）；末位为当前模块分支序
  final List<int> _branches;

  bool get isEmpty => _branches.isEmpty;

  /// 「存在上一个操作页面」的唯一判据（配合当前位于分支根 / 无瞬态层）
  bool get hasPrevious => _branches.length > 1;

  int get depth => _branches.length;

  int? get current => _branches.isEmpty ? null : _branches.last;

  int? get previous =>
      hasPrevious ? _branches[_branches.length - 2] : null;

  /// 只读快照（断言 / 排查用）
  List<int> get branches => List<int>.unmodifiable(_branches);

  /// 记录一次模块访问；相邻同址去重，超上限裁掉最老访问
  OrbitNavHistory withVisit(int branchIndex) {
    if (_branches.isNotEmpty && _branches.last == branchIndex) return this;
    final next = <int>[..._branches, branchIndex];
    if (next.length > maxDepth) {
      next.removeRange(0, next.length - maxDepth);
    }
    return OrbitNavHistory._(List<int>.unmodifiable(next));
  }

  /// 外部直达子页 / 应用启动时登记首页基线；仅空栈生效，不覆写既有历史
  OrbitNavHistory withBaseline(int homeBranch) => _branches.isEmpty
      ? OrbitNavHistory._(List<int>.unmodifiable(<int>[homeBranch]))
      : this;

  /// 弹出当前模块（返回动作调用 `goBranch` 前先弹，避免回退被重新记成访问）
  OrbitNavHistory withoutCurrent() => hasPrevious
      ? OrbitNavHistory._(
          List<int>.unmodifiable(
            _branches.sublist(0, _branches.length - 1),
          ),
        )
      : this;
}
