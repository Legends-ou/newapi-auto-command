#!/usr/bin/env bash
#
# Sub2API 一键部署 / 卸载脚本（Debian / Ubuntu）
#
# 安装：自动创建独立的 PostgreSQL 集群与独立的 Redis 实例，下载官方 Release，
#       写入 systemd 服务，首次启动自动建库、建管理员，全程无交互。
#       不修改、不重启机器上已有的 PostgreSQL / Redis，不影响其他程序。
#
# 卸载：删除本脚本创建的全部资源（服务、集群、实例、配置、数据、账号），
#       并在确认没有其他使用者后卸载自己装的软件包，最后做残留自检。
#
# 用法：
#   sudo bash deploy.sh                        # 装，IP:8080 访问
#   sudo bash deploy.sh --domain api.example.com --email you@example.com
#   sudo bash deploy.sh upgrade                # 只换二进制
#   sudo bash deploy.sh status
#   sudo bash deploy.sh uninstall              # 全清（默认删数据）
#   sudo bash deploy.sh uninstall --keep-data  # 全清但保留数据库与缓存数据
#
# 只支持 Ubuntu 22.04+ / Debian 12+，需要 root 与 systemd。

set -Eeuo pipefail

APP="sub2api"
REPO="Wei-Shaw/sub2api"
SERVICE_USER="sub2api"
INSTALL_DIR="/opt/sub2api"
DATA_DIR="${INSTALL_DIR}/data"
REDIS_DATA_DIR="${INSTALL_DIR}/redis-data"
CONF_DIR="/etc/sub2api"
ENV_FILE="${CONF_DIR}/sub2api.env"
REDIS_CONF="${CONF_DIR}/redis.conf"
STATE_FILE="${CONF_DIR}/install-state.conf"
CRED_FILE="${CONF_DIR}/credentials.txt"
UNIT_FILE="/etc/systemd/system/sub2api.service"
REDIS_UNIT="sub2api-redis"
REDIS_UNIT_FILE="/etc/systemd/system/${REDIS_UNIT}.service"
SERVICE="sub2api"
PG_CLUSTER_NAME="sub2api"
PG_VERSION_DEFAULT="16"
REDIS_BUILD_VERSION="7.4.2"
NGINX_SITE="/etc/nginx/sites-available/sub2api.conf"

# 发布地址：sub 快捷命令的本地副本丢失时，用它重新拉取。
SCRIPT_URL="https://raw.githubusercontent.com/Legends-ou/sub2api-auto-command/main/deploy.sh"
SUB_BIN="/usr/local/bin/sub"
LOCAL_SCRIPT="${INSTALL_DIR}/deploy.sh"

ACTION="install"
PORT="8080"
PORT_SET="false"
DOMAIN=""
TLS_EMAIL=""
ARG_ADMIN_EMAIL=""
ARG_ADMIN_PASSWORD=""
ARG_VERSION=""
GH_PROXY=""
TIMEZONE="Asia/Shanghai"
KEEP_DATA="false"
ASSUME_YES="false"
LOG_LINES="100"
VERBOSE="false"
FROM_MENU="false"
APT_LOG="/tmp/sub2api-deploy-apt.log"

ARCH=""
OS_ID=""
OS_CODENAME=""
APT_UPDATED="false"
# 给 apt 加超时：镜像不可达时快速失败，而不是无限等待。
APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
REDIS_BIN=""
STATE_LOADED="false"
PG_CLUSTERS_BEFORE=""

# 既支持「下载后执行」，也支持 `curl ... | sudo bash`：
# 管道执行时 $0 是 bash、BASH_SOURCE 不是文件，这里统一出一个可复制的重跑命令。
SELF_CMD="bash deploy.sh"
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SELF_CMD="bash $(basename "${BASH_SOURCE[0]}")"
fi

# 安装状态（写入 STATE_FILE，卸载时读取；重装时沿用）
ST_VERSION="1"
ST_INSTALLED_AT=""
ST_PG_VERSION=""
ST_PG_CLUSTER=""
ST_PG_PORT=""
ST_PG_CLUSTER_CREATED="false"
ST_PG_PACKAGES_CREATED="false"
ST_REDIS_PORT=""
ST_REDIS_BIN=""
ST_REDIS_PACKAGES_CREATED="false"
ST_REDIS_BUILT="false"
ST_REDIS_BUILT_PACKAGES="false"
ST_NGINX_PACKAGES_CREATED="false"
ST_CERTBOT_PACKAGES_CREATED="false"
ST_NGINX_SITE_CREATED="false"
ST_CERT_CREATED="false"
ST_DOMAIN=""
ST_TLS_EMAIL=""
ST_UFW_PORTS=""
ST_SERVER_PORT=""
ST_PGDG_REPO_CREATED="false"
ST_REDIS_REPO_CREATED="false"
ST_EXTRA_PKGS=""

# ---------------------------------------------------------------- 输出

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_RESET=""
fi

log_info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()   { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
# 出错时先退出全屏界面，否则错误信息会随备用屏一起消失。
die()      { tui_leave; log_err "$*"; exit 1; }
step()     { printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }

have_tty() {
  # /dev/tty 存在不代表有控制终端，要真的尝试打开。
  { : < /dev/tty; } 2>/dev/null || return 1
  { : > /dev/tty; } 2>/dev/null || return 1
  return 0
}

prompt_confirm() {
  local prompt="$1" reply=""
  if have_tty; then
    # 通过管道执行时 stdin 是脚本正文，必须从终端读，否则会把代码当成回答。
    printf '%s' "$prompt" > /dev/tty
    read -r reply < /dev/tty || reply=""
    printf '\n' > /dev/tty
  else
    printf '%s' "$prompt"
    read -r reply || reply=""
  fi
  case "$reply" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

on_error() {
  local code=$1 line=$2
  tui_leave
  log_err "脚本在第 ${line} 行失败（退出码 ${code}）。"
  log_err "应用日志：journalctl -u ${SERVICE} -n 80 --no-pager"
  log_err "如已装到一半，可重跑本命令继续，或用 uninstall 清理。"
  exit "$code"
}
trap 'on_error $? $LINENO' ERR
trap 'tui_leave' EXIT
trap 'tui_leave; exit 130' INT TERM

TUI_ACTIVE="false"

tui_enter() {
  have_tty || return 0
  [ "${SUB2API_NO_TUI:-0}" = "1" ] && return 0
  [ "${TUI_ACTIVE:-false}" = "true" ] && return 0
  # 1049 = 进入备用屏（新"窗口"），退出时原终端内容原样恢复。
  printf '\033[?1049h' > /dev/tty 2>/dev/null || return 0
  TUI_ACTIVE="true"
}

tui_leave() {
  [ "${TUI_ACTIVE:-false}" = "true" ] || return 0
  printf '\033[?1049l' > /dev/tty 2>/dev/null || true
  TUI_ACTIVE="false"
}

tui_clear() {
  have_tty || return 0
  printf '\033[H\033[2J' > /dev/tty 2>/dev/null || true
}

usage() {
  cat <<'EOF'
Sub2API 一键部署 / 卸载脚本（Debian / Ubuntu）

用法：
  bash deploy.sh [命令] [选项]

  首次运行（未安装）直接安装；已安装后不带参数运行会显示交互菜单：
    sudo bash deploy.sh                # 首次=安装；已装=菜单
    sudo bash deploy.sh install        # 跳过菜单，直接安装（脚本化用）

  通过 curl 执行时，命令与选项要放在 bash -s -- 之后：
    curl -sSL <脚本地址> | sudo bash                      # 安装
    curl -sSL <脚本地址> | sudo bash -s -- upgrade        # 升级
    curl -sSL <脚本地址> | sudo bash -s -- status         # 状态
    curl -sSL <脚本地址> | sudo bash -s -- uninstall      # 卸载

命令：
  install      安装（默认）
  upgrade      只替换二进制，保留数据
  status       查看服务状态
  uninstall    卸载并清理本脚本创建的全部资源
  domain       配置域名并启用 HTTPS（已安装后随时可用）
  passwd       重置管理员密码（忘记密码时用）
  show         查看当前凭据、端口与访问地址
  restart      重启应用（不动数据库与缓存）
  logs         跟踪应用日志（默认最近 100 行）
  clean        删除旧版本备份 sub2api.bak

选项：
  --port <端口>              Sub2API 监听端口（默认 8080）
  --domain <域名>            绑定域名并自动申请 HTTPS 证书（需已解析到本机）
  --email <邮箱>             申请证书用的邮箱，使用 --domain 时必填
  --admin-email <邮箱>       管理员登录账号，默认随机生成
  --admin-password <密码>    管理员密码（8-72 字节），默认随机生成
  --version <vX.Y.Z>         指定安装版本，默认最新
  --gh-proxy <URL>           GitHub 下载加速前缀，例如 https://ghproxy.net/
  --timezone <时区>          默认 Asia/Shanghai
  --yes                      卸载时跳过确认
  --keep-data                卸载时先把数据库与缓存数据备份到 /var/backups 再删除
  --lines <行数>             logs 命令显示的日志行数（默认 100）
  --verbose                  显示 apt / certbot 等底层命令的完整输出（排障用）
  -h, --help                 显示本帮助

隔离说明：
  本脚本创建独立的 PostgreSQL 集群（16/sub2api）与独立的 Redis 实例
  （sub2api-redis，端口 6380 起），不修改也不重启系统已有的数据库与缓存，
  因此不会影响机器上其他程序。
EOF
}

# ---------------------------------------------------------------- 参数

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      install|upgrade|status|uninstall|domain|passwd|show|restart|logs|clean) ACTION="$1"; shift ;;
      --port)            PORT="${2:-}"; PORT_SET="true"; shift 2 ;;
      --port=*)          PORT="${1#*=}"; PORT_SET="true"; shift ;;
      --domain)          DOMAIN="${2:-}"; shift 2 ;;
      --domain=*)        DOMAIN="${1#*=}"; shift ;;
      --email)           TLS_EMAIL="${2:-}"; shift 2 ;;
      --email=*)         TLS_EMAIL="${1#*=}"; shift ;;
      --admin-email)     ARG_ADMIN_EMAIL="${2:-}"; shift 2 ;;
      --admin-email=*)   ARG_ADMIN_EMAIL="${1#*=}"; shift ;;
      --admin-password)  ARG_ADMIN_PASSWORD="${2:-}"; shift 2 ;;
      --admin-password=*) ARG_ADMIN_PASSWORD="${1#*=}"; shift ;;
      --version)         ARG_VERSION="${2:-}"; shift 2 ;;
      --version=*)       ARG_VERSION="${1#*=}"; shift ;;
      --gh-proxy)        GH_PROXY="${2:-}"; shift 2 ;;
      --gh-proxy=*)      GH_PROXY="${1#*=}"; shift ;;
      --timezone)        TIMEZONE="${2:-}"; shift 2 ;;
      --timezone=*)      TIMEZONE="${1#*=}"; shift ;;
      --keep-data)       KEEP_DATA="true"; shift ;;
      --lines)           LOG_LINES="${2:-}"; shift 2 ;;
      --lines=*)         LOG_LINES="${1#*=}"; shift ;;
      --verbose)         VERBOSE="true"; shift ;;
      --yes|-y)          ASSUME_YES="true"; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done

  case "$ACTION" in
    install|upgrade|status|uninstall|domain|passwd|show|restart|logs|clean) ;;
    *) die "未知命令：$ACTION" ;;
  esac

  case "$LOG_LINES" in
    ''|*[!0-9]*) die "--lines 必须是数字" ;;
  esac

  [ -n "$PORT" ] || die "--port 不能为空"
  case "$PORT" in ''|*[!0-9]*) die "--port 必须是数字" ;; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port 超出 1-65535"

  if [ -n "$DOMAIN" ]; then
    [ -n "$TLS_EMAIL" ] || die "使用 --domain 时必须同时给出 --email（证书通知邮箱）"
    case "$DOMAIN" in
      *[!A-Za-z0-9.-]*) die "--domain 只能包含字母、数字、点和连字符" ;;
    esac
  fi

  GH_PROXY="${GH_PROXY%/}"
}

