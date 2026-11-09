#!/usr/bin/env bash
# ChatGPT.app 能力默认值发布：扫描
#   coskey/app-capability/statsig/<appVersion>/<appBuild>/<sdkVersion>/defaults.json
# 生成单一 index.json，校验内容与不可变性，并可签名、提交、双推、部署 cosk.ai。
#
# 默认只生成本地 index.json 与做校验，不签名、不提交、不推送、不部署。
#
# 用法：
#   tools/publish-app-capability.sh [--dry-run] [--sign] [--publish]
#     [--no-push] [--no-deploy] [--force] [--keep N]
#     [--allow-schema3]
#     [--message MSG] [--signing-key PATH]
#     [--expected-public-key PATH]
#     [--tauri-bin PATH] [--coskey-repo PATH]
#     [--github-remote origin] [--gitee-remote gitee] [--branch main]
#     [--host cosk-site] [--root /opt/cosk/cosk-site] [--domain www.cosk.ai]
#
# 模式：
#   （默认）     校验并生成/更新本地 index.json；已有签名若因此失效会被删除
#   --dry-run    只校验与打印计划，不写文件
#   --sign       生成本地 index.json 并签名，不提交、不推送、不部署
#   --publish    生成、签名、提交、双推、部署并回读核对
#
# 索引策略：
#   - 只读取 <appVersion>/<appBuild>/<sdkVersion>/defaults.json；
#   - 按 appVersion 数值倒序，保留最近 20 个应用版本；
#   - 同一 appVersion 下的不同 sdkVersion 全部保留；
#   - defaults schema 2 / 3 可混合发布，index.json 始终使用 schemaVersion: 2；
#   - schema 3 必须显式传 --allow-schema3，且必须使用新的版本目录；
#   - 同一 appVersion + appBuild + sdkVersion 的 contractVersion 不得变化，
#     不允许从 schema 2/contract 1 原地迁移到 schema 3/contract 2，--force 也不行；
#   - 已存在的版本若内容 sha256 变化，默认拒绝，需 --force；
#   - defaults.json 是运维输入，index.json 是脚本生成物，不手写。
#
# 发布前置：
#   - --publish 或 --sign 需要 Tauri CLI 与 minisign 私钥；
#   - 私钥缺省为 ~/.config/coskey-release/coskey.key；
#   - 签名使用 Tauri updater 的 minisign 格式，并由 coskey 仓库的
#     scripts/lib/verify-minisign.mjs 做独立校验；
#   - 不要把私钥路径、内容或签名材料写进仓库。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CAP="$ROOT/coskey/app-capability/statsig"
INDEX="$CAP/index.json"
SIG="$CAP/index.json.sig"

GITHUB_REMOTE="${GITHUB_REMOTE:-origin}"
GITEE_REMOTE="${GITEE_REMOTE:-gitee}"
BRANCH="${BRANCH:-main}"
SITE_HOST="${SITE_HOST:-cosk-site}"
SITE_ROOT="${SITE_ROOT:-/opt/cosk/cosk-site}"
DOMAIN="${DOMAIN:-www.cosk.ai}"
COSKEY_REPO="${COSKEY_REPO:-$ROOT/../coskey}"
SIGNING_KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.config/coskey-release/coskey.key}"
SIGNING_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
EXPECTED_PUBLIC_KEY="${EXPECTED_PUBLIC_KEY_FILE:-}"
TAURI_BIN="${TAURI_BIN:-}"
VERIFY_JS="${VERIFY_MINISIGN_JS:-}"
KEEP_APP_VERSIONS=20

DRY_RUN=0
SIGN_ONLY=0
PUBLISH=0
NO_PUSH=0
NO_DEPLOY=0
FORCE=0
ALLOW_SCHEMA3=0
MESSAGE=""

say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "$*" >&2; exit 1; }
ssh_() { ssh -o BatchMode=yes "$SITE_HOST" "$@"; }
hash_stdin() { python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --sign) SIGN_ONLY=1 ;;
    --publish) PUBLISH=1 ;;
    --no-push) NO_PUSH=1 ;;
    --no-deploy) NO_DEPLOY=1 ;;
    --force) FORCE=1 ;;
    --allow-schema3) ALLOW_SCHEMA3=1 ;;
    --keep) KEEP_APP_VERSIONS="${2:-}"; shift ;;
    --message) MESSAGE="${2:-}"; shift ;;
    --signing-key) SIGNING_KEY="${2:-}"; shift ;;
    --expected-public-key) EXPECTED_PUBLIC_KEY="${2:-}"; shift ;;
    --tauri-bin) TAURI_BIN="${2:-}"; shift ;;
    --coskey-repo) COSKEY_REPO="${2:-}"; shift ;;
    --github-remote) GITHUB_REMOTE="${2:-}"; shift ;;
    --gitee-remote) GITEE_REMOTE="${2:-}"; shift ;;
    --branch) BRANCH="${2:-}"; shift ;;
    --host) SITE_HOST="${2:-}"; shift ;;
    --root) SITE_ROOT="${2:-}"; shift ;;
    --domain) DOMAIN="${2:-}"; shift ;;
    -h|--help)
      awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print; next } exit }' "$0"
      exit 0
      ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

