#!/usr/bin/env bash
# 元模板索引生成（cosk-releases 侧）：扫描 coskey/models/*.json，生成/更新
# index.json，提交并推送到 GitHub 与 Gitee 两个平台。
#
# index.json 是本仓的**生成物**：版本号的事实源就是它自己（见下面的版本规则），
# 不要手写。客户端读它判断有没有更新，格式与校验约定见 coskey 仓库 0018 §5.0：
#   {"meta_templates":[{"id","version","sha256","path"?}]}
# sha256 按模板文件的**原始字节**计算，客户端逐字节校验。
#
# 用法：
#   tools/gen-models-index.sh [选项]
#
#   --from DIR        模板来源目录：先把该目录下的 <id>.json 覆盖进 coskey/models/
#                     （coskey 仓库的 src/resources/model-catalog 可直接用）。
#                     不给则只处理 coskey/models/ 现有文件。
#   --version ID=VER  指定某模板版本（可重复）
#   --version-file F  批量版本文件（每行 `<id> <semver>`，`#` 注释）
#   --dry-run         只生成并打印计划，不提交、不推送
#   --no-push         生成并提交，但不推远端
#   --force           内容变了但版本没抬时也照发（默认拒绝）
#   --message MSG     自定义提交信息
#
# 版本规则（防「已发布内容被原地改」——客户端只在版本更高时更新）：
#   新模板        必须给版本（--version / --version-file）
#   内容有变化    版本必须高于 index.json 里记录的版本
#   内容无变化    沿用已记录版本（允许重发/补传）
set -euo pipefail

FROM=""
DRY_RUN=0; NO_PUSH=0; FORCE=0
MESSAGE=""
VERSION_FILE=""
GITHUB_REMOTE="${GITHUB_REMOTE:-origin}"   # 发布仓的 GitHub 远端
GITEE_REMOTE="${GITEE_REMOTE:-gitee}"      # 发布仓的 Gitee 镜像远端
BRANCH="${BRANCH:-main}"
DECLARE_VERSIONS=()

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODELS="$ROOT/coskey/models"
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from)         FROM="${2:-}"; shift ;;
    --version)      DECLARE_VERSIONS+=("${2:-}"); shift ;;
    --version-file) VERSION_FILE="${2:-}"; shift ;;
    --dry-run)      DRY_RUN=1 ;;
    --no-push)      NO_PUSH=1 ;;
    --force)        FORCE=1 ;;
    --message)      MESSAGE="${2:-}"; shift ;;
    -h|--help)      awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print; next } exit }' "$0"; exit 0 ;;
    *)              echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null || die "需要 python3"
[ -d "$MODELS" ] || die "找不到模板目录：$MODELS"

# 1) 从来源目录导入模板（可选）
if [ -n "$FROM" ]; then
  [ -d "$FROM" ] || die "--from 目录不存在：$FROM"
  say "导入模板 → $MODELS"
  count=0
  for f in "$FROM"/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [ "$name" = "index.json" ] && continue
    cp -f "$f" "$MODELS/$name"
    say "  ← $name"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "$FROM 下没有可导入的 <id>.json"
fi

# 2) 生成 index.json
say "生成 index.json（${MODELS}）"
VERSIONS_JOINED=""
for v in "${DECLARE_VERSIONS[@]:-}"; do
  [ -n "$v" ] || continue
  VERSIONS_JOINED="${VERSIONS_JOINED}${v}"$'\n'
done
MODELS="$MODELS" VERSION_FILE="$VERSION_FILE" DECLARED="$VERSIONS_JOINED" \
FORCE="$FORCE" python3 - <<'PY'
import hashlib, json, os, re
from pathlib import Path

root = Path(os.environ["MODELS"])
version_file = os.environ.get("VERSION_FILE", "")
declared_raw = os.environ.get("DECLARED", "")
force = os.environ.get("FORCE") == "1"

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
META_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
INDEX = root / "index.json"

def vkey(v):
    return tuple(int(p) if str(p).isdigit() else -1 for p in str(v).split("."))

# 显式版本：--version id=ver 优先，其次版本文件
declared = {}
for item in declared_raw.splitlines():
    item = item.strip()
    if not item:
        continue
    mid, sep, ver = item.partition("=")
    if not sep:
        raise SystemExit(f"错误：--version 需为 `<id>=<semver>`，实际：{item!r}")
    declared[mid.strip()] = ver.strip()
if version_file:
    p = Path(version_file)
    if not p.is_file():
        raise SystemExit(f"错误：版本文件不存在：{p}")
    for lineno, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            raise SystemExit(f"错误：版本文件第 {lineno} 行应为 `<id> <semver>`：{line!r}")
        declared.setdefault(parts[0], parts[1])
for mid, ver in declared.items():
    if not SEMVER.match(ver):
        raise SystemExit(f"错误：版本号非法（需 X.Y.Z）：{mid} = {ver!r}")

# 已发布记录：index.json 是版本事实源
old = {}
if INDEX.is_file():
    try:
        for e in json.loads(INDEX.read_text(encoding="utf-8"))["meta_templates"]:
            old[e["id"]] = (e.get("version", ""), e.get("sha256", ""))
    except Exception as exc:
        raise SystemExit(f"错误：现有 index.json 不可解析：{exc}")

files = sorted(p for p in root.iterdir()
               if p.is_file() and p.suffix == ".json"
               and not p.name.startswith(".") and p.name != "index.json")
if not files:
    raise SystemExit(f"错误：{root} 下没有模板（<id>.json）")

