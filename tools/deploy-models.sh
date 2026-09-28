#!/usr/bin/env bash
# 元模板部署（cosk-releases → cosk.ai 托管入口）：把本仓 coskey/models/ 的内容
# 传上线，供 app 的「元模板更新」读取。
#
#   app 入口   https://www.cosk.ai/data/app/coskey/models/index.json        不缓存
#   直读入口   https://www.cosk.ai/data/releases/coskey/models/index.json   缓存 600s
# 两者指向磁盘同一份：$SITE_ROOT/data/releases/coskey/models/。
# 目录里有 <版本>/<id>.json 模板与两份生成物索引（index.json 只含每 id 最新版本，
# index-all.json 含全部版本），两份都会一并上线；回读核对逐个文件比对。
# 落地是**整目录镜像**：源里删掉/移走的旧项（如迁移前残留的顶层 <id>.json）
# 会从站点一并清除，落地后站点内容与工作区一致。
# 发布仓工作副本是唯一来源，本脚本不生成内容——生成与提交见
# tools/gen-models-index.sh。
#
# 用法：tools/deploy-models.sh [--dry-run] [--host <别名>] [--root <路径>]
set -eu
# pipefail 只有 bash/zsh/ksh 有；dash 等 POSIX sh 没有，能开就开
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

SITE_HOST="${SITE_HOST:-cosk-site}"        # ssh 别名：脚本里不写地址/端口/账号
SITE_ROOT="${SITE_ROOT:-/opt/cosk/cosk-site}"
DOMAIN="${DOMAIN:-www.cosk.ai}"            # 回读核对用（站点规范地址）
DRY_RUN=0

# 本脚本路径：bash 用 BASH_SOURCE（被 source 时也准），dash 等没有就退回 $0
if [ -n "${BASH_VERSION:-}" ]; then SRC="${BASH_SOURCE[0]}"; else SRC="$0"; fi
ROOT=$(cd "$(dirname "$SRC")/.." && pwd)
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
index_all = root / "index-all.json"
for f in (index, index_all):
    if not f.is_file():
        sys.exit(f"错误：缺 {f.name}（先跑 tools/gen-models-index.sh）")


def load(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))["meta_templates"]
    except Exception as exc:
        sys.exit(f"错误：{path.name} 不可解析：{exc}")


def rel_of(e):
    return e.get("path") or f"{e.get('version', '')}/{e.get('id', '')}.json"


def vkey(v):
    return tuple(int(p) for p in str(v).split("."))


entries = load(index)
all_entries = load(index_all)
if not entries:
    sys.exit("错误：index.json 里没有模板")

# index.json：每个 id 只一条，sha256 按原始字节与文件一一对应
ids = set()
for e in entries:
    mid = e.get("id", "")
    if not mid or mid in ids:
        sys.exit(f"错误：index.json 有空的或重复的 id：{e!r}")
    ids.add(mid)
    rel = rel_of(e)
    p = root / rel
    if not p.is_file():
        sys.exit(f"错误：index.json 指向的模板不存在：{rel}")
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    if got != e.get("sha256"):
        sys.exit(f"错误：{rel} 的 sha256 与 index.json 不符（索引 {e.get('sha256')}，实际 {got}）")
    if not e.get("version"):
        sys.exit(f"错误：{rel} 在 index.json 里没有版本号")
    print(f"  {mid}：v{e['version']}  sha256 {got[:16]}…")

# index-all.json：覆盖全部 <版本>/<id>.json；目录里有模板就必须在册
by_path = {}
for e in all_entries:
    rel = rel_of(e)
    if rel in by_path:
        sys.exit(f"错误：index-all.json 有重复条目：{rel}")
    by_path[rel] = e
for p in sorted(root.glob("*/*.json")):
    rel = p.relative_to(root).as_posix()
    e = by_path.get(rel)
    if e is None:
        sys.exit(f"错误：{rel} 未出现在 index-all.json（重跑 tools/gen-models-index.sh）")
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    if got != e.get("sha256"):
        sys.exit(f"错误：{rel} 的 sha256 与 index-all.json 不符（索引 {e.get('sha256')}，实际 {got}）")