[ -n "$TAURI_BIN" ] || TAURI_BIN="$COSKEY_REPO/gui/frontend/node_modules/.bin/tauri"
[ -n "$VERIFY_JS" ] || VERIFY_JS="$COSKEY_REPO/scripts/lib/verify-minisign.mjs"

case "$KEEP_APP_VERSIONS" in
  ''|*[!0-9]*) die "--keep 必须是正整数" ;;
esac
[ "$KEEP_APP_VERSIONS" -gt 0 ] || die "--keep 必须大于 0"
command -v python3 >/dev/null || die "需要 python3"
[ -d "$CAP" ] || die "找不到能力默认值目录：$CAP"

SUMMARY=$(CAP="$CAP" INDEX="$INDEX" KEEP_APP_VERSIONS="$KEEP_APP_VERSIONS" \
FORCE="$FORCE" DRY_RUN="$DRY_RUN" ALLOW_SCHEMA3="$ALLOW_SCHEMA3" python3 - <<'PY'
import hashlib
import json
import math
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ["CAP"])
index_path = Path(os.environ["INDEX"])
keep_n = int(os.environ["KEEP_APP_VERSIONS"])
force = os.environ["FORCE"] == "1"
dry_run = os.environ["DRY_RUN"] == "1"
allow_schema3 = os.environ["ALLOW_SCHEMA3"] == "1"

APP_VERSION = re.compile(r"^\d+(?:\.\d+){2,}$")
SDK_VERSION = re.compile(r"^\d+(?:\.\d+)+$")
GATE_IDS_V13 = {
    "770071981",
    "410262010",
    "419294242",
    "410065390",
    "1506311413",
    "1892382740",
    "3085093835",
    "1304276663",
    "1532120159",
    "1288674243",
    "2124127696",
    "2296472986",
    "1042620455",
}
GATE_IDS_V14 = GATE_IDS_V13 | {"4114442250"}
LAYER_ID = "72216192"
SCHEMA2 = 2
SCHEMA3 = 3
CONTRACT_SCHEMA2 = 1
CONTRACT_SCHEMA3 = 2
UI_SCHEMA_VERSION = 1
NO_EXPIRY = "9999-12-31T23:59:59Z"
CONTROL_KINDS = {"switch", "select", "text", "number"}
PLATFORMS = {"macOS", "Windows"}
UI_KEYS = {"schemaVersion", "groups", "controls"}
GROUP_KEYS = {"id", "order", "label"}
CONTROL_KEYS = {
    "id",
    "target",
    "kind",
    "group",
    "order",
    "label",
    "description",
    "platforms",
    "options",
}
OPTION_KEYS = {"value", "label"}
MAX_BYTES = 512 * 1024
FORBIDDEN_KEYS = {
    "stableID",
    "source_surface_stable_id",
    "userID",
    "sessionID",
    "app_session_id",
    "codex_app_session_id",
    "Cookie",
    "Authorization",
}


def version_key(value):
    return tuple(int(part) for part in value.split("."))


def parse_time(value, label):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise SystemExit(f"错误：{label} 必须是 UTC ISO-8601（以 Z 结尾）")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise SystemExit(f"错误：{label} 不是合法 ISO-8601：{value!r}")
    if parsed.tzinfo != timezone.utc:
        raise SystemExit(f"错误：{label} 必须使用 UTC")
    return parsed


def check_gate(gid, gate, label):
    if not isinstance(gate, dict):
        raise SystemExit(f"错误：{label}.featureGates.{gid} 必须是对象")
    if gate.get("name") != gid:
        raise SystemExit(f"错误：{label}.featureGates.{gid}.name 必须等于 id")
    if not isinstance(gate.get("rule_id"), str) or not gate["rule_id"]:
        raise SystemExit(f"错误：{label}.featureGates.{gid}.rule_id 为空")
    if not isinstance(gate.get("secondary_exposures"), list):
        raise SystemExit(f"错误：{label}.featureGates.{gid}.secondary_exposures 必须是数组")
    version = gate.get("version")
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        raise SystemExit(f"错误：{label}.featureGates.{gid}.version 非法")
    if not isinstance(gate.get("id_type"), str) or not gate["id_type"]:
        raise SystemExit(f"错误：{label}.featureGates.{gid}.id_type 为空")
    if not isinstance(gate.get("value"), bool):
        raise SystemExit(f"错误：{label}.featureGates.{gid}.value 必须是布尔值")


