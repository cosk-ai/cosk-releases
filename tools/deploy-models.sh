#!/usr/bin/env bash
# 元模板部署（cosk-releases → cosk.ai 托管入口）：把本仓 coskey/models/ 的内容
# 传上线，供 app 的「元模板更新」读取。
#
#   app 入口   https://www.cosk.ai/data/app/coskey/models/index.json        不缓存
#   直读入口   https://www.cosk.ai/data/releases/coskey/models/index.json   缓存 600s
# 两者指向磁盘同一份：$SITE_ROOT/data/releases/coskey/models/。
# 发布仓工作副本是唯一来源，本脚本不生成内容——生成与提交见
# tools/gen-models-index.sh。
#
# 用法：tools/deploy-models.sh [--dry-run] [--host <别名>] [--root <路径>]
set -euo pipefail

SITE_HOST="${SITE_HOST:-cosk-site}"        # ssh 别名：脚本里不写地址/端口/账号
SITE_ROOT="${SITE_ROOT:-/opt/cosk/cosk-site}"
DOMAIN="${DOMAIN:-www.cosk.ai}"            # 回读核对用（站点规范地址）
DRY_RUN=0

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODELS="$ROOT/coskey/models"
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
[ -d "$MODELS" ] || die "找不到模板目录：$MODELS"

# 1) 本地自检：index.json 与模板逐一对应，sha256 按原始字节核对
say "自检 $MODELS"
MODELS="$MODELS" python3 - <<'PY'
import hashlib, json, os, sys
from pathlib import Path

root = Path(os.environ["MODELS"])
index = root / "index.json"
if not index.is_file():
    sys.exit("错误：缺 index.json（先跑 tools/gen-models-index.sh）")
try:
    entries = json.loads(index.read_text(encoding="utf-8"))["meta_templates"]
except Exception as exc:
    sys.exit(f"错误：index.json 不可解析：{exc}")
if not entries:
    sys.exit("错误：index.json 里没有模板")
ids = set()
for e in entries:
    mid = e.get("id", "")
    if not mid or mid in ids:
        sys.exit(f"错误：index.json 有空的或重复的 id：{e!r}")
    ids.add(mid)
    p = root / (e.get("path") or f"{mid}.json")
    if not p.is_file():
        sys.exit(f"错误：index.json 指向的模板不存在：{p.name}")
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    if got != e.get("sha256"):
        sys.exit(f"错误：{p.name} 的 sha256 与 index.json 不符（索引 {e.get('sha256')}，实际 {got}）")
    if not e.get("version"):
        sys.exit(f"错误：{p.name} 在 index.json 里没有版本号")
    print(f"  {mid}：v{e['version']}  sha256 {got[:16]}…")
# 反向：目录里有模板但索引没列（新增后忘了重跑生成）
for p in sorted(root.glob("*.json")):
    if p.name != "index.json" and p.stem not in ids:
        sys.exit(f"错误：{p.name} 未出现在 index.json（重跑 tools/gen-models-index.sh）")
PY

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  say "dry-run：将把 $( (cd "$MODELS" && ls *.json | tr '\n' ' ') ) 部署到 $SITE_HOST:$SITE_ROOT/data/releases/coskey/models/"
  say "dry-run：跳过传输、就位与回读核对"
  exit 0
fi

# 2) 传输 → 原子就位
INCOMING="$SITE_ROOT/data/releases/.incoming/coskey-models"
REL="$SITE_ROOT/data/releases/coskey/models"
say "部署 → $SITE_HOST:$REL"
ssh_ "set -e
  mkdir -p '$SITE_ROOT/data/releases/.incoming'
  rm -rf '$INCOMING'
  mkdir -p '$INCOMING'" || die "ssh 准备中转目录失败：$SITE_HOST"
# COPYFILE_DISABLE/--no-xattrs 防止 macOS 把扩展属性与 ._* 元数据文件打进产物
COPYFILE_DISABLE=1 tar -cz --no-xattrs -C "$MODELS" . | ssh_ "tar -xz -C '$INCOMING'" \
  || die "传输失败（ssh 或服务器侧 tar 报错，见上方输出）"
# 先模板、后 index.json：索引最后落地，避免读到指向未就位模板的新索引
ssh_ "set -e
  cd '$INCOMING'
  [ -f index.json ] || { echo '中转目录里缺少 index.json' >&2; exit 1; }
  mkdir -p '$REL'
  for f in *.json; do
    [ \"\$f\" = index.json ] && continue
    mv -f \"\$f\" '$REL'/\"\$f\"
  done
  mv -f index.json '$REL'/index.json
  rm -rf '$INCOMING'
  find '$REL' -type d -exec chmod 755 {} +
  find '$REL' -type f -exec chmod 644 {} +" \
  || die "落地失败：中转目录 $INCOMING 还在，线上未变；修好重跑即可"

# 3) 回读核对（app 入口不缓存，读到的就是刚传的那份）
say "回读核对"
for f in "$MODELS"/*.json; do
  name=$(basename "$f")
  URL="https://$DOMAIN/data/app/coskey/models/$name"
  BODY=$(curl -fsSL --max-time 10 "$URL") || die "回读失败：${URL}（nginx 的 /data/app/ 段没配好？）"
  printf '%s' "$BODY" | OUT_FILE="$f" python3 -c '
import json, os, sys
local = json.loads(open(os.environ["OUT_FILE"], encoding="utf-8").read())
try:
    remote = json.loads(sys.stdin.read())
except Exception:
    sys.exit("回读内容不是 JSON")
if local != remote:
    sys.exit("线上与本地不一致")
' || die "回读核对失败：$URL"
  say "  $name ✓"
done

echo ""
SUMMARY=$(MODELS="$MODELS" python3 - <<'PYEOF'
import json, os
from pathlib import Path
d = json.loads((Path(os.environ["MODELS"]) / "index.json").read_text(encoding="utf-8"))
print("、".join(f'{e["id"]} v{e["version"]}' for e in d["meta_templates"]))
PYEOF
)
say "已部署：${SUMMARY}"
echo "    app 入口：https://$DOMAIN/data/app/coskey/models/index.json（不缓存，立即生效）"
echo "    自查：curl -s https://$DOMAIN/data/app/coskey/models/index.json | head -c 200"
