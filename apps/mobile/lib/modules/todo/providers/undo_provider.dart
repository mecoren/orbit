import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/undo_stack.dart';

/// 会话级撤销栈注入点（对齐桌面 `use-undo-stack` 的 Provider 语义）
///
/// 纯会话态：不进 DB、不进同步、不落盘；Provider 存活期 = 进程存活期，
/// 与 `use-undo-stack` 的 React Provider 同生命周期口径。
///
/// 多选选中集**刻意不做 Provider**：选中项依附于「当前筛选结果」这一视图态，
/// 提到全局会在切换视图/项目后留下幽灵选中项（桌面端同样是组件内 state）。
final undoStackProvider = Provider<UndoStack>((ref) => UndoStack());