def check_identity_free(value, label):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in FORBIDDEN_KEYS:
                raise SystemExit(f"错误：{label} 不得包含用户身份字段 `{key}`")
            check_identity_free(child, f"{label}.{key}")
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            check_identity_free(child, f"{label}[{idx}]")


def reject_json_constant(value):
    raise ValueError(f"不允许非有限 JSON 常量：{value}")


def check_keys(value, allowed, label):
    if not isinstance(value, dict):
        raise SystemExit(f"错误：{label} 必须是对象")
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise SystemExit(f"错误：{label} 含未知字段：{', '.join(unknown)}")


def check_order(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise SystemExit(f"错误：{label} 必须是有限数字")


def check_text_map(value, label, required):
    if value is None and not required:
        return
    if not isinstance(value, dict) or (required and not value):
        raise SystemExit(f"错误：{label} 必须是非空语言文本对象")
    for lang, text in value.items():
        if not isinstance(lang, str) or not lang.strip():
            raise SystemExit(f"错误：{label} 的语言键不能为空")
        if not isinstance(text, str) or not text.strip():
            raise SystemExit(f"错误：{label}.{lang} 必须是非空纯文本")
        if (
            "<" in text
            or ">" in text
            or "javascript:" in text.lower()
            or "http://" in text.lower()
            or "https://" in text.lower()
        ):
            raise SystemExit(f"错误：{label}.{lang} 只允许纯文本，不得包含 HTML、脚本或 URL")


def target_value(doc, target, label):
    if not isinstance(target, str) or not target:
        raise SystemExit(f"错误：{label}.target 必须是非空字符串")
    if target.startswith("gate:"):
        gate_id = target[len("gate:"):]
        gate = doc["featureGates"].get(gate_id)
        if not isinstance(gate, dict):
            raise SystemExit(f"错误：{label}.target 不存在：{target}")
        return gate.get("value")
    if target.startswith("layer:"):
        rest = target[len("layer:"):]
        if "." not in rest:
            raise SystemExit(f"错误：{label}.target 缺少 layer 字段路径：{target}")
        layer_id, field_path = rest.split(".", 1)
        layer = doc["layers"].get(layer_id)
        if not isinstance(layer, dict) or not isinstance(layer.get("value"), dict):
            raise SystemExit(f"错误：{label}.target 不存在：{target}")
        current = layer["value"]
        for part in field_path.split("."):
            if not part or not isinstance(current, dict) or part not in current:
                raise SystemExit(f"错误：{label}.target 不存在：{target}")
            current = current[part]
        return current
    raise SystemExit(f"错误：{label}.target 只允许 gate:<id> 或 layer:<id>.<字段>")


def check_control(doc, control, label, group_ids):
    check_keys(control, CONTROL_KEYS, label)
    control_id = control.get("id")
    if not isinstance(control_id, str) or not control_id.strip():
        raise SystemExit(f"错误：{label}.id 必须是非空字符串")
    group = control.get("group")
    if not isinstance(group, str) or group not in group_ids:
        raise SystemExit(f"错误：{label}.group 不存在：{group!r}")
    check_order(control.get("order"), f"{label}.order")
    check_text_map(control.get("label"), f"{label}.label", True)
    check_text_map(control.get("description"), f"{label}.description", False)

    platforms = control.get("platforms", [])
    if not isinstance(platforms, list) or any(not isinstance(item, str) for item in platforms):
        raise SystemExit(f"错误：{label}.platforms 必须是字符串数组")
    if len(platforms) != len(set(platforms)) or not set(platforms).issubset(PLATFORMS):
        raise SystemExit(f"错误：{label}.platforms 只能包含不重复的 macOS / Windows")

    kind = control.get("kind")
    if kind not in CONTROL_KINDS:
        raise SystemExit(f"错误：{label}.kind 未知：{kind!r}")
    value = target_value(doc, control.get("target"), label)
    type_ok = {
        "switch": isinstance(value, bool),
        "select": isinstance(value, str),
        "text": isinstance(value, str),
        "number": (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(value)
        ),
    }[kind]
    if not type_ok:
        raise SystemExit(f"错误：{label}.kind={kind} 与 target 值类型不匹配")

    options = control.get("options", [])
    if not isinstance(options, list):
        raise SystemExit(f"错误：{label}.options 必须是数组")
    if kind == "select":
        if not options:
            raise SystemExit(f"错误：{label}.options 在 select 控件中不能为空")
        seen_values = set()
        for idx, option in enumerate(options):
            option_label = f"{label}.options[{idx}]"
            check_keys(option, OPTION_KEYS, option_label)
            option_value = option.get("value")
            if not isinstance(option_value, str) or not option_value:
                raise SystemExit(f"错误：{option_label}.value 必须是非空字符串")
            if option_value in seen_values:
                raise SystemExit(f"错误：{label}.options.value 不得重复：{option_value}")
            seen_values.add(option_value)
            check_text_map(option.get("label"), f"{option_label}.label", True)
        if value not in seen_values:
            raise SystemExit(
                f"错误：{label}.target 的默认值 {value!r} 不在 select options 中"
            )
    elif options:
        raise SystemExit(f"错误：{label}.options 只允许出现在 select 控件中")
    return control_id, control.get("target")


def check_ui(doc, path):
    ui = doc.get("ui")
    label = f"{path}.ui"
    check_keys(ui, UI_KEYS, label)
    if ui.get("schemaVersion") != UI_SCHEMA_VERSION:
        raise SystemExit(
            f"错误：{label}.schemaVersion 必须为 {UI_SCHEMA_VERSION}，当前为 {ui.get('schemaVersion')!r}"
        )

    groups = ui.get("groups")
    controls = ui.get("controls")
    if not isinstance(groups, list):
        raise SystemExit(f"错误：{label}.groups 必须是数组")
    if not isinstance(controls, list):
        raise SystemExit(f"错误：{label}.controls 必须是数组")

    group_ids = set()
    for idx, group in enumerate(groups):
        group_label = f"{label}.groups[{idx}]"
        check_keys(group, GROUP_KEYS, group_label)
        group_id = group.get("id")
        if not isinstance(group_id, str) or not group_id:
            raise SystemExit(f"错误：{group_label}.id 必须是非空字符串")
        if group_id in group_ids:
            raise SystemExit(f"错误：{label}.groups.id 不得重复：{group_id}")
        group_ids.add(group_id)
        check_order(group.get("order"), f"{group_label}.order")
        check_text_map(group.get("label"), f"{group_label}.label", True)

    control_ids = set()
    targets = set()
    for idx, control in enumerate(controls):
        control_label = f"{label}.controls[{idx}]"
        control_id, target = check_control(doc, control, control_label, group_ids)
        if control_id in control_ids:
            raise SystemExit(f"错误：{label}.controls.id 不得重复：{control_id}")
        if target in targets:
            raise SystemExit(f"错误：{label}.controls.target 不得重复：{target}")
        control_ids.add(control_id)
        targets.add(target)


records = []
seen = set()
for path in sorted(root.glob("*/*/*/defaults.json")):
    if not path.is_file():
        continue
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        raise SystemExit(f"错误：{path} 超过 512 KiB")
    try:
        doc = json.loads(raw.decode("utf-8"), parse_constant=reject_json_constant)
    except Exception as exc:
        raise SystemExit(f"错误：{path} 不是合法 UTF-8 JSON：{exc}")
    if not isinstance(doc, dict):
        raise SystemExit(f"错误：{path} 顶层必须是对象")
    schema = doc.get("schemaVersion")
    if schema not in (SCHEMA2, SCHEMA3):
        raise SystemExit(f"错误：{path}.schemaVersion 必须为 2 或 3")
    if schema == SCHEMA3 and not allow_schema3:
        raise SystemExit(
            f"错误：{path} 是 schema 3；安全发布需要显式传入 --allow-schema3"
        )
    app_version = doc.get("appVersion")
    app_build = doc.get("appBuild")
    sdk_version = doc.get("sdkVersion")
    if not isinstance(app_version, str) or not APP_VERSION.fullmatch(app_version):
        raise SystemExit(f"错误：{path}.appVersion 不是点分数字版本")
    if not isinstance(sdk_version, str) or not SDK_VERSION.fullmatch(sdk_version):
        raise SystemExit(f"错误：{path}.sdkVersion 不是点分数字版本")
    if not isinstance(app_build, str) or not app_build.isdigit():
        raise SystemExit(f"错误：{path}.appBuild 必须是数字 build")
    if (
        path.parent.parent.parent.name != app_version
        or path.parent.parent.name != app_build
        or path.parent.name != sdk_version
    ):
        raise SystemExit(f"错误：{path} 的目录层与 appVersion/appBuild/sdkVersion 不一致")
    key = (app_version, app_build, sdk_version)
    if key in seen:
        raise SystemExit(f"错误：重复版本 {app_version} / {app_build} / {sdk_version}")
    seen.add(key)
    contract = doc.get("contractVersion")
    expected_contract = CONTRACT_SCHEMA2 if schema == SCHEMA2 else CONTRACT_SCHEMA3
    if isinstance(contract, bool) or not isinstance(contract, int) or contract != expected_contract:
        raise SystemExit(
            f"错误：{path}.contractVersion 必须为 {expected_contract}（schema {schema}）"
        )
    if doc.get("hash") != "djb2":
        raise SystemExit(f"错误：{path}.hash 必须为 djb2")
    if not isinstance(doc.get("source"), str) or not doc["source"].strip():
        raise SystemExit(f"错误：{path}.source 不能为空")
    captured = parse_time(doc.get("capturedAt"), f"{path}.capturedAt")
    if schema == SCHEMA2:
        expires = parse_time(doc.get("expiresAt"), f"{path}.expiresAt")
        if expires <= captured:
            raise SystemExit(f"错误：{path}.expiresAt 必须晚于 capturedAt")
        published_expiry = doc["expiresAt"]
    else:
        if "expiresAt" in doc:
            raise SystemExit(
                f"错误：{path} 是 schema 3，不得声明 expiresAt；索引会自动写入兼容哨兵"
            )
        published_expiry = NO_EXPIRY
    if not isinstance(doc.get("forwardCompatible"), bool):
        raise SystemExit(f"错误：{path}.forwardCompatible 必须是布尔值")
    if not isinstance(doc.get("sdkFlags"), dict):
        raise SystemExit(f"错误：{path}.sdkFlags 必须是对象")
    if not isinstance(doc.get("sdkConfigs"), dict):
        raise SystemExit(f"错误：{path}.sdkConfigs 必须是对象")
    interval = doc["sdkConfigs"].get("live_values_auto_refresh_interval_seconds")
    if isinstance(interval, bool) or not isinstance(interval, int) or interval <= 0:
        raise SystemExit(f"错误：{path}.sdkConfigs.live_values_auto_refresh_interval_seconds 非法")
    gates = doc.get("featureGates")
    if not isinstance(gates, dict):
        raise SystemExit(f"错误：{path}.featureGates 必须是对象")
    if schema == SCHEMA2 and set(gates) not in (GATE_IDS_V13, GATE_IDS_V14):
        raise SystemExit(
            f"错误：{path}.featureGates 必须包含 13-gate 历史投影或 14-gate 当前投影"
        )
    for gid in sorted(gates):
        check_gate(gid, gates[gid], str(path))
    layers = doc.get("layers")
    if not isinstance(layers, dict):
        raise SystemExit(f"错误：{path}.layers 必须是对象")
    if schema == SCHEMA2 and set(layers) != {LAYER_ID}:
        raise SystemExit(f"错误：{path}.layers 必须恰好包含层 {LAYER_ID}")
    for layer_id, layer in layers.items():
        layer_label = f"{path}.layers.{layer_id}"
        if not isinstance(layer, dict) or layer.get("name") != layer_id:
            raise SystemExit(f"错误：{layer_label} 形态不对")
        if not isinstance(layer.get("value"), dict):
            raise SystemExit(f"错误：{layer_label}.value 必须是对象")
        if not isinstance(layer.get("rule_id"), str) or not layer["rule_id"]:
            raise SystemExit(f"错误：{layer_label}.rule_id 为空")
        if not isinstance(layer.get("secondary_exposures"), list):
            raise SystemExit(f"错误：{layer_label}.secondary_exposures 必须是数组")
        version = layer.get("version")
        if isinstance(version, bool) or not isinstance(version, int) or version < 1:
            raise SystemExit(f"错误：{layer_label}.version 非法")
        if not isinstance(layer.get("id_type"), str) or not layer["id_type"]:
            raise SystemExit(f"错误：{layer_label}.id_type 为空")
    if schema == SCHEMA2:
        if "ui" in doc:
            raise SystemExit(f"错误：{path} 的 schema 2 不得包含 ui")
        i18n_value = layers[LAYER_ID]["value"]
        if not isinstance(i18n_value.get("enable_i18n"), bool):
            raise SystemExit(
                f"错误：{path}.layers.{LAYER_ID}.value.enable_i18n 缺失或类型错误"
            )
    else:
        check_ui(doc, str(path))
    check_identity_free(doc, str(path))
    records.append({
        "schemaVersion": schema,
        "gate_count": len(gates),
        "appVersion": app_version,
        "appBuild": app_build,
        "sdkVersion": sdk_version,
        "contractVersion": contract,
        "path": f"{app_version}/{app_build}/{sdk_version}/defaults.json",
        "sha256": hashlib.sha256(raw).hexdigest(),
        "capturedAt": doc["capturedAt"],
        "expiresAt": published_expiry,
        "forwardCompatible": doc["forwardCompatible"],
    })

if not records:
    raise SystemExit(f"错误：{root} 下没有 defaults.json")
if not any(
    record["schemaVersion"] == SCHEMA2 and record["gate_count"] == 14
    for record in records
):
    raise SystemExit(
        "错误：旧客户端兼容发布至少需要一个 schema 2、contract 1、"
        "包含 4114442250 的 14-gate defaults.json"
    )
old_entries = {}
if index_path.is_file():
    try:
        old_doc = json.loads(index_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"错误：现有 index.json 不可解析：{exc}")
    if not isinstance(old_doc, dict) or old_doc.get("schemaVersion") not in (1, 2):
        raise SystemExit("错误：现有 index.json schemaVersion 必须为 1 或 2")
    if not isinstance(old_doc.get("entries"), list):
        raise SystemExit("错误：现有 index.json.entries 必须是数组")
    for old in old_doc["entries"]:
        if not isinstance(old, dict):
            raise SystemExit("错误：现有 index.json.entries 含非对象")
        oa, ob, osv = old.get("appVersion"), old.get("appBuild"), old.get("sdkVersion")
        if isinstance(oa, str) and isinstance(ob, str) and isinstance(osv, str):
            old_entries[(oa, ob, osv)] = old

by_app = {}
for rec in records:
    by_app.setdefault(rec["appVersion"], []).append(rec)
recent_apps = sorted(by_app, key=version_key, reverse=True)[:keep_n]
recent_set = set(recent_apps)
selected = [rec for rec in records if rec["appVersion"] in recent_set]
selected.sort(
    key=lambda rec: (version_key(rec["appVersion"]), version_key(rec["sdkVersion"])),
    reverse=True,
)
if not any(
    rec["schemaVersion"] == SCHEMA2 and rec["gate_count"] == 14
    for rec in selected
):
    raise SystemExit(
        f"错误：最近 {keep_n} 个应用版本的索引必须至少保留一个 schema 2、"
        "contract 1、14-gate defaults.json，不能只发布 schema 3"
    )

problems = []
for rec in selected:
    old = old_entries.get((rec["appVersion"], rec["appBuild"], rec["sdkVersion"]))
    if old is not None:
        old_contract = old.get("contractVersion")
        if old_contract != rec["contractVersion"]:
            problems.append(
                f"{rec['appVersion']} / {rec['appBuild']} / {rec['sdkVersion']}："
                f"已发布 contractVersion={old_contract}，当前为 {rec['contractVersion']}；"
                "schema 2 → 3 或相反迁移必须使用新的版本目录，--force 不允许"
            )
        elif old.get("sha256") != rec["sha256"] and not force:
            problems.append(
                f"{rec['appVersion']} / {rec['appBuild']} / {rec['sdkVersion']}："
                "已发布内容被原地修改；请新建版本目录，或明确使用 --force"
            )
for key, old in old_entries.items():
    if key not in {(r["appVersion"], r["appBuild"], r["sdkVersion"]) for r in selected} and key[0] in recent_set and not force:
        problems.append(f"{key[0]} / {key[1]} / {key[2]}：仍在最近 {keep_n} 个应用版本内，但源文件已消失")
if problems:
    raise SystemExit("错误：\n  " + "\n  ".join(problems))

counts = {SCHEMA2: 0, SCHEMA3: 0}
for rec in selected:
    counts[rec["schemaVersion"]] += 1

for rec in selected:
    rec.pop("schemaVersion")
    rec.pop("gate_count", None)

new_doc = {"schemaVersion": 2, "entries": selected}
encoded = (json.dumps(new_doc, ensure_ascii=False, indent=2) + "\n").encode()
old_bytes = index_path.read_bytes() if index_path.is_file() else b""
changed = encoded != old_bytes

if dry_run:
    print(
        f"  将生成 index.json：{len(selected)} 个条目（schema 2={counts[SCHEMA2]}，"
        f"schema 3={counts[SCHEMA3]}），覆盖最近 {len(recent_apps)} 个应用版本"
    )
else:
    index_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".index.", suffix=".json", dir=index_path.parent)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, index_path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(
        f"  index.json：{len(selected)} 个条目（schema 2={counts[SCHEMA2]}，"
        f"schema 3={counts[SCHEMA3]}），覆盖最近 {len(recent_apps)} 个应用版本"
          + ("（内容有变化）" if changed else "（内容未变）"))

