# Sub2API 一键部署 / 卸载脚本

一条命令把 [Sub2API](https://github.com/Wei-Shaw/sub2api) 完整装好，另一条命令把它**干净地**删掉。

- **首次运行就是安装**：自动创建独立的 PostgreSQL 集群与 Redis 实例、下载官方 Release、注册 systemd、自动建管理员，不需要手动装数据库，也不需要打开网页设置向导；
- **装完生成 `sub` 命令**：以后输入 `sub` 就能打开配置菜单，不用再贴那串 curl；
- **一键卸载**：服务、独立集群、缓存实例、目录、用户、快捷命令、临时日志、软件包、apt 源一起清理，最后做残留自检；
- **不干扰现有程序**：不改系统原有的 PostgreSQL / Redis 配置，不重启它们的服务，不占用它们的数据目录和端口。

---

## 为什么需要它

官方 `deploy/install.sh` 只做三件事：下载二进制、建系统用户、装 systemd 服务。PostgreSQL、Redis、数据库配置、管理员账号全留给用户，装完还得在浏览器里逐项填向导。官方的 Docker 方案则要求先有 Docker。

本脚本补上这段空缺，同时避开"装一个东西弄坏另一个"的常见坑。

---

## 它怎么做到不影响现有程序

| 资源 | 做法 | 卸载时 |
| --- | --- | --- |
| PostgreSQL | 创建**独立集群** `<版本>/sub2api`，独立端口（5433 起自动找空闲）、独立数据目录 | `pg_dropcluster` 只删这个集群 |
| PostgreSQL 版本 | 优先用发行版自带的：Ubuntu 24.04 → 16、Debian 12 → 15；低于 15 才添加 PGDG 源装 16 | 只卸载自己装的版本 |
| Redis | 起**独立实例** `sub2api-redis`，独立端口（6380 起）、独立配置 `/etc/sub2api/redis.conf`、独立数据 `/opt/sub2api/redis-data` | 停服务、删单元与数据目录 |
| 系统 Redis | **完全不碰** `/etc/redis/redis.conf`，不重启 `redis-server`；系统自带低于 7 时编译独立副本，不升级系统包 | 原文件与状态不变 |
| 系统 PostgreSQL | **不 enable、不 restart** 全局 `postgresql`，只操作自己的集群 | 其他集群照常运行 |
| 端口 | 主动避开 5432 / 6379；应用 8080 被占用会直接报错而不是抢占 | 释放自己用的端口 |
| Nginx | 只新增 `sub2api.conf` 一个站点，reload 不影响其他站点 | 删文件后 reload |
| ufw | 只 `allow` 需要的端口 | 按记录 `delete` 对应规则 |
| 软件包 | 只装缺的，并记录哪些是本次装的 | 确认无其他使用者后才卸载 |

**装包副产物也会清掉**：安装 PostgreSQL 时 apt 会自动建一个空的 `main` 集群占住 5432，脚本会识别并删除它（仅当安装前没有该版本集群）；Redis 包会自动启用 6379 的默认服务，脚本会 `disable --now` 它。

**网络请求都有超时**：`curl` 带 `--connect-timeout / --max-time`，`apt` 带 `Acquire::http(s)::Timeout`，镜像不可达时快速失败并打印原因，不会无限卡住。

---

## 支持环境

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 / 24.04、Debian 12 |
| 架构 | x86_64（amd64）、arm64 |
| 权限 | root（`sudo`） |
| 初始化系统 | systemd |
| 内存 | 建议 ≥ 1 GB；小于 1.5 GB 且无 swap 时会提示（PG + Redis + 应用可能 OOM） |
| 网络 | 能访问 GitHub Releases 与系统软件源（国内建议配 `--gh-proxy`） |

---

## 首次安装

```bash
curl -sSL https://raw.githubusercontent.com/Legends-ou/sub2api-auto-command/main/deploy.sh | sudo bash
```

**第一次运行直接进入安装**（不显示菜单），中途会问一次：

```
是否绑定域名并启用 HTTPS？(y/N)
```

- 答 `n` 或直接回车 → 装完用 `IP:8080` 访问；
- 答 `y` → 再填域名和证书邮箱，自动装 Nginx + 申请 Let's Encrypt 证书。

装完会打印访问地址和管理员账号密码，并生成 `sub` 快捷命令。

### 不想要交互

```bash
# 明确带 install，不会询问域名
curl -sSL <脚本地址> | sudo bash -s -- install

# 直接指定域名
curl -sSL <脚本地址> | sudo bash -s -- install --domain api.example.com --email you@example.com
```

非交互环境（CI、无终端）本身就是直接安装，不会停下来等输入。

---

## 装完之后：`sub` 快捷命令

安装会在 `/usr/local/bin/sub` 生成一个入口，执行的是本地副本 `/opt/sub2api/deploy.sh`（副本丢失时会自动重新拉取，非 root 会自动 `sudo`）。

```bash
sub              # 打开全屏菜单
sub status       # 查看状态（含访问地址与域名检查）
sub domain       # 配置域名 / HTTPS
sub passwd       # 重置管理员密码
sub uninstall    # 卸载
```

菜单是全屏界面（备用屏），退出后原来的终端内容原样恢复：

```
  1) 安装 / 重装（自动使用最新版）
  2) 配置域名 / HTTPS
  3) 查看状态
  4) 升级到最新版
  5) 卸载
  6) 重置管理员密码
  7) 查看凭据
  8) 重启应用
  9) 查看日志
 10) 清理旧版本备份
  0) 退出
```

> 少数 Web 终端不支持全屏或读不到输入，脚本会明确报错。此时用 `SUB2API_NO_TUI=1 sudo bash /opt/sub2api/deploy.sh`，或直接带子命令执行。

---

## 命令一览

`<脚本地址>` = `https://raw.githubusercontent.com/Legends-ou/sub2api-auto-command/main/deploy.sh`

| 操作 | 已装（推荐） | 未装 / 不依赖本地副本 |
| --- | --- | --- |
| 安装 / 重装 | `sub` → 选 1 | `curl -sSL <脚本地址> \| sudo bash -s -- install` |
| 配置域名 / HTTPS | `sub domain` | `curl -sSL <脚本地址> \| sudo bash -s -- domain` |
| 查看状态 | `sub status` | `curl -sSL <脚本地址> \| sudo bash -s -- status` |
| 升级到最新版 | `sub upgrade` | `curl -sSL <脚本地址> \| sudo bash -s -- upgrade` |
| 重置管理员密码 | `sub passwd` | `curl -sSL <脚本地址> \| sudo bash -s -- passwd` |
| 查看凭据 | `sub show` | `curl -sSL <脚本地址> \| sudo bash -s -- show` |
| 重启应用 | `sub restart` | `curl -sSL <脚本地址> \| sudo bash -s -- restart` |
| 跟踪日志 | `sub logs` | `curl -sSL <脚本地址> \| sudo bash -s -- logs` |
| 清理旧备份 | `sub clean` | `curl -sSL <脚本地址> \| sudo bash -s -- clean` |
| 卸载 | `sub` → 选 5 | `curl -sSL <脚本地址> \| sudo bash -s -- uninstall` |

`-s --` 的作用：让 bash 从标准输入读脚本，同时把它后面的内容作为脚本参数；漏掉 `--` 时 `uninstall` 会被当成 bash 自己的参数。

---

## 参数一览

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--port <端口>` | 应用监听端口 | `8080` |
| `--domain <域名>` | 绑定域名并启用 HTTPS | 交互时询问 |
| `--email <邮箱>` | 证书通知邮箱，用 `--domain` 时必填 | 无 |
| `--admin-email <邮箱>` | 管理员登录账号 | 随机 `admin-xxxxxx@sub2api.local` |
| `--admin-password <密码>` | 管理员密码（8–72 字节） | 随机 24 位十六进制 |
| `--version <vX.Y.Z>` | 指定版本 | 最新 Release |
| `--gh-proxy <URL>` | GitHub 下载加速前缀 | 无 |
| `--timezone <时区>` | 应用时区 | `Asia/Shanghai` |
| `--yes` / `-y` | 卸载时跳过确认 | 关闭 |
| `--keep-data` | 卸载前备份数据库与缓存数据 | 关闭 |
| `--lines <行数>` | `logs` 命令显示的行数 | `100` |
| `--verbose` | 显示 apt / certbot / 下载的完整输出（排障用） | 关闭 |

---

## 版本策略：始终跟随上游最新版

脚本**不锁定** Sub2API 版本：

- 不带 `--version` 时，每次都向 `releases/latest` 取最新 Release 再下载；
- 已装过旧版时重跑安装或执行 `upgrade`，都会重新解析最新版并替换二进制，数据与账号保留；
- `--version` 只是可选的临时手段（回滚或固定排查），不写进任何配置。

> `deploy.sh` 里的 `REDIS_BUILD_VERSION` 是「系统 Redis 低于 7 时编译独立副本」用的 Redis 版本，与 Sub2API 版本无关。

---

## 域名与 HTTPS

已装好的机器随时可以补配：

```bash
sub domain
# 或
sudo bash /opt/sub2api/deploy.sh domain --domain api.example.com --email you@example.com
```

成功后会打印访问地址；失败会自动回退到 `IP:端口`，不会把服务弄坏。

### 域名打不开怎么查

```bash
sub status
```

它会直接显示**访问地址**，并做四项检查：DNS 是否指向本机、Nginx 是否运行、80/443 是否在监听、证书是否签发。

按出现频率排查：

1. **云安全组没放行 80/443**（最常见）。阿里云 / 腾讯云要在控制台安全组里加规则，脚本改不了；
2. **只做了 DNS 解析，没配域名模式**。`status` 里没有「域名」那一行，说明还在 IP 模式，跑 `sub domain`；
3. **Nginx 没起来**：`systemctl status nginx`、`nginx -t`；
4. **证书没签发**（80 不通时 certbot 必然失败）：修好 80 后重跑 `sub domain`。

> 域名模式下应用只监听 `127.0.0.1:8080`，由 Nginx 转发 80/443；IP 模式下监听 `0.0.0.0:8080`。

---

## 重置管理员密码

```bash
sub passwd                                  # 随机生成并打印
sub passwd --admin-password '新密码'         # 指定（8–72 字节）
sub passwd --admin-email x@y.com            # 多个管理员时指定账号
```

直接改数据库里的 bcrypt 哈希，**忘记密码也能救**。首次执行会安装 `apache2-utils`（用 `htpasswd` 生成哈希），卸载时会一并清理。

注意：改密码不会让已登录的浏览器会话失效；怀疑他人仍在线时，在后台退出全部会话，或更换 `JWT_SECRET` 后 `sub restart`。

---

## 旧版本备份

升级/重装时会把旧二进制复制为 `/opt/sub2api/sub2api.bak`，`cp -f` **覆盖同一个文件**，无论升级多少次都只占一份（约一个二进制大小）。不需要回滚时：

```bash
sub clean     # 删除 .bak 并显示释放了多少
```

---

## 卸载

```bash
sub            # 选 5
sub uninstall  # 或直接
```

默认**连数据一起删除**（会先问一次 `y/N`）：

- 应用服务与 systemd 单元；
- 独立 Redis 实例及其数据目录；
- 独立 PostgreSQL 集群（含 `/var/log/postgresql` 里该集群的日志）；
- Nginx 站点与脚本申请的证书；
- `/opt/sub2api`、`/etc/sub2api`、`/usr/local/bin/sub`；
- `/tmp/sub2api-deploy-apt.log`；
- 系统用户 `sub2api`；
- 自己加的 ufw 规则；
- **有条件地**卸载软件包：没有其他 PG 集群 / Redis 实例 / Nginx 站点才删，否则保留并说明原因；
- 自己添加的 PGDG / Redis 软件源；
- 最后逐项残留自检（目录、单元、用户、集群、快捷命令、端口）。

**保留数据**用 `--keep-data`：先 `pg_dump` 导出数据库、复制 Redis 数据目录到 `/var/backups/sub2api-<时间>/`，然后再清理。

```bash
sub uninstall --keep-data
```

---

## 装完之后

| 内容 | 位置 |
| --- | --- |
| 管理员账号密码、数据库/缓存密码、JWT/TOTP 密钥 | `/etc/sub2api/credentials.txt`（600） |
| 应用运行配置 | `/etc/sub2api/sub2api.env`（600） |
| 安装状态（卸载依赖） | `/etc/sub2api/install-state.conf` |
| 程序与数据 | `/opt/sub2api/`（脚本副本 `deploy.sh`、数据 `data/`、缓存 `redis-data/`） |
| 快捷命令 | `/usr/local/bin/sub` |
| systemd 单元 | `sub2api.service`、`sub2api-redis.service` |
| 日志 | `journalctl -u sub2api -f`，或 `/opt/sub2api/data/logs/` |
| apt / 证书申请日志 | `/tmp/sub2api-deploy-apt.log` |

```bash
systemctl status sub2api
systemctl status sub2api-redis
pg_lsclusters                 # 应看到 <版本>/sub2api
journalctl -u sub2api -n 100 --no-pager
```

---

## 安装流程

1. 检查系统版本、架构、systemd、root 权限，内存不足时提示
2. （交互）询问是否绑定域名
3. 安装基础工具；准备系统用户与目录
4. 生成或沿用数据库密码、Redis 密码、JWT、TOTP、管理员账号
5. 装 PostgreSQL：优先发行版自带（≥15），否则加 PGDG 源装 16；清掉顺带产生的空 `main` 集群
6. 创建独立集群 `<版本>/sub2api`（自动找空闲端口），建库建账号
7. 准备 Redis 二进制（系统有 7+ 就复用；低于 7 则编译独立副本，不动系统包）
8. 创建独立 Redis 实例（独立配置、数据、systemd 单元）
9. 下载 Release 二进制并校验 SHA-256
10. 写入 env 与 systemd 单元，启动并轮询 `/health`（最多 300 秒）
11. 可选：Nginx + 证书
12. 写凭据与安装状态，生成 `sub` 命令，打印摘要

重跑安装：沿用已有密码与账号、保留数据，只替换二进制并重启；已配置过域名会沿用，除非重新指定。

---

## 常见问题

**GitHub 下载失败 / 卡住**

```bash
sudo bash /opt/sub2api/deploy.sh upgrade --gh-proxy https://ghproxy.net/
```

所有网络请求都有超时，失败会直接报错并打印原因，不会无限等待。

**装完打不开页面**

1. `sub status`
2. `curl -i http://127.0.0.1:8080/health`
3. `ufw status`；云服务器还要在安全组放行对应端口

**菜单一闪而过 / 读不到输入**

少数 Web 终端不支持全屏（备用屏）或 `/dev/tty` 读不到输入。脚本会明确报错，不会假装你选了退出。绕开菜单：

```bash
curl -sSL <脚本地址> | sudo bash -s -- install
# 或
SUB2API_NO_TUI=1 sudo bash /opt/sub2api/deploy.sh
```

**端口 5433 / 6380 被占用**

脚本会自动向后找空闲端口，实际端口写在 `/etc/sub2api/credentials.txt` 与 `install-state.conf` 里。

**卸载后想恢复数据**

只有加过 `--keep-data` 才有备份，在 `/var/backups/sub2api-<时间>/`：

- 数据库：`pg_restore -d 新库 sub2api.dump`
- 缓存：`redis-data/` 整个目录

**卸载时提示"还有其他 PostgreSQL 集群 / Redis 服务 / Nginx 站点"**

这是有意的保护：说明机器上还有其他东西在用，脚本只删自己的部分、保留软件包并告诉你原因。

---

## 验证状态

- `bash -n` 语法检查通过；`--help`、非法参数、缺 `--email`、`--lines` 校验等分支本机实测；
- 真机（Ubuntu 24.04）已验证：装 PostgreSQL、创建独立集群、建库、Redis 包安装与独立实例创建均成功；
- 真机暴露并已修复的问题：`pipefail` + 提前退出管道导致 141、Redis 配置权限、`/etc/os-release` 覆盖版本变量、PGDG 公钥下载无超时；
- **仍未在真实服务器上完整跑通一次「安装 → 域名 → 状态 → 卸载」全链路**，尤其证书申请、`status` 诊断与卸载自检需要真机确认。
