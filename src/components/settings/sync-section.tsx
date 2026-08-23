/**
 * SyncSection — 同步与备份分区（M3，06 任务 3.2/3.3/3.4）
 *
 * 结构：
 * 1. 连接卡：WebDAV/S3 引擎切换 + 表单 + 测试连接/保存/断开
 * 2. 同步密码卡（E2E）：未设置 → 设置；已设置 → 解锁/锁定/修改
 * 3. 同步执行卡：立即同步 + 进度事件 + 上次同步时间
 * 4. 备份卡：.orsync 导出 / 导入（全量覆盖恢复）
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import { toast } from "sonner";
import {
  CloudUpload,
  DatabaseBackup,
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import {
  cloudSyncNow,
  fullBackupExport,
  fullBackupImport,
  syncConfigGet,
  syncConfigSave,
  syncCryptoChangePassword,
  syncCryptoInit,
  syncCryptoLock,
  syncCryptoStatus,
  syncCryptoUnlock,
  syncDisconnect,
  syncErrorTag,
  syncTestConnection,
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

export function SyncSection() {
  return (
    <div className="space-y-6">
      <SectionHeader title="同步与备份" desc="E2E 加密云同步 · WebDAV / S3 · 全量备份" />
      <ConnectionCard />
      <SyncPasswordCard />
      <SyncRunCard />
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
          <Button variant="ghost" className="text-destructive" disabled={busy} onClick={() => void handleDisconnect()}>
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
                <LockOpen className="mr-1 size-3" />
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

/* ============================ 4. 备份卡 ============================ */

function BackupCard() {
  const [pw, setPw] = useState("");
  const [busy, setBusy] = useState<"export" | "import" | null>(null);

  const handleExport = async () => {
    setBusy("export");
    try {
      const r = await fullBackupExport(pw, false);
      if (r.local_path) {
        const name = r.local_path.split(/[\\/]/).pop();
        toast.success(`已导出：${name ?? r.local_path}`);
        if (r.cloud_error) toast.warning(`云端副本上传失败：${r.cloud_error}`);
      } else {
        toast.error(r.local_error ?? "导出失败");
      }
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

  const handleImport = async () => {
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
        <Button size="sm" variant="outline" disabled={!!busy || !pw} onClick={() => void handleImport()}>
          {busy === "import" ? <Loader2 className="mr-1 size-3 animate-spin" /> : null}
          导入恢复
        </Button>
      </div>
    </div>
  );
}