for rec in selected:
    print(
        f"    {rec['appVersion']} / {rec['appBuild']} / {rec['sdkVersion']} "
        f"contract={rec['contractVersion']}  {rec['sha256'][:16]}…"
    )
if len(by_app) > len(recent_apps):
    print(f"  保留策略：发现 {len(by_app)} 个应用版本，索引只保留最近 {len(recent_apps)} 个；"
          "旧文件不会自动删除")
print("  changed=%d" % (1 if changed else 0))
PY
)

INDEX_CHANGED=$(printf '%s\n' "$SUMMARY" | awk -F= '/^  changed=/{print $2; exit}')
printf '%s\n' "$SUMMARY" | sed '/^  changed=/d'

if [ "$DRY_RUN" = 1 ]; then
  say "dry-run：未写入 index.json，未签名、提交、推送或部署"
  exit 0
fi

if [ "$SIGN_ONLY" = 0 ] && [ "$PUBLISH" = 0 ]; then
  if [ "$INDEX_CHANGED" = 1 ] && [ -f "$SIG" ]; then
    rm -f "$SIG"
    say "index.json 已变化，旧 index.json.sig 已删除；运行 --sign 或 --publish 重新签名"
  fi
  say "本地索引已生成；未签名、未提交、未推送、未部署"
  exit 0
