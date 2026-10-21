# HANDOFF — New API 一键部署脚本

## 1. 元信息

| 项 | 内容 |
| --- | --- |
| 最后更新 | 2026-10-21 |
| 当前版本 | v1.5.4 |
| 定位 | 可对外发布的单文件部署器（产品形态） |
| 上游应用 | [QuantumNous/new-api](https://github.com/QuantumNous/new-api) |
| 可选组件 | [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) |
| 仓库 | `Legends-ou/newapi-auto-command` |
| 状态 | 已可用；New API 安装链路真机跑通，交互体验持续修 |

## 2. 一句话定位

在 Debian / Ubuntu 上用一条命令装好 New API（单二进制 + SQLite，systemd 托管），可选中装 CPA 接管订阅账号；再一条命令干净卸载。

## 3. 产品目标

1. 用户不需要 Docker、PG、Redis，也不需要网页初始化向导；
2. 装完即可访问，管理员由用户首次访问时自建（脚本不碰密码）；
3. 能配域名 HTTPS、升级、回滚、诊断；
4. 卸载不留服务、用户、证书、快捷命令，且不影响同机其他服务；
5. 可选 CPA 默认不装、默认只监听本机，需要时再开放。

## 4. 当前进度

| 项 | 状态 |
| --- | --- |
| 安装（二进制 + SQLite + systemd） | ✅ 用户真机跑通（v1.0.0-rc.45） |
| 菜单 / `napi` / 状态 / 升级 / 卸载 | ✅ 代码完成 |
| 域名 + HTTPS | ✅ 代码完成，未真机验证 |
| CPA 安装 / 开放 / 收回 / 卸载 | ✅ 代码完成，未真机验证 |
| 脚本自更新（原子替换） | ✅ 代码完成 |
| 交互体验（分页、退出、未安装态） | ✅ 本轮修复，待用户实机确认 |
| 文档（README / CHANGELOG） | ✅ 已按产品形态重写 |

## 5. 功能清单

| 功能 | 入口 | 说明 |
| --- | --- | --- |
| 安装 / 重装 | 菜单 1 / `install` | 下载官方 Release，SHA-256 校验 |
| 查看状态 | 菜单 2 / `status` | 地址、版本、SQLite、健康、管理后台初始化、CPA、域名四项检查 |
| 域名 HTTPS | 菜单 3 / `domain` | Nginx + certbot，失败回退 IP:端口 |
| 升级 | 菜单 4 / `upgrade` | 备份 `new-api.bak`，数据保留，顺带刷新脚本 |
| 重启 | 菜单 5 / `restart` | 健康检查 |
| 日志 | 菜单 6 / `logs` | `journalctl` 跟踪 |
| 查看凭据 | 菜单 7 / `show` | 600 权限文件 |
| 重新生成凭据 | 菜单 8 / `cred` | 不重装 |
| 更新脚本 | 菜单 9 / `self-update` | 下载 + `bash -n` + 原子替换 |
| 清理备份 | 菜单 10 / `clean` | 删除 `new-api.bak` |
| CPA 管理 | 菜单 11 子菜单 | 开放 / 收回 / 状态 / 安装修复 / 卸载 |
| 卸载全部 | 菜单 12 / `uninstall` | 含 CPA，残留自检，`--keep-data` 备份 |

## 6. 关键实现点（改前必读）

1. **不自动建管理员**：New API 密码是 Argon2id，脚本无法生成；管理员由用户首次访问网页创建。
2. **CPA 面板是下载的**：`/management.html` 来自 GitHub Release，启动时下载到 `MANAGEMENT_STATIC_PATH`（默认配置同级）；配置在 `/etc/cpa` 不可写，故显式设为 `/opt/cpa/static`。
3. **CPA 资产命名**：`CLIProxyAPI_<ver>_linux_<arch>.tar.gz`，tag 去掉 `v`，校验文件 `checksums.txt`，二进制 `cli-proxy-api`。
4. **CPA 默认只监听 127.0.0.1**：`--cpa-expose` 改 `0.0.0.0` + `allow-remote: true`，`--cpa-hide` 收回并撤销 ufw。
5. **脚本自更新必须原子**：`save_self` / `self-update` 用同目录临时文件 + `mv`，否则运行中的脚本被截断会导致菜单闪退（v1.5.1 修）。
6. **菜单分页**：进入菜单、执行动作前都要 `tui_clear`；子菜单选 0 返回时用 `SKIP_MENU_PAUSE` 跳过主菜单的"按回车"。
7. **卸载断言路径**：`/opt/new-api`、`/etc/new-api`；卸载状态存 `/etc/new-api/install-state.conf`。
8. **`pipefail` 陷阱**：不要用 `| head`、`| grep -q`、`awk ... exit` 这类提前退出的管道（会 141），用 `sed -n '1p'` / `awk 'END{exit}'`。

## 7. 目录与文件

```text
newapi-auto-command/
├── deploy.sh          # 唯一脚本（约 2000 行）
├── README.md          # 产品文档
├── CHANGELOG.md       # 脚本版本变更
├── HANDOFF.md         # 本文件（.gitignore，不发布）
├── LICENSE            # MIT
├── .gitignore
└── .gitattributes     # 强制 LF，避免 curl | bash 报 \r
```

服务器端：

```text
/opt/new-api/new-api           二进制
/opt/new-api/data/new-api.db   SQLite
/opt/new-api/deploy.sh         脚本副本（napi 用）
/etc/new-api/new-api.env       运行配置（600）
/etc/new-api/credentials.txt   凭据（600）
/etc/new-api/install-state.conf 卸载状态
/usr/local/bin/napi            快捷命令
/opt/cpa/cli-proxy-api         CPA（可选）
/opt/cpa/static/               CPA 管理面板
/etc/cpa/config.yaml           CPA 配置（640 root:cpa）
```

## 8. 已知问题与风险

- **交互仅在部分终端验证**：网页版 SSH 可能不支持备用屏/清屏，表现为菜单叠加；建议本地终端。
- **域名与 CPA 链路未真机验证**：Nginx/certbot、CPA 下载启动、面板下载、SSH 隧道均待实测。
- **CPA 面板依赖 GitHub**：服务器访问不了 GitHub 时 404，需手动放置 `management.html`。
- **不能重置管理员密码**：Argon2id，只能删库重建。
- **New API 当前最新为 RC**（`v1.0.0-rc.*`），升级可能遇到行为变化。
- **CPA 有 ToS 风险**：把订阅账号转 API 可能违反上游条款。

## 9. 后续目标

1. 域名 + HTTPS 真机验证（含证书失败回退）。
2. CPA 全链路验证：下载、启动、面板、OAuth、New API 渠道测试。
3. 交互在 Windows Terminal / Xshell / 网页 SSH 三类的表现确认，必要时加非全屏模式。
4. 可选：面板自动重试下载、CPA 版本升级命令。
5. 发布：GitHub Release 打 tag（v1.5.4），README 增加截图。

## 10. 交接须知

- 改脚本后必须同步：`SCRIPT_VERSION`、`CHANGELOG.md`、`README.md` 中的版本与菜单、本文件 §4。
- 不要删除 `install-state.conf` 的读写逻辑，卸载的证书/包清理依赖它。
- 不要把 `SQLITE_PATH` 指到 `/opt/new-api` 之外（systemd 沙箱）。
- 不要把 CPA 管理面板目录指回 `/etc/cpa`（cpa 用户不可写）。
- 文档里的命令必须与 `parse_args` 一一对应；新增命令要同时更新 usage、菜单、README、CHANGELOG。
