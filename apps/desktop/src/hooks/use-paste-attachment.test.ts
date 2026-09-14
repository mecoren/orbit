import { describe, expect, it } from "vitest";
import {
  extractFilesFromDrop,
  extractImageFromPaste,
  pastedImageName,
} from "./use-paste-attachment";

interface FakeFile {
  type: string;
  name: string;
}

const makeEvent = (files: FakeFile[]): ClipboardEvent =>
  ({ clipboardData: { files } }) as unknown as ClipboardEvent;

describe("extractImageFromPaste", () => {
  it("多文件中取第一个图片", () => {
    const ev = makeEvent([
      { type: "text/plain", name: "a.txt" },
      { type: "image/png", name: "shot.png" },
    ]);
    const r = extractImageFromPaste(ev);
    expect(r?.name).toBe("shot.png");
    expect(r?.mime).toBe("image/png");
  });

  it("无图片/空 files/无 clipboardData 返回 null", () => {
    expect(extractImageFromPaste(makeEvent([{ type: "text/plain", name: "a.txt" }]))).toBeNull();
    expect(extractImageFromPaste(makeEvent([]))).toBeNull();
    expect(extractImageFromPaste({} as ClipboardEvent)).toBeNull();
  });

  it("截图位图空 name 按时间戳生成文件名", () => {
    const r = extractImageFromPaste(makeEvent([{ type: "image/png", name: "" }]));
    expect(r?.name).toMatch(/^粘贴图片_\d{8}_\d{6}\.png$/);
  });
});

describe("pastedImageName", () => {
  it("格式：粘贴图片_日期_时间.扩展名（补零）", () => {
    expect(pastedImageName("image/png", new Date(2026, 8, 9, 14, 5, 3))).toBe(
      "粘贴图片_20260909_140503.png",
    );
  });

  it("jpeg 扩展名用 jpg；未知 mime 回退 png", () => {
    expect(pastedImageName("image/jpeg", new Date(2026, 0, 2, 3, 4, 5))).toMatch(/\.jpg$/);
    expect(pastedImageName("image/bmp", new Date(2026, 0, 2, 3, 4, 5))).toMatch(/\.png$/);
  });
});

describe("extractFilesFromDrop", () => {
  const makeDrop = (types: string[], files: FakeFile[]): DragEvent =>
    ({
      dataTransfer: { types, files },
    }) as unknown as DragEvent;

  it("文件拖放：types 含 Files 时返回全部文件（多文件保序）", () => {
    const files = extractFilesFromDrop(
      makeDrop(["Files"], [
        { type: "image/png", name: "a.png" },
        { type: "application/pdf", name: "b.pdf" },
      ]),
    );
    expect(files.map((f) => f.name)).toEqual(["a.png", "b.pdf"]);
  });

  it("文本拖放（拖字符串/拖任务行）不含 Files 类型 → 空数组让位原生放置", () => {
    expect(extractFilesFromDrop(makeDrop(["text/plain"], [{ type: "text/plain", name: "t" }]))).toEqual([]);
    // dataTransfer 为 null（极旧环境）也返回空不炸
    expect(extractFilesFromDrop({} as DragEvent)).toEqual([]);
  });
});