fi

command -v node >/dev/null || die "签名校验需要 node"
[ -f "$VERIFY_JS" ] || die "找不到 minisign 校验器：${VERIFY_JS}（可设 VERIFY_MINISIGN_JS）"
[ -x "$TAURI_BIN" ] || die "找不到 Tauri CLI：${TAURI_BIN}（可设 TAURI_BIN）"
[ -f "$SIGNING_KEY" ] || die "找不到签名私钥：${SIGNING_KEY}（可设 --signing-key）"
PUBLIC_KEY="${SIGNING_KEY}.pub"
[ -f "$PUBLIC_KEY" ] || die "找不到签名公钥：$PUBLIC_KEY"
if [ -n "$EXPECTED_PUBLIC_KEY" ]; then
  [ -f "$EXPECTED_PUBLIC_KEY" ] || die "找不到期望公钥：${EXPECTED_PUBLIC_KEY}"
  EXPECTED_SOURCE="$EXPECTED_PUBLIC_KEY"
  EXPECTED_KIND=file
else
  TAURI_CONF="$COSKEY_REPO/gui/tauri.conf.json"
  [ -f "$TAURI_CONF" ] || die "找不到客户端公钥配置：${TAURI_CONF}"
  EXPECTED_SOURCE="$TAURI_CONF"
  EXPECTED_KIND=tauri
