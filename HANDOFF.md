# HANDOFF — Sub2API 一键部署 / 卸载脚本

## 1. 元信息

| 项 | 内容 |
| --- | --- |
| 最后更新 | 2026-10-20 |
| 当前版本 | v2.0.0 |
| 更新者 | DSH |
| 上游项目 | [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) |
| 状态 | 功能完整，**尚未在真实 Linux 服务器端到端验证** |

## 2. 一句话定位

在 Debian/Ubuntu 上一条命令装完 Sub2API 及其独立数据库与缓存，再一条命令把它连数据带服务干净删除，且**全程不碰机器上已有的 PostgreSQL / Redis**。

## 3. 产品目标

**要解决的问题**：

1. 官方 `install.sh` 不装 PostgreSQL/Redis，装完还必须开浏览器向导逐项配置；
2. 常见的一键脚本为了"省事"会改系统 `/etc/redis/redis.conf`、重启系统 Redis、把所有 PG 集群一起重启，**装一个东西弄坏另一个**；
3. 卸载往往只删二进制，留下服务、用户、数据库、端口、apt 源。

**给谁用**：在已有其他服务的 VPS 上部署 Sub2API、并且希望随时能干净撤回的个人或小团队。

**成功标准**：

1. 干净 Ubuntu 22.04/24.04 / Debian 12 上一条命令在 10 分钟内完成，`/health` 返回 200，打印的管理员能登录；
2. 安装过程中系统原有的 PostgreSQL / Redis 服务**不被重启、配置不被修改**；
3. `uninstall` 后残留自检全部通过（无目录、无服务单元、无用户、无集群、无监听端口），且其他服务照常运行；
4. 重复 `install` 不重复建账号、不破坏数据；
5. `--keep-data` 能在删除前导出可恢复的备份。

## 4. 当前进度

| 项 | 状态 |
| --- | --- |
| 安装（独立 PG 集群 + 独立 Redis 实例） | ✅ 代码完成 |
| 卸载（含包清理、apt 源清理、残留自检） | ✅ 代码完成 |
| 域名 + 自动 HTTPS | 🟡 代码完成，未在真实域名验证 |
| 真机验证 | ⬜ 未开始 |
| 文档 | ✅ 完成 |
| GitHub 发布 | ✅ 仓库文件已就绪并完成首次提交（LF 换行、`.gitattributes` 已锁定），待用户填仓库名推送 |

**已执行的验证（命令 + 结果）**：

```text
bash -n deploy.sh                          → exit 0（1616 行）
bash deploy.sh --help                      → 正常输出中文用法，exit 0
bash deploy.sh --port abc                  → "[错误] --port 必须是数字"，exit 1
bash deploy.sh --domain api.example.com    → "[错误] 使用 --domain 时必须同时给出 --email"，exit 1
bash deploy.sh uninstall --keep-data --yes → "[错误] 请用 root 运行"，exit 1（参数组合合法）
cat deploy.sh | bash -s -- --help          → 与文件执行一致，exit 0（模拟 curl | bash）
cat deploy.sh | bash -s -- uninstall --yes → "[错误] 请用 root 运行，例如：sudo bash deploy.sh"，exit 1
git ls-files --eol                         → 全部 i/lf w/lf（GitHub 上可直接 curl | bash）
```

**未验证**：apt 安装、PG 集群创建与 `16/main` 清理、Redis 编译/实例、二进制下载、systemd 启动、首次迁移、Nginx 与证书、**整条卸载链路**、真实 `curl | bash`（只在本地用管道模拟过）。

## 5. 功能清单

| 功能 | 状态 | 入口 | 说明 |
| --- | --- | --- | --- |
| 一键安装 | ✅ | `sudo bash deploy.sh` | 独立 PG + 独立 Redis + 应用 + 管理员 |
| 独立 PostgreSQL 集群 | ✅ | 自动 | `16/sub2api`，端口 5433 起自动找空闲 |
| 独立 Redis 实例 | ✅ | 自动 | `sub2api-redis`，端口 6380 起，独立配置与数据 |
| 不碰系统 Redis | ✅ | 自动 | 不改 `/etc/redis/redis.conf`，不重启 `redis-server` |
| 不重启系统 PG | ✅ | 自动 | 不 enable/restart 全局 `postgresql`，只操作自己的实例 |
| 清理装包副产物 | ✅ | 自动 | 删除自动生成的 `16/main`；停用并禁用默认 6379 服务 |
| IP:端口访问 | ✅ | 默认 | 监听 `0.0.0.0:8080`，打印时自动探测公网 IP |
| 域名 + 自动 HTTPS | 🟡 | `--domain` + `--email` | 代码完成，未实测 |
| 自定义端口 | ✅ | `--port` | 端口被占时报错而不是抢占 |
| 自定义管理员 | ✅ | `--admin-email` / `--admin-password` | 已初始化时忽略并提示 |
| 指定版本 | ✅ | `--version` | 跳过 GitHub API 查询 |
| GitHub 加速 | ✅ | `--gh-proxy` | 只作用于文件下载 |
| SHA-256 校验 | ✅ | 自动 | checksums 缺失时降级为警告 |
| 升级 | ✅ | `deploy.sh upgrade` | 备份为 `sub2api.bak`，保留数据 |
| 状态 | ✅ | `deploy.sh status` | 应用 / Redis / PG 三处状态 + 健康检查 |
| **一键卸载** | ✅ | `deploy.sh uninstall` | 服务、集群、实例、目录、用户、ufw、软件包、apt 源 |
| 卸载残留自检 | ✅ | 自动 | 目录 / 单元 / 用户 / 集群 / 端口逐项检查 |
| 卸载保留数据 | ✅ | `--keep-data` | 先 `pg_dump` + 复制 Redis 数据到 `/var/backups` |
| 有条件卸载软件包 | ✅ | 自动 | 有其他使用者则保留并说明原因 |
| 幂等重装 | ✅ | 重复 `install` | 沿用密码、端口、域名与数据 |

