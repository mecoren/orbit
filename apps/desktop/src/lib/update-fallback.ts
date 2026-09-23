/**
 * 应用内更新的兜底出口（docs/07 #50 残余项）。
 *
 * 就地升级不可用时（签名校验失败、安装方式未被更新清单覆盖、网络/权限失败）
 * 必须给用户一条可走的路：跳 Release 页手动下载。URL 由本文件的纯函数生成，
 * 与 `tauri.conf.json` 的 updater endpoint 同仓（mecoren/orbit）。
 *
 * **为什么只做「兜底」而不做「安装方式识别（MSI/NSIS/便携/dmg）」**：
 * 本项目 `bundle.targets = "all"`，但 `latest.json` 只发布
 * `windows-x86_64-nsis` / `darwin-aarch64(-app)` / `linux-x86_64(-appimage)` /
 * `linux-x86_64-deb` 这几类键，**不发布便携产物**；可靠区分 MSI 与 NSIS 需要
 * 查注册表（新增平台依赖）或真机安装器验证——两者当前都不具备，而启发式误判
 * 会挡住本可正常升级的用户（收益为负）。故本轮只交付可验证的兜底出口，
 * 识别逻辑待有真机安装器验证条件后再补（记 docs/07 #60 依据列）。
 */

/** Release 页根地址（与 tauri.conf.json 的 updater endpoint 同仓） */
export const RELEASES_URL = "https://github.com/mecoren/orbit/releases";

/**
 * 兜底下载地址：给了版本号就定位到该 tag（`v` 前缀容错，重复前缀不会叠加），
 * 否则落 `/latest`（等价于 updater endpoint 所在的那次发布）。
 */
export function resolveReleaseFallbackUrl(version?: string | null): string {
  const v = (version ?? "").trim().replace(/^v+/i, "");
  return v ? `${RELEASES_URL}/tag/v${v}` : `${RELEASES_URL}/latest`;
}