fi

EXPECTED_PUB=$(EXPECTED_SOURCE="$EXPECTED_SOURCE" EXPECTED_KIND="$EXPECTED_KIND" python3 - <<'PY'
import base64
import json
import os

if os.environ["EXPECTED_KIND"] == "file":
    value = open(os.environ["EXPECTED_SOURCE"], encoding="utf-8").read().strip()
else:
    value = json.load(open(os.environ["EXPECTED_SOURCE"], encoding="utf-8"))["plugins"]["updater"]["pubkey"].strip()
if "untrusted comment:" not in value:
    value = base64.b64decode(value, validate=True).decode("utf-8")
print(value.strip())
PY
)
ACTUAL_PUB=$(PUBLIC_KEY="$PUBLIC_KEY" python3 - <<'PY'
import base64
import os
import pathlib

value = pathlib.Path(os.environ["PUBLIC_KEY"]).read_text(encoding="utf-8").strip()
if "untrusted comment:" not in value:
    value = base64.b64decode(value, validate=True).decode("utf-8")
print(value.strip())
PY
)
[ "$EXPECTED_PUB" = "$ACTUAL_PUB" ] \
  || die "签名公钥与 coskey gui/tauri.conf.json 的 updater pubkey 不一致"

say "签名 index.json"
rm -f "$SIG"
(
  cd "$COSKEY_REPO/gui"
  env -u TAURI_SIGNING_PRIVATE_KEY \
    TAURI_SIGNING_PRIVATE_KEY_PATH="$SIGNING_KEY" \
    TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$SIGNING_PASSWORD" \
    "$TAURI_BIN" signer sign "$INDEX"
)
[ -s "$SIG" ] || die "签名命令未生成 $SIG"
node "$VERIFY_JS" -m "$INDEX" -x "$SIG" -p "$PUBLIC_KEY" >/dev/null \
  || die "index.json 签名校验失败"
