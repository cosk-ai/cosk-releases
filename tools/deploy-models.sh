#!/usr/bin/env bash
# 元模板部署（cosk-releases → cosk.ai 托管入口）：把本仓 coskey/models/ 的内容
# 传上线，供 app 的「元模板更新」读取。
#
#   app 入口   https://www.cosk.ai/data/app/coskey/models/index.json        不缓存
#   直读入口   https://www.cosk.ai/data/releases/coskey/models/index.json   缓存 600s
# 两者指向磁盘同一份：$SITE_ROOT/data/releases/coskey/models/。
# 目录里有 <版本>/<id>.json 模板与生成物 index.json（每 id 一条，含 history）；
# 会一并上线，回读核对逐个文件比对。
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
if not index.is_file():
    sys.exit("错误：缺 index.json（先跑 tools/gen-models-index.sh）")
if (root / "index-all.json").is_file():
    sys.exit("错误：index-all.json 已废弃（内容并入 index.json 的 history）；"
             "重跑 tools/gen-models-index.sh 会删除它")
try:
    data = json.loads(index.read_text(encoding="utf-8"))
    # 顶层键现行 catalog_templates；meta_templates 是 0.6.0 前的发布键，读时兼容
    entries = data.get("catalog_templates", data.get("meta_templates"))
    if entries is None:
        raise KeyError("catalog_templates")
except Exception as exc:
    sys.exit(f"错误：index.json 不可解析：{exc}")
if not entries:
    sys.exit("错误：index.json 里没有模板")


def vkey(v):
    return tuple(int(p) for p in str(v).split("."))


def check(rel, sha, whom):
    p = root / rel
    if not p.is_file():
        sys.exit(f"错误：{whom} 指向的模板不存在：{rel}")
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    if got != sha:
        sys.exit(f"错误：{rel} 的 sha256 与 {whom} 不符（索引 {sha}，实际 {got}）")
    return got


# index.json：每个 id 一条；顶层是最新版本，history 是更低的版本（新→旧）
ids = set()
covered = set()
for e in entries:
    mid = e.get("id", "")
    if not mid or mid in ids:
        sys.exit(f"错误：index.json 有空的或重复的 id：{e!r}")
    ids.add(mid)
    ver = e.get("version", "")
    if not ver:
        sys.exit(f"错误：{mid} 在 index.json 里没有版本号")
    rel = e.get("path") or f"{ver}/{mid}.json"
    got = check(rel, e.get("sha256"), "index.json")
    covered.add(rel)
    seen = set()
    for h in e.get("history") or []:
        hv = h.get("version", "")
        if not hv or hv in seen or hv == ver:
            sys.exit(f"错误：{mid} 的 history 版本重复或非法：{hv!r}")
        seen.add(hv)
        if vkey(hv) >= vkey(ver):
            sys.exit(f"错误：{mid} 的 history 版本 v{hv} 不低于当前 v{ver}")
        hrel = h.get("path") or f"{hv}/{mid}.json"
        check(hrel, h.get("sha256"), f"{mid} 的 history v{hv}")
        covered.add(hrel)
    print(f"  {mid}：v{ver}  sha256 {got[:16]}…  历史 {len(seen)} 个")

# 反向：目录里每个 <版本>/<id>.json 都要被 index.json 覆盖（顶层或 history）
dangling = [p.relative_to(root).as_posix() for p in sorted(root.glob("*/*.json"))
            if p.relative_to(root).as_posix() not in covered]
if dangling:
    sys.exit("错误：以下模板未出现在 index.json（重跑 tools/gen-models-index.sh）："
             + "、".join(dangling))
print(f"  索引核对通过：{len(entries)} 个模板、{len(covered) - len(entries)} 个历史版本")
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
    case \"\$entry\" in index.json) continue ;; esac
    printf '%s\n' \"\$entry\" >> .publish-list
  done
  while IFS= read -r entry; do
    rm -rf '$REL'/\"\$entry\"
    mv -f \"\$entry\" '$REL'/\"\$entry\"
  done < .publish-list
  for old in '$REL'/*; do
    [ -e \"\$old\" ] || continue
    name=\$(basename \"\$old\")
    case \"\$name\" in index.json) continue ;; esac
    grep -qxF -- \"\$name\" .publish-list || rm -rf \"\$old\"
  done
  rm -f .publish-list
  mv -f index.json '$REL'/index.json
  rm -rf '$INCOMING'
  find '$REL' -type d -exec chmod 755 {} +
  find '$REL' -type f -exec chmod 644 {} +" \
  || die "落地失败：中转目录 $INCOMING 还在，线上未变；修好重跑即可"

# 3) 回读核对（app 入口不缓存，读到的就是刚传的那份）
say "回读核对"
# 逐文件回读：<版本>/<id>.json 与根下的 index.json。用 glob 而非 process substitution，
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
data = json.loads((Path(os.environ["MODELS"]) / "index.json").read_text(encoding="utf-8"))
idx = data.get("catalog_templates", data.get("meta_templates"))
n_hist = sum(len(e.get("history") or []) for e in idx)
print("、".join(f'{e["id"]} v{e["version"]}' for e in idx)
      + f"（{len(idx)} 个模板 / {n_hist} 个历史版本）")
PYEOF
)
say "已部署：${SUMMARY}"
echo "    app 入口：https://$DOMAIN/data/app/coskey/models/index.json（不缓存，立即生效）"
echo "    自查：curl -s https://$DOMAIN/data/app/coskey/models/index.json | head -c 200"
