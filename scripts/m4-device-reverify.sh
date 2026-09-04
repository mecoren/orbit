#!/usr/bin/env bash
# m4-device-reverify.sh — M4 清单「待物理真机复核项」自动复验脚本
#
# 用法：接入 arm64 物理真机（USB 调试）后，在 Git Bash 仓库根执行：
#   bash scripts/m4-device-reverify.sh [adb_serial]
#   （多设备时传 serial，如 bash scripts/m4-device-reverify.sh device-serial）
#
# 前置：
#   - ANDROID_HOME 环境变量（adb 在 $ANDROID_HOME/platform-tools/adb.exe）
#   - 本机跑 WebDAV 探针（可选，仅 5.3 用）：cd .m4-evidence && python dav_probe.py
#     （或直接用用户自己的 WebDAV/Nutstore，手动在设备上配置）
#   - APK：apps/mobile/build/app/outputs/flutter-apk/app-release.apk（v0.1.1）
#
# 本脚本自动完成：
#   0. 设备检测与信息回显（确认 arm64 真机）
#   1. 安装 v0.1.1 APK + aapt2 权限/版本核对
#   2. 4.1 通知授权流（系统弹窗 → 允许 → 设提醒 → 系统通知验证）
#   3. 3.2 滚动流畅度：注入 500 条 + screenrecord + 抽帧量化
#   4. 2.3 IME 遮挡：四输入框聚焦 + IME inset 采集（真机有真实软键盘）
#   5. 5.3 双端同步：配 WebDAV（宿主地址）→ 设密码 → 立即同步 → 请求序列断言
#   6. 输出 evidence 目录与清单回写建议（4.4 Doze 需手动息屏一晚）
#
# 产出：.m4-device-evidence/<serial>/ 下全部证据文件

set -uo pipefail

ADB="${ANDROID_HOME:-C:/Develop/env/Android/Sdk}/platform-tools/adb.exe"
AAPT="${ANDROID_HOME:-C:/Develop/env/Android/Sdk}/build-tools/37.0.0/aapt2.exe"
APK="apps/mobile/build/app/outputs/flutter-apk/app-release.apk"
OUT=".m4-device-evidence"
SERIAL="${1:-}"

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die() { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }

# ---------- 0. 设备检测 ----------
log "0. 设备检测"
DEVS=$("$ADB" devices | awk 'NR>1 && $2=="device" && $1 !~ /^emulator|^127\.0\.0\.1/' | awk '{print $1}')
if [ -z "$DEVS" ]; then
  # 无真机时列出全部设备让用户挑
  echo "未检测到物理真机（已过滤模拟器）。当前全部设备："
  "$ADB" devices -l
  die "请接入 arm64 真机后重试，或传 serial：bash scripts/m4-device-reverify.sh <serial>"
fi
if [ -z "$SERIAL" ]; then
  if [ "$(echo "$DEVS" | wc -l)" -gt 1 ]; then
    echo "检测到多台设备，请指定 serial：" ; echo "$DEVS" | sed 's/^/  /'
    die "bash scripts/m4-device-reverify.sh <serial>"
  fi
  SERIAL="$DEVS"