say "签名校验通过"

if [ "$SIGN_ONLY" = 1 ] && [ "$PUBLISH" = 0 ]; then
  say "已生成签名；未提交、未推送、未部署"
  exit 0
fi

BR=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
[ "$BR" = "$BRANCH" ] || die "当前分支=${BR}，需在 $BRANCH"
git -C "$ROOT" remote get-url "$GITHUB_REMOTE" >/dev/null 2>&1 || die "缺 GitHub 远端：$GITHUB_REMOTE"
git -C "$ROOT" remote get-url "$GITEE_REMOTE" >/dev/null 2>&1 || die "缺 Gitee 远端：$GITEE_REMOTE"

DIRTY=$(git -C "$ROOT" status --porcelain -uall | grep -v '^.. coskey/app-capability/statsig/' || true)
[ -z "$DIRTY" ] || die "仓库有其他未提交改动，请先处理：${DIRTY}"

git -C "$ROOT" add coskey/app-capability/statsig
if git -C "$ROOT" diff --cached --quiet; then
  say "Git 无新增变化"
else
  MSG="${MESSAGE:-chore(app-capability): 更新 ChatGPT.app 能力默认值}"
  git -C "$ROOT" commit -q -m "$MSG"
  say "已提交：$(git -C "$ROOT" rev-parse --short HEAD)"