# ---------------------------------------------------------------- 系统检查

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行，例如：sudo ${SELF_CMD}"
}

detect_os() {
  [ -r /etc/os-release ] || die "找不到 /etc/os-release，无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "$OS_ID" in
    ubuntu|debian) ;;
    *) die "当前系统（${PRETTY_NAME:-未知}）不受支持。本脚本只支持 Ubuntu 22.04+ / Debian 12+。" ;;
  esac
  [ -n "$OS_CODENAME" ] || die "无法识别系统代号（VERSION_CODENAME）"

  local vmajor="${VERSION_ID:-0}"
  vmajor="${vmajor%%.*}"
  case "$OS_ID" in
    ubuntu) [ "${vmajor:-0}" -ge 22 ] || die "Ubuntu ${VERSION_ID:-?} 太旧，需要 22.04 或更高" ;;
    debian) [ "${vmajor:-0}" -ge 12 ] || die "Debian ${VERSION_ID:-?} 太旧，需要 12 或更高" ;;
  esac

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)          ARCH="amd64" ;;
    aarch64|arm64)   ARCH="arm64" ;;
    *) die "不支持的 CPU 架构：$ARCH（只支持 x86_64 / arm64）" ;;
  esac

  command -v systemctl >/dev/null 2>&1 || die "本脚本依赖 systemd，当前系统没有 systemctl"

  log_info "系统：${PRETTY_NAME:-$OS_ID}，架构：${ARCH}"
}

apt_update_once() {
  [ "$APT_UPDATED" = "false" ] || return 0
  log_info "更新软件包索引..."
  if [ "$VERBOSE" = "true" ]; then
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get "${APT_OPTS[@]}" update -qq
  elif ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get "${APT_OPTS[@]}" update -qq >"$APT_LOG" 2>&1; then
    log_err "更新软件包索引失败，详细输出："
    tail -n 30 "$APT_LOG" >&2 || true
    die "请检查网络或软件源后重试"
  fi
  APT_UPDATED="true"
}

install_pkgs() {
  apt_update_once
  local pkgs="$*"
  log_info "安装软件包：${pkgs}"

  if [ "$VERBOSE" = "true" ]; then
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get "${APT_OPTS[@]}" install -y -qq --no-install-recommends "$@"
    log_ok "已安装：${pkgs}"
    return 0
  fi

  # 默认把 apt/dpkg 的滚动输出收进日志，终端只留一行进度；
  # 失败时再把日志尾部打出来，且不清屏，方便往上翻。
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get "${APT_OPTS[@]}" install -y -qq --no-install-recommends "$@" >"$APT_LOG" 2>&1; then
    log_err "安装失败，apt 输出（最后 40 行）："
    tail -n 40 "$APT_LOG" >&2 || true
    die "软件包安装失败：${pkgs}"
  fi
  log_ok "已安装：${pkgs}"
}

ensure_base_deps() {
  step "检查基础工具"
  local missing=()
  for cmd in curl tar openssl gpg sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_info "安装缺失工具：${missing[*]}"
    install_pkgs ca-certificates curl tar openssl gnupg
  fi
  log_ok "基础工具就绪"
}

rand_hex() { openssl rand -hex "$1"; }

env_get() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | sed -n '1p'
}

save_self() {
  # 保存一份脚本本体，供 sub 快捷命令离线使用。
  if [ -f "${BASH_SOURCE[0]:-}" ]; then
    if cp -f "${BASH_SOURCE[0]}" "$LOCAL_SCRIPT" 2>/dev/null; then
      chmod 0755 "$LOCAL_SCRIPT"
      return 0
    fi
  fi
  if curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$LOCAL_SCRIPT" 2>/dev/null; then
    chmod 0755 "$LOCAL_SCRIPT"
    return 0
  fi
  return 1
}

install_launcher() {
  if ! save_self; then
    log_warn "未能保存本地脚本副本，sub 每次会尝试从网络拉取"
  fi

  cat > "$SUB_BIN" <<EOF
#!/usr/bin/env bash
# Sub2API 快捷入口（由 deploy.sh 安装）
SCRIPT="${LOCAL_SCRIPT}"
if [ ! -f "\$SCRIPT" ]; then
  echo "本地脚本不存在，正在下载..."
  curl -fsSL "${SCRIPT_URL}" -o "\$SCRIPT" || { echo "下载失败，请检查网络"; exit 1; }
  chmod 0755 "\$SCRIPT"
fi
if [ "\$(id -u)" -ne 0 ]; then
  exec sudo bash "\$SCRIPT" "\$@"
fi
exec bash "\$SCRIPT" "\$@"
EOF
  chmod 0755 "$SUB_BIN"
  log_ok "已安装快捷命令：输入 sub 直接打开菜单（也支持 sub status / sub uninstall）"
}

check_memory() {
  local mem_kb swap_kb
  mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  swap_kb="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  mem_kb="${mem_kb:-0}"
  swap_kb="${swap_kb:-0}"
  if [ "$mem_kb" -lt 1500000 ] && [ "$swap_kb" -eq 0 ]; then
    log_warn "内存只有 $((mem_kb / 1024)) MB 且没有 swap；PostgreSQL + Redis + 应用可能触发 OOM。"
    log_warn "建议先加 1GB swap：fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
  fi
}

# ---------------------------------------------------------------- 端口

port_in_use() {
  local port="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -lntH 2>/dev/null)" || return 1
  elif command -v netstat >/dev/null 2>&1; then
    out="$(netstat -lnt 2>/dev/null)" || return 1
  else
    return 1
  fi
  # 不用 grep -q / head：它们提前退出会让上游吃到 SIGPIPE，
  # 在 pipefail 下被误判为失败（真机踩过）。
  printf '%s\n' "$out" | awk -v p=":${port}" '
    {
      n = split($0, a, " ")
      for (i = 1; i <= n; i++) {
        if (a[i] ~ (p "$")) { found = 1 }
      }
    }
    END { exit !found }'
}

# 从起始端口向后找空闲端口；找不到就返回起始端口（由调用方负责报错）
find_free_port() {
  local start="$1" i p
  for i in $(seq 0 50); do
    p=$((start + i))
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '%s' "$start"
  return 0
}

# ---------------------------------------------------------------- 状态文件

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    STATE_LOADED="true"
  fi
}

