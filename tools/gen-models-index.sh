#!/usr/bin/env bash
# 元模板索引生成（cosk-releases 侧）：扫描 coskey/models/<版本>/<id>.json，
# 生成/更新 index.json（每个模板一条：最新版本 + 历史版本），
# 提交并推送到 GitHub 与 Gitee 两个平台。
#
# 目录约定（索引格式与校验约定见 coskey 仓库 0018 §5.0）：
#   coskey/models/
#   ├── <版本>/<id>.json   模板本体，版本号就是所在目录名（X.Y.Z）
#   └── index.json         生成物：每个 id 一条
#
# index.json 是本仓的**生成物**，不要手写：
#   {"meta_templates":[{"id","version","sha256","path","history":[…]}]}
#   每条一个 id：顶层是最新版本，history 是同一 id 的旧版本（新→旧），
#   每项 {version,sha256,path}（旧的全量索引 index-all.json 已并入 history）。
#   path 相对 coskey/models/（如 `1.1.1/deepseek-flash.json`）；
#   sha256 按模板文件的**原始字节**计算，客户端逐字节校验。
#
# 用法：
#   tools/gen-models-index.sh [选项]
#
#   --from DIR         模板来源目录：把该目录下的 <id>.json 复制进
#                      coskey/models/<版本>/（coskey 仓库的
#                      src/resources/model-catalog 可直接用）。
#                      不给则只处理 coskey/models/ 现有文件。
#   --from-version VER --from 导入文件的默认目标版本目录
#   --version ID=VER   指定某模板导入的目标版本目录（可重复，覆盖 --from-version）
#   --version-file F   批量版本文件（每行 `<id> <semver>`，`#` 注释）
#   --dry-run          只生成并打印计划，不提交、不推送
#   --no-push          生成并提交，但不推远端
#   --force            已发布内容被原地改动时也照发（默认拒绝）
#   --message MSG      自定义提交信息
#
# 版本规则（防「已发布内容被原地改」——客户端只在版本更高时更新）：
#   发布新版本    放进新的 <版本>/ 目录即可，版本号就是目录名
#   内容有变化    必须放进更高的版本目录；原地改已发布目录里的文件会被拒绝
#   内容无变化    可原样重跑（允许重发/补传）
#
# index.json 里每个 id 一条：version 写最新版本，history 收纳它的旧版本。
set -eu
# pipefail 只有 bash/zsh/ksh 有；dash 等 POSIX sh 没有，能开就开
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

FROM=""
FROM_VERSION=""
DRY_RUN=0; NO_PUSH=0; FORCE=0
MESSAGE=""
VERSION_FILE=""
GITHUB_REMOTE="${GITHUB_REMOTE:-origin}"   # 发布仓的 GitHub 远端
GITEE_REMOTE="${GITEE_REMOTE:-gitee}"      # 发布仓的 Gitee 镜像远端
BRANCH="${BRANCH:-main}"
# 累积的 `--version id=ver`，以换行分隔（POSIX sh 没有数组）
DECLARE_VERSIONS=""

# 本脚本路径：bash 用 BASH_SOURCE（被 source 时也准），dash 等没有就退回 $0
if [ -n "${BASH_VERSION:-}" ]; then SRC="${BASH_SOURCE[0]}"; else SRC="$0"; fi
ROOT=$(cd "$(dirname "$SRC")/.." && pwd)
MODELS="$ROOT/coskey/models"
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from)         FROM="${2:-}"; shift ;;
    --from-version) FROM_VERSION="${2:-}"; shift ;;
    --version)      DECLARE_VERSIONS="${DECLARE_VERSIONS}$(printf '\n%s' "${2:-}")"; shift ;;
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

