#!/usr/bin/env bash
# 应用插件 profile 部署（cosk-releases → cosk.ai 托管入口）：把本仓 coskey/plugins/ 的内容
# 传上线，供 Coskey 的 `app check` / `app repair` 在 GitHub、Gitee 都取不到时保底读取。
#
#   app 入口   https://www.cosk.ai/data/app/coskey/plugins/app-plugin-profile.json        不缓存
#   直读入口   https://www.cosk.ai/data/releases/coskey/plugins/app-plugin-profile.json   缓存 600s
# 两者指向磁盘同一份：$SITE_ROOT/data/releases/coskey/plugins/。
# 发布仓工作副本是唯一来源，本脚本不生成内容——内容从 coskey 产品的
# src/resources/plugins/app-plugin-profile.json 同步过来后提交。
#
# 整目录发布：app-plugin-profile.json 之外的文件会一并上线；profile 最后落地，
# 避免读到指向尚未就位文件的名单。
#
# 用法：tools/deploy-app-plugin-profile.sh [--dry-run] [--host <别名>] [--root <路径>]
set -euo pipefail

SITE_HOST="${SITE_HOST:-cosk-site}"        # ssh 别名：脚本里不写地址/端口/账号
SITE_ROOT="${SITE_ROOT:-/opt/cosk/cosk-site}"
DOMAIN="${DOMAIN:-www.cosk.ai}"            # 回读核对用（站点规范地址）
DRY_RUN=0

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGINS="$ROOT/coskey/plugins"
PROFILE_NAME="app-plugin-profile.json"
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "$*" >&2; exit 1; }
ssh_() { ssh -o BatchMode=yes "$SITE_HOST" "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --host)    SITE_HOST="${2:-}"; shift ;;
    --root)    SITE_ROOT="${2:-}"; shift ;;
    -h|--help) awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print; next } exit }' "$0"; exit 0 ;;
    *)         echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null || die "需要 python3"
[ -d "$PLUGINS" ] || die "找不到插件目录：$PLUGINS"
[ -f "$PLUGINS/$PROFILE_NAME" ] || die "找不到 $PLUGINS/$PROFILE_NAME"

# 1) 本地自检：按 coskey 的 app_profile::PluginProfileFile::parse 同一套规则校验
say "自检 $PLUGINS"
PLUGINS="$PLUGINS" PROFILE_NAME="$PROFILE_NAME" python3 - <<'PY'
import hashlib, json, os, re, sys
from pathlib import Path

root = Path(os.environ["PLUGINS"])
profile = root / os.environ["PROFILE_NAME"]
raw = profile.read_bytes()
try:
    doc = json.loads(raw.decode("utf-8"))
except Exception as exc:
    sys.exit(f"错误：{profile.name} 不可解析：{exc}")
if not isinstance(doc, dict):
    sys.exit(f"错误：{profile.name} 顶层应是对象")
if doc.get("schemaVersion") != 1:
    sys.exit(f"错误：不支持的 schemaVersion：{doc.get('schemaVersion')!r}（只认 1）")
profiles = doc.get("profiles")
if not isinstance(profiles, list) or not profiles:
    sys.exit("错误：profiles 应是非空数组")

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
PLATFORMS = {"macos", "windows", "linux"}


def valid_version(value):
    if not isinstance(value, str) or not value.strip():
        return False
    return all(part.isdigit() for part in value.strip().split("."))


def check_names(label, names):
    if not isinstance(names, list):
        sys.exit(f"错误：{label} 应是数组")
    for name in names:
        if not isinstance(name, str) or not NAME_RE.match(name):
            sys.exit(f"错误：{label} 含非法插件名：{name!r}")


canonical = []
for idx, entry in enumerate(profiles, 1):
    if not isinstance(entry, dict):
        sys.exit(f"错误：profiles[{idx}] 不是对象")
    start = entry.get("startVersion")
    if not valid_version(start):
        sys.exit(f"错误：profiles[{idx}] 的 startVersion 不是点分数字版本号：{start!r}")
    check_names(f"profiles[{idx}].builtinInstall", entry.get("builtinInstall", []))
    check_names(f"profiles[{idx}].hidden", entry.get("hidden", []))
    exclusions = entry.get("platformExclusions", {})
    if not isinstance(exclusions, dict):
        sys.exit(f"错误：profiles[{idx}].platformExclusions 应是对象")
    for platform, names in exclusions.items():
        if platform not in PLATFORMS:
            sys.exit(f"错误：platformExclusions 含未知平台：{platform!r}")
        check_names(f"platformExclusions.{platform}", names)
    canonical.append({
        "startVersion": start,
        "builtinInstall": entry.get("builtinInstall", []),
        "hidden": entry.get("hidden", []),
        "platformExclusions": {k: exclusions[k] for k in sorted(exclusions)},
    })
    print(f"  {start}：内置安装 {len(entry.get('builtinInstall', []))} 个、"
          f"隐藏 {len(entry.get('hidden', []))} 个")

