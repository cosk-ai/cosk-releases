# tools

发布仓侧的操作脚本。**产品仓库不重复实现这里的逻辑**：清单/索引在本仓生成，
由本仓推双平台并部署到 cosk.ai，产品仓库只提供内容与文档指引。

## 元模板（`coskey/models/`）

app 的「元模板更新」读取的索引与模板（约定见 coskey 仓库 `0018` §5.0）。
模板按版本号放在一层子目录里，版本号就是目录名：

```
coskey/models/
├── <版本>/<id>.json   模板本体（如 1.1.1/deepseek-flash.json）
└── index.json         生成物：每个 id 一条（最新版本 + 历史版本）
```

`index.json` 是**生成物**，不要手写。顶层是 `catalog_templates` 数组（每条一个 id）：

```json
{"catalog_templates": [
 {"id": "deepseek-flash", "version": "1.1.1", "sha256": "…", "path": "1.1.1/deepseek-flash.json",
  "history": [{"version": "1.0.1", "sha256": "…", "path": "1.0.1/deepseek-flash.json"}]}
]}
```

键名现行是 `catalog_templates`；`meta_templates` 是 0.6.0 前的发布键，
生成脚本与部署脚本读写都留了回退（旧索引不会卡住下一次生成）。
顶层 `version` / `sha256` / `path` 是最新版本；`history` 是同一 id 的旧版本
（**新→旧**），每项 `{version, sha256, path}`，无旧版本时为空数组。
`path` 相对 `coskey/models/`。客户端读 `index.json` 判断有没有更新；需要旧版本时
从 `history` 里取。旧的全量索引 `index-all.json` 已废弃，内容并入 `history`。

```bash
# 1) 生成 index.json 并推双平台
tools/gen-models-index.sh                              # 只扫描 coskey/models/ 现有文件
tools/gen-models-index.sh --from <模板目录> --from-version <semver>
#    模板目录可直接用 coskey 仓库的 src/resources/model-catalog/
#    --from 会把 <id>.json 复制进 coskey/models/<semver>/；
#    一批里想落到不同版本目录时，用 --version <id>=<semver>（可重复）或
#    --version-file（每行 `<id> <semver>`）逐条覆盖 --from-version
#    加 --dry-run 只看计划

# 2) 部署到 cosk.ai
tools/deploy-models.sh
#    加 --dry-run 只做本地自检与计划
```

| 脚本 | 职责 |
|---|---|
| `gen-models-index.sh` | 扫描 `coskey/models/<版本>/<id>.json` → 生成 `index.json`（每 id 一条，含 `history`）→ 提交并推送 GitHub + Gitee |
| `deploy-models.sh` | 自检（索引与 sha256 对应、`history` 版本低于当前、目录里每个模板都被覆盖）→ 传站点 → 原子就位 → 回读核对 |
| `deploy-provider-presets.sh` | 自检（列表字段、id 合法且不重复）→ 传站点 → 原子就位 → 回读核对 |
| `deploy-app-plugin-profile.sh` | 自检（`schemaVersion`、`startVersion`、插件名、平台、可选 `sha256`）→ 传站点 → 原子就位 → 回读核对 |
| `publish-app-capability.sh` | 校验能力默认值 → 生成最近 20 个应用版本的 `index.json` → 可选签名、提交、GitHub/Gitee 双推与 cosk.ai 部署 |

**版本规则**（`index.json` 是版本事实源，客户端只在版本更高时提示更新）：

| 情形 | 要求 |
|---|---|
| 发布新版本 | 放进新的 `<版本>/` 目录即可，版本号就是目录名 |
| 内容有变化 | 必须放进**更高**的版本目录，原地改已发布目录里的文件会被拒绝 |
| 内容无变化 | 可原样重跑（允许重发/补传） |

所以**已发布的模板内容不可原地改**：改了内容就得放进更高的版本目录，否则客户端拿不到
更新。`--force` 可跳过，但同版本不会触发客户端更新，等于发了个拿不到的版本（脚本会警告）。
新增的版本目录若低于该 id 的已发布最高版本，只会进该条的 `history`（脚本会提示）。

