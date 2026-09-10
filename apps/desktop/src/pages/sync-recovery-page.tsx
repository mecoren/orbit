/**
 * SyncRecoveryPage — KeyMismatch 恢复引导页
 *
 * 触发场景：本机 Data Key 与云端加密数据不匹配（probe_data_key_with_global_meta）。
 *
 * v2 确定性密钥下，KeyMismatch 只剩一种真实成因：**云端数据由另一个同步密码
 * 加密**（例如另一台设备用不同密码初始化并覆盖了云端）。因此恢复路径为：
 * 1. 常规：输入「加密云端的那台设备使用的密码」→ 同密码必然同 Key，
 *    解锁后「立即同步」即可完成对账
 * 2. 兜底：以本机为准——放弃解不开的云端数据，用本机 Key 全量重加密覆盖
 *    （cloud_sync_rekey；本机没有的数据将丢失，UI 明示）。确认弹层带 5 秒
 *    强制冷静期倒计时（确认钮倒计时走完才可点，防误触）。
 *
 * v1（随机 Key）存量设备额外显示「升级到 v2」迁移入口——升级后同密码
 * 跨设备自动同 Key，此类不一致从根源上不再发生。
 */
import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { AlertTriangle, ArrowLeft, FileWarning, KeyRound, RefreshCw } from "lucide-react";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  cloudSyncRekey,
  syncCryptoMetaVersion,
  syncCryptoUnlock,
  syncCryptoUpgradeV2,
} from "@/lib/tauri";

/** rekey 确认钮强制冷静期（秒）：危险操作防误触，倒计时走完才可确认 */
const REKEY_HOLD_SECONDS = 5;