save_state() {
  [ -d "$CONF_DIR" ] || return 0
  umask 077
  {
    printf '# Sub2API 安装状态（由 deploy.sh 写入，卸载时依赖此文件；请勿手改）\n'
    printf 'ST_VERSION=1\n'
    printf 'ST_INSTALLED_AT=%s\n' "${ST_INSTALLED_AT:-$(date -Iseconds)}"
    printf 'ST_PG_VERSION=%s\n' "${ST_PG_VERSION:-}"
    printf 'ST_PG_CLUSTER=%s\n' "${ST_PG_CLUSTER:-}"
    printf 'ST_PG_PORT=%s\n' "${ST_PG_PORT:-}"
    printf 'ST_PG_CLUSTER_CREATED=%s\n' "${ST_PG_CLUSTER_CREATED:-false}"
    printf 'ST_PG_PACKAGES_CREATED=%s\n' "${ST_PG_PACKAGES_CREATED:-false}"
    printf 'ST_REDIS_PORT=%s\n' "${ST_REDIS_PORT:-}"
    printf 'ST_REDIS_BIN=%s\n' "${ST_REDIS_BIN:-}"
    printf 'ST_REDIS_PACKAGES_CREATED=%s\n' "${ST_REDIS_PACKAGES_CREATED:-false}"
    printf 'ST_REDIS_BUILT=%s\n' "${ST_REDIS_BUILT:-false}"
    printf 'ST_NGINX_PACKAGES_CREATED=%s\n' "${ST_NGINX_PACKAGES_CREATED:-false}"
    printf 'ST_CERTBOT_PACKAGES_CREATED=%s\n' "${ST_CERTBOT_PACKAGES_CREATED:-false}"
    printf 'ST_NGINX_SITE_CREATED=%s\n' "${ST_NGINX_SITE_CREATED:-false}"
    printf 'ST_CERT_CREATED=%s\n' "${ST_CERT_CREATED:-false}"
    printf 'ST_DOMAIN=%s\n' "${ST_DOMAIN:-}"
    printf 'ST_TLS_EMAIL=%s\n' "${ST_TLS_EMAIL:-}"
    printf 'ST_UFW_PORTS=%s\n' "${ST_UFW_PORTS:-}"
    printf 'ST_SERVER_PORT=%s\n' "${ST_SERVER_PORT:-}"
    printf 'ST_PGDG_REPO_CREATED=%s\n' "${ST_PGDG_REPO_CREATED:-false}"
    printf 'ST_REDIS_REPO_CREATED=%s\n' "${ST_REDIS_REPO_CREATED:-false}"
    printf 'ST_EXTRA_PKGS=%s\n' "${ST_EXTRA_PKGS:-}"
    umask 022
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

# ---------------------------------------------------------------- PostgreSQL（独立集群）

pg_cluster_exists() {
  pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 == c { found = 1 } END { exit !found }'
}

pg_cluster_port_of() {
  pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 == c { print $3 }' | sed -n '1p'
}

add_pgdg_repo() {
  log_info "添加 PostgreSQL 官方源（PGDG）..."
  install -d -m 0755 /usr/share/postgresql-common/pgdg

  log_info "下载 PGDG 公钥（超时 60 秒）..."
  if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc; then
    die "下载 PGDG 公钥失败（网络不通或超时）。
请确认服务器能访问 https://www.postgresql.org ；网络恢复后重跑即可。"
  fi

  printf 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' \
    "$OS_CODENAME" > /etc/apt/sources.list.d/pgdg.list
  ST_PGDG_REPO_CREATED="true"
  APT_UPDATED="false"
  apt_update_once
}

installed_pg_major() {
  ls -1 /usr/lib/postgresql 2>/dev/null | awk '/^[0-9]+$/ { print }' | sort -rn | sed -n '1p'
}

apt_pg_candidate_major() {
  local cand
  cand="$(apt-cache policy postgresql 2>/dev/null | sed -n 's/^ *Candidate: *//p' | sed -n '1p')"
  [ -n "$cand" ] || { printf '0'; return 0; }
  cand="${cand#*:}"
  printf '%s' "${cand%%.*}"
}

pg_clusters_snapshot() {
  pg_lsclusters -h 2>/dev/null | awk '{ print $1 "/" $2 }' | sort
}

ensure_pg_packages() {
  # 记录安装前已有的集群，用于识别「装包时自动带出来的空 main 集群」。
  PG_CLUSTERS_BEFORE="$(pg_clusters_snapshot)"

  local installed cand
  installed="$(installed_pg_major)"
  if [ -n "$installed" ] && [ "$installed" -ge 15 ]; then
    PG_VERSION_DEFAULT="$installed"
    log_info "已安装 PostgreSQL ${installed}，直接复用"
    return 0
  fi

  apt_update_once
  cand="$(apt_pg_candidate_major)"

  if [ -n "$cand" ] && [ "$cand" -ge 15 ]; then
    # Ubuntu 24.04 自带 16、Debian 12 自带 15，直接用发行版源，无需访问 postgresql.org。
    log_info "系统软件源已提供 PostgreSQL ${cand}，直接安装（不添加 PGDG 源）"
    install_pkgs postgresql postgresql-contrib
    PG_VERSION_DEFAULT="$cand"
  else
    log_info "系统软件源只提供 PostgreSQL ${cand:-未知}，改用 PGDG 官方源"
    if [ ! -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ] \
      || ! grep -qs 'apt.postgresql.org' /etc/apt/sources.list.d/pgdg.list; then
      add_pgdg_repo
    fi
    install_pkgs "postgresql-${PG_VERSION_DEFAULT}" "postgresql-client-${PG_VERSION_DEFAULT}" "postgresql-contrib-${PG_VERSION_DEFAULT}"
  fi

  ST_PG_PACKAGES_CREATED="true"

  installed="$(installed_pg_major)"
  if [ -n "$installed" ]; then
    PG_VERSION_DEFAULT="$installed"
  fi
  log_ok "已安装 PostgreSQL ${PG_VERSION_DEFAULT}"
}

ensure_pg_cluster() {
  # 安装包时 Debian/Ubuntu 通常会自动创建一个 main 空集群并占用 5432；
  # 如果装之前没有，这个 main 是本次安装的副产物，删掉以免多占端口。
  local main_key="${PG_VERSION_DEFAULT}/main"
  case "${PG_CLUSTERS_BEFORE:-}" in
    *"$main_key"*) ;;
    *)
      if pg_lsclusters -h 2>/dev/null | awk -v v="$PG_VERSION_DEFAULT" '$1 == v && $2 == "main" { found = 1 } END { exit !found }'; then
        log_info "清理安装包时自动创建的空集群 ${main_key}（不影响其他版本集群）"
        pg_dropcluster "$PG_VERSION_DEFAULT" main --stop >/dev/null 2>&1 || true
      fi
      ;;
  esac

  if pg_cluster_exists; then
    ST_PG_VERSION="$(pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 == c { print $1 }' | sed -n '1p')"
    ST_PG_CLUSTER="$PG_CLUSTER_NAME"
    ST_PG_PORT="$(pg_cluster_port_of)"
    log_info "独立集群 ${ST_PG_VERSION}/${PG_CLUSTER_NAME} 已存在（端口 ${ST_PG_PORT}），复用"
  else
    ST_PG_VERSION="$PG_VERSION_DEFAULT"
    ST_PG_CLUSTER="$PG_CLUSTER_NAME"
    ST_PG_PORT="$(find_free_port 5433)"

    local create_log
    create_log="$(mktemp)"
    if ! pg_createcluster "$ST_PG_VERSION" "$PG_CLUSTER_NAME" \
        --port "$ST_PG_PORT" --locale=C.UTF-8 --encoding=UTF8 --start >"$create_log" 2>&1; then
      log_err "创建独立 PostgreSQL 集群失败："
      cat "$create_log" >&2
      rm -f "$create_log"
      die "请检查端口 ${ST_PG_PORT} 是否被占用，或 PostgreSQL 日志"
    fi
    rm -f "$create_log"
    ST_PG_CLUSTER_CREATED="true"
    log_ok "已创建独立集群 ${ST_PG_VERSION}/${PG_CLUSTER_NAME}（端口 ${ST_PG_PORT}，不影响其他集群）"
  fi

  # 只操作这个集群本身：不 enable/restart 全局 postgresql 服务，
  # 避免改变机器上其他集群的开机行为。
  if ! pg_isready -h 127.0.0.1 -p "$ST_PG_PORT" -q; then
    pg_ctlcluster "$ST_PG_VERSION" "$PG_CLUSTER_NAME" start 2>/dev/null || true
  fi

  local i
  for i in $(seq 1 30); do
    if pg_isready -h 127.0.0.1 -p "$ST_PG_PORT" -q; then
      log_ok "PostgreSQL 就绪（127.0.0.1:${ST_PG_PORT}）"
      return 0
    fi
    sleep 1
  done
  die "独立 PostgreSQL 集群启动失败，查看：pg_lsclusters / journalctl -u postgresql@${ST_PG_VERSION}-${PG_CLUSTER_NAME}"
}

ensure_database() {
  step "创建数据库与账号（在独立集群内）"

  local role_exists db_exists
  role_exists="$(su - postgres -c "psql -p ${ST_PG_PORT} -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${SERVICE_USER}'\"")"
  if [ "$role_exists" = "1" ]; then
    su - postgres -c "psql -p ${ST_PG_PORT} -v ON_ERROR_STOP=1 -c \"ALTER ROLE ${SERVICE_USER} WITH LOGIN SUPERUSER PASSWORD '${DB_PASS}'\"" >/dev/null
    log_info "数据库账号 ${SERVICE_USER} 已存在，已同步密码"
  else
    su - postgres -c "psql -p ${ST_PG_PORT} -v ON_ERROR_STOP=1 -c \"CREATE ROLE ${SERVICE_USER} WITH LOGIN SUPERUSER PASSWORD '${DB_PASS}'\"" >/dev/null
    log_ok "已创建数据库账号 ${SERVICE_USER}"
  fi

  db_exists="$(su - postgres -c "psql -p ${ST_PG_PORT} -tAc \"SELECT 1 FROM pg_database WHERE datname='${SERVICE_USER}'\"")"
  if [ "$db_exists" != "1" ]; then
    su - postgres -c "createdb -p ${ST_PG_PORT} -O ${SERVICE_USER} ${SERVICE_USER}"
    log_ok "已创建数据库 ${SERVICE_USER}"
  else
    log_info "数据库 ${SERVICE_USER} 已存在，保留数据"
  fi

  # 迁移可能用到扩展；失败不影响主流程。
  su - postgres -c "psql -p ${ST_PG_PORT} -d ${SERVICE_USER} -q -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto'" >/dev/null 2>&1 || true
  su - postgres -c "psql -p ${ST_PG_PORT} -d ${SERVICE_USER} -q -c 'CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"'" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- Redis（独立实例）

redis_major() {
  redis-server --version 2>/dev/null | sed -nE 's/.*v=([0-9]+)\..*/\1/p' | sed -n '1p'
}

apt_candidate_major() {
  local cand
  # 不用 awk 'exit'：提前退出会让 apt-cache 收到 SIGPIPE，在 pipefail 下变成 141。
  cand="$(apt-cache policy redis-server 2>/dev/null \
    | sed -n 's/^ *Candidate: *//p' | sed -n '1p')"
  [ -n "$cand" ] || { printf '0'; return 0; }
  cand="${cand#*:}"
  printf '%s' "${cand%%.*}"
}

add_redis_repo() {
  log_info "添加 Redis 官方源..."
  install_pkgs ca-certificates curl gnupg
  log_info "下载 Redis 公钥（超时 60 秒）..."
  if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 \
      https://packages.redis.io/gpg \
      | gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg; then
    die "下载 Redis 公钥失败（网络不通或超时）。请确认服务器能访问 https://packages.redis.io"
  fi
  chmod 0644 /usr/share/keyrings/redis-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb %s main\n' \
    "$OS_CODENAME" > /etc/apt/sources.list.d/redis.list
  ST_REDIS_REPO_CREATED="true"
  APT_UPDATED="false"
  apt_update_once
}

build_redis() {
  log_warn "系统已有 Redis 低于 7 且可能被其他程序使用：不升级系统包，改为编译一份独立副本"

  if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    install_pkgs build-essential
    ST_REDIS_BUILT_PACKAGES="true"
  fi

  local tmp
  tmp="$(mktemp -d)"
  log_info "下载并编译 Redis ${REDIS_BUILD_VERSION}..."
  if ! curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
      -o "${tmp}/redis.tar.gz" \
      "https://download.redis.io/releases/redis-${REDIS_BUILD_VERSION}.tar.gz"; then
    rm -rf "$tmp"
    die "下载 Redis 源码失败；可改用系统 Redis（不推荐）或手动安装 Redis 7 后重跑"
  fi

  tar -xzf "${tmp}/redis.tar.gz" -C "$tmp"
  if ! make -C "${tmp}/redis-${REDIS_BUILD_VERSION}" -j"$(nproc)" >/dev/null 2>&1; then
    rm -rf "$tmp"
    die "编译 Redis 失败；可手动安装 Redis 7 后重跑"
  fi
  make -C "${tmp}/redis-${REDIS_BUILD_VERSION}" install PREFIX="${INSTALL_DIR}/redis" >/dev/null 2>&1
  rm -rf "$tmp"

  REDIS_BIN="${INSTALL_DIR}/redis/bin/redis-server"
  [ -x "$REDIS_BIN" ] || die "Redis 编译产物缺失：${REDIS_BIN}"
  ST_REDIS_BUILT="true"
  log_ok "已编译独立 Redis 到 ${INSTALL_DIR}/redis（未改动系统包）"
}

ensure_redis_binary() {
  step "准备 Redis 二进制"

  if [ -z "$REDIS_BIN" ] && [ -n "${ST_REDIS_BIN:-}" ] && [ -x "${ST_REDIS_BIN}" ]; then
    REDIS_BIN="$ST_REDIS_BIN"
  fi
  if [ -n "$REDIS_BIN" ] && [ -x "$REDIS_BIN" ]; then
    log_info "沿用已就绪的 Redis：${REDIS_BIN}"
    return 0
  fi

  if ! command -v redis-server >/dev/null 2>&1; then
    local cand
    cand="$(apt_candidate_major)"
    if [ "${cand:-0}" -lt 7 ]; then
      add_redis_repo
      install_pkgs redis
    else
      install_pkgs redis-server
    fi
    ST_REDIS_PACKAGES_CREATED="true"
    REDIS_BIN="$(command -v redis-server || true)"
    [ -n "$REDIS_BIN" ] || die "Redis 安装后找不到 redis-server"
    # 装包会顺带启用并启动一个 6379 的默认服务；我们只用它的二进制，
    # 关掉这个默认服务，避免多占端口、多一个不在本项目名下的实例。
    systemctl disable --now redis-server >/dev/null 2>&1 || true
    log_ok "已安装 Redis $(redis_major || echo '?')（默认 6379 服务已停用，本脚本使用独立实例）"
    return 0
  fi

  local major
  major="$(redis_major || echo 0)"
  if [ "${major:-0}" -ge 7 ]; then
    REDIS_BIN="$(command -v redis-server)"
    log_info "复用系统 Redis ${major} 的二进制（只读使用，不改配置、不改服务）"
  else
    build_redis
  fi
}