`gen-models-index.sh --dry-run` 仍会改写本地 `index.json`（不提交不推送），
看完计划记得 `git checkout -- coskey/models/`。

## 常用供应商预设（`coskey/provider/`）

app 供应商页「一键填充」读的远端列表（落点与读取方式见 coskey 仓库设计 `0003` §12 第 5 条，
客户端读取侧尚未实现，本仓先把托管入口备好）。内容来自产品仓库 coskey 的
`src/resources/provider-presets.json`，**本仓不生成**，同步过来提交即可。

```bash
# 1) 从产品仓库同步内容（含 icon：相对路径的图标必须一起拷进来才发得出去）
cp <coskey 仓库>/src/resources/provider-presets.json coskey/provider/
cp -R <coskey 仓库>/src/resources/provider-icon coskey/provider/   # 列表里写了相对路径才需要

# 2) 部署到 cosk.ai
tools/deploy-provider-presets.sh
#    加 --dry-run 只做本地自检与计划
```

| 入口 | URL |
|---|---|
| app（不缓存，立即生效） | `https://www.cosk.ai/data/app/coskey/provider/provider-presets.json` |
| 直读（缓存 600s） | `https://www.cosk.ai/data/releases/coskey/provider/provider-presets.json` |

整目录发布：`coskey/provider/` 下的文件（如 `provider-icon/`）会一并上线，列表最后落地。
脚本自检要求每条含 `id` / `name` / `base_url` / `version`，`id` 合法（同 `service::valid_id`）且不重复；
`icon` 写相对路径时本地必须有对应文件（缺了只告警，不拦发布）；写 `http(s)://` 绝对地址则运行时远端取图。
改了某条的字段就抬那条的 `version`，否则客户端拿不到更新。

## 应用插件 profile（`coskey/plugins/`）

Coskey 的 `app check` / `app repair` 读取的版本化插件名单（约定见 coskey 仓库设计 `0021` §5.3.1）。
客户端依次尝试 GitHub → Gitee → cosk.ai，cosk.ai 是保底入口。内容来自产品仓库 coskey 的
`src/resources/plugins/app-plugin-profile.json`，**本仓不生成**，同步过来提交即可。

```bash
cp <coskey 仓库>/src/resources/plugins/app-plugin-profile.json coskey/plugins/
```

```bash
# 部署到 cosk.ai
tools/deploy-app-plugin-profile.sh
#    加 --dry-run 只做本地自检与计划
```

| 入口 | URL |
|---|---|
| app（不缓存，立即生效） | `https://www.cosk.ai/data/app/coskey/plugins/app-plugin-profile.json` |
| 直读（缓存 600s） | `https://www.cosk.ai/data/releases/coskey/plugins/app-plugin-profile.json` |

整目录发布：`coskey/plugins/` 下的文件会一并上线，profile 最后落地。脚本按客户端同一套规则
自检（兼容旧的扁平 `profiles`）：`schemaVersion` 必须为 1；`platforms` 只认
`macos` / `windows` / `linux`，各平台用 `platforms.<平台>.profiles` 维护独立版本线；
所有平台与旧式列表合计至少一条 profile；`startVersion`（以及旧式的 `windowsStartVersion`）
是点分数字版本号；插件名只含字母、数字与 `-_.`；`alwaysAvailable` 缺失时按
`codex-app-tools` / `latex` / `visualize` 处理；`capabilityGated` 的值必须是非空能力名；
`platformExclusions` 只认 `macos` / `windows` / `linux`；`appMaterialized` 缺失时按
macOS 基线 `messages` 处理；写了可选 `sha256` 时，接受 platforms、profiles 或整份文件的
紧凑 / pretty 序列化，以及原始字节。

## ChatGPT.app 能力默认值（`coskey/app-capability/statsig/`）

对应 coskey 设计 `0023`。客户端读取一个按应用版本分层的索引，并从三个入口回退：