# 1) 导入模板（可选）+ 2) 生成 index.json
say "生成 index.json（${MODELS}）"
VERSIONS_JOINED="$DECLARE_VERSIONS"
MODELS="$MODELS" FROM="$FROM" FROM_VERSION="$FROM_VERSION" \
VERSION_FILE="$VERSION_FILE" DECLARED="$VERSIONS_JOINED" \
FORCE="$FORCE" python3 - <<'PY'
import hashlib, json, os, re, shutil
from pathlib import Path

root = Path(os.environ["MODELS"])
from_dir = os.environ.get("FROM", "").strip()
from_version = os.environ.get("FROM_VERSION", "").strip()
version_file = os.environ.get("VERSION_FILE", "")
declared_raw = os.environ.get("DECLARED", "")
force = os.environ.get("FORCE") == "1"

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
META_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
INDEX = root / "index.json"
INDEX_ALL = root / "index-all.json"
SKIP = {"index.json", "index-all.json"}


def vkey(v):
    return tuple(int(p) for p in str(v).split("."))


def check_id(mid):
    if mid == "default":
        raise SystemExit("错误：`default` 是客户端编译期内置的保留 id，不能发布")
    if not META_ID.match(mid):
        raise SystemExit(f"错误：id 非法（ASCII 字母/数字与 ._-, ≤64）：{mid!r}")


# 显式版本：--version id=ver 优先，其次版本文件；仅在 --from 导入时用于选目标目录
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
if from_version and not SEMVER.match(from_version):
    raise SystemExit(f"错误：--from-version 非法（需 X.Y.Z）：{from_version!r}")
if declared and not from_dir:
    raise SystemExit("错误：--version/--version-file 只在配合 --from 导入时用于选择目标版本目录")
if from_version and not from_dir:
    raise SystemExit("错误：--from-version 只在配合 --from 导入时使用")

# 1) 从来源目录导入模板（可选）：<id>.json → coskey/models/<版本>/<id>.json
if from_dir:
    src = Path(from_dir)
    if not src.is_dir():
        raise SystemExit(f"错误：--from 目录不存在：{src}")
    print(f"  导入模板 → {root}")
    imported = 0
    for p in sorted(src.glob("*.json")):
        if p.name in SKIP:
            continue
        mid = p.stem
        check_id(mid)
        ver = declared.get(mid, from_version)
        if not ver:
            raise SystemExit(
                f"错误：导入 {p.name} 需要目标版本目录"
                f"（加 --from-version X.Y.Z 或 --version {mid}=X.Y.Z）"
            )
        dst_dir = root / ver
        dst_dir.mkdir(parents=True, exist_ok=True)
        dst = dst_dir / p.name
        if dst.is_file() and dst.read_bytes() == p.read_bytes():
            print(f"    ← {ver}/{p.name}（内容未变）")
        else:
            shutil.copyfile(p, dst)
            print(f"    ← {ver}/{p.name}")
        imported += 1
    if imported == 0:
        raise SystemExit(f"错误：{from_dir} 下没有可导入的 <id>.json")

# 2) 扫描 coskey/models/<版本>/<id>.json
version_dirs = []
for d in sorted(root.iterdir()):
    if d.name.startswith(".") or not d.is_dir():
        continue
    if not SEMVER.match(d.name):
        raise SystemExit(f"错误：models/ 下的子目录名必须是版本号 X.Y.Z：{d.name!r}")
    version_dirs.append(d)
if not version_dirs:
    raise SystemExit(f"错误：{root} 下没有版本目录（应为 `<版本>/<id>.json`）")

# 已发布记录：index.json 是版本事实源（含各条的 history）；兼容遗留的 index-all.json
old = {}


def load_index(path):
    if not path.is_file():
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))["meta_templates"]
    except Exception as exc:
        raise SystemExit(f"错误：现有 {path.name} 不可解析：{exc}")
    for e in data:
        mid, ver = e.get("id", ""), e.get("version", "")
        if mid and ver:
            old[(mid, ver)] = e.get("sha256", "")
        for h in e.get("history") or []:
            hmid, hver = h.get("id", mid), h.get("version", "")
            if hmid and hver:
                old.setdefault((hmid, hver), h.get("sha256", ""))


