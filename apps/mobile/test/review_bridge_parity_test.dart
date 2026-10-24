import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';

// F1 项目回顾节奏：MockOrbitBridge 与 core project_review_api 的口径镜像回归
//（开启起算 / 从未回顾立即到期 / 标记推进 / 暂缓窗口 / 关闭保留历史）。
// 真值判定（本地日界/DST）在 core 的 Rust 单测覆盖，这里锁 mock 不漂移。
void main() {
  late MockOrbitBridge bridge;
  setUp(() => bridge = MockOrbitBridge());

  /// 把项目的上次回顾时间拨到 N 天前正午（DST 安全）
  void backdateReview(int projectId, int intervalDays, int reviewedDaysAgo) {
    final p = bridge.store.projects[projectId]!;
    p['review_interval_days'] = intervalDays;
    final n = DateTime.now();
    final noon = DateTime(n.year, n.month, n.day, 12).millisecondsSinceEpoch;
    p['review_last_at'] = noon - reviewedDaysAgo * 86400000;
  }

  int firstProjectId() => bridge.store.projects.keys.first;

  test('开启周期后首次到期 = 设定日 + 周期（不立即到期）', () async {
    final id = firstProjectId();
    final updated =
        await bridge.todoProjectSetReviewInterval(id, 7);
    expect(updated.reviewIntervalDays, 7);
    expect(updated.reviewLastAt, isNotNull, reason: '从未回顾则从现在起算');
    final due =
        await bridge.todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch);
    expect(due.where((s) => s.project.id == id), isEmpty);
  });

  test('周期过了才到期，逾期天数按日差，未完成计数只算活任务', () async {
    final id = firstProjectId();
    backdateReview(id, 7, 10); // 到期 = today-3
    final due =
        await bridge.todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch);
    final mine = due.firstWhere((s) => s.project.id == id);
    expect(mine.overdueDays, 3);
    expect(mine.openTaskCount, greaterThanOrEqualTo(0));
  });

  test('标记已回顾：暂缓清空且不再到期', () async {
    final id = firstProjectId();
    backdateReview(id, 7, 30);
    await bridge.todoProjectSnoozeReview(id, 7, DateTime.now().millisecondsSinceEpoch);
    expect(
      (await bridge.todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch))
          .where((s) => s.project.id == id),
      isEmpty,
      reason: '暂缓期间不到期',
    );
    final reviewed = await bridge.todoProjectMarkReviewed(id);
    expect(reviewed.reviewSnoozeUntil, isNull);
    expect(
      (await bridge.todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch))
          .where((s) => s.project.id == id),
      isEmpty,
    );
  });

  test('暂缓截止落库 = 今天零点 + N 天；非法天数拒绝', () async {
    final id = firstProjectId();
    final now = DateTime.now();
    final nowMs = DateTime(now.year, now.month, now.day, 15).millisecondsSinceEpoch;
    final snoozed = await bridge.todoProjectSnoozeReview(id, 7, nowMs);
    final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    expect(snoozed.reviewSnoozeUntil, dayStart + 7 * 86400000);
    expect(() => bridge.todoProjectSnoozeReview(id, 0, nowMs), throwsException);
  });

  test('关闭周期：清 interval 与暂缓，保留 last_at 历史', () async {
    final id = firstProjectId();
    backdateReview(id, 7, 30);
    await bridge.todoProjectSnoozeReview(id, 7, DateTime.now().millisecondsSinceEpoch);
    final off = await bridge.todoProjectSetReviewInterval(id, null);
    expect(off.reviewIntervalDays, isNull);
    expect(off.reviewSnoozeUntil, isNull);
    expect(off.reviewLastAt, isNotNull);
    expect(
      (await bridge.todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch))
          .where((s) => s.project.id == id),
      isEmpty,
    );
  });

  test('已开周期但从未回顾（同步对端写入形态）：立即到期且逾期 0 天', () async {
    final id = firstProjectId();
    bridge.store.projects[id]!['review_interval_days'] = 14;
    bridge.store.projects[id]!['review_last_at'] = null;
    final due =
        await bridge.todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch);
    final mine = due.firstWhere((s) => s.project.id == id);
    expect(mine.overdueDays, 0);
  });

  test('DTO 镜像：TodoProject.fromJson 读三态回顾列（缺键 = 关闭）', () async {
    final id = firstProjectId();
    backdateReview(id, 7, 5);
    final p = await bridge.todoProjectGet(id);
    expect(p.reviewIntervalDays, 7);
    expect(p.reviewLastAt, isNotNull);
    // 缺键行（seed 老形态）回落关闭
    const legacy = TodoProject(
      id: 1, uuid: 'u', title: 't', description: null, hexColor: '#000000',
      sortOrder: 0, parentUuid: null, isArchived: 0, isDeleted: 0,
      createdAt: 0, updatedAt: 0, deletedAt: null, version: 1,
    );
    expect(legacy.reviewIntervalDays, isNull);
  });
}
