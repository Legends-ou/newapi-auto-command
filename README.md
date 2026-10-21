# New API 一键部署脚本

在 Debian / Ubuntu 上用一条命令装好 [New API](https://github.com/QuantumNous/new-api)：单二进制 + SQLite，自动配置 systemd，可选绑定域名并签发 HTTPS 证书，需要时再装 CPA 接管订阅账号。卸载同样一条命令，清理干净。

```
Debian 12+ / Ubuntu 22.04+  ·  amd64 / arm64  ·  root  ·  无数据库依赖
```

---

## 目录

- [为什么用它](#为什么用它)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [菜单](#菜单)
- [命令](#命令)
- [参数](#参数)
- [安装做了什么](#安装做了什么)
- [访问与首次配置](#访问与首次配置)
- [域名与 HTTPS](#域名与-https)
- [CPA（可选）](#cpa可选)
- [数据与备份](#数据与备份)
- [升级与回滚](#升级与回滚)
- [卸载](#卸载)
- [安全说明](#安全说明)
- [常见问题](#常见问题)
- [版本策略](#版本策略)
- [许可](#许可)

---

## 为什么用它

| 你可能会遇到 | 这个脚本的做法 |
| --- | --- |
| 官方部署要 Docker / Compose，还要自己写 compose 文件 | 直接下载官方 Release 单二进制，systemd 托管 |
| 要额外装 PostgreSQL / Redis | 不需要，数据存 SQLite（`/opt/new-api/data/new-api.db`） |
| 装完还要打开网页向导初始化 | 装完打开网页，自己创建管理员即可（脚本不生成、不保存你的密码） |
| 想上 HTTPS 又要手动配 Nginx + certbot | `napi domain` 一条命令，失败自动回退到 IP:端口 |
| 卸载后留下服务、用户、证书、快捷命令 | 卸载会逐项清理并做残留自检 |
| 想用 Claude / Gemini 等订阅账号 | 可选装 CPA，默认只监听 `127.0.0.1`，不暴露公网 |

它**不**做的事：不接管你的账号密码、不内置任何密钥、不在后台偷偷更新自己。

---

## 环境要求

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 / 24.04、Debian 12 |
| 架构 | x86_64（amd64）、arm64 |
| 权限 | root（`sudo`） |
| 初始化系统 | systemd |
| 网络 | 可访问 GitHub Releases（国内可用 `--gh-proxy`） |
| 磁盘 | 二进制约 130MB + SQLite 数据 |

---

## 快速开始

```bash
curl -sSL https://raw.githubusercontent.com/Legends-ou/newapi-auto-command/main/deploy.sh | sudo bash
```

首次运行**直接安装**，过程中会问一次是否绑定域名：

- 回车 / `n` → 装完用 `http://IP:3000` 访问；
- `y` → 填域名和证书邮箱，自动配置 Nginx + Let's Encrypt。

安装完成后会：

- 打印访问地址、凭据文件位置；
- 生成 `napi` 快捷命令（以后不用再贴 curl）；
- 输出下一步该做什么。

不想要交互：

```bash
# 只装 New API，不问域名
curl -sSL <脚本地址> | sudo bash -s -- install

# 一步到位：域名 + 证书
curl -sSL <脚本地址> | sudo bash -s -- install --domain api.example.com --email you@example.com

# 顺带装 CPA
curl -sSL <脚本地址> | sudo bash -s -- install --with-cpa
```

---

## 菜单

安装后执行 `napi`（非 root 会自动 `sudo`）：

```
  脚本版本：v1.5.4（2026-10-21）
  当前状态：已安装 v1.0.0-rc.45

  1) 安装 / 重装（自动使用最新版）
  2) 查看状态
  3) 配置域名 / HTTPS
  4) 升级到最新版
  5) 重启应用
  6) 查看日志

  7) 查看凭据
  8) 重新生成凭据
  9) 更新脚本本身
 10) 清理旧版本备份
 11) CPA 管理（安装 / 开放 / 收回）

 12) 卸载
  0) 退出
```

- 每一项**独占一页**：选中后先清屏，看完按回车回到菜单；
- 退出：主菜单按 `0` 或 `q`；操作完成后的提示处按 `q` 可直接退出；
- CPA 子菜单（11）：开放公网 / 收回 / 查看状态与密钥 / 安装修复 / 卸载。

> 部分网页版 SSH 终端不支持全屏（备用屏），菜单可能显示异常。建议用 Windows Terminal、Xshell、FinalShell 等本地终端连接。

---

## 命令

`<脚本地址>` = `https://raw.githubusercontent.com/Legends-ou/newapi-auto-command/main/deploy.sh`

| 操作 | 已安装（推荐） | 不依赖本地副本 |
| --- | --- | --- |
| 安装 / 重装 | `napi` → 1 | `curl -sSL <脚本地址> \| sudo bash -s -- install` |
| 查看状态 | `napi status` | `... -s -- status` |
| 配置域名 | `napi domain` | `... -s -- domain` |
| 升级 | `napi upgrade` | `... -s -- upgrade` |
| 重启 | `napi restart` | `... -s -- restart` |
| 日志 | `napi logs` | `... -s -- logs` |
| 查看凭据 | `napi show` | `... -s -- show` |
| 重新生成凭据 | `napi cred` | `... -s -- cred` |
| 更新脚本本身 | `napi self-update` | `... -s -- self-update` |
| 清理旧备份 | `napi clean` | `... -s -- clean` |
| CPA 安装 / 开放 / 收回 | `napi` → 11 | `... -s -- cpa [--cpa-expose\|--cpa-hide]` |
| 卸载 CPA | `napi` → 11 → 5 | `... -s -- cpa --cpa-remove` |
| 卸载全部 | `napi` → 12 | `... -s -- uninstall` |
| 查看脚本版本 | `napi -V` | `bash deploy.sh -V` |

`-s --` 的作用：让 bash 从标准输入读脚本，同时把它后面的内容作为脚本参数；漏掉 `--` 时命令会被当成 bash 自己的参数。

---

## 参数

| 分组 | 参数 | 说明 | 默认 |
| --- | --- | --- | --- |
| 监听与域名 | `--port <端口>` | New API 监听端口 | `3000` |
| | `--domain <域名>` | 绑定域名并自动申请 HTTPS | 交互询问 |
| | `--email <邮箱>` | 证书通知邮箱（配合 `--domain`） | 无 |
| 版本与网络 | `--version <vX.Y.Z>` | 指定 New API 版本 | 最新 Release |
| | `--gh-proxy <URL>` | GitHub 下载加速前缀 | 无 |
| | `--timezone <时区>` | 时区 | `Asia/Shanghai` |
| CPA | `--with-cpa` | 安装时一并装 CPA | 不装 |
| | `--cpa-remove` | 卸载 CPA（保留 New API） | — |
| | `--cpa-port <端口>` | CPA 端口（只绑 127.0.0.1，除非 `--cpa-expose`） | `8317` |
| | `--cpa-version <vX.Y.Z>` | 指定 CPA 版本 | 最新 Release |
| | `--cpa-expose` | 临时开放 CPA 管理界面到公网 | 关闭 |
| | `--cpa-hide` | 收回 CPA，只监听本机 | 关闭 |
| 维护 | `--lines <行数>` | `logs` 显示行数 | `100` |
| | `--verbose` | 显示 apt / certbot / 下载的完整输出 | 关闭 |
| 卸载 | `--yes` | 跳过确认 | 关闭 |
| | `--keep-data` | 先备份 SQLite 再删除 | 关闭 |
| 其他 | `-h, --help` | 显示帮助 | — |
| | `-V, --script-version` | 只看脚本版本 | — |

---

## 安装做了什么

| 类别 | 内容 |
| --- | --- |
| 系统包 | 仅在缺失时装：`ca-certificates` `curl` `tar` `openssl` `iproute2`；配域名时再装 `nginx` `certbot` `python3-certbot-nginx` |
| 应用 | 下载官方 Release `new-api-<tag>`（amd64）或 `new-api-arm64-<tag>`，SHA-256 校验后安装到 `/opt/new-api/new-api` |
| 系统资源 | 用户 `newapi`、目录 `/opt/new-api`、`/etc/new-api`、systemd 单元 `newapi.service` |
| 配置 | `/etc/new-api/new-api.env`（端口、SQLite 路径、会话密钥，600） |
| 快捷命令 | `/usr/local/bin/napi` + 本地副本 `/opt/new-api/deploy.sh` |
| 域名模式 | Nginx 站点 `/etc/nginx/sites-available/new-api.conf` + Let's Encrypt 证书 |
| CPA（可选） | `/opt/cpa`（二进制与 OAuth 凭据）、`/etc/cpa`（配置与密钥）、`cpa.service`、用户 `cpa` |

**不会**安装 PostgreSQL、Redis、Docker、Go、Node.js，也不会改动机器上已有的数据库和其他站点。

---

## 访问与首次配置

装完打开 `http://<服务器IP>:3000`（或你的域名），**首次访问会让你创建管理员**：

- 用户名、密码由你自己设置，脚本不生成也不保存；
- 创建完成后 `napi status` 会显示「管理后台：已初始化」。

创建后建议进入 **设置 → 系统设置**：

- 把站点地址填成你的域名（否则邮件里的链接会用 IP）；
- 按需调整注册开关、额度等。

---

## 域名与 HTTPS

```bash
napi domain
```

会依次：安装 Nginx/certbot → 写反向代理 → 申请证书 → 把应用改成只监听 `127.0.0.1` → 输出 `https://你的域名`。

前提：

1. 域名 A 记录已指向本机公网 IP；
2. 云安全组放行 **80、443**（脚本改不了安全组）；
3. 本机没有其他程序占用 80。

失败时不会弄坏服务：自动回退到 `IP:端口` 访问，并提示 DNS 与公网 IP 是否一致。

检查现状：

```bash
napi status
```

会显示 DNS 解析、Nginx 状态、80 端口监听、证书签发情况。

---

## CPA（可选）

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 把 Claude / Codex / Gemini / Antigravity 等 CLI 订阅账号转成兼容 API，再由 New API 作为渠道对外提供。

**默认不安装。** 需要时：

```bash
napi cpa                # 安装 / 修复
napi                    # 选 11 → 1 临时开放公网
napi                    # 选 11 → 2 收回
napi cpa --cpa-remove   # 卸载 CPA，保留 New API
```

### 安全默认

- 只监听 `127.0.0.1:8317`，公网访问不到；
- 管理密钥与渠道密钥随机生成，权限 600/640；
- `auth/` 目录 700，只有 `cpa` 用户可读；
- systemd 沙箱（`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`）；
- 管理界面默认需 SSH 隧道：

  ```bash
  ssh -L 8317:127.0.0.1:8317 root@你的服务器
  # 浏览器打开 http://127.0.0.1:8317/management.html
  ```

### 接入 New API

渠道 → 新建：

- 类型：**OpenAI（兼容）**
- Base URL：`http://127.0.0.1:8317/v1`
- 密钥：`/etc/new-api/credentials.txt` 里的 `CPA_API_KEY`

保存后点「测试」，通过即可给令牌使用。

> CPA 的 `/management.html` 是**启动时从 GitHub 下载**的官方面板。下载失败会 404，脚本会提示；此时可手动放一份到 `/opt/cpa/static/management.html` 后 `systemctl restart cpa`。

> OAuth 登录必须在浏览器完成，脚本无法代劳。

---

## 数据与备份

| 内容 | 位置 |
| --- | --- |
| 程序 | `/opt/new-api/new-api` |
| 数据库 | `/opt/new-api/data/new-api.db` |
| 应用日志 | `/opt/new-api/data/logs/`、`journalctl -u newapi` |
| 运行配置 | `/etc/new-api/new-api.env`（600） |
| 凭据汇总 | `/etc/new-api/credentials.txt`（600） |
| 安装状态 | `/etc/new-api/install-state.conf`（卸载依赖） |
| CPA 配置 | `/etc/cpa/config.yaml`、`/etc/cpa/cpa.env` |

备份：停服务后拷贝 `.db` 文件即可。卸载时加 `--keep-data` 会自动备份到 `/var/backups/new-api-<时间>/`。

---

## 升级与回滚

```bash
napi upgrade      # 更新应用二进制，并顺带更新脚本副本
napi self-update  # 只更新脚本
```

- 升级会先停服务、把旧二进制备份为 `new-api.bak`、再替换并重启，SQLite 数据保留；
- 回滚：

  ```bash
  systemctl stop newapi
  cp /opt/new-api/new-api.bak /opt/new-api/new-api
  systemctl start newapi
  ```

- `napi clean` 删除 `new-api.bak`。

---

## 卸载

```bash
napi                              # 选 12
napi uninstall --yes
napi uninstall --yes --keep-data  # 先备份数据库
```

清理内容：

- `newapi.service`、`cpa.service`（如安装）
- `/opt/new-api`、`/etc/new-api`、`/opt/cpa`、`/etc/cpa`
- `/usr/local/bin/napi`、`/tmp/newapi-deploy-apt.log`
- 用户 `newapi`、`cpa`
- Nginx 站点与脚本申请的证书
- ufw 中为它添加的放行规则
- 仅当没有其他站点时，卸载脚本安装的 Nginx / certbot

最后会做**残留自检**，逐项列出还存在的问题。不会动其他服务、数据库或站点。

---

## 安全说明

- 脚本以 root 运行，安装前可先通读源码；
- 密钥文件均为 600，只有 root 可读；
- 不内置任何账号、Key 或后门；
- **不会静默自动更新**：只有显式执行 `self-update` / `upgrade` 才会拉取新脚本，且更新前做 `bash -n` 校验、原子替换；
- CPA 默认不暴露公网，开放是显式操作且可随时收回；
- 卸载前会断言目标路径（`/opt/new-api`、`/etc/new-api`），避免误删。

---

## 常见问题

**安装卡住 / 下载慢**

```bash
sudo bash /opt/new-api/deploy.sh install --gh-proxy https://ghproxy.net/
```

**3000 端口打不开**

1. `napi status` 看服务与健康检查；
2. `ufw status`，以及云服务器安全组是否放行 3000（或 80/443）；
3. `journalctl -u newapi -n 50`。

**域名打不开**

- `napi status` 会检查 DNS、Nginx、80、证书；
- 最常见原因是安全组没放行 80/443，或 DNS 还没生效。

**打开是「创建管理员」页面**

正常现象。脚本不自动建号，请在该页面设置你自己的用户名和密码。

**管理员密码忘了**

账号由你创建时设置，脚本不保存。New API 用 Argon2id 哈希，当前不支持重置，只能删库重建（会丢数据），请务必记牢。

**CPA 管理页 404**

面板启动时从 GitHub 下载失败。看 `journalctl -u cpa -n 50 | grep -i management`，或手动放入 `/opt/cpa/static/management.html` 后重启。

**菜单显示异常 / 清屏无效**

网页版 SSH 终端可能不支持备用屏与 ANSI 清屏，建议改用 Windows Terminal、Xshell、FinalShell 等本地终端。

**怎么确认脚本版本**

```bash
napi -V
```

菜单顶部与 `napi status` 也会显示。

---

## 版本策略

- 仓库始终指向官方**最新 Release**，上游发版后重跑 `install` / `upgrade` 即可，无需改脚本；
- `--version` 可临时锁定版本；
- 脚本自身有独立版本号（`napi -V`），变更见 [CHANGELOG.md](CHANGELOG.md)。

---

## 许可

[MIT](LICENSE)

---

相关项目：[New API](https://github.com/QuantumNous/new-api) · [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
