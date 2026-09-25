#!/usr/bin/env bash
# 常用供应商预设部署（cosk-releases → cosk.ai 托管入口）：把本仓 coskey/provider/ 的内容
# 传上线，供 app 的「常用供应商」列表读取。
#
#   app 入口   https://www.cosk.ai/data/app/coskey/provider/provider-presets.json        不缓存
#   直读入口   https://www.cosk.ai/data/releases/coskey/provider/provider-presets.json   缓存 600s
# 两者指向磁盘同一份：$SITE_ROOT/data/releases/coskey/provider/。
# 发布仓工作副本是唯一来源，本脚本不生成内容——列表内容由产品仓库
# （coskey 的 src/resources/provider-presets.json）同步过来后提交。
#
# 整目录发布：provider-presets.json 之外的文件（如 provider-icon/）会一并上线，
# 列表里写相对路径的 icon 才取得到图。列表最后落地，避免读到指向未就位图标的列表。
#
# 用法：tools/deploy-provider-presets.sh [--dry-run] [--host <别名>] [--root <路径>]
set -euo pipefail

SITE_HOST="${SITE_HOST:-cosk-site}"        # ssh 别名：脚本里不写地址/端口/账号
SITE_ROOT="${SITE_ROOT:-/opt/cosk/cosk-site}"
DOMAIN="${DOMAIN:-www.cosk.ai}"            # 回读核对用（站点规范地址）
DRY_RUN=0

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROVIDER="$ROOT/coskey/provider"
PRESETS_NAME="provider-presets.json"
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
[ -d "$PROVIDER" ] || die "找不到预设目录：$PROVIDER"
[ -f "$PROVIDER/$PRESETS_NAME" ] || die "找不到 $PROVIDER/$PRESETS_NAME"

# 1) 本地自检：列表可解析、字段齐、id 合法且不重复，相对路径的 icon 随目录一起发
say "自检 $PROVIDER"
PROVIDER="$PROVIDER" PRESETS_NAME="$PRESETS_NAME" python3 - <<'PY'
import json, os, re, sys
from pathlib import Path

root = Path(os.environ["PROVIDER"])
presets = root / os.environ["PRESETS_NAME"]
try:
    entries = json.loads(presets.read_text(encoding="utf-8"))
except Exception as exc:
    sys.exit(f"错误：{presets.name} 不可解析：{exc}")
if not isinstance(entries, list) or not entries:
    sys.exit(f"错误：{presets.name} 应是非空数组（一条 = 一家供应商）")

ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")   # 与 coskey 的 service::valid_id 一致
ids = set()
warns = []
for e in entries:
    if not isinstance(e, dict):
        sys.exit(f"错误：条目不是对象：{e!r}")
    pid = e.get("id", "")
    if not ID_RE.match(pid):
        sys.exit(f"错误：id 非法（限字母数字与 -_、1~64 字符）：{pid!r}")
    if pid in ids:
        sys.exit(f"错误：id 重复：{pid}")
    ids.add(pid)
    for field in ("name", "base_url", "version"):
        if not str(e.get(field) or "").strip():
            sys.exit(f"错误：{pid} 缺 {field}")
    url = e["base_url"]
    if not url.startswith(("http://", "https://")):
        sys.exit(f"错误：{pid} 的 base_url 不是绝对地址：{url}")
    icon = str(e.get("icon") or "").strip()
    if not icon:
        warns.append(f"{pid} 没有 icon（远端条目会退化成无图）")
        continue
    if icon.startswith(("http://", "https://")):
        print(f"  {pid}：v{e['version']}  icon 远端取图")
        continue
    if not (root / icon).is_file():
        warns.append(f"{pid} 的 icon 是相对路径但本地没有：{icon}"
                     f"（把它放进 {root.name}/ 下，否则线上取不到图）")
    else:
        print(f"  {pid}：v{e['version']}  icon {icon}")
print(f"共 {len(entries)} 条")
sys.stdout.flush()
for w in warns:
    print(f"  ! {w}", file=sys.stderr)
PY