write_redis_conf() {
  umask 077
  cat > "$REDIS_CONF" <<EOF
# Sub2API 专用 Redis 实例（由 deploy.sh 生成，独立于系统 Redis）
bind 127.0.0.1
port ${ST_REDIS_PORT}
protected-mode yes
requirepass ${REDIS_PASS}
daemonize no
supervised no
dir ${REDIS_DATA_DIR}
dbfilename dump.rdb
appendonly yes
appenddirname appendonlydir
appendfsync everysec
save 60 1
logfile ""
loglevel notice
maxmemory-policy noeviction
EOF
  chmod 0640 "$REDIS_CONF"
  chown "root:${SERVICE_USER}" "$REDIS_CONF"
  umask 022
}

write_redis_unit() {
  cat > "$REDIS_UNIT_FILE" <<EOF
[Unit]
Description=Sub2API isolated Redis instance
Documentation=https://github.com/${REPO}
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${REDIS_BIN} ${REDIS_CONF}
Restart=always
RestartSec=3
LimitNOFILE=100000
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$REDIS_UNIT_FILE"
}

ensure_redis_instance() {
  step "创建独立 Redis 实例"

  ST_REDIS_BIN="$REDIS_BIN"

  if [ -z "${ST_REDIS_PORT:-}" ]; then
    ST_REDIS_PORT="$(find_free_port 6380)"
    log_info "为独立实例分配端口 ${ST_REDIS_PORT}（不改系统 Redis 的 6379）"
  fi

  if [ ! -d "$REDIS_DATA_DIR" ]; then
    install -d -m 0750 "$REDIS_DATA_DIR"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$REDIS_DATA_DIR"
  fi

  write_redis_conf
  write_redis_unit

  systemctl daemon-reload
  systemctl enable "$REDIS_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$REDIS_UNIT"

  local cli i
  cli="$(command -v redis-cli || true)"
  [ -n "$cli" ] || cli="${INSTALL_DIR}/redis/bin/redis-cli"

  for i in $(seq 1 20); do
    if "$cli" -h 127.0.0.1 -p "$ST_REDIS_PORT" -a "$REDIS_PASS" --no-auth-warning ping 2>/dev/null \
      | awk '/PONG/ { found = 1 } END { exit !found }'; then
      log_ok "独立 Redis 已就绪（127.0.0.1:${ST_REDIS_PORT}，仅本机，已设密码）"
      return 0
    fi
    sleep 1
  done
  log_err "Redis 实例启动失败，日志："
  journalctl -u "$REDIS_UNIT" -n 40 --no-pager || true
  die "独立 Redis 实例启动失败"
}

# ---------------------------------------------------------------- 应用

ensure_user_dirs() {
  step "创建系统用户与目录"

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/sh -d "$INSTALL_DIR" "$SERVICE_USER"
    log_ok "已创建系统用户 ${SERVICE_USER}"
  else
    local shell
    shell="$(getent passwd "$SERVICE_USER" | cut -d: -f7)"
    if [ "$shell" = "/bin/false" ] || [ "$shell" = "/sbin/nologin" ]; then
      usermod -s /bin/sh "$SERVICE_USER" || true
    fi
    log_info "系统用户 ${SERVICE_USER} 已存在"
  fi

  install -d -m 0755 "$INSTALL_DIR"
  install -d -m 0750 "$DATA_DIR"
  install -d -m 0750 "$CONF_DIR"
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
  # 目录属组给服务用户：Redis 进程以 sub2api 身份运行，需要能进入 /etc/sub2api
  # 读取自己的 redis.conf；env 与凭据文件仍是 600 root，服务用户读不到。
  chown "root:${SERVICE_USER}" "$CONF_DIR"
  chmod 0750 "$CONF_DIR"
}

resolve_version() {
  local api="https://api.github.com/repos/${REPO}/releases/latest"
  local tag=""

  # 注意：变量名不能用 VERSION —— detect_os 里 `. /etc/os-release` 会把它
  # 覆盖成系统版本（如 "24.04.3 LTS (Noble Numbat)"），真机踩过。
  if [ -n "$ARG_VERSION" ]; then
    tag="$ARG_VERSION"
    case "$tag" in v*) ;; *) tag="v${tag}" ;; esac
  else
    log_info "查询最新版本..."
    local raw=""
    raw="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 "$api" 2>/dev/null || true)"
    tag="$(printf '%s' "$raw" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
    [ -n "$tag" ] || die "获取最新版本失败。请检查网络，或用 --version vX.Y.Z 指定版本"
  fi

  # 防御：曾经因为变量被 /etc/os-release 覆盖，把系统版本当成 tag。
  case "$tag" in
    v[0-9]*) ;;
    *) die "版本号格式异常：${tag}（请用 --version vX.Y.Z 指定，例如 v1.2.3）" ;;
  esac

  RELEASE_TAG="$tag"
  RELEASE_VER="${tag#v}"
  log_info "目标版本：${RELEASE_TAG}"
}

download_binary() {
  local dest_dir="$1"
  local asset="sub2api_${RELEASE_VER}_linux_${ARCH}.tar.gz"
  local base="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
  local url="${base}/${asset}"
  local tmp
  tmp="$(mktemp -d)"

  if [ -n "$GH_PROXY" ]; then
    url="${GH_PROXY}/${url}"
  fi

  log_info "下载 ${asset}"
  if ! curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
      -o "${tmp}/${asset}" "$url"; then
    rm -rf "$tmp"
    die "下载失败：${url}
如果服务器在国内，可以加加速前缀重试，例如：
  sudo ${SELF_CMD} --gh-proxy https://ghproxy.net/"
  fi

  if curl -fsSL --retry 2 --max-time 40 -o "${tmp}/checksums.txt" "${GH_PROXY:+${GH_PROXY}/}${base}/checksums.txt"; then
    local expected actual
    expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1; exit }' "${tmp}/checksums.txt")"
    actual="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
    if [ -z "$expected" ]; then
      log_warn "checksums.txt 中没有 ${asset}，跳过校验"
    elif [ "$expected" != "$actual" ]; then
      rm -rf "$tmp"
      die "SHA-256 校验失败，已中止安装"
    else
      log_ok "SHA-256 校验通过"
    fi
  else
    log_warn "无法下载 checksums.txt，跳过校验"
  fi

  tar -xzf "${tmp}/${asset}" -C "$tmp"
  [ -f "${tmp}/sub2api" ] || { rm -rf "$tmp"; die "压缩包内没有 sub2api 二进制"; }

  install -m 0755 "${tmp}/sub2api" "${dest_dir}/sub2api"
  rm -rf "$tmp"
  log_ok "二进制已安装到 ${dest_dir}/sub2api"
}

load_or_generate_secrets() {
  step "准备密钥与管理员账号"

  DB_PASS="$(env_get DATABASE_PASSWORD)"
  REDIS_PASS="$(env_get REDIS_PASSWORD)"
  JWT_SECRET="$(env_get JWT_SECRET)"
  TOTP_KEY="$(env_get TOTP_ENCRYPTION_KEY)"
  local saved_admin_email saved_admin_pass saved_port
  saved_admin_email="$(env_get ADMIN_EMAIL)"
  saved_admin_pass="$(env_get ADMIN_PASSWORD)"
  saved_port="$(env_get SERVER_PORT)"

  if [ "$PORT_SET" = "false" ] && [ -n "$saved_port" ]; then
    PORT="$saved_port"
  fi

  DB_PASS="${DB_PASS:-$(rand_hex 24)}"
  REDIS_PASS="${REDIS_PASS:-$(rand_hex 24)}"
  JWT_SECRET="${JWT_SECRET:-$(rand_hex 32)}"
  TOTP_KEY="${TOTP_KEY:-$(rand_hex 32)}"

  IS_FIRST_INSTALL="true"
  if [ -f "${DATA_DIR}/.installed" ] || [ -f "${DATA_DIR}/config.yaml" ]; then
    IS_FIRST_INSTALL="false"
  fi

  if [ -n "$ARG_ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="$ARG_ADMIN_EMAIL"
  elif [ -n "${saved_admin_email:-}" ]; then
    ADMIN_EMAIL="$saved_admin_email"
  else
    ADMIN_EMAIL="admin-$(rand_hex 6)@sub2api.local"
  fi

  if [ -n "$ARG_ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$ARG_ADMIN_PASSWORD"
  elif [ -n "${saved_admin_pass:-}" ]; then
    ADMIN_PASSWORD="$saved_admin_pass"
  else
    ADMIN_PASSWORD="$(rand_hex 12)"
  fi

  case "$ADMIN_EMAIL" in
    *@*.*) ;;
    *) die "管理员账号必须是邮箱格式：$ADMIN_EMAIL" ;;
  esac
  local pass_len=${#ADMIN_PASSWORD}
  if [ "$pass_len" -lt 8 ] || [ "$pass_len" -gt 72 ]; then
    die "管理员密码长度必须在 8-72 字节之间（当前 ${pass_len}）"
  fi
  case "$ADMIN_PASSWORD" in
    *$'\n'*|*$'\r'*) die "管理员密码不能包含换行" ;;
  esac

  if [ "$IS_FIRST_INSTALL" = "false" ] && { [ -n "$ARG_ADMIN_EMAIL" ] || [ -n "$ARG_ADMIN_PASSWORD" ]; }; then
    log_warn "系统已初始化过，--admin-email / --admin-password 不会改动已有账号"
  fi

  log_ok "密钥与账号已就绪（管理员：${ADMIN_EMAIL}）"
}

write_env_file() {
  local host="$1"
  umask 077
  {
    printf '# Sub2API 运行配置（由 deploy.sh 生成，请勿提交到版本库）\n'
    printf 'AUTO_SETUP=true\n'
    printf 'DATA_DIR=%s\n' "$DATA_DIR"
    printf 'SERVER_HOST=%s\n' "$host"
    printf 'SERVER_PORT=%s\n' "$PORT"
    printf 'SERVER_MODE=release\n'
    printf 'SERVER_H2C_ENABLED=true\n'
    printf 'TZ=%s\n' "$TIMEZONE"
    printf '\n'
    printf 'DATABASE_HOST=127.0.0.1\n'
    printf 'DATABASE_PORT=%s\n' "$ST_PG_PORT"
    printf 'DATABASE_USER=%s\n' "$SERVICE_USER"
    printf 'DATABASE_PASSWORD=%s\n' "$DB_PASS"
    printf 'DATABASE_DBNAME=%s\n' "$SERVICE_USER"
    printf 'DATABASE_SSLMODE=disable\n'
    printf 'DATABASE_MAX_OPEN_CONNS=50\n'
    printf 'DATABASE_MAX_IDLE_CONNS=10\n'
    printf '\n'
    printf 'REDIS_HOST=127.0.0.1\n'
    printf 'REDIS_PORT=%s\n' "$ST_REDIS_PORT"
    printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASS"
    printf 'REDIS_DB=0\n'
    printf 'REDIS_POOL_SIZE=512\n'
    printf 'REDIS_MIN_IDLE_CONNS=32\n'
    printf '\n'
    printf 'JWT_SECRET=%s\n' "$JWT_SECRET"
    printf 'JWT_EXPIRE_HOUR=24\n'
    printf 'TOTP_ENCRYPTION_KEY=%s\n' "$TOTP_KEY"
    printf '\n'
    printf 'ADMIN_EMAIL=%s\n' "$ADMIN_EMAIL"
    printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
    printf '\n'
    printf 'LOG_LEVEL=info\n'
    printf 'LOG_FORMAT=json\n'
    printf 'LOG_OUTPUT_TO_STDOUT=true\n'
    printf 'LOG_OUTPUT_TO_FILE=true\n'
    umask 022
  } > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  chown root:root "$ENV_FILE"
}

