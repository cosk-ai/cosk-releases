# cosk-releases

cosk 家族产品的发布产物与更新清单。

本仓库是 cosk 家族产品（coskey 等）的发布基础设施，托管：

- **发布产物**：各产品/平台的安装包与签名文件，经 GitHub Releases 与
  Gitee 发行版发布；
- **更新清单**：客户端应用自动更新读取的 `latest.json`。

## 目录约定

每个产品一个目录：

```
cosk-releases/
├── coskey/                  # 示例产品
│   ├── github/latest.json   # 清单：产物 URL → github.com
│   ├── gitee/latest.json    # 清单（同版本）：产物 URL → gitee.com
│   └── notes/               # 更新说明
└── …
```

清单提交在仓库树中（不作为 release 附件）；两份清单仅产物 URL 主机名不同，
与所在镜像对应。

## 下载与镜像

| 镜像 | 发行页 |
|---|---|
| GitHub | https://github.com/cosk-ai/cosk-releases/releases |
| Gitee | https://gitee.com/cosk-ai/cosk-releases/releases |

客户端自动测速并选择较快的镜像。tag 形如 `<产品>-v<semver>`
（例：`coskey-v0.1.0`）。

## 许可

产物、清单与更新说明遵循对应产品仓库的许可协议。