FILES=$(cd "$PROVIDER" && find . -type f | sed 's|^\./||' | sort)

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  say "dry-run：将把下列文件部署到 $SITE_HOST:$SITE_ROOT/data/releases/coskey/provider/"
  printf '%s\n' "$FILES" | sed 's/^/    /'
  say "dry-run：跳过传输、就位与回读核对"
  exit 0
fi

# 2) 传输 → 原子就位
INCOMING="$SITE_ROOT/data/releases/.incoming/coskey-provider"
REL="$SITE_ROOT/data/releases/coskey/provider"
say "部署 → $SITE_HOST:$REL"
ssh_ "set -e
  mkdir -p '$SITE_ROOT/data/releases/.incoming'
  rm -rf '$INCOMING'
  mkdir -p '$INCOMING'" || die "ssh 准备中转目录失败：$SITE_HOST"
# COPYFILE_DISABLE/--no-xattrs 防止 macOS 把扩展属性与 ._* 元数据文件打进产物
COPYFILE_DISABLE=1 tar -cz --no-xattrs -C "$PROVIDER" . | ssh_ "tar -xz -C '$INCOMING'" \
  || die "传输失败（ssh 或服务器侧 tar 报错，见上方输出）"
# 先图标、后列表：列表最后落地，避免读到指向未就位图标的新列表
ssh_ "set -e
  cd '$INCOMING'
  [ -f '$PRESETS_NAME' ] || { echo '中转目录里缺少 $PRESETS_NAME' >&2; exit 1; }
  mkdir -p '$REL'
  find . -mindepth 1 -maxdepth 1 -type d -exec mv -f {} '$REL'/ \;
  find . -mindepth 1 -maxdepth 1 -type f ! -name '$PRESETS_NAME' -exec mv -f {} '$REL'/ \;
  mv -f '$PRESETS_NAME' '$REL'/'$PRESETS_NAME'
  rm -rf '$INCOMING'
  find '$REL' -type d -exec chmod 755 {} +
  find '$REL' -type f -exec chmod 644 {} +" \
  || die "落地失败：中转目录 $INCOMING 还在，线上未变；修好重跑即可"

# 3) 回读核对（app 入口不缓存，读到的就是刚传的那份）
say "回读核对"
URL="https://$DOMAIN/data/app/coskey/provider/$PRESETS_NAME"
BODY=$(curl -fsSL --max-time 10 "$URL") || die "回读失败：${URL}（nginx 的 /data/app/ 段没配好？）"
printf '%s' "$BODY" | OUT_FILE="$PROVIDER/$PRESETS_NAME" python3 -c '
import json, os, sys
local = json.loads(open(os.environ["OUT_FILE"], encoding="utf-8").read())
try:
    remote = json.loads(sys.stdin.read())
except Exception:
    sys.exit("回读内容不是 JSON")
if local != remote:
    sys.exit("线上与本地不一致")
' || die "回读核对失败：$URL"
say "  $PRESETS_NAME ✓"
# 同目录的其余文件（如 provider-icon/ 下的图标）按原始字节核对
while IFS= read -r rel; do
  [ "$rel" = "$PRESETS_NAME" ] && continue
  file="$PROVIDER/$rel"
  url="https://$DOMAIN/data/app/coskey/provider/$rel"
  want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$file")
  got=$(curl -fsSL --max-time 20 "$url" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') \
    || die "回读失败：${url}"
  [ "$want" = "$got" ] || die "回读核对失败（sha256 不符）：$url"
  say "  $rel ✓"
done <<< "$FILES"

echo ""
SUMMARY=$(PROVIDER="$PROVIDER" PRESETS_NAME="$PRESETS_NAME" python3 - <<'PYEOF'
import json, os
from pathlib import Path
d = json.loads((Path(os.environ["PROVIDER"]) / os.environ["PRESETS_NAME"]).read_text(encoding="utf-8"))
print("、".join(f'{e["id"]} v{e["version"]}' for e in d))
PYEOF
)
say "已部署：${SUMMARY}"
echo "    app 入口：https://$DOMAIN/data/app/coskey/provider/${PRESETS_NAME}（不缓存，立即生效）"
echo "    自查：curl -s https://$DOMAIN/data/app/coskey/provider/$PRESETS_NAME | head -c 200"