write_unit_file() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Sub2API - AI API Gateway Platform
Documentation=https://github.com/${REPO}
After=network-online.target postgresql@${ST_PG_VERSION}-${PG_CLUSTER_NAME}.service ${REDIS_UNIT}.service
Wants=network-online.target postgresql@${ST_PG_VERSION}-${PG_CLUSTER_NAME}.service ${REDIS_UNIT}.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/sub2api
Restart=always
RestartSec=5
LimitNOFILE=100000
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT_FILE"
}

wait_health() {
  local i
  for i in $(seq 1 100); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! systemctl is-active --quiet "$SERVICE"; then
      return 1
    fi
    sleep 3
  done
  return 1
}

prompt_domain_config() {
  local ans="" d="" e=""
  printf '是否绑定域名并启用 HTTPS？(y/N) ' > /dev/tty
  read -r ans < /dev/tty || ans=""
  case "$ans" in
    [Yy]*) ;;
    *) return 1 ;;
  esac

  while true; do
    printf '  域名（例如 api.example.com）: ' > /dev/tty
    read -r d < /dev/tty || d=""
    case "$d" in
      ''|*[!A-Za-z0-9.-]*) printf '  域名只能含字母、数字、点和连字符，请重试\n' > /dev/tty ;;
      *) break ;;
    esac
  done

  while true; do
    printf '  证书通知邮箱: ' > /dev/tty
    read -r e < /dev/tty || e=""
    case "$e" in
      *@*.*) break ;;
      *) printf '  邮箱格式不对，请重试\n' > /dev/tty ;;
    esac
  done

  DOMAIN="$d"
  TLS_EMAIL="$e"
  printf '  将使用 https://%s（需域名已解析到本机、80/443 可访问）\n' "$DOMAIN" > /dev/tty
  return 0
}

# 把应用切到域名模式并配置 Nginx/证书；失败则回退 0.0.0.0。
# $1 = true 时先改监听地址并重启（已有安装在运行的情况）。
ensure_domain_setup() {
  local restart_first="$1"

  if [ "$restart_first" = "true" ]; then
    write_env_file "127.0.0.1"
    systemctl restart "$SERVICE"
    wait_health || log_err "服务重启后健康检查未通过：journalctl -u ${SERVICE} -n 60 --no-pager"
  fi

  if setup_nginx; then
    save_state
    return 0
  fi

  log_warn "Nginx 配置未完成，回退为监听 0.0.0.0，改用 IP:${PORT} 访问"
  write_env_file "0.0.0.0"
  if command -v ufw >/dev/null 2>&1 \
    && ufw status 2>/dev/null | awk '/Status: active/ { found = 1 } END { exit !found }'; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    ST_UFW_PORTS="${ST_UFW_PORTS:+${ST_UFW_PORTS},}${PORT}/tcp"
  fi
  systemctl restart "$SERVICE"
  wait_health || log_err "服务重启后健康检查未通过：journalctl -u ${SERVICE} -n 60 --no-pager"
  save_state
  return 1
}

start_service() {
  step "启动应用"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE"; then
    log_err "systemd 启动失败，最近日志："
    journalctl -u "$SERVICE" -n 60 --no-pager || true
    die "服务无法启动"
  fi

  log_info "等待服务就绪（首次启动要跑数据库迁移，可能需要 1-3 分钟）..."
  if wait_health; then
    log_ok "服务已启动，健康检查通过"
    return 0
  fi

  log_err "服务未能通过健康检查，最近日志："
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  die "启动失败。常见原因：数据库/Redis 连接失败、迁移超时。"
}

ensure_app_port_free() {
  if ! port_in_use "$PORT"; then
    return 0
  fi
  # 重装时端口可能被自己占用
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    return 0
  fi
  die "端口 ${PORT} 已被其他程序占用。请换端口：sudo ${SELF_CMD} --port 其它端口"
}

# ---------------------------------------------------------------- Nginx / HTTPS

nginx_http_only_conf() {
  cat <<'NGINX'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    client_max_body_size 256m;
    underscores_in_headers on;

    location / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
}

nginx_tls_conf() {
  cat <<'NGINX'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 256m;
    underscores_in_headers on;

    location / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
}

render_nginx_conf() {
  local src="$1"
  sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__PORT__|${PORT}|g" "$src" > "$NGINX_SITE"
}

setup_nginx() {
  step "配置 Nginx 反向代理与 HTTPS"

  if ! dpkg -s nginx >/dev/null 2>&1; then
    install_pkgs nginx
    ST_NGINX_PACKAGES_CREATED="true"
  fi
  if ! dpkg -s certbot >/dev/null 2>&1; then
    ST_CERTBOT_PACKAGES_CREATED="true"
  fi
  install_pkgs certbot python3-certbot-nginx

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/sub2api.conf
  ST_NGINX_SITE_CREATED="true"
  # 先记下域名：即使后面证书失败，status/重跑也能知道配的是哪个域名。
  ST_DOMAIN="$DOMAIN"
  ST_TLS_EMAIL="$TLS_EMAIL"

  local tmp_http tmp_tls cert_dir
  tmp_http="$(mktemp)"
  tmp_tls="$(mktemp)"
  nginx_http_only_conf > "$tmp_http"
  nginx_tls_conf > "$tmp_tls"
  cert_dir="/etc/letsencrypt/live/${DOMAIN}"

  render_nginx_conf "$tmp_http"
  if ! nginx -t >/dev/null 2>&1; then
    log_err "Nginx 配置校验失败，可能是 80 端口被其他站点占用："
    nginx -t || true
    rm -f /etc/nginx/sites-enabled/sub2api.conf
    rm -f "$tmp_http" "$tmp_tls"
    ST_NGINX_SITE_CREATED="false"
    return 1
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  if [ ! -f "${cert_dir}/fullchain.pem" ]; then
    log_info "正在申请 Let's Encrypt 证书（需要 ${DOMAIN} 已解析到本机、80 端口可访问）..."
    local cert_ok="false"
    if [ "$VERBOSE" = "true" ]; then
      if certbot certonly --nginx -d "$DOMAIN" -m "$TLS_EMAIL" \
          --agree-tos --non-interactive --keep-until-expiring; then
        cert_ok="true"
      fi
    else
      if certbot certonly --nginx -d "$DOMAIN" -m "$TLS_EMAIL" \
          --agree-tos --non-interactive --keep-until-expiring >>"$APT_LOG" 2>&1; then
        cert_ok="true"
      fi
    fi
    if [ "$cert_ok" != "true" ]; then
      if [ "$VERBOSE" != "true" ]; then
        log_err "certbot 输出（最后 20 行）："
        tail -n 20 "$APT_LOG" >&2 || true
      fi

      # 证书失败最常见的两个原因：DNS 没指向本机、80 端口不通。先查解析。
      local dns_ips="" pub=""
      dns_ips="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')"
      pub="$(get_public_ip || true)"
      if [ -n "$dns_ips" ] && [ -n "$pub" ]; then
        case " ${dns_ips} " in
          *" ${pub} "*) ;;
          *)
            log_warn "域名当前解析到：${dns_ips}"
            log_warn "本机公网 IP 是：${pub}"
            log_warn "两者不一致，Let's Encrypt 会去旧地址验证，证书必然失败。"
            log_warn "请把 A 记录改成 ${pub}，等解析生效后再执行：sudo ${SELF_CMD} domain"
            ;;
        esac
      fi

      log_warn "证书申请失败，暂时保留 HTTP 访问"
      log_warn "排查后重跑本脚本即可继续申请：sudo ${SELF_CMD} --domain ${DOMAIN} --email ${TLS_EMAIL}"
      rm -f "$tmp_http" "$tmp_tls"
      return 1
    fi
    ST_CERT_CREATED="true"
  fi

  render_nginx_conf "$tmp_tls"
  if ! nginx -t >/dev/null 2>&1; then
    log_err "HTTPS 配置校验失败："
    nginx -t || true
    rm -f "$tmp_http" "$tmp_tls"
    return 1
  fi
  systemctl reload nginx

  rm -f "$tmp_http" "$tmp_tls"
  ST_DOMAIN="$DOMAIN"
  ST_TLS_EMAIL="$TLS_EMAIL"
  log_ok "HTTPS 已启用：https://${DOMAIN}"
}

# ---------------------------------------------------------------- 摘要

get_public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 5 https://ipinfo.io/ip 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

write_credentials() {
  umask 077
  {
    printf '# Sub2API 部署凭据（由 deploy.sh 生成）\n'
    printf '# 生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '访问地址   : %s\n' "$1"
    printf '管理员账号 : %s\n' "$ADMIN_EMAIL"
    printf '管理员密码 : %s\n' "$ADMIN_PASSWORD"
    printf '\n# 数据库（独立 PostgreSQL 集群 %s/%s，仅本机）\n' "$ST_PG_VERSION" "$PG_CLUSTER_NAME"
    printf 'DB_HOST=127.0.0.1\n'
    printf 'DB_PORT=%s\n' "$ST_PG_PORT"
    printf 'DB_NAME=%s\n' "$SERVICE_USER"
    printf 'DB_USER=%s\n' "$SERVICE_USER"
    printf 'DB_PASSWORD=%s\n' "$DB_PASS"
    printf '\n# 缓存（独立 Redis 实例 %s，仅本机）\n' "$REDIS_UNIT"
    printf 'REDIS_PORT=%s\n' "$ST_REDIS_PORT"
    printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASS"
    printf '\n# 应用配置\n'
    printf 'ENV_FILE=%s\n' "$ENV_FILE"
    printf 'STATE_FILE=%s\n' "$STATE_FILE"
    printf 'JWT_SECRET=%s\n' "$JWT_SECRET"
    printf 'TOTP_ENCRYPTION_KEY=%s\n' "$TOTP_KEY"
    umask 022
  } > "$CRED_FILE"
  chmod 0600 "$CRED_FILE"
  chown root:root "$CRED_FILE"
}

