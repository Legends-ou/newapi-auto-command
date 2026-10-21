# New API 一键部署 / 卸载脚本

一条命令把 [New API](https://github.com/QuantumNous/new-api) 装好，另一条命令把它删干净。

- **单二进制 + SQLite**：不依赖 PostgreSQL / Redis，装完即可用；
- **可选 CPA**：把订阅账号（Claude / Gemini / Codex 等）转成兼容 API，**只监听 `127.0.0.1:8317`，公网访问不到**；不想要加 `--no-cpa`；
- **管理员自己建**：装完打开网址，用 New API 的初始化页面创建（脚本不生成、也不保存你的密码）；
- **装完生成 `napi` 命令**：以后输入 `napi` 打开菜单，不用再贴 curl；
- **一键卸载**：服务、二进制、SQLite 数据、快捷命令、Nginx 站点、证书、临时文件、按需卸载的软件包，最后做残留自检；
- **不干扰现有程序**：只新增 `newapi` 用户、`/opt/new-api`、`/etc/new-api` 与自己的 systemd 单元，不动别的服务。

> 本脚本由原 Sub2API 版脚本改写而来。Sub2API 需要独立 PG 集群 + Redis 实例；New API 不需要，所以这一版简单得多。

---

## 支持环境

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 / 24.04、Debian 12 |
| 架构 | x86_64（amd64）、arm64 |
| 权限 | root（`sudo`） |
| 初始化系统 | systemd |
| 磁盘 | 二进制约 130MB，数据是单个 SQLite 文件 |
| 网络 | 能访问 GitHub Releases（国内可配 `--gh-proxy`） |

---

## 首次安装

```bash
curl -sSL https://raw.githubusercontent.com/Legends-ou/newapi-auto-command/main/deploy.sh | sudo bash
```

**第一次运行直接安装**，中途会问一次是否绑定域名：

- 答 `n` 或回车 → 装完用 `http://IP:3000` 访问；
- 答 `y` → 填域名和证书邮箱，自动装 Nginx + Let's Encrypt 证书。

装完会打印访问地址，并生成 `napi` 快捷命令。**首次打开网址会要求创建管理员**，用户名和密码由你自己设置。

不想要交互：

```bash
# 明确带 install，不问域名
curl -sSL <脚本地址> | sudo bash -s -- install

# 直接指定域名
curl -sSL <脚本地址> | sudo bash -s -- install --domain api.example.com --email you@example.com
```

---

## 装完之后：`napi`

安装会在 `/usr/local/bin/napi` 生成入口，执行本地副本 `/opt/new-api/deploy.sh`（副本丢失会自动重新拉取，非 root 自动 `sudo`）。

```bash
napi              # 全屏菜单
napi status       # 访问地址 + 服务状态 + 域名检查
napi domain       # 配置域名 / HTTPS
napi upgrade      # 升级到最新版
napi uninstall    # 卸载
```

菜单：

```
  1) 安装 / 重装（自动使用最新版）
  2) 配置域名 / HTTPS
  3) 查看状态
  4) 升级到最新版
  5) 卸载
  6) 查看凭据
  7) 重启应用
  8) 查看日志
  9) 清理旧版本备份
  0) 退出
```

> 少数 Web 终端不支持全屏或读不到输入，脚本会明确报错。此时用 `NO_TUI=1 sudo bash /opt/new-api/deploy.sh`，或直接带子命令。

---

## 命令一览

`<脚本地址>` = `https://raw.githubusercontent.com/Legends-ou/newapi-auto-command/main/deploy.sh`

| 操作 | 已装（推荐） | 未装 / 不依赖本地副本 |
| --- | --- | --- |
| 安装 / 重装 | `napi` → 1 | `curl -sSL <脚本地址> \| sudo bash -s -- install` |
| 配置域名 | `napi domain` | `... -s -- domain` |
| 查看状态 | `napi status` | `... -s -- status` |
| 升级 | `napi upgrade` | `... -s -- upgrade` |
| 查看凭据 | `napi show` | `... -s -- show` |
| 重启 | `napi restart` | `... -s -- restart` |
| 日志 | `napi logs` | `... -s -- logs` |
| 清理旧备份 | `napi clean` | `... -s -- clean` |
| 卸载 | `napi` → 5 | `... -s -- uninstall` |
| 查看脚本版本 | `napi -V` | `bash deploy.sh -V` |

`-s --` 的作用：让 bash 从标准输入读脚本，同时把它后面的内容作为脚本参数；漏掉 `--` 时命令会被当成 bash 自己的参数。

---

## 参数

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--port <端口>` | 监听端口 | `3000` |
| `--domain <域名>` | 绑定域名并启用 HTTPS | 交互时询问 |
| `--email <邮箱>` | 证书通知邮箱，用 `--domain` 时必填 | 无 |
| `--version <vX.Y.Z>` | 指定版本 | 最新 Release |
| `--gh-proxy <URL>` | GitHub 下载加速前缀 | 无 |
| `--timezone <时区>` | 时区 | `Asia/Shanghai` |
| `--lines <行数>` | `logs` 显示行数 | `100` |
| `--verbose` | 显示 apt / certbot / 下载的完整输出 | 关闭 |
| `--yes` / `-y` | 卸载时跳过确认 | 关闭 |
| `--keep-data` | 卸载前备份 SQLite 数据库 | 关闭 |
| `--no-cpa` | 不安装 CPA，只装 New API | 安装 CPA |
| `--cpa-port <端口>` | CPA 监听端口（只绑 127.0.0.1） | `8317` |
| `--cpa-version <vX.Y.Z>` | 指定 CPA 版本 | 最新 Release |

---

## 数据与备份

| 内容 | 位置 |
| --- | --- |
| 程序 | `/opt/new-api/new-api` |
| SQLite 数据库 | `/opt/new-api/data/new-api.db` |
| 日志 | `/opt/new-api/data/logs/`、`journalctl -u newapi` |
| 运行配置（密钥、端口、管理员） | `/etc/new-api/new-api.env`（600） |
| 凭据汇总 | `/etc/new-api/credentials.txt`（600） |
| 安装状态（卸载依赖） | `/etc/new-api/install-state.conf` |
| 快捷命令 | `/usr/local/bin/napi` |

备份就是拷贝那个 `.db` 文件（服务运行中建议先 `systemctl stop newapi`）。卸载时加 `--keep-data` 会自动备份到 `/var/backups/new-api-<时间>/`。

---

## CPA（把订阅转成 API）

安装默认会一并装 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)，**只监听 `127.0.0.1:8317`，公网访问不到**。不想要就加 `--no-cpa`。

### 访问 CPA 管理界面（仅管理员）

```bash
ssh -L 8317:127.0.0.1:8317 root@你的服务器IP
# 保持这个窗口，浏览器打开 http://127.0.0.1:8317/management.html
# 管理密钥见 /etc/new-api/credentials.txt 里的 CPA_MANAGE_KEY
```

### 在 CPA 里登录订阅账号

管理界面 → 选择提供商（Claude / Codex / Gemini / Antigravity）→ 走 OAuth 登录。**这一步必须在浏览器完成**，脚本替不了。

### 在 New API 里接 CPA

渠道 → 新建：

- 类型：OpenAI（兼容）
- Base URL：`http://127.0.0.1:8317/v1`
- 密钥：`credentials.txt` 里的 `CPA_API_KEY`

保存后点「测试」，通过即可给令牌使用。

> CPA 的数据与配置在 `/opt/cpa`（含 `auth/` 账号凭据）和 `/etc/cpa`，权限 600/640；卸载时一并删除。
## 升级与回滚

```bash
napi upgrade
```

会停服务 → 备份旧二进制为 `new-api.bak` → 下载最新版 → 重启，SQLite 数据保留。

回滚：

```bash
systemctl stop newapi
cp /opt/new-api/new-api.bak /opt/new-api/new-api
systemctl start newapi
```

`napi clean` 删除 `new-api.bak`。

---

## 域名与 HTTPS

```bash
napi domain
```

成功会打印访问地址；失败会自动回退到 `IP:3000`，不会把服务弄坏。证书失败时会比对 DNS 解析与本机公网 IP，不一致会直接提示。

### 域名打不开

```bash
napi status
```

会显示访问地址，并检查：DNS 是否指向本机、Nginx 是否运行、80 是否监听、证书是否签发。

按频率排查：

1. **云安全组没放行 80/443**（最常见，阿里云/腾讯云控制台，脚本改不了）；
2. **只做了 DNS，没配域名模式**（`status` 里没有「域名」那行）；
3. **Nginx 没起来**：`systemctl status nginx`、`nginx -t`；
4. **证书没签发**：修好 80 后重跑 `napi domain`。

---

## 卸载

```bash
napi uninstall            # 会先问一次
napi uninstall --yes      # 不问
napi uninstall --keep-data   # 先备份数据库再删
```

清理：systemd 单元、`/opt/new-api`、`/etc/new-api`、`/usr/local/bin/napi`、`/tmp/newapi-deploy-apt.log`、系统用户、Nginx 站点与脚本申请的证书、ufw 规则、按需卸载的 Nginx/certbot，最后逐项残留自检。

---

## 常见问题

**下载慢 / 失败**

```bash
sudo bash /opt/new-api/deploy.sh install --gh-proxy https://ghproxy.net/
```

**端口 3000 被占用**

```bash
sudo bash /opt/new-api/deploy.sh install --port 3001
```

**打开网址是「创建管理员」页面**

这是**正常现象**：脚本不自动建号，请在这个页面设置你自己的管理员用户名和密码。创建完成后 `napi status` 会显示「管理后台：已初始化」。

**管理员密码忘了**

账号密码由你创建时自己设置，脚本不保存。当前版本**不支持重置**（New API 账号密码用 Argon2id，没法用普通工具生成哈希写库）。请务必记牢；确实忘了只能删库重建（会丢数据）。

所以请第一时间保存好 `credentials.txt`。

**装完打不开**

1. `napi status`
2. `curl -i http://127.0.0.1:3000/api/status`
3. `ufw status`；云服务器还要在安全组放行端口

---

## 验证状态

- `bash -n` 通过；`--help`、非法端口、非 root 分支本机实测；
- `POST /api/setup` 的字段、`/api/status` 的健康检查端点、Release 资产命名（`new-api-vX.Y.Z` / `new-api-arm64-vX.Y.Z`）均按当前源码核对；
- **CPA 部分未真机验证**（下载、启动、`/v1/models` 鉴权、SSH 隧道访问均未实测）；
- **本版脚本尚未在真实 Linux 上跑通一次完整安装**（上一版 Sub2API 脚本的真机经验已复用，但 New API 的下载、建库、setup 三段仍需真机确认）。
