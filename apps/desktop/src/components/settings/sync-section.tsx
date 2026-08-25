/**
 * SyncSection — 同步与备份分区（M3，06 任务 3.2/3.3/3.4）
 *
 * 结构：
 * 1. 连接卡：WebDAV/S3 引擎切换 + 表单 + 测试连接/保存/断开
 * 2. 同步密码卡（E2E）：未设置 → 设置；已设置 → 解锁/锁定/修改 + 密钥包导出
 * 3. 同步执行卡：立即同步 + 进度事件 + 上次同步时间
 * 4. 自动备份卡：调度频率（core v4 调度器）+ 本地/云端开关 + 上次/下次时间
 * 5. 备份卡：.orsync 导出（可选云端副本）/ 导入恢复 / 本地历史备份列表
 *
 * sync-config-changed（保存/断开）→ 重挂连接与执行卡刷新配置视图。
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import { toast } from "sonner";
import {
  CalendarClock,
  CloudUpload,
  DatabaseBackup,
  Download,
  History,
  KeyRound,
  Loader2,
  Lock,
  LockOpen,
  RefreshCw,
  ShieldCheck,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import {
  backupPrefsGet,
  backupPrefsSave,
  cloudSyncNow,
  fullBackupExport,
  fullBackupImport,
  fullBackupListLocal,
  syncConfigGet,
  syncConfigSave,
  syncCryptoChangePassword,
  syncCryptoExportBundle,
  syncCryptoForgetSession,
  syncCryptoInit,
  syncCryptoLock,
  syncCryptoStatus,
  syncCryptoUnlock,
  syncDisconnect,
  syncErrorTag,
  syncTestConnection,
  type AutoBackupFinishedEvent,
  type BackupEntryView,
  type BackupPrefs,
  type BackupScheduleType,
  type SyncConfigView,
  type SyncCryptoStatus,
  type SyncEngineKind,
} from "@/lib/tauri";

function SectionHeader({ title, desc }: { title: string; desc: string }) {
  return (
    <div>
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
}

/** 错误消息转用户文案（保留 tag 前缀供开发排查） */
function errMsg(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.replace(/^\[\w+\]\s*/, "");
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export function SyncSection() {
  // 配置保存/断开后重挂连接与执行卡（表单回读已保存值、刷新上次同步时间）
  const [version, setVersion] = useState(0);

  useEffect(() => {
    const unlisten = listen("sync-config-changed", () => {
      setVersion((v) => v + 1);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  return (
    <div className="space-y-6">
      <SectionHeader title="同步与备份" desc="E2E 加密云同步 · WebDAV / S3 · 全量备份" />
      <ConnectionCard key={`conn-${version}`} />
      <SyncPasswordCard />
      <SyncRunCard key={`run-${version}`} />
      <AutoBackupCard />
      <BackupCard />
    </div>
  );
}

/* ============================ 1. 连接卡 ============================ */

function ConnectionCard() {
  const qc = useQueryClient();
  const [config, setConfig] = useState<SyncConfigView | null>(null);
  const [engine, setEngine] = useState<SyncEngineKind>("webdav");
  const [endpoint, setEndpoint] = useState("");
  const [bucket, setBucket] = useState("");
  const [region, setRegion] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [basePath, setBasePath] = useState("orbit");
  const [interval, setIntervalMin] = useState(60);
  const [autoEnabled, setAutoEnabled] = useState(true);
  const [onChange, setOnChange] = useState(false);
  const [skipTls, setSkipTls] = useState(false);
  const [timeoutSecs, setTimeoutSecs] = useState(30);
  const [busy, setBusy] = useState(false);
  const [testing, setTesting] = useState(false);
  // 断开前确认（断开只清本机配置，不动本地数据与云端文件）
  const [confirmDisconnect, setConfirmDisconnect] = useState(false);

  useEffect(() => {
    syncConfigGet()
      .then((c) => {
        if (!c) return;
        setConfig(c);
        setEngine(c.engine === "s3" ? "s3" : "webdav");
        setEndpoint(c.endpoint);
        setBucket(c.bucket);
        setRegion(c.region);
        setUsername(c.username);
        setBasePath(c.base_path || "orbit");
        setIntervalMin(c.interval_minutes);
        setAutoEnabled(c.auto_sync_enabled);
        setOnChange(c.sync_on_change);
        setSkipTls(c.skip_tls_verify);
        setTimeoutSecs(c.timeout_seconds || 30);
      })
      .catch(() => {});
  }, []);

  /** 密码留空 = 沿用已保存凭据（后端语义：空串不覆盖 credential 列） */
  const buildInput = () => ({
    engine,
    endpoint: endpoint.trim(),
    bucket: engine === "s3" ? bucket.trim() : "",
    region: engine === "s3" ? region.trim() : "",
    username,
    password,
    base_path: basePath.trim() || "orbit",
    interval_minutes: interval,
    auto_sync_enabled: autoEnabled,
    sync_on_change: onChange,
    skip_tls_verify: skipTls,
    timeout_seconds: timeoutSecs,
  });

  const handleTest = async () => {
    setTesting(true);
    try {
      const n = await syncTestConnection({ ...buildInput(), password });
      toast.success(`连接成功（根目录 ${n} 个条目）`);
    } catch (err) {
      toast.error(`连接失败：${errMsg(err)}`);
    } finally {
      setTesting(false);
    }
  };

  const handleSave = async () => {
    setBusy(true);
    try {
      await syncConfigSave(buildInput());
      toast.success("同步配置已保存");
      const c = await syncConfigGet();
      setConfig(c);
      void qc.invalidateQueries({ queryKey: ["sync-config"] });
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  const handleDisconnect = async () => {
    setBusy(true);
    try {
      await syncDisconnect();
      toast.success("已断开云同步（本地数据与云端文件均未删除）");
      setConfig(null);
      setConfirmDisconnect(false);
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <CloudUpload className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">云同步连接</span>
        {config && (
          <span className="ml-auto text-xs text-muted-foreground">
            已配置 · {config.engine.toUpperCase()}
          </span>
        )}
      </div>

      {/* 引擎选择 */}
      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-engine">引擎</Label>
        <Select value={engine} onValueChange={(v) => setEngine(v as SyncEngineKind)}>
          <SelectTrigger id="sync-engine">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="webdav">WebDAV</SelectItem>
            <SelectItem value="s3">S3 兼容存储</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-endpoint">{engine === "s3" ? "Endpoint" : "服务器地址"}</Label>
        <Input
          id="sync-endpoint"
          placeholder={engine === "s3" ? "https://s3.example.com" : "https://dav.example.com/dav"}
          value={endpoint}
          onChange={(e) => setEndpoint(e.target.value)}
        />
      </div>

      {engine === "s3" && (
        <>
          <div className="grid grid-cols-[80px_1fr] items-center gap-3">
            <Label htmlFor="sync-bucket">存储桶</Label>
            <Input id="sync-bucket" value={bucket} onChange={(e) => setBucket(e.target.value)} />
          </div>
          <div className="grid grid-cols-[80px_1fr] items-center gap-3">
            <Label htmlFor="sync-region">Region</Label>
            <Input
              id="sync-region"
              placeholder="us-east-1"
              value={region}
              onChange={(e) => setRegion(e.target.value)}
            />
          </div>
        </>
      )}

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-user">{engine === "s3" ? "Access Key" : "用户名"}</Label>
        <Input id="sync-user" value={username} onChange={(e) => setUsername(e.target.value)} />
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-pass">{engine === "s3" ? "Secret Key" : "密码"}</Label>
        <Input
          id="sync-pass"
          type="password"
          placeholder={config?.password_set ? "已保存（修改请重新输入）" : ""}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-path">远端路径</Label>
        <Input id="sync-path" value={basePath} onChange={(e) => setBasePath(e.target.value)} />
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-interval">定时同步</Label>
        <div className="flex items-center gap-3">
          <Switch checked={autoEnabled} onCheckedChange={setAutoEnabled} aria-label="自动同步开关" />
          <Select
            value={String(interval)}
            onValueChange={(v) => setIntervalMin(Number(v))}
            disabled={!autoEnabled}
          >
            <SelectTrigger className="w-36" id="sync-interval">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="10">每 10 分钟</SelectItem>
              <SelectItem value="30">每 30 分钟</SelectItem>
              <SelectItem value="60">每 60 分钟</SelectItem>
              <SelectItem value="120">每 2 小时</SelectItem>
              <SelectItem value="360">每 6 小时</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-on-change">修改后立即同步</Label>
        <div className="flex items-center gap-2">
          <Switch checked={onChange} onCheckedChange={setOnChange} aria-label="修改后立即同步开关" />
          <span className="text-xs text-muted-foreground">
            {onChange ? "编辑/删除任务后约 5 秒自动推送" : "仅按定时或手动同步"}
          </span>
        </div>
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-timeout">请求超时</Label>
        <div className="flex items-center gap-2">
          <Input
            id="sync-timeout"
            type="number"
            min={5}
            max={600}
            className="h-8 w-24"
            value={timeoutSecs}
            onChange={(e) => setTimeoutSecs(Number(e.target.value) || 30)}
          />
          <span className="text-xs text-muted-foreground">秒（5–600）</span>
        </div>
      </div>

      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="sync-tls">跳过 TLS 验证</Label>
        <div className="flex items-center gap-2">
          <Switch
            id="sync-tls"
            checked={skipTls}
            onCheckedChange={setSkipTls}
            aria-label="跳过 TLS 证书验证开关"
          />
          <span className={cn("text-xs", skipTls ? "text-warning" : "text-muted-foreground")}>
            {skipTls ? "自签名证书场景专用，存在中间人风险" : "校验服务器证书（推荐）"}
          </span>
        </div>
      </div>

      <p className="text-xs text-muted-foreground">
        数据以 AES-256-GCM 端到端加密后上传，服务商无法读取内容。
      </p>

      <div className="flex justify-end gap-2 border-t pt-3">
        {config && (
          <Button
            variant="ghost"
            className="text-destructive"
            disabled={busy}
            onClick={() => setConfirmDisconnect(true)}
          >
            断开
          </Button>
        )}
        <Button variant="outline" disabled={testing || busy || !endpoint.trim()} onClick={() => void handleTest()}>
          {testing ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          测试连接
        </Button>
        <Button disabled={busy || !endpoint.trim()} onClick={() => void handleSave()}>
          {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          保存
        </Button>
      </div>

      {/* 断开确认：断开仅清除本机连接配置，不删本地数据与云端文件 */}
      <AlertDialog open={confirmDisconnect} onOpenChange={setConfirmDisconnect}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>断开云同步？</AlertDialogTitle>
            <AlertDialogDescription>
              将清除本机保存的连接配置与凭据；本地数据与云端文件均不会删除，之后可随时重新配置。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-white hover:bg-destructive/90"
              disabled={busy}
              onClick={() => void handleDisconnect()}
            >
              {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
              断开
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/* ============================ 2. 同步密码卡 ============================ */

function SyncPasswordCard() {
  const [status, setStatus] = useState<SyncCryptoStatus | null>(null);

  // 设置密码
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);

  // 解锁
  const [unlockPw, setUnlockPw] = useState("");

  // 修改密码
  const [changeOpen, setChangeOpen] = useState(false);
  const [oldPw, setOldPw] = useState("");
  const [newPw, setNewPw] = useState("");

  const refresh = () => {
    syncCryptoStatus().then(setStatus).catch(() => {});
  };
  useEffect(refresh, []);

  const handleSetup = async () => {
    if (pw.length < 6) {
      toast.error("同步密码至少 6 位");
      return;
    }
    if (pw !== confirm) {
      toast.error("两次输入的密码不一致");
      return;
    }
    setBusy(true);
    try {
      await syncCryptoInit(pw, true);
      toast.success("同步密码已设置，端到端加密已就绪");
      setPw("");
      setConfirm("");
      refresh();
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  const handleUnlock = async () => {
    setBusy(true);
    try {
      await syncCryptoUnlock(unlockPw, true);
      toast.success("已解锁");
      setUnlockPw("");
      refresh();
    } catch (err) {
      const tag = syncErrorTag(err);
      toast.error(tag === "wrong_password" ? "同步密码错误" : errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  const handleLock = async () => {
    await syncCryptoLock().catch(() => {});
    refresh();
  };

  /** 导出 crypto bundle：跨设备 Data Key 分发载体（恢复页可导入） */
  const handleExportBundle = async () => {
    try {
      const bundle = await syncCryptoExportBundle();
      const { save } = await import("@tauri-apps/plugin-dialog");
      const path = await save({
        defaultPath: `orbit-crypto-bundle-${new Date().toISOString().slice(0, 10)}.json`,
        filters: [{ name: "Crypto Bundle", extensions: ["json"] }],
      });
      if (!path) return;
      const { writeTextFile } = await import("@tauri-apps/plugin-fs");
      await writeTextFile(path, JSON.stringify(bundle, null, 2));
      toast.success("密钥包已导出。请妥善保管：在其他设备导入它即可恢复解密能力");
    } catch (err) {
      toast.error(errMsg(err));
    }
  };

  const handleForgetSession = async () => {
    if (!window.confirm("将清除系统钥匙串中缓存的同步密码，下次启动需手动输入解锁。确定？")) {
      return;
    }
    try {
      await syncCryptoForgetSession();
      toast.success("已清除本机密码缓存（当前会话仍保持解锁）");
    } catch (err) {
      toast.error(errMsg(err));
    }
  };

  const handleChange = async () => {
    setBusy(true);
    try {
      await syncCryptoChangePassword(oldPw, newPw);
      toast.success("同步密码已修改");
      setChangeOpen(false);
      setOldPw("");
      setNewPw("");
    } catch (err) {
      const tag = syncErrorTag(err);
      toast.error(tag === "wrong_password" ? "旧密码错误" : errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <KeyRound className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">同步密码（端到端加密密钥）</span>
      </div>

      {status === null && (
        <p className="text-xs text-muted-foreground">加载中…</p>
      )}

      {status !== null && !status.has_password && (
        <>
          <p className="text-xs text-muted-foreground">
            未设置。设置后生成随机 Data Key 加密所有上传数据；跨设备请使用相同同步密码。
          </p>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="sync-pw">同步密码</Label>
              <Input id="sync-pw" type="password" value={pw} onChange={(e) => setPw(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="sync-confirm">确认密码</Label>
              <Input
                id="sync-confirm"
                type="password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
              />
            </div>
          </div>
          <div className="flex justify-end">
            <Button size="sm" disabled={busy || !pw} onClick={() => void handleSetup()}>
              {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
              设置并解锁
            </Button>
          </div>
        </>
      )}

      {status !== null && status.has_password && (
        <div className="flex items-center gap-3">
          <div
            className={cn(
              "flex size-8 shrink-0 items-center justify-center rounded-full",
              status.is_unlocked ? "bg-success/15" : "bg-muted",
            )}
          >
            {status.is_unlocked ? (
              <ShieldCheck className="size-4 text-success" />
            ) : (
              <Lock className="size-4 text-muted-foreground" />
            )}
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">
              {status.is_unlocked ? "已解锁" : "已锁定"}
            </p>
            <p className="text-xs text-muted-foreground">
              {status.is_unlocked
                ? "Data Key 在内存中，可执行同步与备份"
                : "输入同步密码解锁后才能同步"}
            </p>
          </div>
          {!status.is_unlocked && (
            <div className="flex items-center gap-2">
              <Input
                type="password"
                placeholder="同步密码"
                className="h-8 w-40"
                value={unlockPw}
                onChange={(e) => setUnlockPw(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void handleUnlock();
                }}
              />
              <Button size="sm" variant="outline" disabled={busy || !unlockPw} onClick={() => void handleUnlock()}>
                {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : <LockOpen className="mr-1 size-3" />}
                解锁
              </Button>
            </div>
          )}
          {status.is_unlocked && (
            <div className="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                onClick={() => {
                  setOldPw("");
                  setNewPw("");
                  setChangeOpen(true);
                }}
              >
                修改密码
              </Button>
              <Button size="sm" variant="ghost" onClick={() => void handleLock()}>
                <Lock className="mr-1 size-3" />
                锁定
              </Button>
            </div>
          )}
        </div>
      )}

      {status !== null && status.has_password && (
        <div className="flex items-center justify-between border-t pt-2">
          <Button
            variant="ghost"
            size="sm"
            className="h-7 text-xs text-muted-foreground"
            onClick={() => void handleExportBundle()}
            title="导出 crypto bundle，用于在其他设备恢复解密能力"
          >
            <Download className="mr-1 size-3" />
            导出密钥包
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 text-xs text-muted-foreground"
            onClick={() => void handleForgetSession()}
          >
            忘记此设备的同步密码缓存
          </Button>
        </div>
      )}

      {changeOpen && (
        <div className="space-y-3 rounded-md border bg-muted/20 p-3">
          <div className="grid grid-cols-2 gap-3">
            <Input
              type="password"
              placeholder="旧密码"
              value={oldPw}
              onChange={(e) => setOldPw(e.target.value)}
            />
            <Input
              type="password"
              placeholder="新密码（至少 6 位）"
              value={newPw}
              onChange={(e) => setNewPw(e.target.value)}
            />
          </div>
          <div className="flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={() => setChangeOpen(false)}>
              取消
            </Button>
            <Button size="sm" disabled={busy || !oldPw || newPw.length < 6} onClick={() => void handleChange()}>
              {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
              确认修改
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

/* ============================ 3. 同步执行卡 ============================ */

function SyncRunCard() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [config, setConfig] = useState<SyncConfigView | null>(null);
  const [running, setRunning] = useState(false);
  const [progressText, setProgressText] = useState<string | null>(null);

  useEffect(() => {
    syncConfigGet().then(setConfig).catch(() => {});
  }, []);

  // 后台同步完成（含定时触发）→ 刷新上次同步时间展示
  useEffect(() => {
    const unlisten = listen("sync-finished", () => {
      syncConfigGet().then(setConfig).catch(() => {});
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  // 手动同步进度（origin=manual；background 由全局 SyncIndicator 展示）
  useEffect(() => {
    const unlisten = listen<{
      phase: string;
      origin: string;
      display_name?: string;
      current?: number;
      total?: number;
    }>("sync-progress", (evt) => {
      const p = evt.payload;
      if (p.origin !== "manual") return;
      const label =
        p.phase === "pushing" || p.phase === "pulling"
          ? `正在${p.phase === "pushing" ? "上传" : "下载"}${p.display_name ?? ""} ${p.current ?? 0}/${p.total ?? 0}`
          : p.phase === "merging"
            ? `正在合并${p.display_name ?? ""}`
            : null;
      if (label) setProgressText(label);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const handleSyncNow = async () => {
    setRunning(true);
    try {
      const result = await cloudSyncNow("manual");
      if (result.skipped) {
        toast.info("已有同步任务在进行中");
      } else {
        toast.success(
          `同步完成：推送 ${result.pushed_modules} 模块 / 拉取 ${result.pulled_modules} 模块` +
            (result.errors.length ? `（${result.errors.length} 个非致命错误）` : ""),
        );
      }
    } catch (err) {
      // KeyMismatch → 引导恢复页（与后台调度器行为对齐）
      if (syncErrorTag(err) === "key_mismatch") {
        navigate("/sync-recovery");
        return;
      }
      toast.error(errMsg(err));
    } finally {
      setRunning(false);
      setProgressText(null);
      void qc.invalidateQueries();
      syncConfigGet().then(setConfig).catch(() => {});
    }
  };

  return (
    <div className="flex items-center gap-4 rounded-lg border p-5">
      <RefreshCw className={cn("size-4 shrink-0 text-muted-foreground", running && "animate-spin")} />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium">立即同步</p>
        <p className="truncate text-xs text-muted-foreground">
          {running
            ? progressText ?? "正在同步…"
            : config?.last_synced_at
              ? `上次同步：${new Date(config.last_synced_at).toLocaleString()}`
              : "从未同步"}
        </p>
      </div>
      <Button size="sm" disabled={running} onClick={() => void handleSyncNow()}>
        {running ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
        同步
      </Button>
    </div>
  );
}

/* ============================ 4. 自动备份卡 ============================ */

const SCHEDULE_LABELS: Record<BackupScheduleType, string> = {
  off: "关闭",
  hourly: "每小时",
  daily: "每天",
  weekly: "每周",
  monthly: "每月",
  yearly: "每年",
};

const WEEKDAY_LABELS = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

function formatTsSecs(ts: number): string | null {
  return ts > 0 ? new Date(ts * 1000).toLocaleString() : null;
}

function AutoBackupCard() {
  const [prefs, setPrefs] = useState<BackupPrefs | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    backupPrefsGet()
      .then(setPrefs)
      .catch(() => setPrefs(null));
  }, []);

  // 定时备份完成事件 → 刷新上次/下次展示 + toast 提示
  useEffect(() => {
    const unlisten = listen<AutoBackupFinishedEvent>("auto-backup-finished", (evt) => {
      backupPrefsGet().then(setPrefs).catch(() => {});
      const p = evt.payload;
      if (!p.ok) {
        toast.warning(`自动备份失败：${p.error ?? "未知错误"}`);
        return;
      }
      if (p.local_path) {
        const name = p.local_path.split(/[\\/]/).pop();
        toast.success(`自动备份完成：${name ?? ""}`);
      } else {
        toast.success("自动备份完成（仅云端）");
      }
      if (p.cloud_error) toast.warning(`云端副本上传失败：${p.cloud_error}`);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const patch = (u: Partial<BackupPrefs>) =>
    setPrefs((p) => (p ? { ...p, ...u } : p));

  const handleSave = async () => {
    if (!prefs) return;
    setBusy(true);
    try {
      const saved = await backupPrefsSave(prefs);
      setPrefs(saved);
      toast.success(
        saved.schedule_type === "off"
          ? "已关闭定时自动备份"
          : `自动备份已保存，下次执行：${formatTsSecs(saved.next_backup_at) ?? "待调度"}`,
      );
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  if (!prefs) {
    return (
      <div className="flex items-center gap-2 rounded-lg border p-5">
        <CalendarClock className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">自动备份</span>
        <span className="ml-auto text-xs text-muted-foreground">加载中…</span>
      </div>
    );
  }

  const st = prefs.schedule_type;

  return (
    <div className="space-y-4 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <CalendarClock className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">自动备份</span>
        {st !== "off" && (
          <span className="ml-auto text-xs text-muted-foreground">
            已启用 · {SCHEDULE_LABELS[st]}
          </span>
        )}
      </div>

      {/* 调度频率 */}
      <div className="grid grid-cols-[80px_1fr] items-center gap-3">
        <Label htmlFor="backup-schedule">频率</Label>
        <Select
          value={st}
          onValueChange={(v) => patch({ schedule_type: v as BackupScheduleType })}
        >
          <SelectTrigger id="backup-schedule" className="w-40">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {(Object.keys(SCHEDULE_LABELS) as BackupScheduleType[]).map((k) => (
              <SelectItem key={k} value={k}>
                {SCHEDULE_LABELS[k]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {/* 调度时刻（按类型显示对应字段；core 以 UTC 计算） */}
      {st !== "off" && (
        <div className="grid grid-cols-[80px_1fr] items-center gap-3">
          <Label htmlFor="backup-time">时刻</Label>
          <div className="flex flex-wrap items-center gap-2">
            {st === "hourly" && (
              <>
                <span className="text-xs text-muted-foreground">每小时的第</span>
                <Input
                  id="backup-time"
                  type="number"
                  min={0}
                  max={59}
                  className="h-8 w-20"
                  value={prefs.schedule_minute}
                  onChange={(e) =>
                    patch({
                      schedule_minute: Math.min(59, Math.max(0, Number(e.target.value) || 0)),
                    })
                  }
                />
                <span className="text-xs text-muted-foreground">分</span>
              </>
            )}
            {st === "weekly" && (
              <Select
                value={String(prefs.schedule_weekday)}
                onValueChange={(v) => patch({ schedule_weekday: Number(v) })}
              >
                <SelectTrigger className="h-8 w-24">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {WEEKDAY_LABELS.map((label, i) => (
                    <SelectItem key={i} value={String(i)}>
                      {label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
            {st === "monthly" && (
              <>
                <span className="text-xs text-muted-foreground">每月</span>
                <Select
                  value={String(prefs.schedule_day_of_month)}
                  onValueChange={(v) => patch({ schedule_day_of_month: Number(v) })}
                >
                  <SelectTrigger className="h-8 w-20">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {Array.from({ length: 28 }, (_, i) => i + 1).map((d) => (
                      <SelectItem key={d} value={String(d)}>
                        {d} 日
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </>
            )}
            {st === "yearly" && (
              <>
                <Select
                  value={String(prefs.schedule_month)}
                  onValueChange={(v) => patch({ schedule_month: Number(v) })}
                >
                  <SelectTrigger className="h-8 w-24">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {Array.from({ length: 12 }, (_, i) => i + 1).map((m) => (
                      <SelectItem key={m} value={String(m)}>
                        {m} 月
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select
                  value={String(prefs.schedule_day_of_month)}
                  onValueChange={(v) => patch({ schedule_day_of_month: Number(v) })}
                >
                  <SelectTrigger className="h-8 w-20">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {Array.from({ length: 28 }, (_, i) => i + 1).map((d) => (
                      <SelectItem key={d} value={String(d)}>
                        {d} 日
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </>
            )}
            {st !== "hourly" && (
              <Input
                type="time"
                className="h-8 w-32"
                value={prefs.schedule_time}
                onChange={(e) => patch({ schedule_time: e.target.value || "03:00" })}
              />
            )}
          </div>
        </div>
      )}

      {/* 阶段开关 */}
      <div className="space-y-2.5">
        <div className="flex items-center gap-2">
          <Switch
            id="backup-local-enabled"
            checked={prefs.local_backup_enabled}
            onCheckedChange={(v) => patch({ local_backup_enabled: v })}
            aria-label="本地备份开关"
          />
          <Label htmlFor="backup-local-enabled" className="text-xs font-normal">
            写入本地 backups 目录
          </Label>
        </div>
        <div className="flex items-center gap-2">
          <Switch
            id="backup-cloud-enabled"
            checked={prefs.cloud_backup_enabled}
            onCheckedChange={(v) => patch({ cloud_backup_enabled: v })}
            aria-label="云端备份开关"
          />
          <Label htmlFor="backup-cloud-enabled" className="text-xs font-normal">
            上传云端副本
          </Label>
          <span className="text-xs text-muted-foreground">需已配置云同步</span>
        </div>
        <div className="flex items-center gap-2">
          <Switch
            id="backup-keep-latest"
            checked={prefs.keep_latest}
            onCheckedChange={(v) => patch({ keep_latest: v })}
            aria-label="仅保留最新备份开关"
          />
          <Label htmlFor="backup-keep-latest" className="text-xs font-normal">
            仅保留最新一份（防堆积）
          </Label>
        </div>
        <p className="text-xs text-muted-foreground">
          开关同时作用于云同步前的自动备份；加密口令取自钥匙串缓存的同步密码。
        </p>
      </div>

      {/* 状态与保存 */}
      <p className="text-xs text-muted-foreground">
        上次备份：
        {formatTsSecs(prefs.last_backup_at) ?? "从未执行"}
        {" · "}
        下次：
        {st === "off"
          ? "未调度"
          : formatTsSecs(prefs.next_backup_at) ?? "待调度"}
        （时刻按 UTC 计算，展示为本地时间）
      </p>

      <div className="flex justify-end border-t pt-3">
        <Button size="sm" disabled={busy} onClick={() => void handleSave()}>
          {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          保存设置
        </Button>
      </div>
    </div>
  );
}

/* ============================ 5. 备份卡 ============================ */

function BackupCard() {
  const [pw, setPw] = useState("");
  const [busy, setBusy] = useState<"export" | "import" | null>(null);
  const [cloudCopy, setCloudCopy] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [history, setHistory] = useState<BackupEntryView[] | null>(null);

  const loadHistory = () => {
    fullBackupListLocal()
      .then(setHistory)
      .catch(() => setHistory([]));
  };

  // 首次展开时懒加载；导出成功后由 handleExport 调 loadHistory 刷新
  useEffect(() => {
    if (historyOpen && history === null) loadHistory();
  }, [historyOpen]);

  // 定时自动备份完成 → 静默刷新历史列表（含未展开时的计数）
  useEffect(() => {
    const unlisten = listen<AutoBackupFinishedEvent>("auto-backup-finished", () => {
      loadHistory();
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const handleExport = async () => {
    setBusy("export");
    try {
      const r = await fullBackupExport(pw, cloudCopy);
      if (r.local_path) {
        const name = r.local_path.split(/[\\/]/).pop();
        toast.success(`已导出：${name ?? r.local_path}`);
        if (r.cloud_error) toast.warning(`云端副本上传失败：${r.cloud_error}`);
      } else {
        toast.error(r.local_error ?? "导出失败");
      }
      if (historyOpen) loadHistory();
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(null);
    }
  };

  const doImport = async (path: string, password: string, ignoreSchemaMismatch: boolean) => {
    setBusy("import");
    try {
      const r = await fullBackupImport(path, password, ignoreSchemaMismatch);
      toast.success(
        `导入完成：成功 ${r.success_count} 条${r.error_count ? `，失败 ${r.error_count} 条` : ""}`,
      );
    } catch (err) {
      // schema 版本不一致 → 提示后以忽略版本差异重试
      if (/schema/i.test(String(err)) && !ignoreSchemaMismatch) {
        if (window.confirm("备份的 schema 版本与当前应用不同，可能存在兼容风险。仍要导入？")) {
          return doImport(path, password, true);
        }
        return;
      }
      toast.error(errMsg(err));
    } finally {
      setBusy(null);
    }
  };

  const handleImportFile = async () => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({
      filters: [{ name: "Orbit 备份", extensions: ["orsync", "waitfullsync"] }],
      multiple: false,
    });
    if (!selected || typeof selected !== "string") return;
    const confirmed = window.confirm(
      "导入将用备份内容完全覆盖当前全部待办数据。确定继续？",
    );
    if (!confirmed) return;
    await doImport(selected, pw, false);
  };

  const handleRestoreEntry = async (entry: BackupEntryView) => {
    if (!window.confirm(`从「${entry.filename}」恢复将完全覆盖当前全部待办数据。确定继续？`)) {
      return;
    }
    await doImport(entry.file_path, pw, false);
  };

  return (
    <div className="space-y-3 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <DatabaseBackup className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">全量备份（.orsync）</span>
      </div>
      <p className="text-xs text-muted-foreground">
        导出包含全部待办表数据的加密备份包（AES-256-GCM）；导入为全量覆盖恢复，请先确认备份密码。
      </p>
      <div className="flex items-center gap-2">
        <Input
          type="password"
          placeholder="同步密码（备份加密口令）"
          className="h-8 flex-1"
          value={pw}
          onChange={(e) => setPw(e.target.value)}
        />
        <Button size="sm" variant="outline" disabled={!!busy || !pw} onClick={() => void handleExport()}>
          {busy === "export" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          导出
        </Button>
        <Button size="sm" variant="outline" disabled={!!busy || !pw} onClick={() => void handleImportFile()}>
          {busy === "import" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          导入恢复
        </Button>
      </div>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Switch
            id="backup-cloud-copy"
            checked={cloudCopy}
            onCheckedChange={setCloudCopy}
            aria-label="上传云端副本开关"
          />
          <Label htmlFor="backup-cloud-copy" className="text-xs font-normal">
            导出后同时上传云端副本
          </Label>
          <span className="text-xs text-muted-foreground">
            {cloudCopy ? "需已配置云同步并解锁" : "仅保存到本地 backups 目录"}
          </span>
        </div>
        <Button
          variant="ghost"
          size="sm"
          className="h-7 text-xs text-muted-foreground"
          onClick={() => {
            if (!historyOpen && history === null) loadHistory();
            setHistoryOpen((v) => !v);
          }}
        >
          <History className="mr-1 size-3" />
          历史备份{history ? `（${history.length}）` : ""}
        </Button>
      </div>

      {historyOpen && (
        <div className="space-y-1 rounded-md border bg-muted/20 p-2">
          {history === null && (
            <p className="px-1 py-0.5 text-xs text-muted-foreground">加载中…</p>
          )}
          {history !== null && history.length === 0 && (
            <p className="px-1 py-0.5 text-xs text-muted-foreground">暂无本地备份</p>
          )}
          {history?.map((e) => (
            <div key={e.file_path} className="flex items-center gap-2 rounded px-1 py-0.5 hover:bg-accent/40">
              <div className="min-w-0 flex-1">
                <p className="truncate text-xs font-medium">{e.filename}</p>
                <p className="text-[11px] text-muted-foreground">
                  {new Date(e.modified_at * 1000).toLocaleString()} · {formatBytes(e.size_bytes)}
                </p>
              </div>
              <Button
                variant="ghost"
                size="sm"
                className="h-7 text-xs"
                disabled={!!busy || !pw}
                onClick={() => void handleRestoreEntry(e)}
              >
                恢复
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