print_summary() {
  local url="$1"
  local version=""
  version="$(app_version)"

  echo ""
  printf '%s==============================================%s\n' "$C_GREEN" "$C_RESET"
  printf '%s  Sub2API 部署完成%s\n' "$C_GREEN" "$C_RESET"
  printf '%s==============================================%s\n' "$C_GREEN" "$C_RESET"
  echo ""
  echo "  访问地址：${url}"
  echo "  管理员账号：${ADMIN_EMAIL}"
  echo "  管理员密码：${ADMIN_PASSWORD}"
  echo ""
  echo "  数据库：独立集群 ${ST_PG_VERSION}/${PG_CLUSTER_NAME}（127.0.0.1:${ST_PG_PORT}）"
  echo "  缓存  ：独立实例 ${REDIS_UNIT}（127.0.0.1:${ST_REDIS_PORT}）"
  echo "  版本  ：${version:-未知}"
  echo ""
  echo "  本脚本没有改动系统原有的 PostgreSQL / Redis，它们可以继续正常服务。"
  echo ""
  echo "  凭据文件：${CRED_FILE}（权限 600，仅 root 可读）"
  echo "  应用配置：${ENV_FILE}"
  echo "  安装状态：${STATE_FILE}（卸载依赖它，请勿删除）"
  echo ""
  echo "  常用命令："
  echo "    sub                     再次打开本菜单"
  echo "    systemctl status ${SERVICE}"
  echo "    journalctl -u ${SERVICE} -f"
  echo "    systemctl restart ${SERVICE}"
  echo ""
  if [ -n "$DOMAIN" ] && [ "${HTTPS_OK:-false}" = "true" ]; then
    echo "  首次登录后请在后台「系统设置」里确认站点地址为 https://${DOMAIN}"
  elif [ -n "$DOMAIN" ]; then
    echo "  域名 ${DOMAIN} 已配置，但 HTTPS 没成功（当前仍用上面的 IP:端口 访问）。"
    echo "  修好 DNS 解析或 80 端口后执行：sudo ${SELF_CMD} domain"
  else
    echo "  提示：当前用 IP:端口 直接访问。要绑定域名并自动上 HTTPS，执行："
    echo "    sudo ${SELF_CMD} domain"
  fi
  echo ""
  echo "  完全卸载（不留痕迹）："
  echo "    sudo ${SELF_CMD} uninstall"
  echo ""
}

# ---------------------------------------------------------------- 卸载辅助

nginx_other_sites() {
  local count=0 f
  for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      sub2api.conf|default) continue ;;
    esac
    count=$((count + 1))
  done
  printf '%s' "$count"
}

other_pg_clusters() {
  pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 != c { n++ } END { print n + 0 }'
}

other_redis_units() {
  local n=""
  n="$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '^(redis|redis-server)' | grep -v "^${REDIS_UNIT}.service$" | wc -l || true)"
  n="${n//[[:space:]]/}"
  printf '%s' "${n:-0}"
}

purge_pg_packages() {
  if [ "${ST_PG_PACKAGES_CREATED:-false}" != "true" ]; then
    return 0
  fi
  # 实际安装的版本可能是 15（Debian 12）或 16（Ubuntu 24.04 / PGDG）。
  local pg_ver="${ST_PG_VERSION:-$PG_VERSION_DEFAULT}"
  if [ "$(other_pg_clusters)" -gt 0 ]; then
    log_warn "机器上还有其他 PostgreSQL 集群，保留 postgresql-${pg_ver} 软件包"
    return 0
  fi
  log_info "卸载脚本安装的 PostgreSQL 软件包（版本 ${pg_ver}）..."
  apt-get "${APT_OPTS[@]}" purge -y -qq "postgresql-${pg_ver}" "postgresql-client-${pg_ver}" "postgresql-contrib-${pg_ver}" \
    >/dev/null 2>&1 || log_warn "PostgreSQL 软件包卸载未完全成功，可手动检查 dpkg -l | grep postgresql"

  # 机器上已无任何其他 PostgreSQL 版本时，连公共包一起清掉，避免 dpkg 残留。
  local others
  others="$(dpkg-query -W -f='${Package}\n' 'postgresql-*' 2>/dev/null \
    | grep -vE '^(postgresql-common|postgresql-client-common)$' | wc -l || true)"
  others="${others//[[:space:]]/}"
  if [ "${others:-0}" -eq 0 ]; then
    apt-get "${APT_OPTS[@]}" purge -y -qq postgresql-common postgresql-client-common >/dev/null 2>&1 || true
    if [ "${ST_PGDG_REPO_CREATED:-false}" = "true" ]; then
      rm -f /etc/apt/sources.list.d/pgdg.list /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
      log_info "已移除本脚本添加的 PGDG 软件源"
    fi
  fi
}

purge_redis_packages() {
  if [ "${ST_REDIS_PACKAGES_CREATED:-false}" != "true" ] || [ "${ST_REDIS_BUILT:-false}" = "true" ]; then
    return 0
  fi
  if [ "$(other_redis_units)" -gt 1 ]; then
    log_warn "机器上还有其他 Redis 服务单元，保留 Redis 软件包"
    return 0
  fi
  log_info "卸载脚本安装的 Redis 软件包..."
  apt-get "${APT_OPTS[@]}" purge -y -qq redis redis-server redis-tools >/dev/null 2>&1 \
    || log_warn "Redis 软件包卸载未完全成功，可手动检查 dpkg -l | grep redis"

  if [ "${ST_REDIS_REPO_CREATED:-false}" = "true" ]; then
    local left
    left="$(dpkg-query -W -f='${Package}\n' 'redis*' 2>/dev/null | wc -l || true)"
    left="${left//[[:space:]]/}"
    if [ "${left:-0}" -eq 0 ]; then
      rm -f /etc/apt/sources.list.d/redis.list /usr/share/keyrings/redis-archive-keyring.gpg
      log_info "已移除本脚本添加的 Redis 软件源"
    fi
  fi
}

purge_nginx_packages() {
  if [ "${ST_NGINX_PACKAGES_CREATED:-false}" != "true" ]; then
    return 0
  fi
  if [ "$(nginx_other_sites)" -gt 0 ]; then
    log_warn "Nginx 上还有其他站点，保留 Nginx 软件包"
    return 0
  fi
  log_info "卸载脚本安装的 Nginx 软件包..."
  apt-get "${APT_OPTS[@]}" purge -y -qq nginx nginx-common >/dev/null 2>&1 \
    || log_warn "Nginx 软件包卸载未完全成功，可手动检查 dpkg -l | grep nginx"

  if [ "${ST_CERTBOT_PACKAGES_CREATED:-false}" = "true" ]; then
    apt-get "${APT_OPTS[@]}" purge -y -qq certbot python3-certbot-nginx >/dev/null 2>&1 \
      || log_warn "certbot 卸载未完全成功，可手动检查 dpkg -l | grep certbot"
  fi
}

verify_clean() {
  step "残留自检"

  local issues=0

  check_path() {
    if [ -e "$1" ]; then
      log_warn "残留：$1"
      issues=$((issues + 1))
    fi
  }
  check_unit() {
    if systemctl list-unit-files 2>/dev/null | awk -v u="$1" '$1 == u { found = 1 } END { exit !found }'; then
      log_warn "残留服务单元：$1"
      issues=$((issues + 1))
    fi
  }

  check_path "$INSTALL_DIR"
  check_path "$CONF_DIR"
  check_path "$SUB_BIN"
  check_path "$APT_LOG"
  if [ -n "${ST_PG_VERSION:-}" ]; then
    check_path "/var/log/postgresql/postgresql-${ST_PG_VERSION}-${PG_CLUSTER_NAME}.log"
  fi
  check_unit "${SERVICE}.service"
  check_unit "${REDIS_UNIT}.service"

  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log_warn "残留系统用户：$SERVICE_USER"
    issues=$((issues + 1))
  fi
  if pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 == c { found = 1 } END { exit !found }'; then
    log_warn "残留 PostgreSQL 集群：${PG_CLUSTER_NAME}"
    issues=$((issues + 1))
  fi
  if [ -n "${PORT:-}" ] && port_in_use "$PORT"; then
    log_warn "端口 ${PORT} 仍在监听（可能是其他程序）"
    issues=$((issues + 1))
  fi

  if [ "$issues" -eq 0 ]; then
    log_ok "未发现本项目的残留"
  else
    log_warn "发现 ${issues} 处残留，请按上面的提示处理"
  fi
}

# ---------------------------------------------------------------- 命令

cmd_install() {
  require_root "$@"
  detect_os
  check_memory

  # 交互安装（从菜单进入）时询问是否配域名；带 --domain 或非交互环境则跳过。
  if [ -z "$DOMAIN" ] && [ "$FROM_MENU" = "true" ] && have_tty; then
    if prompt_domain_config; then
      log_info "已选择域名模式：${DOMAIN}"
    fi
  fi

  ensure_base_deps
  load_state
  # 重装时如果没显式指定域名，沿用上次的域名配置（避免意外从 HTTPS 退回 IP 直连）
  if [ -z "$DOMAIN" ] && [ -n "${ST_DOMAIN:-}" ]; then
    DOMAIN="$ST_DOMAIN"
    TLS_EMAIL="${TLS_EMAIL:-${ST_TLS_EMAIL:-}}"
  fi
  ensure_user_dirs
  load_or_generate_secrets
  ensure_app_port_free

  ensure_pg_packages
  ensure_pg_cluster
  save_state

  ensure_database
  ensure_redis_binary
  ensure_redis_instance
  save_state

  step "下载 Sub2API"
  resolve_version
  if systemctl is-active --quiet "$SERVICE"; then
    systemctl stop "$SERVICE" || true
  fi
  if [ -x "${INSTALL_DIR}/sub2api" ]; then
    cp -f "${INSTALL_DIR}/sub2api" "${INSTALL_DIR}/sub2api.bak"
    log_info "已备份旧二进制到 ${INSTALL_DIR}/sub2api.bak"
  fi
  download_binary "$INSTALL_DIR"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/sub2api"

  local server_host="0.0.0.0"
  if [ -n "$DOMAIN" ]; then
    server_host="127.0.0.1"
  fi

  step "写入运行配置"
  write_env_file "$server_host"
  write_unit_file
  ST_SERVER_PORT="$PORT"
  log_ok "配置已写入 ${ENV_FILE}"

  start_service
  open_firewall

  local url="" nginx_ok="true"
  if [ -n "$DOMAIN" ]; then
    if ensure_domain_setup false; then
      url="https://${DOMAIN}"
      HTTPS_OK="true"
    else
      nginx_ok="false"
      HTTPS_OK="false"
      local ip=""
      ip="$(get_public_ip || true)"
      [ -n "$ip" ] || ip="服务器IP"
      url="http://${ip}:${PORT}"
    fi
  else
    local ip=""
    ip="$(get_public_ip || true)"
    [ -n "$ip" ] || ip="服务器IP"
    url="http://${ip}:${PORT}"
  fi

  ST_INSTALLED_AT="${ST_INSTALLED_AT:-$(date -Iseconds)}"
  save_state
  write_credentials "$url"
  print_summary "$url"
  install_launcher
  if [ "$nginx_ok" = "false" ]; then
    log_warn "HTTPS 没配成功：按上面的提示排查后，执行 sudo ${SELF_CMD} domain 重试"
  fi

  if [ "$IS_FIRST_INSTALL" = "false" ]; then
    log_info "检测到已有数据，本次为升级/重配，未改动数据库与管理员账号"
  fi
}

open_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | awk '/Status: active/ { found = 1 } END { exit !found }' || return 0

  if [ -n "$DOMAIN" ]; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ST_UFW_PORTS="80/tcp,443/tcp"
  else
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    ST_UFW_PORTS="${PORT}/tcp"
  fi
  log_info "已在 ufw 放行端口（卸载时会移除对应规则）"
}

