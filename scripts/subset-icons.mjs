// Material Symbols 子集生成器(P0 性能治理):
// 按 scripts/icon-names.json 清单调 Google Fonts css2 API,生成保留 ligature
// 的可变字体子集 woff2(全量 5.1MB → 预期 <100KB)。
// 用法:pnpm fonts:subset(需联网,一次性执行,产物提交入库)
import { readFile, writeFile } from "node:fs/promises";

const NAMES_PATH = new URL("./icon-names.json", import.meta.url);
const OUT_PATH = new URL("../public/fonts/MaterialSymbolsRounded.subset.woff2", import.meta.url);

const names = JSON.parse(await readFile(NAMES_PATH, "utf8"));
if (!Array.isArray(names) || names.length === 0 || names.some((n) => !/^[a-z0-9_]+$/.test(n))) {
  console.error("icon-names.json 必须是非空的 [a-z0-9_] 字符串数组");
  process.exit(1);
}

// icon_names 需字母序;UA 必须是浏览器身份才返回 woff2(默认 UA 给 ttf)
const family = "Material+Symbols+Rounded";
const axes = "opsz,wght,FILL,GRAD@20..48,100..700,0..1,-50..200";
const cssUrl =
  `https://fonts.googleapis.com/css2?family=${family}:${axes}` +
  `&icon_names=${[...names].sort().join(",")}&display=block`;
const cssRes = await fetch(cssUrl, {
  headers: {
    "User-Agent":
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  },
});
if (!cssRes.ok) {
  console.error(`css2 请求失败: ${cssRes.status}`);
  process.exit(1);
}
const css = await cssRes.text();
const m = css.match(/url\((https:[^)]+)\)\s*format\(['"]woff2['"]\)/);
if (!m) {
  console.error("css 响应中未找到 woff2 链接,响应头部:\n" + css.slice(0, 400));
  process.exit(1);
}
const fontRes = await fetch(m[1]);
if (!fontRes.ok) {
  console.error(`字体下载失败: ${fontRes.status}`);
  process.exit(1);
}
const buf = Buffer.from(await fontRes.arrayBuffer());
await writeFile(OUT_PATH, buf);
console.log(`已写入 ${OUT_PATH.pathname} — ${buf.length} bytes, ${names.length} 个图标`);