entries, problems, notes, forced = [], [], [], []
for path in files:
    mid = path.stem
    if mid == "default":
        raise SystemExit("错误：`default` 是客户端编译期内置的保留 id，不能发布")
    if not META_ID.match(mid):
        raise SystemExit(f"错误：id 非法（ASCII 字母/数字与 ._-, ≤64）：{mid!r}")
    raw = path.read_bytes()
    try:
        doc = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError:
        raise SystemExit(f"错误：{path.name} 不是 UTF-8 文本")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"错误：{path.name} 不是合法 JSON：{exc}")
    models = doc.get("models") if isinstance(doc, dict) else None
    if not isinstance(models, list) or len(models) != 1:
        raise SystemExit(f'错误：{path.name} 必须恰好含一个条目（{{"models":[{{…}}]}}）')
    entry = models[0]
    if not isinstance(entry, dict):
        raise SystemExit(f"错误：{path.name} 的条目不是对象")
    tpl = (entry.get("model_messages") or {}).get("instructions_template")
    base = entry.get("base_instructions")
    if not (isinstance(tpl, str) and tpl) and not (isinstance(base, str) and base):
        raise SystemExit(
            f"错误：{path.name} 缺提示词（`model_messages.instructions_template` 或 "
            "`base_instructions` 至少一个非空），客户端会拒整份目录"
        )

    sha = hashlib.sha256(raw).hexdigest()
    prev = old.get(mid)
    declared_ver = declared.get(mid, "")

    if prev is None:
        # 新模板：必须有版本，否则客户端无从比较（--force 也不给空版本）
        if not declared_ver:
            problems.append(f"{mid}：新模板必须指定版本（--version {mid}=X.Y.Z 或 --version-file）")
            ver = ""
        else:
            ver = declared_ver
            notes.append(f"  {mid}：新增 v{ver}")
    elif prev[1] == sha:
        # 内容未变：沿用已记录版本；显式声明不得低于它
        ver = declared_ver or prev[0]
        if vkey(ver) < vkey(prev[0]):
            problems.append(f"{mid}：内容未变，但声明的 v{ver} 低于已发布 v{prev[0]}")
        notes.append(f"  {mid}：v{ver}（内容未变）")
    else:
        # 内容有变化：版本必须高于已发布版本
        ver = declared_ver
        if not ver:
            problems.append(
                f"{mid}：内容有变化但没给新版本（已发布 v{prev[0]}）；请加 --version {mid}=X.Y.Z"
            )
            ver = prev[0] if force else ""
            if force:
                forced.append(mid)
                notes.append(f"  {mid}：内容变化但沿用 v{prev[0]}（--force）")
        elif vkey(ver) <= vkey(prev[0]):
            if force:
                forced.append(mid)
                notes.append(f"  {mid}：内容变化但沿用 v{ver}（--force，不高于已发布 v{prev[0]}）")
            else:
                problems.append(f"{mid}：内容有变化，版本需高于已发布 v{prev[0]}，实际 v{ver}")
        else:
            notes.append(f"  {mid}：v{prev[0]} → v{ver}（内容变化）")
    entries.append({"id": mid, "version": ver, "sha256": sha})

if problems:
    raise SystemExit("错误：\n  " + "\n  ".join(problems))
if forced:
    print("  警告：以下内容变化但未抬版本（--force）：" + "、".join(forced))
    print("        客户端按版本比较，同版本不会提示更新——这些改动实际发不出去。")

INDEX.write_text(
    json.dumps({"meta_templates": entries}, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
for n in notes:
    print(n)
print(f"  index.json 已更新：{len(entries)} 条")
PY

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  say "dry-run：index.json 已写入本地工作区，未提交、未推送"
  MODELS="$MODELS" python3 - <<'PYEOF'
import json, os
from pathlib import Path
d = json.loads((Path(os.environ["MODELS"]) / "index.json").read_text(encoding="utf-8"))
items = "、".join(f'{e["id"]} v{e["version"]}' for e in d["meta_templates"])
print("  预览：" + items)
PYEOF
  exit 0
fi

# 3) 提交并推送双平台
BR=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
[ "$BR" = "$BRANCH" ] || die "当前分支=${BR}，需在 $BRANCH"
git -C "$ROOT" remote get-url "$GITHUB_REMOTE" >/dev/null 2>&1 || die "缺 GitHub 远端：$GITHUB_REMOTE"
git -C "$ROOT" remote get-url "$GITEE_REMOTE" >/dev/null 2>&1 || die "缺 Gitee 远端：$GITEE_REMOTE"
# 只允许 coskey/models/ 有改动：本脚本不该顺带带走别的未提交内容
DIRTY=$(git -C "$ROOT" status --porcelain -uall | grep -v '^.. coskey/models/' || true)
[ -z "$DIRTY" ] || die "仓库有其他未提交改动，请先处理：${DIRTY}"

git -C "$ROOT" add coskey/models
if git -C "$ROOT" diff --cached --quiet; then
  say "无变化：仓库已是本次内容"
  exit 0
fi
git -C "$ROOT" commit -q -m "${MESSAGE:-chore(models): 更新元模板 index 与模板}"
say "已提交：$(git -C "$ROOT" rev-parse --short HEAD)"
if [ "$NO_PUSH" = 1 ]; then
  say "未推送（--no-push）：确认后手动 git push $GITHUB_REMOTE $BRANCH 与 $GITEE_REMOTE $BRANCH"
else
  # 先 Gitee 后 GitHub：GitHub 是上游 raw 的参考入口，最后落地可缩短两平台不一致窗口
  for R in "$GITEE_REMOTE" "$GITHUB_REMOTE"; do
    git -C "$ROOT" push "$R" "HEAD:$BRANCH" || die "推送到 $R 失败（已提交，修好重跑即可）"
    say "已推送到 $R/$BRANCH"
  done
fi
