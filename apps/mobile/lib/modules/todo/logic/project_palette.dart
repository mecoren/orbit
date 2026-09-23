/// 项目（清单）色彩口径：预设板 / 无颜色档 / 新建默认色
///
/// **为什么单独成文件**：色板此前是 `sidebar_screen` 的私有常量，2026-09-23 起
/// 「编辑项目」整页与自定义取色抽屉都要用它——三处各抄一份必然漂移。
library;

/// 10 色预设板（#36；与桌面端 `project-sidebar` 的 PROJECT_COLORS 同序列）
const List<String> projectColorPalette = <String>[
  '#EF4444',
  '#F59E0B',
  '#22C55E',
  '#3B82F6',
  '#8B5CF6',
  '#EC4899',
  '#14B8A6',
  '#F97316',
  '#6366F1',
  '#6B7280',
];

/// 「无颜色」档（`hex_color` 空串）
///
/// 下游口径已经就绪：侧栏项目行文件夹图标取强调色、列表行项目名回落次要文本色、
/// 看板列头回退强调色——「不着色」是既有语义，不是新增状态。
const String projectNoColor = '';

/// 新建项目的默认色：按现有项目数轮换预设板（避免连开两个项目就撞色）
String defaultProjectColor(int projectCount) =>
    projectColorPalette[projectCount % projectColorPalette.length];

/// 该颜色是否在预设板内（不在 = 来自自定义取色，颜色行要把「自定义」圆点
/// 也渲染成选中态）
bool isCustomProjectColor(String hex) =>
    hex.isNotEmpty && !projectColorPalette.contains(hex.toUpperCase());