# index.json 必须等于 index-all.json 里每个 id 的最高版本
high = {}
for e in all_entries:
    mid = e.get("id", "")
    if mid not in high or vkey(e.get("version", "0")) > vkey(high[mid].get("version", "0")):
        high[mid] = e
for e in entries:
    h = high.get(e["id"])
    if h is None or h.get("version") != e.get("version"):
        sys.exit(f"错误：{e['id']} 在 index.json 里是 v{e.get('version')}，"
                 f"不是 index-all.json 里的最新版本（{h and h.get('version')}）")
for mid in high:
    if mid not in ids:
        sys.exit(f"错误：{mid} 的最新版本没进 index.json（重跑 tools/gen-models-index.sh）")
print(f"  索引核对通过：index.json {len(entries)} 条 / index-all.json {len(all_entries)} 条")
PY

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  say "dry-run：将把 $( (cd "$MODELS" && find . -type f -name '*.json' | sed 's#^\./##' | sort | tr '\n' ' ') ) 部署到 $SITE_HOST:$SITE_ROOT/data/releases/coskey/models/"
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
# 整目录镜像：先模板（含 <版本>/ 子目录）、后索引，并清掉源里已不存在的旧项
# （例如迁移后残留的顶层 <id>.json）。索引最后落地，避免读到指向未就位模板的新索引。
ssh_ "set -e
  cd '$INCOMING'
  [ -f index.json ] || { echo '中转目录里缺少 index.json' >&2; exit 1; }
  mkdir -p '$REL'
  : > .publish-list
  for entry in *; do
    [ -e \"\$entry\" ] || continue
    case \"\$entry\" in index.json|index-all.json) continue ;; esac
    printf '%s\n' \"\$entry\" >> .publish-list
  done
  while IFS= read -r entry; do
    rm -rf '$REL'/\"\$entry\"
    mv -f \"\$entry\" '$REL'/\"\$entry\"
  done < .publish-list
  for old in '$REL'/*; do
    [ -e \"\$old\" ] || continue
    name=\$(basename \"\$old\")
    case \"\$name\" in index.json|index-all.json) continue ;; esac
    grep -qxF -- \"\$name\" .publish-list || rm -rf \"\$old\"
  done
  rm -f .publish-list
  mv -f index.json '$REL'/index.json
  if [ -f index-all.json ]; then mv -f index-all.json '$REL'/index-all.json; fi
  rm -rf '$INCOMING'
  find '$REL' -type d -exec chmod 755 {} +
  find '$REL' -type f -exec chmod 644 {} +" \
  || die "落地失败：中转目录 $INCOMING 还在，线上未变；修好重跑即可"

# 3) 回读核对（app 入口不缓存，读到的就是刚传的那份）
say "回读核对"
# 逐文件回读：<版本>/<id>.json 与根下两份索引。用 glob 而非 process substitution，
# 保持本脚本可在 sh（含 dash）下运行。
for f in "$MODELS"/*/*.json "$MODELS"/*.json; do
  [ -f "$f" ] || continue
  rel="${f#${MODELS}/}"
  URL="https://$DOMAIN/data/app/coskey/models/$rel"
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
  say "  $rel ✓"
done

echo ""
SUMMARY=$(MODELS="$MODELS" python3 - <<'PYEOF'
import json, os
from pathlib import Path
root = Path(os.environ["MODELS"])
idx = json.loads((root / "index.json").read_text(encoding="utf-8"))["meta_templates"]
allidx = json.loads((root / "index-all.json").read_text(encoding="utf-8"))["meta_templates"]
print("、".join(f'{e["id"]} v{e["version"]}' for e in idx)
      + f"（index {len(idx)} 条 / index-all {len(allidx)} 条）")
PYEOF
)
say "已部署：${SUMMARY}"
echo "    app 入口：https://$DOMAIN/data/app/coskey/models/index.json（不缓存，立即生效）"
echo "    自查：curl -s https://$DOMAIN/data/app/coskey/models/index.json | head -c 200"
