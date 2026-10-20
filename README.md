# Sub2API 一键部署 / 卸载脚本

一条命令把 [Sub2API](https://github.com/Wei-Shaw/sub2api) 完整装好，另一条命令把它**干净地**删掉。

- **安装**：自动创建独立的 PostgreSQL 集群与独立的 Redis 实例、下载官方 Release、注册 systemd、首次启动自动建库建管理员。不需要手动装数据库，不需要打开网页设置向导。
- **卸载**：删除本脚本创建的全部资源，并在确认没有其他使用者后卸载自己装的软件包，最后做残留自检。
- **不干扰现有程序**：全程不改系统原有的 PostgreSQL / Redis 配置，不重启它们的服务，不占用它们的数据目录和端口。

---

## 为什么需要它

官方 `deploy/install.sh` 只做三件事：下载二进制、建系统用户、装 systemd 服务。PostgreSQL、Redis、数据库配置、管理员账号全留给用户，装完还得在浏览器里逐项填向导。官方的 Docker 方案则要求先有 Docker。

本脚本补上这段空缺，同时避开"装一个东西弄坏另一个"的常见坑。

---

## 它怎么做到不影响现有程序

| 资源 | 做法 | 卸载时 |
| --- | --- | --- |
| PostgreSQL | 创建**独立集群** `16/sub2api`，独立端口（5433 起自动找空闲）、独立数据目录 | `pg_dropcluster` 只删这个集群 |
| Redis | 起**独立实例** `sub2api-redis`，独立端口（6380 起）、独立配置 `/etc/sub2api/redis.conf`、独立数据 `/opt/sub2api/redis-data` | 停服务、删单元与数据目录 |
| 系统 Redis 配置 | **完全不碰** `/etc/redis/redis.conf`，不重启 `redis-server` | 原文件与状态不变 |
| 系统 PostgreSQL | **不 enable、不 restart** 全局 `postgresql` 服务，不碰其他集群 | 其他集群照常运行 |
| 端口 | 主动避开 5432 / 6379；8080 被占用会直接报错而不是抢占 | 释放自己用的端口 |
| Nginx | 只新增 `sub2api.conf` 这一个站点文件，reload 不改其他站点 | 删文件后 reload |
| ufw | 只 `allow` 需要的端口 | 按记录 `delete` 对应规则 |
| 软件包 | 只装缺的，并记录哪些是本次装的 | 确认无其他使用者后才卸载 |

**装包副产物也会清掉**：安装 `postgresql-16` 时 apt 会自动建一个空的 `16/main` 集群占住 5432，脚本会识别并删除它（仅当安装前没有 16 集群）；安装 Redis 包会自动启用 6379 的默认服务，脚本会 `disable --now` 它。

---

## 支持环境

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 / 24.04、Debian 12 |
| 架构 | x86_64（amd64）、arm64 |
| 权限 | root（`sudo`） |
| 初始化系统 | systemd |
| 网络 | 能访问 GitHub Releases、PGDG（国内建议配 `--gh-proxy`） |

---

## 安装

### 方式一：一条命令（推荐）

```bash
curl -sSL https://raw.githubusercontent.com/Legends-ou/sub2api-auto-command/main/deploy.sh | sudo bash
```

`curl | bash` 与 `sudo` 同时使用时，交互确认会从终端读取（不是从脚本管道），因此卸载确认等提示都能正常工作。

### 方式二：下载后执行

```bash
scp deploy.sh root@你的服务器:/root/
sudo bash /root/deploy.sh
```

装完终端打印访问地址、管理员账号密码，并写入 `/etc/sub2api/credentials.txt`（600）。

### 绑定域名并自动 HTTPS

```bash
sudo bash deploy.sh --domain api.example.com --email you@example.com
```

前置条件：域名已解析到本机、80/443 公网可达。脚本会装 Nginx + certbot、申请 Let's Encrypt 证书、配置 80→443 跳转，并把应用改为只监听 `127.0.0.1`（外部只能经 Nginx）。

证书申请失败不会中断安装：会回退成监听 `0.0.0.0`，仍可用 `IP:8080` 登录，修好后重跑同一条命令即可。

### 其他组合

```bash
sudo bash deploy.sh --port 9000                                   # 换端口
sudo bash deploy.sh --version vX.Y.Z                              # 指定版本（平时不用加）
sudo bash deploy.sh --gh-proxy https://ghproxy.net/               # 国内加速
sudo bash deploy.sh --admin-email me@example.com --admin-password '密码'
sudo bash deploy.sh upgrade                                       # 同步到最新版
sudo bash deploy.sh status                                        # 看状态
```

---

## 版本策略：始终跟随上游最新版

脚本**不锁定** Sub2API 版本：

- 不带 `--version` 时，每次都向 `https://api.github.com/repos/Wei-Shaw/sub2api/releases/latest` 取最新 Release 再下载；
- 已装过旧版时重跑 `install` 或执行 `upgrade`，都会重新解析最新版并替换二进制，数据与账号保留；
- `--version` 只是可选的临时手段（回滚或固定排查），不作为默认值，也不会写进任何配置。

> `deploy.sh` 里的 `REDIS_BUILD_VERSION` 是「系统 Redis 低于 7 时编译独立副本」用的 Redis 版本，与 Sub2API 版本无关。

---

## 卸载

```bash
sudo bash deploy.sh uninstall          # 全删（含数据库与缓存数据）
sudo bash deploy.sh uninstall --yes    # 不询问
sudo bash deploy.sh uninstall --keep-data   # 先把数据备份到 /var/backups 再删
```

会依次处理：

1. 停用并删除 `sub2api.service`；
2. 停用并删除 `sub2api-redis.service` 及其数据目录；
3. 删除 Nginx 站点（仅 `sub2api.conf`）与脚本申请的证书；
4. `pg_dropcluster` 删除独立集群 `16/sub2api`；
5. 删除 `/opt/sub2api`、`/etc/sub2api`、系统用户 `sub2api`；
6. 删除自己加的 ufw 规则；
7. **有条件地**卸载软件包：`postgresql-16`（没有其他 16 集群、也没有其他 PG 版本时连公共包一起清）、Redis（没有其他实例时）、Nginx/certbot（没有其他站点时）；
8. 删除自己添加的 PGDG / Redis 软件源；
9. 残留自检：逐项检查目录、服务单元、用户、集群、端口，全部通过才打印"未发现残留"。

**`--keep-data`** 会在删除前把数据库导出成 `pg_dump` 自定义格式、复制 Redis 数据目录到 `/var/backups/sub2api-<时间>/`，然后照常清理。

---

## 参数一览

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--port <端口>` | 应用监听端口 | `8080` |
| `--domain <域名>` | 绑定域名并启用 HTTPS | 关闭 |
| `--email <邮箱>` | 证书通知邮箱，用 `--domain` 时必填 | 无 |
| `--admin-email <邮箱>` | 管理员登录账号 | 随机 `admin-xxxxxx@sub2api.local` |
| `--admin-password <密码>` | 管理员密码（8–72 字节） | 随机 24 位十六进制 |
| `--version <vX.Y.Z>` | 指定版本 | 最新 Release |
| `--gh-proxy <URL>` | GitHub 下载加速前缀 | 无 |
| `--timezone <时区>` | 应用时区 | `Asia/Shanghai` |
| `--yes` / `-y` | 卸载时跳过确认 | 关闭 |
| `--keep-data` | 卸载前备份数据库与缓存数据 | 关闭 |

---

## 装完之后

| 内容 | 位置 |
| --- | --- |
| 管理员账号密码、数据库/缓存密码、JWT/TOTP 密钥 | `/etc/sub2api/credentials.txt`（600） |
| 应用运行配置 | `/etc/sub2api/sub2api.env`（600） |
| 安装状态（卸载依赖） | `/etc/sub2api/install-state.conf` |
| 程序与数据 | `/opt/sub2api/`（应用数据 `data/`，缓存数据 `redis-data/`） |
| systemd 单元 | `sub2api.service`、`sub2api-redis.service` |
| 日志 | `journalctl -u sub2api -f`，或 `/opt/sub2api/data/logs/` |

```bash
systemctl status sub2api
systemctl status sub2api-redis
pg_lsclusters                 # 应看到 16/sub2api
journalctl -u sub2api -n 100 --no-pager
```

---

## 安装流程

1. 检查系统版本、架构、systemd、root 权限
2. 安装基础工具；准备系统用户与目录
3. 生成或沿用数据库密码、Redis 密码、JWT、TOTP、管理员账号
4. 需要时添加 PGDG 源并安装 PostgreSQL 16，清掉顺带产生的空 `16/main`
5. 创建独立集群 `16/sub2api`（自动找空闲端口），建库建账号
6. 准备 Redis 二进制（系统已有 7+ 就复用；已有低于 7 的则编译独立副本，不动系统包）
7. 创建独立 Redis 实例（配置、数据、systemd 单元都在本项目名下）
8. 下载 Release 二进制并校验 SHA-256
9. 写入 env 与 systemd 单元，启动并轮询 `/health`（最多 300 秒）
10. 可选：Nginx + 证书
11. 写凭据与安装状态，打印摘要

重跑 `install`：沿用已有密码与账号、保留数据，只替换二进制并重启；已配置过域名会沿用，除非重新指定。

---

## 常见问题

**GitHub 下载失败**

```bash
sudo bash deploy.sh --gh-proxy https://ghproxy.net/
```

**装完打不开页面**

1. `systemctl status sub2api`
2. `curl -i http://127.0.0.1:8080/health`
3. `ufw status`；云服务器还要在安全组放行 8080（脚本只能改本机 ufw）

**端口 5433 / 6380 被占用**

脚本会自动向后找空闲端口，实际端口写在 `/etc/sub2api/credentials.txt` 与 `install-state.conf` 里。

**域名证书申请失败**

- 域名必须已解析到本机公网 IP；80 端口必须公网可达
- 失败会回退 IP:8080，不影响服务；修好后重跑 `--domain` 命令

**卸载后想恢复数据**

只有加过 `--keep-data` 才有备份，在 `/var/backups/sub2api-<时间>/`：
- 数据库：`pg_restore -d 新库 sub2api.dump`
- 缓存：`redis-data/` 整个目录

**卸载时提示"还有其他 PostgreSQL 集群 / Redis 服务 / Nginx 站点"**

这是有意的保护：说明机器上还有其他东西在用，脚本只删自己的部分，保留软件包并告诉你原因。

---

## 验证状态

- `bash -n` 语法检查通过（Git Bash 解析器）
- 参数解析与错误分支本机实测：`--help`、非法端口、缺 `--email`、`uninstall --keep-data --yes` 的 root 检查
- **未在真实 Linux 服务器上端到端跑过**（本机无 WSL 发行版、无 Docker、无 shellcheck）

首次真机验证重点：PG 独立集群创建与 `16/main` 清理、Redis 实例启动、首次迁移、卸载后的残留自检。