export function SyncRecoveryPage() {
  const navigate = useNavigate();
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [isV1, setIsV1] = useState(false);
  const [rekeyConfirmOpen, setRekeyConfirmOpen] = useState(false);
  const [rekeyCountdown, setRekeyCountdown] = useState(REKEY_HOLD_SECONDS);
  const countdownTimer = useRef<ReturnType<typeof setInterval> | null>(null);

  // 探测本机密钥方案版本：v1 存量设备才显示迁移入口
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const { version } = await syncCryptoMetaVersion();
        if (!cancelled) setIsV1(version === "v1");
      } catch {
        /* 探测失败不阻塞主路径：默认不显示迁移入口 */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // 确认弹层开启期间跑 5 秒倒计时：确认钮禁用直到走完（强制冷静期）；
  // 关闭/卸载即停表复位，再次打开从头计
  useEffect(() => {
    if (!rekeyConfirmOpen) {
      if (countdownTimer.current) clearInterval(countdownTimer.current);
      countdownTimer.current = null;
      setRekeyCountdown(REKEY_HOLD_SECONDS);
      return;
    }
    countdownTimer.current = setInterval(() => {
      setRekeyCountdown((n) => {
        if (n <= 1 && countdownTimer.current) {
          clearInterval(countdownTimer.current);
          countdownTimer.current = null;
          return 0;
        }
        return n - 1;
      });
    }, 1000);
    return () => {
      if (countdownTimer.current) clearInterval(countdownTimer.current);
      countdownTimer.current = null;
    };
  }, [rekeyConfirmOpen]);

  /** 路径 1：输入加密云端的同步密码解锁 */
  const handleUnlock = async () => {
    setBusy(true);
    try {
      await syncCryptoUnlock(password, false);
      toast.success(
        "已解锁。若此密码正是加密云端的密码，请回到设置点「立即同步」完成对账",
      );
      navigate("/settings");
    } catch (err) {
      toast.error(
        String(err).includes("wrong_password") ? "同步密码错误" : String(err),
      );
    } finally {
      setBusy(false);
    }
  };

  /** 路径 2：以本机为准，全量重加密覆盖云端（5 秒冷静期后才可确认） */
  const handleRekey = async () => {
    setBusy(true);
    try {
      const result = await cloudSyncRekey();
      toast.success(
        `云端已重置：${result.pushed_modules} 个模块、${result.uploaded_attachments} 个附件已用本机密钥重传`,
      );
      navigate("/settings");
    } catch (err) {
      toast.error(String(err));
    } finally {
      setBusy(false);
    }
  };

  /** v1 存量设备迁移到 v2（同密码确定性派生 + 云端全量重传） */
  const handleUpgradeV2 = async () => {
    if (
      !window.confirm(
        "升级到 v2 密钥方案：同一同步密码在任何设备都派生同一把数据密钥，\n" +
          "不再需要密钥包分发。升级会立即用新密钥全量重传云端数据，期间请勿在其他设备同步。\n\n确定继续？",
      )
    ) {
      return;
    }
    setBusy(true);
    try {
      await syncCryptoUpgradeV2(password);
      toast.success("已升级 v2 并完成云端重传。其他设备输入相同密码即可同步");
      navigate("/settings");
    } catch (err) {
      toast.error(String(err));
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
            云端数据由另一个同步密码加密。请选择恢复方式。
          </p>
        </div>
      </div>

      {/* 路径 1 */}
      <div className="space-y-2 rounded-lg border p-4">
        <div className="flex items-center gap-2 text-sm font-medium">
          <KeyRound className="size-4 text-muted-foreground" />
          步骤一 · 输入加密云端的同步密码
        </div>
        <p className="text-xs text-muted-foreground">
          若你记得当初设置同步的那台设备使用的密码，输入它即可恢复（v2
          密钥方案下，同一密码在任何设备都派生同一把密钥）。
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
      <div className="space-y-2 rounded-lg border border-destructive/30 p-4">
        <div className="flex items-center gap-2 text-sm font-medium">
          <AlertTriangle className="size-4 text-destructive" />
          步骤二 · 以本机为准重置云端（危险）
        </div>
        <p className="text-xs text-muted-foreground">
          忘记云端密码或云端数据已无需保留时使用：用本机当前数据密钥重加密并
          <strong>覆盖</strong>云端全部数据。本机没有的数据将丢失。
        </p>
        <Button
          size="sm"
          variant="destructive"
          disabled={busy}
          onClick={() => setRekeyConfirmOpen(true)}
        >
          <RefreshCw className="mr-1 size-4" />
          以本机为准重置云端
        </Button>
      </div>

      {/* 重置确认：确认钮 5 秒倒计时内禁用（强制冷静期，防误触） */}
      <AlertDialog open={rekeyConfirmOpen} onOpenChange={setRekeyConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>以本机为准重置云端</AlertDialogTitle>
            <AlertDialogDescription className="break-words">
              将用当前设备的数据密钥重加密并
              <strong className="text-destructive">覆盖云端全部数据</strong>：
              云端现有数据（含本机没有的记录）将被本机数据替换，仅存云端的记录与附件将
              <strong className="text-destructive">永久丢失</strong>；其他设备需输入本机当前同步密码后重新同步。
              此操作不可撤销，请确认云端数据已无需保留。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              disabled={rekeyCountdown > 0 || busy}
              onClick={() => void handleRekey()}
            >
              {rekeyCountdown > 0 ? `请阅读后果（${rekeyCountdown}s）` : "确认重置云端"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* v1 迁移（仅存量 v1 设备显示） */}
      {isV1 && (
        <div className="space-y-2 rounded-lg border p-4">
          <div className="flex items-center gap-2 text-sm font-medium">
            <RefreshCw className="size-4 text-muted-foreground" />
            升级密钥方案（旧版设备）
          </div>
          <p className="text-xs text-muted-foreground">
            本机仍在使用旧版随机密钥方案。升级到 v2 后，同一密码在任何设备都
            派生同一把密钥，可彻底避免此类不一致。
          </p>
          <Button
            size="sm"
            variant="outline"
            disabled={busy || !password}
            onClick={() => void handleUpgradeV2()}
          >
            升级到 v2
          </Button>
        </div>
      )}

      <Button variant="ghost" className="self-start" onClick={() => navigate(-1)}>
        <ArrowLeft className="mr-1 size-4" />
        返回设置
      </Button>
    </div>
  );
}
