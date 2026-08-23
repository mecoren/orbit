/**
 * 解锁页 — 已设置主密码时的启动入口（03 文档 §四 流程 2b）。
 *
 * 输入主密码 → masterAuthUnlock 解出 db_key_hex → onUnlocked 回调
 * 由 App 执行 dbInitEncrypted 进入主界面。密码错误由 Rust 返回错误展示。
 */
import { useState, type FormEvent } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { masterAuthUnlock } from "@/lib/tauri";

interface UnlockPageProps {
  /** 解锁成功回调，携带 db_key_hex（App 据此调用 dbInitEncrypted） */
  onUnlocked: (dbKeyHex: string) => void;
}

export function UnlockPage({ onUnlocked }: UnlockPageProps) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!password || loading) return;
    setLoading(true);
    setError(null);
    try {
      onUnlocked(await masterAuthUnlock(password));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex h-screen items-center justify-center bg-background">
      <form onSubmit={submit} className="w-full max-w-xs space-y-4 text-center">
        <h1 className="text-xl font-semibold">循迹</h1>
        <p className="text-sm text-muted-foreground">请输入主密码解锁</p>
        <div className="space-y-2 text-left">
          <Label htmlFor="master-password">主密码</Label>
          <Input
            id="master-password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoFocus
          />
          {error && <p className="text-xs text-destructive">{error}</p>}
        </div>
        <Button type="submit" className="w-full" disabled={!password || loading}>
          {loading ? "解锁中…" : "解锁"}
        </Button>
      </form>
    </div>
  );
}
