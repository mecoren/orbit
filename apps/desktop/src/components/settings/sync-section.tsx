/**
 * SyncSection — 同步与备份分区（M3，06 任务 3.2/3.3/3.4）
 *
 * 结构：
 * 1. 连接卡：WebDAV/S3 引擎切换 + 表单 + 测试连接/保存/断开
 * 2. 同步密码卡（E2E）：未设置 → 设置；已设置 → 解锁/锁定/修改 + 密钥包导出
 * 3. 同步执行卡：立即同步 + 进度事件 + 上次同步时间
 * 3b. 同步历史卡（P1-17）：增量同步成败/耗时/计数可回看（sync_history 表）
 * 4. 自动备份卡：调度频率（core v4 调度器）+ 本地/云端开关 + 上次/下次时间
 * 5. 备份卡：.orsync 导出（可选云端副本）/ 导入恢复 / 本地历史备份列表
 * 6. 数据导出卡：明文 JSON/CSV（07 报告 #15，与 .orsync 加密包并列；
 *    未加密明示 + 系统保存对话框，隐私口径见 PRIVACY.md §七）
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
  ChevronDown,
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
  Upload,
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
  cloudSyncHistory,
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
  type CsvImportPresetKey,
  type CsvImportPreviewView,
  type CsvImportStats,
  type SyncConfigView,
  type SyncCryptoStatus,
  type SyncEngineKind,
  type SyncHistoryEntry,
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
      <SectionHeader title="同步与备份" desc="E2E 加密云同步 · WebDAV / S3 · 全量备份 · 数据导出 · CSV 导入" />
      <ConnectionCard key={`conn-${version}`} />
      <SyncPasswordCard />
      <SyncRunCard key={`run-${version}`} />
      <SyncHistoryCard />
      <AutoBackupCard />
      <BackupCard />
      <PlaintextExportCard />
      <CsvImportCard />
      <DbMaintenanceCard />
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
      // v2 密钥方案下改密即换 Key：命令内部已编排云端全量重传
      toast.success("同步密码已修改（云端数据已用新密钥重传，其他设备请用新密码同步）");
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
            未设置。设置后所有上传数据将以该密码端到端加密；同一密码在任何设备
            派生同一把密钥，跨设备只需输入相同密码。
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
          <p className="text-xs text-muted-foreground">
            v2 密钥方案下修改密码会更换数据密钥，云端数据将自动用新密钥全量重传
            （数据量较大时耗时稍长）；其他设备此后请使用新密码。
          </p>
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

/* ============================ 3b. 同步历史卡（P1-17） ============================ */

/** sync_type → 展示名（口径见 core cloud_sync_api::incremental_history） */
const SYNC_TYPE_LABELS: Record<string, string> = {
  incremental: "完整同步",
  push_only: "即时推送",
  pull_only: "启动同步",
};

