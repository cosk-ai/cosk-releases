# tools

发布仓侧的操作脚本。**产品仓库不重复实现这里的逻辑**：清单/索引在本仓生成，
由本仓推双平台并部署到 cosk.ai，产品仓库只提供内容与文档指引。

## 元模板（`coskey/models/`）

app 的「元模板更新」读取的索引与模板（约定见 coskey 仓库 `0018` §5.0）。
`index.json` 是**生成物**，不要手写。

```bash
# 1) 生成 index.json 并推双平台
tools/gen-models-index.sh --from <模板目录> --version <id>=<semver>
#    模板目录可直接用 coskey 仓库的 src/resources/model-catalog/
#    多个模板给多个 --version，或用 --version-file（每行 `<id> <semver>`）
#    加 --dry-run 只看计划

# 2) 部署到 cosk.ai
tools/deploy-models.sh
#    加 --dry-run 只做本地自检与计划
```

| 脚本 | 职责 |
|---|---|
| `gen-models-index.sh` | 扫描 `coskey/models/*.json` → 生成 `index.json` → 提交并推送 GitHub + Gitee |
| `deploy-models.sh` | 自检（索引与 sha256 对应）→ 传站点 → 原子就位 → 回读核对 |
| `deploy-provider-presets.sh` | 自检（列表字段、id 合法且不重复）→ 传站点 → 原子就位 → 回读核对 |

**版本规则**（`index.json` 是版本事实源，客户端只在版本更高时提示更新）：

| 情形 | 要求 |
|---|---|
| 新模板 | 必须给版本，否则拒绝 |
| 内容有变化 | 版本必须**高于**已发布版本，否则拒绝 |
| 内容无变化 | 沿用已记录版本（允许重发/补传） |

所以**已发布的模板内容不可原地改**：改了内容就必须抬版本，否则客户端拿不到更新。
`--force` 可跳过，但同版本不会触发客户端更新，等于发了个拿不到的版本（脚本会警告）。

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