cmd_upgrade() {
  require_root "$@"
  detect_os
  [ -x "${INSTALL_DIR}/sub2api" ] || die "尚未安装，请先执行：sudo ${SELF_CMD} install"
  [ -f "$ENV_FILE" ] || die "找不到 ${ENV_FILE}，安装可能已损坏"

  load_state
  PORT="$(env_get SERVER_PORT)"
  [ -n "$PORT" ] || PORT="8080"
  ensure_base_deps

  resolve_version
  local current
  current="$(app_version)"
  log_info "当前版本：${current:-未知}"

  step "升级"
  systemctl stop "$SERVICE" 2>/dev/null || true
  cp -f "${INSTALL_DIR}/sub2api" "${INSTALL_DIR}/sub2api.bak"
  download_binary "$INSTALL_DIR"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/sub2api"
  start_service

  # 顺手更新本地脚本副本，sub 下次打开就是新版
  save_self >/dev/null 2>&1 || true

  log_ok "升级完成：$(app_version)"
  log_info "回滚方式：cp ${INSTALL_DIR}/sub2api.bak ${INSTALL_DIR}/sub2api && systemctl restart ${SERVICE}"
}

app_version() {
  local out="" v=""
  out="$("${INSTALL_DIR}/sub2api" --version 2>/dev/null || true)"
  v="$(printf '%s' "$out" | sed -n 's/.*Sub2API \([0-9][^ ]*\).*/\1/p' | sed -n '1p')"
  [ -n "$v" ] || v="$(printf '%s' "$out" | sed -n '1p')"
  printf '%s' "$v"
}

access_url() {
  local domain="${ST_DOMAIN:-}"
  if [ -n "$domain" ]; then
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
      printf 'https://%s' "$domain"
    else
      printf 'http://%s' "$domain"
    fi
    return 0
  fi
  local ip=""
  ip="$(get_public_ip || true)"
  [ -n "$ip" ] || ip="<服务器IP>"
  printf 'http://%s:%s' "$ip" "$PORT"
}

is_listening() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -lntH 2>/dev/null | awk -v p=":${port}" '$4 ~ (p "$") { found = 1 } END { exit !found }'
}

status_domain_diagnostics() {
  local domain="$1" issues=0 dns_ips="" pub="" ip

  echo "--- 域名与 HTTPS 检查 ---"

  pub="$(get_public_ip || true)"
  dns_ips="$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')"
  if [ -n "$dns_ips" ]; then
    echo "DNS 解析  ：${dns_ips}"
    if [ -n "$pub" ]; then
      case " ${dns_ips} " in
        *" ${pub} "*) ;;
        *)
          log_warn "域名解析到的 IP 与服务器公网 IP（${pub}）不一致"
          issues=$((issues + 1))
          ;;
      esac
    fi
  else
    log_warn "域名无法解析（DNS 未生效或解析未指向本机）"
    issues=$((issues + 1))
  fi

  if systemctl is-active nginx >/dev/null 2>&1; then
    echo "Nginx     ：运行中"
  else
    log_warn "Nginx 未运行：systemctl status nginx"
    issues=$((issues + 1))
  fi

  if is_listening 80; then
    echo "80 端口   ：本机监听中"
  else
    log_warn "本机没有监听 80 端口（Nginx 未启动或配置未生效）"
    issues=$((issues + 1))
  fi

  if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
    if is_listening 443; then
      echo "443 端口  ：本机监听中"
    else
      log_warn "证书已签发但本机没有监听 443"
      issues=$((issues + 1))
    fi
  else
    log_warn "证书未签发，HTTPS 不可用：重跑 domain 命令申请"
    issues=$((issues + 1))
  fi

  echo ""
  echo "  云服务器（阿里云 / 腾讯云）还需在控制台【安全组】放行 80、443；"
  echo "  脚本只能改本机防火墙，改不了云安全组。"
  echo "  自测：curl -I http://${domain}"
  echo ""

  if [ "$issues" -eq 0 ]; then
    log_ok "域名相关检查未发现问题"
  else
    log_warn "发现 ${issues} 处问题，按上面的提示处理"
  fi
}

cmd_status() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/sub2api" ] || die "尚未安装"

  load_state
  PORT="$(env_get SERVER_PORT)"
  [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-8080}"

  local domain="${ST_DOMAIN:-}"
  local url
  url="$(access_url)"

  echo ""
  echo "访问地址：${url}"
  if [ -n "$domain" ]; then
    echo "域名    ：${domain}"
  fi
  echo "版本    ：$(app_version)"
  echo "端口    ：${PORT}"
  echo ""
  systemctl is-active "$SERVICE" >/dev/null 2>&1 && echo "应用      ：运行中" || echo "应用      ：未运行"
  systemctl is-active "$REDIS_UNIT" >/dev/null 2>&1 && echo "Redis     ：运行中（:${ST_REDIS_PORT:-?}）" || echo "Redis     ：未运行"
  if [ -n "${ST_PG_PORT:-}" ] && pg_isready -h 127.0.0.1 -p "$ST_PG_PORT" -q; then
    echo "PostgreSQL：运行中（:${ST_PG_PORT}）"
  else
    echo "PostgreSQL：未运行"
  fi
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "健康检查  ：通过"
  else
    echo "健康检查  ：失败"
  fi
  echo ""

  if [ -n "$domain" ]; then
    status_domain_diagnostics "$domain"
    echo ""
  fi

  systemctl status "$SERVICE" --no-pager -l | sed -n '1,20p' || true
}

cmd_uninstall() {
  require_root "$@"
  detect_os
  load_state

  local pg_ver="${ST_PG_VERSION:-}" pg_port="${ST_PG_PORT:-}" redis_port="${ST_REDIS_PORT:-}"
  local domain="${ST_DOMAIN:-$DOMAIN}" ufw_ports="${ST_UFW_PORTS:-}"

  PORT="$(env_get SERVER_PORT)"
  [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-8080}"

  echo ""
  log_warn "即将卸载 Sub2API 并清理本脚本创建的全部资源："
  echo "  - 应用服务、systemd 单元、/opt/sub2api、/etc/sub2api"
  echo "  - 独立 PostgreSQL 集群 ${pg_ver:-16}/${PG_CLUSTER_NAME}${pg_port:+（端口 ${pg_port}）}"
  echo "  - 独立 Redis 实例 ${REDIS_UNIT}${redis_port:+（端口 ${redis_port}）}"
  echo "  - 系统用户 ${SERVICE_USER}"
  if [ "$KEEP_DATA" = "true" ]; then
    echo "  - 数据库与缓存数据：先备份到 /var/backups 再删除"
  else
    echo "  - 数据库与缓存数据：一并删除"
  fi
  echo ""
  echo "  不会动：系统原有的 PostgreSQL / Redis / Nginx 软件与服务。"
  echo ""

  if [ "$ASSUME_YES" != "true" ]; then
    if ! prompt_confirm '确认继续？(y/N) '; then
      log_info "已取消"
      return 0
    fi
  fi

  [ "$INSTALL_DIR" = "/opt/sub2api" ] || die "安装路径异常（${INSTALL_DIR}），已中止"
  [ "$CONF_DIR" = "/etc/sub2api" ] || die "配置路径异常（${CONF_DIR}），已中止"

  step "停止并移除应用"
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload

  step "停止独立 Redis 实例"
  systemctl stop "$REDIS_UNIT" 2>/dev/null || true
  systemctl disable "$REDIS_UNIT" 2>/dev/null || true
  rm -f "$REDIS_UNIT_FILE"
  systemctl daemon-reload

  local backup_dir=""
  if [ "$KEEP_DATA" = "true" ]; then
    step "备份数据"
    backup_dir="/var/backups/sub2api-$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "$backup_dir"
    if [ -n "$pg_port" ] && pg_isready -h 127.0.0.1 -p "$pg_port" -q; then
      if su - postgres -c "pg_dump -p ${pg_port} -d ${SERVICE_USER} -Fc" > "${backup_dir}/sub2api.dump" 2>/dev/null; then
        chmod 0600 "${backup_dir}/sub2api.dump"
        log_ok "数据库已导出：${backup_dir}/sub2api.dump"
      else
        rm -f "${backup_dir}/sub2api.dump"
        log_warn "数据库导出失败，继续卸载"
      fi
    fi
    if [ -d "$REDIS_DATA_DIR" ]; then
      if cp -a "$REDIS_DATA_DIR" "${backup_dir}/redis-data" 2>/dev/null; then
        log_ok "Redis 数据已复制：${backup_dir}/redis-data"
      else
        log_warn "Redis 数据复制失败，继续卸载"
      fi
    fi
  fi

  step "移除 Nginx 站点"
  if [ -f /etc/nginx/sites-enabled/sub2api.conf ] || [ -f "$NGINX_SITE" ]; then
    rm -f /etc/nginx/sites-enabled/sub2api.conf "$NGINX_SITE"
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    fi
    log_info "已移除 Sub2API 的 Nginx 站点（其他站点不受影响）"
  fi

  if [ "${ST_CERT_CREATED:-false}" = "true" ] && [ -n "$domain" ]; then
    if [ -d "/etc/letsencrypt/live/${domain}" ]; then
      log_info "删除为 ${domain} 申请的证书..."
      certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 \
        || log_warn "证书删除失败，可手动执行：certbot delete --cert-name ${domain}"
    fi
  elif [ -n "$domain" ] && [ -d "/etc/letsencrypt/live/${domain}" ]; then
    log_info "证书 ${domain} 不是本脚本申请的，已保留（如需删除：certbot delete --cert-name ${domain}）"
  fi

  step "移除独立 PostgreSQL 集群"
  if pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 == c { found = 1 } END { exit !found }'; then
    local ver
    ver="$(pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER_NAME" '$2 == c { print $1 }' | sed -n '1p')"
    if pg_dropcluster "$ver" "$PG_CLUSTER_NAME" --stop; then
      # 集群日志不在 pg_dropcluster 的清理范围内
      rm -f "/var/log/postgresql/postgresql-${ver}-${PG_CLUSTER_NAME}.log"
      log_info "已删除集群 ${ver}/${PG_CLUSTER_NAME}（其他集群不受影响）"
    else
      log_warn "删除集群失败，请手动执行：pg_dropcluster ${ver} ${PG_CLUSTER_NAME} --stop"
    fi
  else
    log_info "未发现独立集群，跳过"
  fi

  step "移除用户与目录"
  rm -rf "$INSTALL_DIR"
  rm -rf "$CONF_DIR"
  rm -f "$SUB_BIN"
  rm -f "$APT_LOG"
  rmdir /usr/share/postgresql-common/pgdg 2>/dev/null || true
  userdel "$SERVICE_USER" 2>/dev/null || true

  if [ -n "$ufw_ports" ] && command -v ufw >/dev/null 2>&1; then
    local p
    for p in $(printf '%s' "$ufw_ports" | tr ',' '\n'); do
      [ -n "$p" ] || continue
      ufw delete allow "$p" >/dev/null 2>&1 || true
    done
    log_info "已移除 ufw 中由本脚本添加的放行规则"
  fi

  if [ "$KEEP_DATA" = "true" ] && [ -n "$backup_dir" ]; then
    log_info "数据已备份到 ${backup_dir}（备份不属于安装残留，可自行保留或删除）"
  fi

  step "清理软件包"
  purge_redis_packages
  purge_pg_packages
  purge_nginx_packages

  if [ -n "${ST_EXTRA_PKGS:-}" ]; then
    log_info "卸载本脚本额外安装的软件包：${ST_EXTRA_PKGS}"
    # 这里按空格拆分是预期行为（ST_EXTRA_PKGS 是内部记录的包名列表）。
    # shellcheck disable=SC2086
    apt-get "${APT_OPTS[@]}" purge -y -qq ${ST_EXTRA_PKGS} >/dev/null 2>&1 \
      || log_warn "额外软件包卸载未完全成功（${ST_EXTRA_PKGS}）"
  fi

  verify_clean

  if [ "${ST_REDIS_BUILT_PACKAGES:-false}" = "true" ]; then
    log_info "编译 Redis 时安装的 build-essential 已保留（通用编译工具，避免影响其他用途；需要可手动 apt purge）"
  fi

  echo ""
  log_ok "卸载完成"
  echo ""
  echo "  如果这台机器上原本就有 PostgreSQL / Redis / Nginx，它们没有被改动，仍在正常运行。"
  echo ""
}