fi

if [ "$NO_PUSH" = 1 ]; then
  say "未推送（--no-push）：$GITHUB_REMOTE / $GITEE_REMOTE"
else
  for R in "$GITEE_REMOTE" "$GITHUB_REMOTE"; do
    git -C "$ROOT" push "$R" "HEAD:$BRANCH" || die "推送到 $R 失败（本地提交已保留）"
    say "已推送到 $R/$BRANCH"
  done
fi

if [ "$NO_DEPLOY" = 1 ]; then
  say "未部署（--no-deploy）"
  exit 0
fi

INCOMING="$SITE_ROOT/data/releases/.incoming/coskey-app-capability"
REL="$SITE_ROOT/data/releases/coskey/app-capability/statsig"
say "部署 → $SITE_HOST:$REL"
ssh_ "set -e
  mkdir -p '$SITE_ROOT/data/releases/.incoming'
  rm -rf '$INCOMING'
  mkdir -p '$INCOMING'" || die "ssh 准备中转目录失败：$SITE_HOST"
COPYFILE_DISABLE=1 tar -cz --no-xattrs -C "$CAP" . | ssh_ "tar -xz -C '$INCOMING'" \
  || die "传输失败（ssh 或服务器侧 tar 报错）"
ssh_ "set -e
  cd '$INCOMING'
  [ -f index.json ] || { echo '中转目录缺少 index.json' >&2; exit 1; }
  [ -f index.json.sig ] || { echo '中转目录缺少 index.json.sig' >&2; exit 1; }
  mkdir -p '$REL'
  # 版本目录先落地，索引和签名最后替换，避免线上读到半套内容。
  # 合并而不是删除整个 appVersion 目录，避免本次 tar 未包含的旧 build/sdk
  # 被误删，给仍在使用 schema 2 的旧客户端保留可达文件。
  for d in */; do
    [ -d \"\$d\" ] || continue
    name=\${d%/}
    mkdir -p '$REL'/\$name
    cp -a \"\$d\". '$REL'/\$name/
  done
  mv -f index.json '$REL'/index.json
  mv -f index.json.sig '$REL'/index.json.sig
  rm -rf '$INCOMING'
  find '$REL' -type d -exec chmod 755 {} +
  find '$REL' -type f -exec chmod 644 {} +" \
  || die "部署落地失败：中转目录 $INCOMING 可能仍在，线上索引未替换"

say "回读核对"
for rel in index.json index.json.sig; do
  got=$(curl -fsSL --max-time 20 "https://$DOMAIN/data/app/coskey/app-capability/statsig/$rel" \
    | hash_stdin) || die "回读失败：$rel"
  want=$(hash_stdin < "$CAP/$rel")
  [ "$got" = "$want" ] || die "回读不一致：$rel"
  say "  $rel ✓"
done

while IFS= read -r rel; do
  url="https://$DOMAIN/data/app/coskey/app-capability/statsig/$rel"
  got=$(curl -fsSL --max-time 20 "$url" | hash_stdin) \
    || die "回读失败：$rel"
  want=$(hash_stdin < "$CAP/$rel")
  [ "$got" = "$want" ] || die "回读不一致：$rel"
  say "  $rel ✓"
done < <(cd "$CAP" && find . -type f -name defaults.json | sed 's|^\./||' | sort)

say "发布完成"
echo "  index: https://$DOMAIN/data/app/coskey/app-capability/statsig/index.json"
echo "  signature: https://$DOMAIN/data/app/coskey/app-capability/statsig/index.json.sig"