| 入口 | URL 前缀 |
|---|---|
| GitHub | `https://raw.githubusercontent.com/cosk-ai/cosk-releases/main/coskey/app-capability/statsig/` |
| Gitee | `https://gitee.com/cosk-ai/cosk-releases/raw/main/coskey/app-capability/statsig/` |
| cosk.ai | `https://www.cosk.ai/data/app/coskey/app-capability/statsig/` |

目录：

```text
coskey/app-capability/statsig/
├── index.json
├── index.json.sig
└── <appVersion>/<appBuild>/<sdkVersion>/defaults.json
```

`defaults.json` 是输入，`index.json` 由脚本生成。脚本保留最近 20 个
`appVersion`；同一应用版本下的 `appBuild` / `sdkVersion` 组合全部保留。
索引始终使用 `schemaVersion: 2`。`defaults.json` 支持混合发布：

- schema 2 / `contractVersion: 1` 继续用于旧客户端，保持 13/14-gate 固定投影；
- schema 3 / `contractVersion: 2` 带同文件 `ui` 目录，供 0.14.0+ 动态渲染；
- schema 3 不维护有效期，`defaults.json` 不写 `expiresAt`；脚本只在索引中写入
  `9999-12-31T23:59:59Z` 兼容哨兵，供旧客户端解析；
- schema 3 必须显式传 `--allow-schema3`，避免误发；
- schema 3 必须使用新的 `<appVersion>/<appBuild>/<sdkVersion>` 目录，不能覆盖
  已发布的 schema 2 路径；
- 同一版本路径的 `contractVersion` 不得变化，`--force` 也不能绕过；
- 一次发布中至少保留一个 schema 2、14-gate 条目，供仍安装了 0.13.x 的客户端使用；
- 客户端仍可只读识别既有 schema 1 缓存。

```bash
# 只校验并打印结果，不写文件
tools/publish-app-capability.sh --dry-run

# 校验并生成/更新本地 index.json；不签名、不提交、不推送、不部署
tools/publish-app-capability.sh

# 生成并签名，不提交、不推送、不部署
tools/publish-app-capability.sh --sign

# 完整发布：签名 → 提交 → Gitee/GitHub 双推 → cosk.ai 部署 → 回读核对
tools/publish-app-capability.sh --publish

# 首次加入 schema 3 时必须显式开启；正式发布同样追加 --publish
tools/publish-app-capability.sh --allow-schema3 --dry-run
```

默认签名私钥为 `~/.config/coskey-release/coskey.key`，也可用
`--signing-key` / `TAURI_SIGNING_PRIVATE_KEY_PATH` 指定。脚本使用 coskey 的 Tauri
签名器，并调用 `scripts/lib/verify-minisign.mjs` 校验 `index.json.sig`；签名前还会核对
`.key.pub` 与 coskey `gui/tauri.conf.json` 的 updater 公钥一致。私钥不会写入仓库。

已存在的 `<appVersion>/<appBuild>/<sdkVersion>` 内容若被原地修改，脚本默认拒绝；只能改用新版本
目录。`--force` 只用于同一 contract 下的明确紧急修订，不能把旧路径从 schema 2/contract 1
迁移到 schema 3/contract 2。默认模式、`--dry-run` 和 `--sign` 用于预发布检查；只有
`--publish` 会提交、推送和部署。部署时按文件合并版本目录，不会删除远端本次未包含的
旧 build/sdk 文件。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GITHUB_REMOTE` / `GITEE_REMOTE` | `origin` / `gitee` | 双平台远端名 |
| `BRANCH` | `main` | 发布分支 |
| `SITE_HOST` / `SITE_ROOT` / `DOMAIN` | `cosk-site` / `/opt/cosk/cosk-site` / `www.cosk.ai` | 站点部署目标（脚本里不写地址与账号） |

## 工程注意项

变量紧邻中文必须写成 `${VAR}`：macOS `/bin/sh` 与 `bash` 在 UTF-8 locale 下会把全角
字符的首字节并进变量名，`set -u` 下直接 `unbound variable`。本目录脚本已全部按此写法，
新增脚本请照做。