cmd_domain() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/sub2api" ] || die "尚未安装，请先完成安装"
  load_state

  if [ -z "$DOMAIN" ]; then
    if ! have_tty; then
      die "请用 --domain 与 --email 指定，例如：sudo ${SELF_CMD} domain --domain api.example.com --email you@example.com"
    fi
    if ! prompt_domain_config; then
      log_info "已取消"
      return 0
    fi
  fi
  [ -n "$TLS_EMAIL" ] || die "域名模式必须提供证书通知邮箱（--email）"

  PORT="$(env_get SERVER_PORT)"
  [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-8080}"

  step "配置域名与 HTTPS"
  if ensure_domain_setup true; then
    log_ok "已启用：https://${DOMAIN}"
    echo ""
    echo "  访问地址：https://${DOMAIN}"
    echo "  账号密码不变，可用 show 查看；建议在后台「系统设置」里把站点地址改成该地址。"
    echo ""
    echo "  如果浏览器打不开，按顺序检查："
    echo "    1. 云服务器安全组是否放行 80、443（阿里云/腾讯云控制台，脚本改不了）"
    echo "    2. 域名解析是否指向本机公网 IP（dig +short ${DOMAIN}）"
    echo "    3. sudo ${SELF_CMD} status    # 会做 DNS / Nginx / 端口检查"
  else
    log_warn "HTTPS 未成功，应用已回退到 IP:${PORT} 访问"
    log_warn "检查域名解析、80 端口与安全组后，重跑本命令即可"
  fi
}

cmd_show() {
  require_root "$@"
  [ -f "$CRED_FILE" ] || die "找不到 ${CRED_FILE}（可能尚未安装或已卸载）"
  load_state

  echo ""
  sed -n '1,60p' "$CRED_FILE"
  echo ""
  local app_port
  app_port="$(env_get SERVER_PORT)"
  if [ -n "$app_port" ]; then
    echo "应用端口：${app_port}"
  fi
  if [ -n "${ST_PG_PORT:-}" ] || [ -n "${ST_REDIS_PORT:-}" ]; then
    echo "数据库端口：${ST_PG_PORT:-?}，缓存端口：${ST_REDIS_PORT:-?}"
  fi
  echo ""
}

cmd_restart() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/sub2api" ] || die "尚未安装"

  load_state
  PORT="$(env_get SERVER_PORT)"
  [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-8080}"

  step "重启应用"
  systemctl restart "$SERVICE"
  if wait_health; then
    log_ok "已重启，健康检查通过"
  else
    journalctl -u "$SERVICE" -n 40 --no-pager || true
    die "重启后健康检查失败"
  fi
}

cmd_logs() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/sub2api" ] || die "尚未安装"
  log_info "跟踪日志（最近 ${LOG_LINES} 行，Ctrl+C 退出）"
  journalctl -u "$SERVICE" -n "$LOG_LINES" -f
}

cmd_clean() {
  require_root "$@"

  local bak="${INSTALL_DIR}/sub2api.bak"
  if [ ! -f "$bak" ]; then
    log_info "没有旧版本备份，无需清理"
    return 0
  fi

  local size
  size="$(du -h "$bak" 2>/dev/null | awk '{ print $1 }')"
  rm -f "$bak"
  log_ok "已删除 ${bak}（释放 ${size:-未知}）"
}

cmd_passwd() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/sub2api" ] || die "尚未安装，无法重置密码"
  load_state

  local pg_port="${ST_PG_PORT:-}"
  [ -n "$pg_port" ] || pg_port="$(env_get DATABASE_PORT)"
  [ -n "$pg_port" ] || die "找不到数据库端口，安装状态可能已损坏"

  local email="${ARG_ADMIN_EMAIL:-$(env_get ADMIN_EMAIL)}"
  [ -n "$email" ] || die "找不到管理员账号；请用 --admin-email 指定"
  case "$email" in
    *"'"*) die "邮箱里不能包含单引号" ;;
  esac

  local pass="${ARG_ADMIN_PASSWORD:-}"
  [ -n "$pass" ] || pass="$(rand_hex 12)"
  local len=${#pass}
  if [ "$len" -lt 8 ] || [ "$len" -gt 72 ]; then
    die "密码长度必须在 8-72 字节之间（当前 ${len}）"
  fi
  case "$pass" in
    *$'\n'*|*$'\r'*) die "密码不能包含换行" ;;
  esac

  step "重置管理员密码"
  if ! command -v htpasswd >/dev/null 2>&1; then
    log_info "安装 apache2-utils（用于生成 bcrypt 哈希）..."
    install_pkgs apache2-utils
    case " ${ST_EXTRA_PKGS:-} " in
      *" apache2-utils "*) ;;
      *) ST_EXTRA_PKGS="${ST_EXTRA_PKGS:+${ST_EXTRA_PKGS} }apache2-utils" ;;
    esac
    save_state
  fi

  local hash
  hash="$(htpasswd -bnBC 10 '' "$pass" 2>/dev/null | sed 's/^://' | tr -d '\r\n')"
  case "$hash" in
    \$2*) ;;
    *) die "生成 bcrypt 哈希失败，未修改任何数据" ;;
  esac

  local updated
  updated="$(printf "UPDATE users SET password_hash = '%s', updated_at = now() WHERE email = '%s' RETURNING email;\n" \
      "$hash" "$email" \
      | su - postgres -c "psql -p ${pg_port} -d ${SERVICE_USER} -v ON_ERROR_STOP=1 -tA")" \
    || die "数据库更新失败"

  [ -n "$updated" ] || die "数据库里没有账号 ${email}；可用 show 查看当前管理员账号"

  log_ok "管理员密码已重置：${email}"
  echo ""
  echo "  新密码：${pass}"
  echo ""
  echo "  提示：已登录的浏览器会话不会自动失效。若怀疑他人仍在登录，"
  echo "        可在后台退出全部会话，或改 JWT_SECRET 后执行 restart。"
}

dispatch() {
  case "$1" in
    install)   cmd_install ;;
    upgrade)   cmd_upgrade ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    domain)    cmd_domain ;;
    passwd)    cmd_passwd ;;
    show)      cmd_show ;;
    restart)   cmd_restart ;;
    logs)      cmd_logs ;;
    clean)     cmd_clean ;;
  esac
}

menu_read() {
  # 优先从终端读；某些环境 /dev/tty 可打开但读会立刻失败，再退回 stdin。
  local __var="$1" __val=""
  if read -r __val < /dev/tty 2>/dev/null; then
    printf -v "$__var" '%s' "$__val"
    return 0
  fi
  if [ -t 0 ] && read -r __val 2>/dev/null; then
    printf -v "$__var" '%s' "$__val"
    return 0
  fi
  return 1
}

menu_quit() {
  tui_leave
  echo ""
  echo "已退出菜单。应用日志：journalctl -u sub2api -n 50"
  echo "安装/卸载细节：/tmp/sub2api-deploy-apt.log"
  echo ""
  exit 0
}

menu_unreadable() {
  tui_leave
  echo ""
  echo "无法从当前终端读取输入，交互菜单不可用（常见于不支持全屏的 Web 终端）。"
  echo ""
  echo "请改用带参数的命令，例如："
  echo "  sudo bash ${LOCAL_SCRIPT} install"
  echo "  sudo bash ${LOCAL_SCRIPT} status"
  echo "  sudo bash ${LOCAL_SCRIPT} uninstall"
  echo ""
  echo "如果只是想关掉全屏界面再试：SUB2API_NO_TUI=1 sudo bash ${LOCAL_SCRIPT}"
  echo ""
  exit 1
}

run_menu() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行，例如：sudo ${SELF_CMD}"

  local choice="" again="" state=""
  while true; do
    state="未安装"
    if [ -x "${INSTALL_DIR}/sub2api" ]; then
      state="已安装 $(app_version)"
    fi

    tui_enter
    tui_clear

    echo "=============================================="
    echo "        Sub2API 一键部署 / 卸载"
    echo "=============================================="
    echo ""
    echo "  当前状态：${state}"
    echo ""
    echo "  1) 安装 / 重装（自动使用最新版）"
    echo "  2) 配置域名 / HTTPS"
    echo "  3) 查看状态"
    echo "  4) 升级到最新版"
    echo "  5) 卸载"
    echo "  6) 重置管理员密码"
    echo "  7) 查看凭据"
    echo "  8) 重启应用"
    echo "  9) 查看日志"
    echo " 10) 清理旧版本备份"
    echo "  0) 退出"
    echo ""

    printf '请选择: ' > /dev/tty 2>/dev/null || true
    if ! menu_read choice; then
      # 有些终端进入备用屏后读不到输入：退出全屏再试一次。
      tui_leave
      printf '请选择: ' > /dev/tty 2>/dev/null || true
      if ! menu_read choice; then
        menu_unreadable
      fi
    fi

    case "$choice" in
      0) menu_quit ;;
      1|2|3|4|5|6|7|8|9|10) ;;
      *) continue ;;
    esac

    # 全程留在全屏界面里执行，只有退出菜单才还原原终端。
    FROM_MENU="true"
    case "$choice" in
      1) dispatch install ;;
      2) dispatch domain ;;
      3) dispatch status ;;
      4) dispatch upgrade ;;
      5) dispatch uninstall ;;
      6) dispatch passwd ;;
      7) dispatch show ;;
      8) dispatch restart ;;
      9) dispatch logs ;;
      10) dispatch clean ;;
    esac

    printf '\n按回车返回菜单（q 退出）: ' > /dev/tty 2>/dev/null || true
    if ! menu_read again; then
      menu_unreadable
    fi
    case "$again" in
      q|Q) menu_quit ;;
    esac
  done
}

main() {
  # 不带参数且能访问终端时：未安装则直接安装（首次运行），已安装则进菜单。
  if [ "$#" -eq 0 ] && have_tty; then
    if [ -x "${INSTALL_DIR}/sub2api" ]; then
      run_menu
    else
      FROM_MENU="true"   # 交互式安装：会询问是否配域名
      dispatch install
    fi
    return 0
  fi

  parse_args "$@"
  dispatch "$ACTION"
}

main "$@"