图例：✅ 已完成 / 🟡 代码完成未验证 / ⬜ 未开始

## 6. 技术栈与目录结构

- Bash 4+（Debian 12 = 5.2，Ubuntu 22.04 = 5.1）
- 目标系统：Ubuntu 22.04/24.04、Debian 12；x86_64 / arm64
- 组件：PostgreSQL 16（PGDG）、Redis 7+（系统包 / packages.redis.io / 源码编译）、Nginx + certbot（仅域名模式）

```text
sub2api-deploy/                 ← GitHub 仓库根目录
├── deploy.sh                   # 唯一脚本（1616 行）
├── README.md                   # 使用说明（含 curl 一键安装与版本策略）
├── LICENSE                     # MIT
├── .gitignore                  # 排除本文件与上传辅助脚本
├── .gitattributes              # 强制 LF，保证 GitHub 上可直接 curl | bash
├── HANDOFF.md                  # 本文档（本地维护，已被 .gitignore 排除）
└── push-to-github.ps1          # 本机一键上传辅助（已被 .gitignore 排除）
```

服务器端产物：

```text
/opt/sub2api/sub2api              二进制
/opt/sub2api/data/                config.yaml、.installed、logs/
/opt/sub2api/redis-data/          独立 Redis 数据
/opt/sub2api/redis/               仅「系统 Redis < 7」时编译的独立副本
/etc/sub2api/sub2api.env          应用环境变量（600）
/etc/sub2api/redis.conf           独立 Redis 配置（600）
/etc/sub2api/install-state.conf   安装状态，卸载依赖（600）
/etc/sub2api/credentials.txt      凭据汇总（600）
/etc/systemd/system/sub2api.service
/etc/systemd/system/sub2api-redis.service
/var/lib/postgresql/16/sub2api/   独立 PG 集群数据
/etc/postgresql/16/sub2api/       独立 PG 集群配置
/var/backups/sub2api-<时间>/       仅 --keep-data 时存在
```

## 7. 运行 · 构建 · 发布

**发布方式**：单文件脚本，无构建步骤。

```bash
bash -n deploy.sh                       # 语法自检
sudo bash deploy.sh [install|upgrade|status|uninstall] [选项]
```

**发布到 GitHub**

仓库已初始化并完成首次提交（`git log` 可见，分支 `main`），`.gitattributes` 已锁定 LF。

```powershell
# 在 GitHub 网页创建空仓库（不要勾 README / .gitignore / LICENSE）后：
.\push-to-github.ps1 -Repo 你的账号/sub2api-deploy
```

该脚本会：把 `README.md` 里的 `<你的账号>/sub2api-deploy` 占位替换成真实地址 → 设置 `origin` → 提交这次改动 → `git push -u origin main`（首次会弹 GitHub 登录窗口）。

手动等价操作：

```bash
git remote add origin https://github.com/账号/仓库.git
git push -u origin main
```

**版本策略**：脚本不锁定 Sub2API 版本，始终请求 `releases/latest`，因此上游发新版后**无需修改本仓库**；用户重跑 `install` 或执行 `upgrade` 即同步。发布时不需要改任何版本号。

**关键实现点（改动前必读）**

1. **`AUTO_SETUP` 只在首次生效**：`backend/internal/setup/setup.go` 的 `AutoSetupFromEnv()` 仅在 `NeedsSetup()` 为真（`DATA_DIR/config.yaml` 与 `.installed` 都不存在）时执行，所以该变量可长期留在 env 里。任何"重装时重新建管理员"的改法都会失败。
2. **`DATA_DIR` 必须是 `/opt/sub2api/data`**：systemd 单元带 `ProtectSystem=strict` + `ReadWritePaths=/opt/sub2api`，写别处会失败。
3. **PG 集群名固定 `sub2api`**：卸载、状态、自检都按这个名字找；改名要同步 `PG_CLUSTER_NAME`、`pg_cluster_exists`、`verify_clean`。
4. **不重启全局服务**：启动 PG 只用 `pg_ctlcluster 16 sub2api start`；开机由 `sub2api.service` 的 `Wants=postgresql@16-sub2api.service` 拉起。不要加 `systemctl restart postgresql`。
5. **Redis 实例的二进制可能来自系统**：系统已有 ≥7 时复用 `/usr/bin/redis-server`，但配置、数据、单元都在本项目名下，卸载只删自己的。
6. **系统 Redis < 7 时编译副本**：因为不能升级系统包（会影响其他程序），编译到 `/opt/sub2api/redis`，版本由 `REDIS_BUILD_VERSION` 固定。
7. **状态文件是卸载的依据**：`ST_*` 变量记录哪些资源是本次创建的。手工改它会导致卸载判断错误。
8. **包清理有硬条件**：没有其他 PG 集群、没有其他 Redis 单元、没有其他 Nginx 站点，才 purge；否则保留并打印原因。

