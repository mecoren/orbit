/**
 * SyncRecoveryPage — KeyMismatch 恢复引导页（06 任务 3.3）
 *
 * 触发场景：本机 Data Key 与云端加密数据不匹配（probe_data_key_with_global_meta）。
 * 两条恢复路径：
 * 1. 常规：重新输入同步密码解锁（密码未变时即可恢复，引擎下次同步会自动对账）
 * 2. 高级：从 bundle 文件强制导入云端密钥（Fix-10 force=true；会切换本机 Data Key）
 */
import { useState } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { ArrowLeft, FileWarning, KeyRound, ShieldCheck } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  syncCryptoImportBundle,
  syncCryptoUnlock,
  syncErrorTag,
  type SyncCryptoBundle,
} from "@/lib/tauri";

export function SyncRecoveryPage() {
  const navigate = useNavigate();
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);

  const handleUnlock = async () => {
    setBusy(true);
    try {
      await syncCryptoUnlock(password, true);
      toast.success("已解锁，稍后可执行「立即同步」完成数据对账");
      navigate("/settings");
    } catch (err) {
      toast.error(
        syncErrorTag(err) === "wrong_password" ? "同步密码错误" : String(err),
      );
    } finally {
      setBusy(false);
    }
  };

  const handleImportBundle = async (force: boolean) => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({
      filters: [{ name: "Crypto Bundle", extensions: ["json"] }],
      multiple: false,
    });
    if (!selected || typeof selected !== "string") return;

    let bundle: SyncCryptoBundle;
    try {
      const { readTextFile } = await import("@tauri-apps/plugin-fs");
      bundle = JSON.parse(await readTextFile(selected));
    } catch {
      toast.error("bundle 文件解析失败");
      return;
    }

    if (
      force &&
      !window.confirm("覆盖将切换本机 Data Key：此后本地以云端密钥为准。确定继续？")
    ) {
      return;
    }

    setBusy(true);
    try {
      await syncCryptoImportBundle(bundle, password, force);
      toast.success(force ? "已强制导入云端密钥" : "已导入云端密钥");
      navigate("/settings");
    } catch (err) {
      if (syncErrorTag(err) === "local_meta_exists") {
        toast.warning("本地已存在不同的同步密钥，需确认后才能覆盖");
        // Fix-10 守卫触发 → 用户在下一个 confirm 中选择是否 force
        if (window.confirm("检测到本地已有不同的同步密钥。用云端密钥覆盖本机？")) {
          try {
            await syncCryptoImportBundle(bundle, password, true);
            toast.success("已覆盖为本机云端密钥");
            navigate("/settings");
          } catch (retryErr) {
            toast.error(String(retryErr));
          }
        }
      } else {
        toast.error(String(err));
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mx-auto flex h-full max-w-lg flex-col justify-center gap-5 p-6">
      <div className="flex items-center gap-3">
        <div className="flex size-10 items-center justify-center rounded-full bg-warning/15">
          <FileWarning className="size-5 text-warning" />
        </div>
        <div>
          <h1 className="text-base font-semibold">同步密钥不一致</h1>
          <p className="text-xs text-muted-foreground">
            本机的数据密钥无法解密云端数据。请按以下步骤恢复。
          </p>
        </div>
      </div>

      {/* 路径 1 */}
      <div className="space-y-2 rounded-lg border p-4">
        <div className="flex items-center gap-2 text-sm font-medium">
          <KeyRound className="size-4 text-muted-foreground" />
          步骤一 · 重新输入同步密码
        </div>
        <p className="text-xs text-muted-foreground">
          若你更换过设备或重装系统，输入原同步密码即可恢复解密能力。
        </p>
        <div className="flex items-center gap-2">
          <Label htmlFor="recovery-pw" className="sr-only">
            同步密码
          </Label>
          <Input
            id="recovery-pw"
            type="password"
            placeholder="同步密码"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && password && !busy) void handleUnlock();
            }}
          />
          <Button size="sm" disabled={busy || !password} onClick={() => void handleUnlock()}>
            解锁
          </Button>
        </div>
      </div>

      {/* 路径 2 */}
      <div className="space-y-2 rounded-lg border p-4">
        <div className="flex items-center gap-2 text-sm font-medium">
          <ShieldCheck className="size-4 text-muted-foreground" />
          步骤二 · 导入云端密钥包（高级）
        </div>
        <p className="text-xs text-muted-foreground">
          若步骤一无效（例如云端密钥已被轮换），可从其他设备导出的 crypto bundle
          JSON 文件强制导入。覆盖后本机将以云端密钥为准。
        </p>
        <Button
          size="sm"
          variant="outline"
          disabled={busy || !password}
          onClick={() => void handleImportBundle(false)}
        >
          选择 bundle 文件导入
        </Button>
      </div>

      <Button variant="ghost" className="self-start" onClick={() => navigate(-1)}>
        <ArrowLeft className="mr-1 size-4" />
        返回设置
      </Button>
    </div>
  );
}
