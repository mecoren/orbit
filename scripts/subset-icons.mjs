// Material Symbols 瀛愰泦鐢熸垚鍣?P0 鎬ц兘娌荤悊):
// 鎸?scripts/icon-names.json 娓呭崟璋?Google Fonts css2 API,鐢熸垚淇濈暀 ligature
// 鐨勫彲鍙樺瓧浣撳瓙闆?woff2(鍏ㄩ噺 5.1MB 鈫?棰勬湡 <100KB)銆?// 鐢ㄦ硶:pnpm fonts:subset(闇€鑱旂綉,涓€娆℃€ф墽琛?浜х墿鎻愪氦鍏ュ簱)
import { readFile, writeFile } from "node:fs/promises";

const NAMES_PATH = new URL("./icon-names.json", import.meta.url);
const OUT_PATH = new URL("../public/fonts/MaterialSymbolsRounded.subset.woff2", import.meta.url);

let names;
try {
  names = JSON.parse(await readFile(NAMES_PATH, "utf8"));
} catch (err) {
  console.error(`icon-names.json 瑙ｆ瀽澶辫触: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
}
if (!Array.isArray(names) || names.length === 0 || names.some((n) => !/^[a-z0-9_]+$/.test(n))) {
  console.error("icon-names.json 蹇呴』鏄潪绌虹殑 [a-z0-9_] 瀛楃涓叉暟缁?);
  process.exit(1);
}

// icon_names 闇€瀛楁瘝搴?UA 蹇呴』鏄祻瑙堝櫒韬唤鎵嶈繑鍥?woff2(榛樿 UA 缁?ttf)
const family = "Material+Symbols+Rounded";
const axes = "opsz,wght,FILL,GRAD@20..48,100..700,0..1,-50..200";
const cssUrl =
  `https://fonts.googleapis.com/css2?family=${family}:${axes}` +
  `&icon_names=${[...names].sort().join(",")}&display=block`;
const cssRes = await fetch(cssUrl, {
  signal: AbortSignal.timeout(30000),
  headers: {
    "User-Agent":
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  },
});
if (!cssRes.ok) {
  console.error(`css2 璇锋眰澶辫触: ${cssRes.status}`);
  process.exit(1);
}
const css = await cssRes.text();
const m = css.match(/url\((https:[^)]+)\)\s*format\(['"]woff2['"]\)/);
if (!m) {
  console.error("css 鍝嶅簲涓湭鎵惧埌 woff2 閾炬帴,鍝嶅簲澶撮儴:\n" + css.slice(0, 400));
  process.exit(1);
}
const fontRes = await fetch(m[1], { signal: AbortSignal.timeout(30000) });
if (!fontRes.ok) {
  console.error(`瀛椾綋涓嬭浇澶辫触: ${fontRes.status}`);
  process.exit(1);
}
const buf = Buffer.from(await fontRes.arrayBuffer());
await writeFile(OUT_PATH, buf);
console.log(`宸插啓鍏?${OUT_PATH.pathname} 鈥?${buf.length} bytes, ${names.length} 涓浘鏍嘸);