## 8. 已知问题、限制与踩过的坑

**未验证（最大风险）**

- 整条安装与卸载链路都没在真实 Linux 上跑过。
- 最可能出问题的点：PGDG 源在具体镜像上的可达性、`pg_createcluster --locale=C.UTF-8`、编译 Redis 的依赖、`pg_dropcluster` 的参数顺序、`systemctl` 实例单元的 `Wants` 行为、证书申请。
- 没跑过 shellcheck（本机无工具，未联网安装）。

**设计限制**

- 只支持 Debian/Ubuntu，不支持 RHEL 系与 Alpine。
- 复用系统 Redis 二进制（≥7）时，若用户之后卸载系统 Redis，本项目的实例会失效。
- 域名模式用 Nginx + certbot，不是 Caddy；需要 80 端口公网可达。
- 云安全组需用户自行放行，脚本只能改本机 ufw。
- 重跑 `install` 会覆盖 `/etc/sub2api/sub2api.env`，对其手改会丢失（密码、账号、端口会沿用）。
- `--keep-data` 的备份目录不会被自动清理，需用户自行管理。
- 卸载会删除 `/opt/sub2api` 整个目录，若用户往里放过自己的文件也会一并删除（文档已说明）。

**实现决策记录**

- Redis 不共用系统实例：因为必须改 `requirepass`/`bind` 并重启，会打断其他程序。
- PG 不用系统实例：因为要在系统库里建 role/database，卸载时删库仍有耦合；独立集群可整体 drop。
- 装包产生的 `16/main` 会删除：仅在安装前不存在 16 集群时执行，避免误删用户集群。
- 默认启用 `disable --now redis-server`（仅当 Redis 包是我们装的）：否则会多一个 6379 监听。

**已修复的实现缺陷（备查）**

1. Nginx 配置函数最初直接写目标文件，导致 `render` 用空临时文件覆盖配置 → 改为输出到 stdout。
2. 用 `psql --version` 判断"已装 PG"会误判只有客户端的情况 → 改为查 `pg_lsclusters`。
3. 多集群下 `psql` 默认连 5432 → 所有调用补 `-p`。
4. `[ -n "$DOMAIN" ] && var=...` 在 `set -e` 下条件为假会直接退出 → 改 `if`。
5. 域名模式反代失败后应用只监听 127.0.0.1，外部不可达 → 回退 0.0.0.0 并补 ufw 规则。
6. `pipefail` 下 curl / 计数管道失败会无提示退出 → 先取原文再解析、计数函数兜底。
7. v1 会改写 `/etc/redis/redis.conf` 并 `restart redis-server`、`restart postgresql` → v2 改为独立实例，彻底移除该行为。
8. v1 的 `--keep-data` 声称保留数据却仍删除 → v2 改为先 `pg_dump` + 复制数据目录，再执行清理。

## 9. 后续开发目标

1. **真机验证**（最高优先级）：Ubuntu 22.04 / 24.04 / Debian 12 各跑一次全新安装 + 卸载，记录耗时与失败点。
2. 验证「机器上已有 PG 15 / Redis 6」的共存场景，确认没被重启、没被改配置。
3. 按真机结果修默认值（健康检查等待、迁移超时）。
4. 补 shellcheck。
5. 建议：支持 RHEL 系（dnf 分支）。
6. 建议：`--dry-run` 只打印动作。
7. 建议：域名模式改用 Caddy。
8. 建议：卸载时把 `verify_clean` 的发现写入日志文件，便于远程排查。

## 10. 交接须知

- **改脚本前先读第 7 节**，尤其第 4、5、8 条：任何"顺手重启系统服务"的改动都会破坏"不影响现有程序"这条核心承诺。
- **不要删除** `/etc/sub2api/install-state.conf` 的读写逻辑：卸载的包清理与 apt 源清理全靠它。
- **删除保护**：`uninstall` 在 `rm -rf` 前有路径断言（`/opt/sub2api`、`/etc/sub2api`），不要移除。
- **不能动的东西**：`PG_CLUSTER_NAME`、`REDIS_UNIT`、`SERVICE_USER` 这三个名字是安装与卸载之间的契约，改名必须同步状态文件与自检。
- 文档与脚本必须同步：参数表在 `README.md`，与 `parse_args` 一一对应；架构说明在第 5 节。
- 反馈真机结果时附上：发行版与版本、完整输出、`journalctl -u sub2api -n 80`、`pg_lsclusters`、`systemctl status sub2api-redis`。