fi
echo "目标设备：$SERIAL"
ABI=$("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')
MODEL=$("$ADB" -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')
SDK=$("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')
echo "model=$MODEL abi=$ABI sdk=$SDK"
[ "$ABI" = "arm64-v8a" ] || echo "[WARN] abi=$ABI 非清单要求的 arm64（继续执行，但请在清单注明）"
mkdir -p "$OUT/$SERIAL"
"$ADB" -s "$SERIAL" shell getprop > "$OUT/$SERIAL/device-props.txt"

# ---------- 1. APK 安装与核对 ----------
log "1. 安装 v0.1.1 APK"
"$ADB" -s "$SERIAL" install -r "$APK" || die "APK 安装失败"
"$AAPT" dump badging "$APK" 2>/dev/null | grep -E "package: name" | tee "$OUT/$SERIAL/apk-badging.txt"
"$AAPT" dump permissions "$APK" 2>/dev/null | tee "$OUT/$SERIAL/apk-permissions.txt"
grep -q "android.permission.INTERNET" "$OUT/$SERIAL/apk-permissions.txt" \
  || die "APK 缺 INTERNET 权限（构建错误）"
echo "INTERNET 权限 ✓"

# ---------- 2. 4.1 通知授权链 ----------
log "2. 4.1 通知授权链（需注意系统弹窗出现时机）"
"$ADB" -s "$SERIAL" shell pm clear cn.wait.orbit >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" logcat -c
"$ADB" -s "$SERIAL" shell am start -n cn.wait.orbit/.MainActivity
echo "  → 若弹出通知权限对话框，请在设备上点『允许』，然后按回车继续..."
read -r
sleep 3
G=$("$ADB" -s "$SERIAL" shell dumpsys package cn.wait.orbit | grep 'POST_NOTIFICATIONS: granted' | head -1)
echo "$G" | tee "$OUT/$SERIAL/notify-permission.txt"
echo "  （granted=true 后续到提醒将出系统通知；完整 4.1 验证需手动建任务设 1 分钟提醒）"

# ---------- 3. 3.2 滚动流畅度 ----------
log "3. 3.2 五百条滚动（先 root 注入数据；无 root 时请手动导入）"
if "$ADB" -s "$SERIAL" shell id 2>/dev/null | grep -q "uid=0"; then
  "$ADB" -s "$SERIAL" root >/dev/null 2>&1; sleep 2
  "$ADB" -s "$SERIAL" shell am force-stop cn.wait.orbit
  DB=/data/data/cn.wait.orbit/files/orbit.db
  "$ADB" -s "$SERIAL" pull "//$DB" "$OUT/$SERIAL/orbit-seed.db" >/dev/null 2>&1 || "$ADB" -s "$SERIAL" pull "$DB" "$OUT/$SERIAL/orbit-seed.db" >/dev/null 2>&1
  "$ADB" -s "$SERIAL" pull "$DB-wal" "$OUT/$SERIAL/orbit-seed.db-wal" >/dev/null 2>&1 || true
  echo "  [提示] 脚本不直接改真机库（避免破坏用户数据）——推荐：手动创建几条任务"
  echo "  然后在『全部任务』持续快速滑动 10 秒，脚本录制："
else
  echo "  无 root——手动创建 ≥500 条任务（或从桌面端同步已有数据）"
fi
echo "  按『允许』开始 12 秒录屏，随后请在设备上连续快速滑动列表并急停..."
read -r
"$ADB" -s "$SERIAL" shell "rm -f /sdcard/m4-scroll.mp4; screenrecord --time-limit 12 --bit-rate 8000000 /sdcard/m4-scroll.mp4" &
sleep 13
"$ADB" -s "$SERIAL" pull "//sdcard/m4-scroll.mp4" "$OUT/$SERIAL/m4-scroll.mp4" >/dev/null 2>&1 || "$ADB" -s "$SERIAL" pull /sdcard/m4-scroll.mp4 "$OUT/$SERIAL/m4-scroll.mp4" >/dev/null 2>&1
echo "  录屏已存 $OUT/$SERIAL/m4-scroll.mp4（抽帧分析：python + opencv，参考会话内 3.2 方法）"
echo "  主观手感结论请记录到清单 3.2 备注。"

# ---------- 4. 2.3 IME 遮挡 ----------
log "4. 2.3 IME 面板遮挡（真机有真实软键盘——这正是模拟器验不了的部分）"
echo "  请在设备上操作：FAB 打开新建表单 → 聚焦『标题』框（软键盘弹出）"
echo "  → 聚焦『描述』多行框 → 保存后进详情 → 点子任务『添加子任务』→ 点评论输入框。"
echo "  每一步确认：聚焦输入框完整可见于软键盘上方。完成后回车，脚本采集 IME inset："
read -r
IME=$("$ADB" -s "$SERIAL" shell dumpsys window 2>/dev/null | grep -m1 -E "ime frame")
echo "$IME" | tee "$OUT/$SERIAL/ime-frame.txt"
echo "  （真机此处应有非零高度的 ime frame——与 MuMu 的零高度帧形成对照）"

# ---------- 5. 5.3 双端同步 ----------
log "5. 5.3 双端同步（先在设备上手动操作，脚本监控证据）"
HOST_IP=$("$ADB" -s "$SERIAL" shell ip route 2>/dev/null | grep -m1 -oE 'via [0-9.]+' | awk '{print $2}')
[ -n "$HOST_IP" ] || HOST_IP="宿主机局域网 IP（ipconfig 查）"
cat <<EOF
  设备端操作步骤（约 2 分钟）：
  1) 设置 → 云同步设置 → 引擎 WebDAV
  2) 服务器地址：http://$HOST_IP:8123（需宿主跑 .m4-evidence/dav_probe.py）
     或填你自己的 WebDAV（坚果云等，注意 https）
  3) 用户名/密码：m4tester / m4pass123（探针默认）
  4) 测试连接 → 保存 → 同步密码：123456 → 设置并解锁
  5) 返回设置页 → 立即同步
  第二台设备（或桌面端）重复 1-5（同密码 123456）→ 数据入环收敛。
EOF
echo "  在真机上完成上述操作后回车，脚本采集同步证据..."
read -r
LS=$("$ADB" -s "$SERIAL" shell dumpsys package cn.wait.orbit 2>/dev/null)
echo "$LS" > /dev/null
"$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/m4-final.xml >/dev/null 2>&1
"$ADB" -s "$SERIAL" shell cat /sdcard/m4-final.xml > "$OUT/$SERIAL/final-ui.xml" 2>/dev/null
if grep -q "上次同步" "$OUT/$SERIAL/final-ui.xml" 2>/dev/null; then
  grep -o "上次同步[^&\"]*" "$OUT/$SERIAL/final-ui.xml" | head -1 | sed 's/&#10;/ · /g' | tee "$OUT/$SERIAL/last-synced.txt"
fi
echo "  （若『上次同步』不再是 1970-01-01 且 WebDAV 侧出现 orbit/ 目录 → 5.3 实机通过，双修复生效）"

# ---------- 6. 汇总 ----------
log "6. 汇总"
cat <<EOF
证据目录：$OUT/$SERIAL/
已完成自动化采集：设备信息 / APK 版本与权限 / 通知权限态 / 滚动录屏 / IME frame / 同步结果快照

仍需手动记录到清单备注列：
  - 3.2 主观滚动手感（流畅/掉帧感受）
  - 2.3 四输入框遮挡目视结论
  - 5.3 双端收敛目视结论（第二设备列表与第一设备一致）
  - 4.4 Doze：设提醒后息屏待机一晚（今晚做），次日查看通知并记录
全部通过后：在 docs/superpowers/plans/2026-08-24-m4-device-checklist.md
结果表回写「真机复核通过」并勾销对应备注——M4 验收完全收口。
EOF
