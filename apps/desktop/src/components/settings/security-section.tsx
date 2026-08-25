/**
 * 安全分区（对齐 wait-home SecuritySection）
 *
 * 结构：分区标题 + 两态状态卡（未设置主密码 / 已设置主密码）+
 * 三个右侧 Sheet（设置主密码 / 修改主密码 / 清除主密码）。
 * 设置与清除完成后需重开连接池，提示用户重启应用。
 */
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Lock, ShieldCheck, TriangleAlert } from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import {
  dbInitEncrypted,
  dbInitPlaintext,
  dbMigrateToEncrypted,
  dbMigrateToPlaintext,
  masterAuthChangePassword,
  masterAuthClear,
  masterAuthHas,
  masterAuthInit,
  masterAuthVerify,
} from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

export function SecuritySection() {
  const [hasMasterAuth, setHasMasterAuth] = useState<boolean | null>(null);
  const refreshStatus = () => {
    masterAuthHas().then(setHasMasterAuth).catch(() => setHasMasterAuth(false));
  };
  useEffect(() => {
    refreshStatus();
  }, []);

  // ---- 设置主密码 ----
  const [setupOpen, setSetupOpen] = useState(false);
  const [setupPw, setSetupPw] = useState("");
  const [setupConfirm, setSetupConfirm] = useState("");
  const [setupError, setSetupError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [setupDone, setSetupDone] = useState(false);

  // ---- 修改主密码 ----
  const [changeOpen, setChangeOpen] = useState(false);
  const [oldPw, setOldPw] = useState("");
  const [newPw, setNewPw] = useState("");
  const [changeConfirm, setChangeConfirm] = useState("");
  const [changeError, setChangeError] = useState<string | null>(null);

  // ---- 清除主密码 ----
  const [clearOpen, setClearOpen] = useState(false);
  const [clearPw, setClearPw] = useState("");

  const openSetup = () => {
    setSetupPw("");
    setSetupConfirm("");
    setSetupError(null);
    setSetupDone(false);
    setSetupOpen(true);
  };

  const handleSetup = async () => {
    if (busy) return;
    if (!setupPw || setupPw.length < 4) {
      setSetupError("主密码至少 4 位");
      return;
    }
    if (setupPw !== setupConfirm) {
      setSetupError("两次输入的密码不一致");
      return;
    }
    setBusy(true);
    try {
      const hex = await masterAuthInit(setupPw);
      await dbMigrateToEncrypted(hex);
      await dbInitEncrypted(hex);
      setSetupDone(true);
      refreshStatus();
    } catch (err) {
      setSetupError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  const openChange = () => {
    setOldPw("");
    setNewPw("");
    setChangeConfirm("");
    setChangeError(null);
    setChangeOpen(true);
  };

  const handleChange = async () => {
    if (busy) return;
    if (!newPw || newPw.length < 4) {
      setChangeError("新密码至少 4 位");
      return;
    }
    if (newPw !== changeConfirm) {
      setChangeError("两次输入的密码不一致");
      return;
    }
    setBusy(true);
    try {
      await masterAuthChangePassword(oldPw, newPw);
      toast.success("主密码已修改");
      setChangeOpen(false);
    } catch (err) {
      setChangeError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  /** 清除流程：verify → 加密→明文迁移 → 重开明文池 → 删除认证文件 */
  const handleClear = async () => {
    if (busy) return;
    setBusy(true);
    try {
      const ok = await masterAuthVerify(clearPw);
      if (!ok) {
        toast.error("当前密码不正确");
        return;
      }
      await dbMigrateToPlaintext();
      await dbInitPlaintext();
      await masterAuthClear();
      toast.success("已清除主密码");
      window.location.reload();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      <SectionHeader title="安全" desc="管理主密码与数据库加密" />

      {/* 状态卡：两态 */}
      {hasMasterAuth === false && (
        <div className="flex items-center gap-4 rounded-lg border p-5">
          <div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-muted">
            <Lock className="size-5 text-muted-foreground" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">未设置主密码</p>
            <p className="text-xs text-muted-foreground">
              设置后数据库将以 SQLCipher 加密存储，每次启动需要输入主密码解锁
            </p>
          </div>
          <Button onClick={openSetup}>设置主密码</Button>
        </div>
      )}

      {hasMasterAuth === true && (
        <div className="flex items-center gap-4 rounded-lg border p-5">
          <div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-success/15">
            <ShieldCheck className="text-success size-5" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">已设置主密码</p>
            <p className="text-xs text-muted-foreground">数据库以 SQLCipher 加密存储</p>
          </div>
          <div className="flex gap-2">
            <Button variant="outline" onClick={openChange}>
              修改密码
            </Button>
            <Button variant="outline" onClick={() => { setClearPw(""); setClearOpen(true); }}>
              清除主密码
            </Button>
          </div>
        </div>
      )}

      {/* ===== 设置主密码 Sheet ===== */}
      <Sheet open={setupOpen} onOpenChange={setSetupOpen}>
        <SheetContent side="right">
          <SheetHeader>
            <SheetTitle>设置主密码</SheetTitle>
            <SheetDescription>
              设置后数据库将以加密模式打开，请务必牢记主密码
            </SheetDescription>
          </SheetHeader>
          {setupDone ? (
            <div className="flex flex-1 flex-col items-center justify-center gap-3 px-6 text-center">
              <ShieldCheck className="text-success size-12" />
              <p className="text-sm font-medium">主密码已设置</p>
              <p className="text-xs text-muted-foreground">
                数据库已完成加密迁移，重启应用后生效
              </p>
              <Button onClick={() => window.location.reload()}>立即重启</Button>
            </div>
          ) : (
            <>
              <div className="flex-1 space-y-4 overflow-y-auto px-6 py-4">
                <div className="space-y-1.5">
                  <Label htmlFor="setup-pw">密码</Label>
                  <Input
                    id="setup-pw"
                    type="password"
                    autoFocus
                    value={setupPw}
                    onChange={(e) => {
                      setSetupPw(e.target.value);
                      setSetupError(null);
                    }}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="setup-confirm">确认密码</Label>
                  <Input
                    id="setup-confirm"
                    type="password"
                    value={setupConfirm}
                    onChange={(e) => {
                      setSetupConfirm(e.target.value);
                      setSetupError(null);
                    }}
                  />
                </div>
                {setupError && <p className="text-xs text-destructive">{setupError}</p>}
              </div>
              <SheetFooter>
                <Button variant="outline" onClick={() => setSetupOpen(false)}>
                  取消
                </Button>
                <Button disabled={busy} onClick={() => void handleSetup()}>
                  {busy ? "处理中…" : "设置"}
                </Button>
              </SheetFooter>
            </>
          )}
        </SheetContent>
      </Sheet>

      {/* ===== 修改主密码 Sheet ===== */}
      <Sheet open={changeOpen} onOpenChange={setChangeOpen}>
        <SheetContent side="right">
          <SheetHeader>
            <SheetTitle>修改主密码</SheetTitle>
            <SheetDescription>输入当前密码与新密码</SheetDescription>
          </SheetHeader>
          <div className="flex-1 space-y-4 overflow-y-auto px-6 py-4">
            <div className="space-y-1.5">
              <Label htmlFor="old-pw">旧密码</Label>
              <Input
                id="old-pw"
                type="password"
                autoFocus
                value={oldPw}
                onChange={(e) => {
                  setOldPw(e.target.value);
                  setChangeError(null);
                }}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="new-pw">新密码</Label>
              <Input
                id="new-pw"
                type="password"
                value={newPw}
                onChange={(e) => {
                  setNewPw(e.target.value);
                  setChangeError(null);
                }}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="new-confirm">确认新密码</Label>
              <Input
                id="new-confirm"
                type="password"
                value={changeConfirm}
                onChange={(e) => {
                  setChangeConfirm(e.target.value);
                  setChangeError(null);
                }}
              />
            </div>
            {changeError && <p className="text-xs text-destructive">{changeError}</p>}
          </div>
          <SheetFooter>
            <Button variant="outline" onClick={() => setChangeOpen(false)}>
              取消
            </Button>
            <Button disabled={busy} onClick={() => void handleChange()}>
              {busy ? "处理中…" : "保存"}
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      {/* ===== 清除主密码 Sheet ===== */}
      <Sheet open={clearOpen} onOpenChange={setClearOpen}>
        <SheetContent side="right">
          <SheetHeader>
            <SheetTitle>清除主密码</SheetTitle>
            <SheetDescription>验证当前密码后将数据库迁移回明文模式</SheetDescription>
          </SheetHeader>
          <div className="flex-1 space-y-4 overflow-y-auto px-6 py-4">
            <div
              className={cn(
                "flex items-start gap-2 rounded-md border border-warning/40 bg-warning/10 p-3",
              )}
            >
              <TriangleAlert className="text-warning mt-0.5 size-4 shrink-0" />
              <p className="text-xs text-warning">
                清除后数据库将以明文存储，不再需要解锁。此操作会在本地完成迁移，建议先备份。
              </p>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="clear-pw">当前密码</Label>
              <Input
                id="clear-pw"
                type="password"
                autoFocus
                value={clearPw}
                onChange={(e) => setClearPw(e.target.value)}
              />
            </div>
          </div>
          <SheetFooter>
            <Button variant="outline" onClick={() => setClearOpen(false)}>
              取消
            </Button>
            <Button variant="destructive" disabled={busy || !clearPw} onClick={() => void handleClear()}>
              {busy ? "处理中…" : "确认清除"}
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
