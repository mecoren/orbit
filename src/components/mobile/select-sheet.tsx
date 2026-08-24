import { MaterialIcon } from "./material-icon";
import { BottomSheet } from "./bottom-sheet";

export interface SelectItem<T = string> {
  value: T;
  label: string;
  /** 12×12 圆点（05 §4.3 选择弹层，如优先级/状态色） */
  colorDot?: string;
}

interface SelectSheetProps<T> {
  open: boolean;
  title: string;
  items: SelectItem<T>[];
  current?: T;
  onSelect: (v: T) => void;
  onClose: () => void;
}

/**
 * 详情/表单底部选择弹层（05 §4.3 基本信息）：头 16/w600 padding16 + ListTile
 * 带 12×12 圆点 + 当前值尾 check_rounded（accent #3B82F6），行高 h-12，
 * 底部安全区 padding（复用 index.css 的 .m-safe-bottom）。
 *
 * snap 取舍：单档 [0.55] —— 选择项数量有限且可预期，单档避免多档位跳变带来的
 * 误触；条目超出一屏时由内容区原生滚动兜底（BottomSheet 内容区不接管手势）。
 * 关闭位（0 档）由 BottomSheet 自动并入档梯，下滑即可关闭。
 */
export function SelectSheet<T extends string | number>({ open, title, items, current, onSelect, onClose }: SelectSheetProps<T>) {
  return (
    <BottomSheet open={open} onClose={onClose} title={title} snapPoints={[0.55]}>
      <ul className="m-safe-bottom">
        {items.map((it) => (
          <li key={String(it.value)}>
            <button
              type="button"
              className="flex h-12 w-full items-center gap-3 px-4 text-left"
              onClick={() => {
                onSelect(it.value);
                onClose();
              }}
            >
              {it.colorDot ? <span className="h-3 w-3 shrink-0 rounded-full" style={{ background: it.colorDot }} /> : null}
              <span className="flex-1 text-[15px] text-[var(--m-text)]">{it.label}</span>
              {it.value === current ? <MaterialIcon name="check_rounded" size={20} color="#3B82F6" /> : null}
            </button>
          </li>
        ))}
      </ul>
    </BottomSheet>
  );
}