function SyncHistoryCard() {
  const [open, setOpen] = useState(false);
  const [entries, setEntries] = useState<SyncHistoryEntry[] | null>(null);
  const [loading, setLoading] = useState(false);

  const load = () => {
    setLoading(true);
    cloudSyncHistory("all", 50)
      .then(setEntries)
      .catch(() => setEntries([]))
      .finally(() => setLoading(false));
  };

  // 展开才拉取；同步完成后刷新（打开状态下增量更新）
  useEffect(() => {
    if (open && entries === null) load();
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const unlisten = listen("sync-finished", () => {
      if (open) load();
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [open]);

  return (
    <div className="rounded-lg border">
      <button
        type="button"
        className="flex w-full items-center gap-4 p-5 text-left"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <History className="size-4 shrink-0 text-muted-foreground" />
        <p className="min-w-0 flex-1 text-sm font-medium">
          同步历史
          {entries !== null && (
            <span className="ml-2 text-xs text-muted-foreground">
              最近 {entries.length} 次增量同步
            </span>
          )}
        </p>
        <ChevronDown
          className={cn("size-4 shrink-0 text-muted-foreground transition-transform", open && "rotate-180")}
        />
      </button>
      {open && (
        <div className="max-h-72 space-y-1 overflow-auto border-t p-3">
          {loading && entries === null && (
            <p className="py-4 text-center text-xs text-muted-foreground">加载中…</p>
          )}
          {entries !== null && entries.length === 0 && (
            <p className="py-4 text-center text-xs text-muted-foreground">
              暂无同步记录——首次同步后此处可回看每次成败与耗时
            </p>
          )}
          {entries?.map((h) => (
            <div key={h.id} className="flex items-center gap-3 rounded-md px-2 py-1.5 hover:bg-muted/50">
              <span
                className={cn(
                  "size-1.5 shrink-0 rounded-full",
                  h.status === "success" ? "bg-emerald-500" : "bg-destructive",
                )}
                aria-label={h.status === "success" ? "成功" : "失败"}
              />
              <span className="w-16 shrink-0 text-xs text-muted-foreground">
                {SYNC_TYPE_LABELS[h.sync_type] ?? h.sync_type}
              </span>
              <span className="min-w-0 flex-1 truncate text-xs">
                {new Date(h.started_at).toLocaleString()}
                {h.finished_at != null && h.finished_at > h.started_at && (
                  <span className="ml-2 text-muted-foreground">
                    耗时 {((h.finished_at - h.started_at) / 1000).toFixed(1)}s
                  </span>
                )}
              </span>
              <span className="shrink-0 text-xs text-muted-foreground">
                拉 {h.pulled_count} / 推 {h.pushed_count}
              </span>
              {h.error_message && (
                <span className="max-w-40 shrink-0 truncate text-xs text-destructive" title={h.error_message}>
                  {h.error_message}
                </span>
              )}
            </div>
          ))}
        </div>
      )}
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
      // 本地写入失败（磁盘满等）不得报成功——P1-15 假成功口径修复
      if (p.local_error) {
        toast.warning(`自动备份本地写入失败：${p.local_error}`);
        if (p.cloud_error) toast.warning(`云端副本上传失败：${p.cloud_error}`);
        return;
      }
      if (p.local_path) {
        const name = p.local_path.split(/[\\/]/).pop();
        toast.success(`自动备份完成：${name ?? ""}`);
      } else if (p.cloud_uploaded) {
        toast.success("自动备份完成（仅云端）");
      } else {
        // 本地关闭且云端未成功：无任何副本落盘，按失败提示
        toast.warning(`自动备份未产生副本：${p.cloud_error ?? "云端未配置或未启用"}`);
      }
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

/* ============================ 6. 数据导出卡（明文） ============================ */

/**
 * 明文数据导出（07 报告 #15）：与 .orsync 加密备份并列的数据主权通道。
 *
 * - JSON：8 张业务表结构化全量（默认排除墓碑行）
 * - CSV：任务主视图（含项目名/标签聚合列），UTF-8 BOM，Excel 直开
 *
 * 保存路径由系统保存对话框选择；导出内容为**未加密明文**，
 * 卡头文案明示（PRIVACY.md §七口径）。
 */
function PlaintextExportCard() {
  const [busy, setBusy] = useState<"json" | "csv" | "ics" | null>(null);
  const [excludeDeleted, setExcludeDeleted] = useState(true);

  const doExport = async (kind: "json" | "csv" | "ics") => {
    setBusy(kind);
    try {
      if (kind === "ics") return doIcsExport();
      const { plaintextExportJson, plaintextExportCsv } = await import("@/lib/tauri");
      const r =
        kind === "json"
          ? await plaintextExportJson(excludeDeleted)
          : await plaintextExportCsv(excludeDeleted);

      const { save } = await import("@tauri-apps/plugin-dialog");
      const path = await save({
        title: "导出明文数据",
        defaultPath: r.suggested_filename,
        filters: [
          kind === "json"
            ? { name: "JSON 文档", extensions: ["json"] }
            : { name: "CSV 表格", extensions: ["csv"] },
        ],
      });
      if (!path) return; // 用户取消

      const { writeTextFile } = await import("@tauri-apps/plugin-fs");
      await writeTextFile(path, r.content);

      const tasks = r.table_counts["todo_tasks"] ?? 0;
      toast.success(`已导出 ${kind.toUpperCase()}（任务 ${tasks} 条）到：${path}`);
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(null);
    }
  };

  /** ICS 导出（#4）：VTODO 日历——系统日历/其他日历软件导入或订阅；
   *  独立处理链（不经 excludeDeleted：日历侧无墓碑概念） */
  const doIcsExport = async () => {
    try {
      const { icsExport } = await import("@/lib/tauri");
      const r = await icsExport();
      const { save } = await import("@tauri-apps/plugin-dialog");
      const path = await save({
        title: "导出日历文件",
        defaultPath: r.suggested_filename,
        filters: [{ name: "iCalendar 日历", extensions: ["ics"] }],
      });
      if (!path) return; // 用户取消
      const { writeTextFile } = await import("@tauri-apps/plugin-fs");
      await writeTextFile(path, r.content);
      const tasks = r.table_counts["todo_tasks"] ?? 0;
      toast.success(`已导出 ICS 日历（任务 ${tasks} 条）到：${path}`);
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(null);
    }
  };

  const confirmExport = (kind: "json" | "csv") => {
    if (
      window.confirm(
        "导出内容为未加密明文，任何拿到该文件的人都能读取。确定继续？",
      )
    ) {
      void doExport(kind);
    }
  };

  return (
    <div className="space-y-3 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <Download className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">数据导出（明文）</span>
      </div>
      <p className="text-xs text-muted-foreground">
        将待办数据导出为开放格式：JSON 为 8 张业务表结构化全量，CSV 为任务主视图
        （含项目名与标签列，Excel 可直接打开），ICS 为标准日历文件（任务以
        VTODO 输出，可导入系统日历或其他日历软件）。文件为未加密明文，请妥善保管。
      </p>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Switch
            id="export-exclude-deleted"
            checked={excludeDeleted}
            onCheckedChange={setExcludeDeleted}
            aria-label="排除已删除数据开关"
          />
          <Label htmlFor="export-exclude-deleted" className="text-xs text-normal">
            排除已删除数据
          </Label>
          <span className="text-xs text-muted-foreground">
            {excludeDeleted ? "仅导出有效数据" : "包含墓碑行（同步语义）"}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={!!busy}
            onClick={() => confirmExport("json")}
          >
            {busy === "json" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
            导出 JSON
          </Button>
          <Button size="sm" variant="outline" disabled={!!busy} onClick={() => confirmExport("csv")}>
            {busy === "csv" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
            导出 CSV
          </Button>
          <Button
            size="sm"
            variant="outline"
            disabled={!!busy}
            onClick={() => {
              setBusy("ics");
              void doIcsExport();
            }}
          >
            {busy === "ics" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
            导出日历
          </Button>
        </div>
      </div>
    </div>
  );
}

/* ============================ 7. CSV 导入卡（迁移路径） ============================ */

/**
 * CSV 导入（迁移路径）：与明文导出对称的导入方向。
 *
 * 三档预设——orbit（自家导出格式，往返一致）/ Todoist / TickTick 模板。
 * 两段式：选文件 → 预览（映射行 + 统计，不写库）→ 确认执行（项目自动
 * 创建、逐行独立成败、每行生成新 uuid）。
 */
function CsvImportCard() {
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState<"preview" | "execute" | null>(null);
  const [preset, setPreset] = useState<CsvImportPresetKey>("orbit");
  const [fileName, setFileName] = useState<string | null>(null);
  const [content, setContent] = useState<string | null>(null);
  const [preview, setPreview] = useState<CsvImportPreviewView | null>(null);
  const [result, setResult] = useState<CsvImportStats | null>(null);

  const pickFile = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const path = await open({
        title: "选择要导入的 CSV 文件",
        multiple: false,
        filters: [{ name: "CSV 表格", extensions: ["csv", "txt"] }],
      });
      if (!path) return; // 用户取消
      const { readTextFile } = await import("@tauri-apps/plugin-fs");
      const text = await readTextFile(path);
      setFileName(path.split(/[\\/]/).pop() ?? String(path));
      setContent(text);
      setPreview(null);
      setResult(null);
    } catch (err) {
      toast.error(errMsg(err));
    }
  };

  const doPreview = async () => {
    if (content == null) return;
    setBusy("preview");
    try {
      const { csvImportPreview } = await import("@/lib/tauri");
      const p = await csvImportPreview(content, preset, 10);
      setPreview(p);
      setResult(null);
      if (p.stats.success === 0 && p.stats.skipped > 0) {
        toast.warning("未识别到可导入行，请检查预设档位是否匹配文件格式");
      }
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(null);
    }
  };

  const doExecute = async () => {
    if (content == null) return;
    setBusy("execute");
    try {
      const { csvImportExecute } = await import("@/lib/tauri");
      const stats = await csvImportExecute(content, preset);
      setResult(stats);
      setPreview(null);
      const parts = [`成功 ${stats.success} 条`];
      if (stats.skipped) parts.push(`跳过 ${stats.skipped} 条`);
      if (stats.failed) parts.push(`失败 ${stats.failed} 条`);
      if (stats.failed) toast.warning(`导入完成：${parts.join("，")}`);
      else toast.success(`导入完成：${parts.join("，")}`);
      // 写库后失效任务/项目缓存（事件面在真实 Tauri 下也会广播，此处兜底）
      queryClient.invalidateQueries();
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="space-y-3 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <Upload className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">导入 CSV（迁移）</span>
      </div>
      <p className="text-xs text-muted-foreground">
        从其他应用迁入任务：支持 Orbit 自有导出格式（往返一致）、Todoist 与
        TickTick 模板。导入前先预览映射结果；项目不存在会自动创建，每行独立
        成败互不阻断。
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <Select
          value={preset}
          onValueChange={(v) => {
            setPreset(v as CsvImportPresetKey);
            setPreview(null);
            setResult(null);
          }}
        >
          <SelectTrigger className="h-8 w-36 text-xs" aria-label="导入预设档位">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="orbit">Orbit 导出格式</SelectItem>
            <SelectItem value="todoist">Todoist 模板</SelectItem>
            <SelectItem value="ticktick">TickTick 模板</SelectItem>
          </SelectContent>
        </Select>
        <Button size="sm" variant="outline" onClick={() => void pickFile()}>
          选择文件
        </Button>
        {fileName ? (
          <span className="max-w-56 truncate text-xs text-muted-foreground">{fileName}</span>
        ) : null}
        <Button
          size="sm"
          disabled={content == null || busy != null}
          onClick={() => void doPreview()}
        >
          {busy === "preview" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          预览
        </Button>
        {preview && preview.stats.success > 0 ? (
          <Button
            size="sm"
            disabled={busy != null}
            onClick={() =>
              window.confirm(
                `将导入 ${preview.stats.success} 条任务（跳过 ${preview.stats.skipped} 行），确定继续？`,
              ) && void doExecute()
            }
          >
            {busy === "execute" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
            导入
          </Button>
        ) : null}
      </div>

      {preview ? (
        <div className="space-y-2">
          <div className="text-xs text-muted-foreground">
            待导入 {preview.stats.success} 条 · 跳过 {preview.stats.skipped} 行
            （前 {preview.rows.length} 行预览）
          </div>
          <div className="overflow-hidden rounded-md border text-xs">
            <table className="w-full">
              <thead className="bg-muted/50 text-muted-foreground">
                <tr>
                  <th className="px-2 py-1.5 text-left font-medium">标题</th>
                  <th className="px-2 py-1.5 text-left font-medium">项目</th>
                  <th className="px-2 py-1.5 text-left font-medium">截止</th>
                  <th className="px-2 py-1.5 text-left font-medium">状态</th>
                </tr>
              </thead>
              <tbody>
                {preview.rows.map((r) => (
                  <tr key={r.source_line} className="border-t">
                    <td className="max-w-48 truncate px-2 py-1.5">
                      {r.input.title}
                    </td>
                    <td className="px-2 py-1.5 text-muted-foreground">
                      {r.project_title ?? "未分组"}
                    </td>
                    <td className="px-2 py-1.5 text-muted-foreground">
                      {r.input.due_date != null ? "有" : "—"}
                    </td>
                    <td className="px-2 py-1.5 text-muted-foreground">
                      {r.skip_reason ? (
                        <span className="text-destructive">跳过：{r.skip_reason}</span>
                      ) : r.input.done === 1 ? (
                        "已完成"
                      ) : (
                        "待办"
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ) : null}

      {result ? (
        <div className="text-xs text-muted-foreground">
          导入完成：成功 {result.success} 条
          {result.skipped ? ` · 跳过 ${result.skipped} 行` : ""}
          {result.failed ? ` · 失败 ${result.failed} 条` : ""}
          {result.notes.length > 0 ? (
            <details className="mt-1">
              <summary className="cursor-pointer">逐行说明（{result.notes.length}）</summary>
              <ul className="mt-1 list-disc pl-4">
                {result.notes.slice(0, 20).map((n, i) => (
                  <li key={i}>{n}</li>
                ))}
              </ul>
            </details>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/* ============================ 8. 数据库维护卡（性能批次） ============================ */

/**
 * 一键数据库维护（性能批次）：WAL checkpoint 回收日志 → 附件 GC 清孤儿文件
 * → PRAGMA optimize 更新查询统计 → VACUUM 整库重写回收碎片页。
 *
 * 只读维护：不产生 db-change（列表缓存不受影响）、不触碰同步数据。
 * 建议低频手动触发（大库 VACUUM 秒级耗时），量化结果就地展示。
 */
function DbMaintenanceCard() {
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<
    import("@/lib/tauri").DbMaintenanceResult | null
  >(null);

  const runMaintenance = async () => {
    setBusy(true);
    setResult(null);
    try {
      const { dbMaintenance } = await import("@/lib/tauri");
      const r = await dbMaintenance();
      setResult(r);
      toast.success("数据库维护完成");
    } catch (err) {
      toast.error(errMsg(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3 rounded-lg border p-5">
      <div className="flex items-center gap-2">
        <DatabaseBackup className="size-4 text-muted-foreground" />
        <span className="text-sm font-medium">数据库维护</span>
      </div>
      <p className="text-xs text-muted-foreground">
        一键优化本地数据库：回收 WAL 日志与磁盘碎片、清理无引用附件文件、
        更新查询统计（列表/搜索提速）。不改动任何数据与同步状态，建议偶发卡顿时手动执行。
      </p>
      <div className="flex items-center justify-between">
        {result ? (
          <span className="text-xs text-muted-foreground">
            回收碎片页 {result.pages_reclaimed} · 附件清理 {result.attachments_cleaned} ·
            WAL 残留 {formatBytes(result.wal_bytes_after_checkpoint)}
          </span>
        ) : (
          <span className="text-xs text-muted-foreground">上次维护结果将在此显示</span>
        )}
        <Button size="sm" variant="outline" disabled={busy} onClick={() => void runMaintenance()}>
          {busy ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          立即维护
        </Button>
      </div>
    </div>
  );
}
