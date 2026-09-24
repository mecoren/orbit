import '../../../services/local_prefs.dart';

/// 底部快速添加面板的快捷操作档（TickTick「编辑操作」的 Orbit 等价物）
///
/// 只收录**本仓真有对应能力**的档位：
/// - [due]/[priority]/[label]/[project] → 截止日期 / 优先级 / 标签 / 清单（项目）；
/// - [image] → 相册图片（任务落库后挂附件，复用 `task_attachment_add`）；
/// - [template] → 任务模板（复用模板选择 + 表单预填链）；
/// - [fullscreen] → 展开为完整新建表单（详细字段编辑）。
///
/// 语音输入 / 转换为笔记等竞品档位本仓无对应能力，刻意不设档位（不做假功能）。
enum QuickActionId { due, priority, label, project, image, template, fullscreen }

extension QuickActionMeta on QuickActionId {
  /// 设置页与「更多」菜单展示用的中文名
  String get label => switch (this) {
        QuickActionId.due => '日期',
        QuickActionId.priority => '优先级',
        QuickActionId.label => '标签',
        QuickActionId.project => '清单',
        QuickActionId.image => '图片',
        QuickActionId.template => '模板',
        QuickActionId.fullscreen => '全屏',
      };
}

/// 「更多」段标题在可拖列表里的哨兵值（不可拖起，但会被拖拽项挤开——
/// 分界线由此随落点移动）。`Object` 序列里非 [QuickActionId] 的元素即它。
const String moreHeaderSentinel = '__more__';

/// 可拖列表的展示序列：启用档 → 「更多」标题（未启用段为空时不插）→ 未启用档
///
/// UI 的 `ReorderableListView` 与重排逻辑共用同一构造，避免两处各拼一次。
List<Object> quickActionDragItems(
  List<QuickActionId> enabled,
  List<QuickActionId> hidden,
) =>
    [
      ...enabled,
      if (hidden.isNotEmpty) moreHeaderSentinel,
      ...hidden,
    ];

/// 跨段拖拽的纯逻辑：把两段视为一张连续列表，把 [oldIndex] 的项移到
/// [newIndex]，再按「更多」标题行的**新位置**解析回两段。
///
/// 语义：项越过标题行即换段（标题行自身不可拖，调用方保证不传它的索引）；
/// 同段内拖拽只调顺序。返回新的（启用段, 未启用段）。
///
/// 索引口径为 `ReorderableListView.onReorderItem` 回调（v3.41+）：[newIndex]
/// 已是"旧位先移除"后的语义插入位，直接 remove + insert 消费，不再 -1。
(List<QuickActionId>, List<QuickActionId>) reorderQuickActions({
  required List<QuickActionId> enabled,
  required List<QuickActionId> hidden,
  required int oldIndex,
  required int newIndex,
}) {
  final items = quickActionDragItems(enabled, hidden);
  if (oldIndex < 0 || oldIndex >= items.length) return (enabled, hidden);
  final moved = items.removeAt(oldIndex);
  if (moved is! QuickActionId) return (enabled, hidden); // 标题行不可拖
  items.insert(newIndex.clamp(0, items.length), moved);

  final boundary = items.indexOf(moreHeaderSentinel);
  final newEnabled = <QuickActionId>[];
  final newHidden = <QuickActionId>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! QuickActionId) continue;
    // 无标题行（未启用段为空）时全部留在工具栏
    (boundary < 0 || i < boundary ? newEnabled : newHidden).add(item);
  }
  return (newEnabled, newHidden);
}

/// 单段内重排的纯逻辑（设置页双卡片各持一段，段内拖拽只调顺序不换段）。
///
/// 索引口径与 [reorderQuickActions] 一致（`onReorderItem` 语义插入位）。
List<QuickActionId> reorderWithinSection(
  List<QuickActionId> list,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex < 0 || oldIndex >= list.length) return list;
  final out = List<QuickActionId>.of(list);
  final moved = out.removeAt(oldIndex);
  out.insert(newIndex.clamp(0, out.length), moved);
  return out;
}

/// 快捷操作档配置读写（本机 UI 偏好，不进 DB、不进同步）
///
/// 落盘走 [LocalPrefs] 字符串键（与桌面 localStorage 键同性质）：
/// `启用档,启用档|未启用档,未启用档`，档名 = [QuickActionId.name]。
///
/// 解析容错（宁缺毋错）：
/// - 未知名忽略；重复名只取首个；
/// - 不在任一组的档补进「更多」组——跨版本新增档不会凭空消失；
/// - 键缺失/脏数据回落默认档（默认态 = 截图默认：工具栏四档 + 更多三档）。
class QuickActions {
  QuickActions._();

  static const key = 'todo_quick_actions';

  /// 工具栏默认直显四档
  static const List<QuickActionId> defaultEnabled = [
    QuickActionId.due,
    QuickActionId.priority,
    QuickActionId.label,
    QuickActionId.project,
  ];

  /// 默认收在「更多」菜单里的三档
  static const List<QuickActionId> defaultHidden = [
    QuickActionId.image,
    QuickActionId.template,
    QuickActionId.fullscreen,
  ];

  /// 读当前配置（返回可变的两个列表；调用方改完须 [write] 回存）
  static (List<QuickActionId>, List<QuickActionId>) read() {
    final raw = LocalPrefs.getString(key);
    if (raw == null) {
      return (List.of(defaultEnabled), List.of(defaultHidden));
    }
    final parts = raw.split('|');
    final enabled = _parse(parts.first);
    final hidden = _parse(parts.length > 1 ? parts[1] : '');
    for (final id in QuickActionId.values) {
      if (!enabled.contains(id) && !hidden.contains(id)) hidden.add(id);
    }
    return (enabled, hidden);
  }

  /// 回存两段配置（启用段在前，`|` 分隔）
  static Future<void> write(
    List<QuickActionId> enabled,
    List<QuickActionId> hidden,
  ) {
    final value = '${enabled.map((e) => e.name).join(',')}'
        '|${hidden.map((e) => e.name).join(',')}';
    return LocalPrefs.setString(key, value);
  }

  /// 单档启用/停用：启用追加到工具栏尾部，停用追加到「更多」尾部
  ///（保持两段各自的既有相对顺序不被打乱）
  static Future<void> setEnabled(QuickActionId id, bool enabled) {
    final (on, off) = read();
    on.remove(id);
    off.remove(id);
    (enabled ? on : off).add(id);
    return write(on, off);
  }

  static List<QuickActionId> _parse(String raw) {
    final out = <QuickActionId>[];
    for (final name in raw.split(',')) {
      for (final id in QuickActionId.values) {
        if (id.name == name && !out.contains(id)) out.add(id);
      }
    }
    return out;
  }
}