load_index(INDEX)
load_index(INDEX_ALL)


def read_template(path):
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
    return raw


entries, problems, notes, forced = [], [], [], []
for vd in version_dirs:
    ver = vd.name
    files = sorted(p for p in vd.iterdir()
                   if p.is_file() and p.suffix == ".json" and not p.name.startswith("."))
    if not files:
        notes.append(f"  {ver}/：空目录，跳过")
        continue
    for path in files:
        mid = path.stem
        check_id(mid)
        raw = read_template(path)
        sha = hashlib.sha256(raw).hexdigest()
        prev = old.get((mid, ver))
        if prev is None:
            notes.append(f"  {mid}：新增 v{ver}")
        elif prev == sha:
            notes.append(f"  {mid}：v{ver}（内容未变）")
        elif force:
            forced.append(f"{mid} v{ver}")
            notes.append(f"  {mid}：v{ver} 内容被改动但版本未抬（--force）")
        else:
            problems.append(f"{mid}：已发布的 v{ver} 内容被改动；请把改动放进更高的版本目录")
        entries.append({"id": mid, "version": ver, "sha256": sha,
                        "path": f"{ver}/{path.name}"})

current = {(e["id"], e["version"]) for e in entries}
for mid, ver in sorted(old):
    if (mid, ver) not in current:
        notes.append(f"  {mid}：v{ver} 已不在工作区（将从索引中移除）")

if problems:
    raise SystemExit("错误：\n  " + "\n  ".join(problems))
if forced:
    print("  警告：以下已发布内容被原地改动（--force）：" + "、".join(forced))
    print("        客户端按版本比较，同版本不会提示更新——这些改动实际发不出去。")

# index.json：每个 id 一条，version 取最高版本，其余版本进 history（新→旧）
by_id = {}
for e in entries:
    by_id.setdefault(e["id"], []).append(e)

index_entries, latest = [], {}
for mid in sorted(by_id):
    versions = sorted(by_id[mid], key=lambda e: vkey(e["version"]), reverse=True)
    head, older = versions[0], versions[1:]
    latest[mid] = head
    index_entries.append({
        "id": mid,
        "version": head["version"],
        "sha256": head["sha256"],
        "path": head["path"],
        "history": [{"version": o["version"], "sha256": o["sha256"], "path": o["path"]}
                    for o in older],
    })

for n in notes:
    print(n)
for e in entries:
    if (e["id"], e["version"]) not in old and latest[e["id"]] is not e:
        print(f"  提示：{e['id']} v{e['version']} 不是最新（只进 history；"
              f"index.json 的 version 是 v{latest[e['id']]['version']}）")

INDEX.write_text(
    json.dumps({"meta_templates": index_entries}, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
n_hist = sum(len(e["history"]) for e in index_entries)
if INDEX_ALL.exists():
    INDEX_ALL.unlink()
    print("  已删除 index-all.json（旧版本并入各条目的 history）")
print(f"  index.json 已更新：{len(index_entries)} 个模板、"
      f"{n_hist} 个历史版本")
PY

if [ "$DRY_RUN" = 1 ]; then
  echo ""
  say "dry-run：index.json 已写入本地工作区（index-all.json 已删除），未提交、未推送"
  MODELS="$MODELS" python3 - <<'PYEOF'
import json, os
from pathlib import Path
root = Path(os.environ["MODELS"])
idx = json.loads((root / "index.json").read_text(encoding="utf-8"))["meta_templates"]
print("  index.json：" + "、".join(
    f'{e["id"]} v{e["version"]}（历史 {len(e.get("history") or [])}）' for e in idx))
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
git -C "$ROOT" commit -q -m "${MESSAGE:-chore(models): 更新元模板索引与模板}"
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