# 可选 sha256：接受 profiles 数组、去掉该字段后的整份文件、原始字节三种口径
want = doc.get("sha256")
if want is not None:
    want = str(want).strip().lower()
    if len(want) != 64 or any(c not in "0123456789abcdef" for c in want):
        sys.exit("错误：sha256 不是 64 位十六进制")

    def digest(value):
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        return hashlib.sha256(data).hexdigest()

    accepted = {
        digest(canonical),
        digest({"schemaVersion": 1, "profiles": canonical}),
        hashlib.sha256(raw).hexdigest(),
    }
    if want not in accepted:
        sys.exit("错误：sha256 与内容不一致")
    print(f"  sha256 {want[:16]}… ✓")

print(f"共 {len(profiles)} 个 profile")
PY

FILES=$(cd "$PLUGINS" && find . -type f | sed 's|^\./||' | sort)

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  say "dry-run：将把下列文件部署到 $SITE_HOST:$SITE_ROOT/data/releases/coskey/plugins/"
  printf '%s\n' "$FILES" | sed 's/^/    /'
  say "dry-run：跳过传输、就位与回读核对"
  exit 0
fi

# 2) 传输 → 原子就位
INCOMING="$SITE_ROOT/data/releases/.incoming/coskey-plugins"
REL="$SITE_ROOT/data/releases/coskey/plugins"
say "部署 → $SITE_HOST:$REL"
ssh_ "set -e
  mkdir -p '$SITE_ROOT/data/releases/.incoming'
  rm -rf '$INCOMING'
  mkdir -p '$INCOMING'" || die "ssh 准备中转目录失败：$SITE_HOST"
# COPYFILE_DISABLE/--no-xattrs 防止 macOS 把扩展属性与 ._* 元数据文件打进产物
COPYFILE_DISABLE=1 tar -cz --no-xattrs -C "$PLUGINS" . | ssh_ "tar -xz -C '$INCOMING'" \
  || die "传输失败（ssh 或服务器侧 tar 报错，见上方输出）"
# 先其余文件、后 profile：profile 最后落地，避免读到指向未就位文件的新名单
ssh_ "set -e
  cd '$INCOMING'
  [ -f '$PROFILE_NAME' ] || { echo '中转目录里缺少 $PROFILE_NAME' >&2; exit 1; }
  mkdir -p '$REL'
  find . -mindepth 1 -maxdepth 1 -type d -exec mv -f {} '$REL'/ \;
  find . -mindepth 1 -maxdepth 1 -type f ! -name '$PROFILE_NAME' -exec mv -f {} '$REL'/ \;
  mv -f '$PROFILE_NAME' '$REL'/'$PROFILE_NAME'
  rm -rf '$INCOMING'
  find '$REL' -type d -exec chmod 755 {} +
  find '$REL' -type f -exec chmod 644 {} +" \
  || die "落地失败：中转目录 $INCOMING 还在，线上未变；修好重跑即可"

# 3) 回读核对（app 入口不缓存，读到的就是刚传的那份）
say "回读核对"
URL="https://$DOMAIN/data/app/coskey/plugins/$PROFILE_NAME"
BODY=$(curl -fsSL --max-time 10 "$URL") || die "回读失败：${URL}（nginx 的 /data/app/ 段没配好？）"
printf '%s' "$BODY" | OUT_FILE="$PLUGINS/$PROFILE_NAME" python3 -c '
import json, os, sys
local = json.loads(open(os.environ["OUT_FILE"], encoding="utf-8").read())
try:
    remote = json.loads(sys.stdin.read())
except Exception:
    sys.exit("回读内容不是 JSON")
if local != remote:
    sys.exit("线上与本地不一致")
' || die "回读核对失败：$URL"
say "  $PROFILE_NAME ✓"
# 同目录的其余文件按原始字节核对
while IFS= read -r rel; do
  [ "$rel" = "$PROFILE_NAME" ] && continue
  file="$PLUGINS/$rel"
  url="https://$DOMAIN/data/app/coskey/plugins/$rel"
  want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$file")
  got=$(curl -fsSL --max-time 20 "$url" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') \
    || die "回读失败：${url}"
  [ "$want" = "$got" ] || die "回读核对失败（sha256 不符）：$url"
  say "  $rel ✓"
done <<< "$FILES"

echo ""
say "已部署：app-plugin-profile.json"
echo "    app 入口：https://$DOMAIN/data/app/coskey/plugins/${PROFILE_NAME}（不缓存，立即生效）"
echo "    自查：curl -s https://$DOMAIN/data/app/coskey/plugins/$PROFILE_NAME | head -c 200"
