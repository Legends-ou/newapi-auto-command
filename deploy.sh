#!/usr/bin/env bash
#
# New API 一键部署 / 卸载脚本（Debian / Ubuntu）
#
# 安装：下载官方 Release 单二进制，用 SQLite 存数据，注册 systemd，
#       启动后调用 /api/setup 自动创建管理员（不需要网页向导）。
# 卸载：删服务、二进制、SQLite 数据、快捷命令、临时文件，并按需清理软件包。
#
# 用法：
#   sudo bash deploy.sh                      # 首次=安装；已装=菜单
#   sudo bash deploy.sh install              # 直接安装
#   sudo bash deploy.sh status|upgrade|uninstall|domain|show|restart|logs|clean
#
# 只支持 Ubuntu 22.04+ / Debian 12+，需要 root 与 systemd。

set -Eeuo pipefail

APP="new-api"
REPO="QuantumNous/new-api"
SERVICE="newapi"
SERVICE_USER="newapi"
INSTALL_DIR="/opt/new-api"
DATA_DIR="${INSTALL_DIR}/data"
CONF_DIR="/etc/new-api"
ENV_FILE="${CONF_DIR}/new-api.env"
STATE_FILE="${CONF_DIR}/install-state.conf"
CRED_FILE="${CONF_DIR}/credentials.txt"
UNIT_FILE="/etc/systemd/system/newapi.service"
SUB_BIN="/usr/local/bin/napi"
LOCAL_SCRIPT="${INSTALL_DIR}/deploy.sh"
NGINX_SITE="/etc/nginx/sites-available/new-api.conf"
SCRIPT_URL="https://raw.githubusercontent.com/Legends-ou/newapi-auto-command/main/deploy.sh"
APT_LOG="/tmp/newapi-deploy-apt.log"

# ---- CPA（CLIProxyAPI）：只监听 127.0.0.1，不对外暴露 ----
CPA_REPO="router-for-me/CLIProxyAPI"
CPA_SERVICE="cpa"
CPA_USER="cpa"
CPA_DIR="/opt/cpa"
CPA_AUTH_DIR="${CPA_DIR}/auth"
CPA_CONF_DIR="/etc/cpa"
CPA_CONF="${CPA_CONF_DIR}/config.yaml"
CPA_UNIT_FILE="/etc/systemd/system/cpa.service"
CPA_PORT="8317"
CPA_BIN="${CPA_DIR}/cli-proxy-api"
CPA_VERSION=""

ACTION="install"
PORT="3000"
PORT_SET="false"
DOMAIN=""
TLS_EMAIL=""
ARG_VERSION=""
GH_PROXY=""
TIMEZONE="Asia/Shanghai"
ASSUME_YES="false"
KEEP_DATA="false"
LOG_LINES="100"
VERBOSE="false"
FROM_MENU="false"
WITH_CPA="true"
CPA_VERSION_ARG=""
CPA_MANAGE_KEY=""
CPA_API_KEY=""
DB_PATH=""
HTTPS_OK="false"

ARCH=""
OS_ID=""
OS_CODENAME=""
APT_UPDATED="false"
APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
TUI_ACTIVE="false"

ST_VERSION="1"
ST_INSTALLED_AT=""
ST_DB_PATH=""
ST_NGINX_PACKAGES_CREATED="false"
ST_CERTBOT_PACKAGES_CREATED="false"
ST_NGINX_SITE_CREATED="false"
ST_CERT_CREATED="false"
ST_DOMAIN=""
ST_TLS_EMAIL=""
ST_UFW_PORTS=""
ST_SERVER_PORT=""
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
step()     { printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }

have_tty() {
  { : < /dev/tty; } 2>/dev/null || return 1
  { : > /dev/tty; } 2>/dev/null || return 1
  return 0
}

die() { tui_leave; log_err "$*"; exit 1; }

on_error() {
  local code=$1 line=$2
  tui_leave
  log_err "脚本在第 ${line} 行失败（退出码 ${code}）。"
  log_err "服务日志：journalctl -u ${SERVICE} -n 80 --no-pager"
  log_err "如已装到一半，可重跑本命令继续，或用 uninstall 清理。"
  exit "$code"
}
trap 'on_error $? $LINENO' ERR
trap 'tui_leave' EXIT
trap 'tui_leave; exit 130' INT TERM

tui_enter() {
  have_tty || return 0
  if [ "${NO_TUI:-0}" = "1" ]; then return 0; fi
  if [ "${TUI_ACTIVE:-false}" = "true" ]; then return 0; fi
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
New API 一键部署 / 卸载脚本（Debian / Ubuntu）

用法：
  bash deploy.sh [命令] [选项]

  首次运行（未安装）直接安装；已安装后不带参数运行会显示交互菜单：
    sudo bash deploy.sh                # 首次=安装；已装=菜单
    sudo bash deploy.sh install        # 跳过菜单，直接安装

  通过 curl 执行时，命令与选项要放在 bash -s -- 之后：
    curl -sSL <脚本地址> | sudo bash                      # 安装
    curl -sSL <脚本地址> | sudo bash -s -- status         # 状态
    curl -sSL <脚本地址> | sudo bash -s -- uninstall      # 卸载

命令：
  install      安装（默认）
  upgrade      只替换二进制，保留数据
  status       查看访问地址与服务状态
  uninstall    卸载并清理本脚本创建的全部资源
  domain       配置域名并启用 HTTPS
  show         查看当前凭据与端口
  restart      重启应用
  logs         跟踪应用日志（默认最近 100 行）
  clean        删除旧版本备份 new-api.bak
  cred         重新生成凭据文件（不重装）
  self-update  只更新脚本本身（不重装、不升级应用）

选项：
  --port <端口>              New API 监听端口（默认 3000）
  --domain <域名>            绑定域名并自动申请 HTTPS 证书
  --email <邮箱>             证书通知邮箱，用 --domain 时必填
  --version <vX.Y.Z>         指定版本，默认最新 Release
  --gh-proxy <URL>           GitHub 下载加速前缀
  --timezone <时区>          默认 Asia/Shanghai
  --lines <行数>             logs 显示行数（默认 100）
  --verbose                  显示 apt / certbot / 下载的完整输出
  --yes                      卸载时跳过确认
  --keep-data                卸载时先备份 SQLite 数据库
  --no-cpa                   不安装 CPA（只装 New API）
  --cpa-port <端口>          CPA 监听端口（默认 8317，只绑 127.0.0.1）
  --cpa-version <vX.Y.Z>     指定 CPA 版本
  -h, --help                 显示本帮助

说明：
  数据默认存 SQLite（/opt/new-api/data/new-api.db），不依赖 PostgreSQL / Redis。
EOF
}

# ---------------------------------------------------------------- 参数

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      install|upgrade|status|uninstall|domain|show|restart|logs|clean|cred|self-update) ACTION="$1"; shift ;;
      --port)            PORT="${2:-}"; PORT_SET="true"; shift 2 ;;
      --port=*)          PORT="${1#*=}"; PORT_SET="true"; shift ;;
      --domain)          DOMAIN="${2:-}"; shift 2 ;;
      --domain=*)        DOMAIN="${1#*=}"; shift ;;
      --email)           TLS_EMAIL="${2:-}"; shift 2 ;;
      --email=*)         TLS_EMAIL="${1#*=}"; shift ;;
      --version)         ARG_VERSION="${2:-}"; shift 2 ;;
      --version=*)       ARG_VERSION="${1#*=}"; shift ;;
      --gh-proxy)        GH_PROXY="${2:-}"; shift 2 ;;
      --gh-proxy=*)      GH_PROXY="${1#*=}"; shift ;;
      --timezone)        TIMEZONE="${2:-}"; shift 2 ;;
      --timezone=*)      TIMEZONE="${1#*=}"; shift ;;
      --lines)           LOG_LINES="${2:-}"; shift 2 ;;
      --lines=*)         LOG_LINES="${1#*=}"; shift ;;
      --verbose)         VERBOSE="true"; shift ;;
      --no-cpa)          WITH_CPA="false"; shift ;;
      --cpa-port)        CPA_PORT="${2:-}"; shift 2 ;;
      --cpa-port=*)      CPA_PORT="${1#*=}"; shift ;;
      --cpa-version)     CPA_VERSION_ARG="${2:-}"; shift 2 ;;
      --cpa-version=*)   CPA_VERSION_ARG="${1#*=}"; shift ;;
      --keep-data)       KEEP_DATA="true"; shift ;;
      --yes|-y)          ASSUME_YES="true"; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done

  case "$ACTION" in
    install|upgrade|status|uninstall|domain|show|restart|logs|clean|cred|self-update) ;;
    *) die "未知命令：$ACTION" ;;
  esac

  [ -n "$PORT" ] || die "--port 不能为空"
  case "$PORT" in ''|*[!0-9]*) die "--port 必须是数字" ;; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port 超出 1-65535"
  case "$LOG_LINES" in ''|*[!0-9]*) die "--lines 必须是数字" ;; esac
  case "$CPA_PORT" in ''|*[!0-9]*) die "--cpa-port 必须是数字" ;; esac

  if [ -n "$DOMAIN" ]; then
    [ -n "$TLS_EMAIL" ] || die "使用 --domain 时必须同时给出 --email（证书通知邮箱）"
    case "$DOMAIN" in
      *[!A-Za-z0-9.-]*) die "--domain 只能包含字母、数字、点和连字符" ;;
    esac
  fi

  GH_PROXY="${GH_PROXY%/}"
}

# ---------------------------------------------------------------- 系统

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行，例如：sudo bash deploy.sh"
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

check_memory() {
  local mem_kb swap_kb
  mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  swap_kb="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  mem_kb="${mem_kb:-0}"; swap_kb="${swap_kb:-0}"
  if [ "$mem_kb" -lt 700000 ] && [ "$swap_kb" -eq 0 ]; then
    log_warn "内存只有 $((mem_kb / 1024)) MB 且没有 swap；首次启动建库可能吃紧。"
  fi
}

apt_update_once() {
  [ "$APT_UPDATED" = "false" ] || return 0
  log_info "更新软件包索引..."
  if [ "$VERBOSE" = "true" ]; then
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${APT_OPTS[@]}" update -qq
  elif ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get "${APT_OPTS[@]}" update -qq >"$APT_LOG" 2>&1; then
    log_err "更新软件包索引失败："
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
  for cmd in curl tar openssl sha256sum ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_info "安装缺失工具：${missing[*]}"
    install_pkgs ca-certificates curl tar openssl iproute2
  fi
  log_ok "基础工具就绪"
}

rand_hex() { openssl rand -hex "$1"; }

env_get() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | sed -n '1p'
}

is_listening() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -lntH 2>/dev/null | awk -v p=":${port}" '$4 ~ (p "$") { found = 1 } END { exit !found }'
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

save_state() {
  [ -d "$CONF_DIR" ] || return 0
  umask 077
  {
    printf '# New API 安装状态（由 deploy.sh 写入，卸载时依赖）\n'
    printf 'ST_VERSION=1\n'
    printf 'ST_INSTALLED_AT=%s\n' "${ST_INSTALLED_AT:-$(date -Iseconds)}"
    printf 'ST_DB_PATH=%s\n' "${ST_DB_PATH:-}"
    printf 'ST_NGINX_PACKAGES_CREATED=%s\n' "${ST_NGINX_PACKAGES_CREATED:-false}"
    printf 'ST_CERTBOT_PACKAGES_CREATED=%s\n' "${ST_CERTBOT_PACKAGES_CREATED:-false}"
    printf 'ST_NGINX_SITE_CREATED=%s\n' "${ST_NGINX_SITE_CREATED:-false}"
    printf 'ST_CERT_CREATED=%s\n' "${ST_CERT_CREATED:-false}"
    printf 'ST_DOMAIN=%s\n' "${ST_DOMAIN:-}"
    printf 'ST_TLS_EMAIL=%s\n' "${ST_TLS_EMAIL:-}"
    printf 'ST_UFW_PORTS=%s\n' "${ST_UFW_PORTS:-}"
    printf 'ST_SERVER_PORT=%s\n' "${ST_SERVER_PORT:-}"
    printf 'ST_EXTRA_PKGS=%s\n' "${ST_EXTRA_PKGS:-}"
    umask 022
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

# ---------------------------------------------------------------- 应用

ensure_user_dirs() {
  step "创建系统用户与目录"
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/sh -d "$INSTALL_DIR" "$SERVICE_USER"
    log_ok "已创建系统用户 ${SERVICE_USER}"
  else
    log_info "系统用户 ${SERVICE_USER} 已存在"
  fi

  install -d -m 0755 "$INSTALL_DIR"
  install -d -m 0750 "$DATA_DIR"
  install -d -m 0750 "$CONF_DIR"
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
  chown "root:${SERVICE_USER}" "$CONF_DIR"
  chmod 0750 "$CONF_DIR"
}

resolve_version() {
  local tag=""
  if [ -n "$ARG_VERSION" ]; then
    tag="$ARG_VERSION"
    case "$tag" in v*) ;; *) tag="v${tag}" ;; esac
  else
    log_info "查询最新版本..."
    local raw=""
    raw="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 \
      "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s' "$raw" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
    [ -n "$tag" ] || die "获取最新版本失败。请检查网络，或用 --version 指定版本"
  fi

  case "$tag" in
    v[0-9]*) ;;
    *) die "版本号格式异常：${tag}" ;;
  esac
  RELEASE_TAG="$tag"
  log_info "目标版本：${RELEASE_TAG}"
}

download_binary() {
  local dest_dir="$1"
  local asset
  if [ "$ARCH" = "arm64" ]; then
    asset="new-api-arm64-${RELEASE_TAG}"
  else
    asset="new-api-${RELEASE_TAG}"
  fi
  local base="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
  local url="${base}/${asset}"
  local tmp
  tmp="$(mktemp -d)"

  if [ -n "$GH_PROXY" ]; then url="${GH_PROXY}/${url}"; fi

  log_info "下载 ${asset}（约 130MB，可能需要一会儿）..."
  if ! curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
      -o "${tmp}/${asset}" "$url"; then
    rm -rf "$tmp"
    die "下载失败：${url}
如果服务器在国内，可以加加速前缀重试：sudo bash deploy.sh install --gh-proxy https://ghproxy.net/"
  fi

  local sum_url="${base}/checksums-linux.txt"
  if [ -n "$GH_PROXY" ]; then sum_url="${GH_PROXY}/${sum_url}"; fi
  if curl -fsSL --retry 2 --max-time 40 -o "${tmp}/checksums.txt" "$sum_url" 2>/dev/null; then
    local expected actual
    expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1; exit }' "${tmp}/checksums.txt")"
    actual="$(sha256sum "${tmp}/${asset}" | awk '{ print $1 }')"
    if [ -z "$expected" ]; then
      log_warn "校验文件里没有 ${asset}，跳过校验"
    elif [ "$expected" != "$actual" ]; then
      rm -rf "$tmp"
      die "SHA-256 校验失败，已中止安装"
    else
      log_ok "SHA-256 校验通过"
    fi
  else
    log_warn "无法下载校验文件，跳过校验"
  fi

  install -m 0755 "${tmp}/${asset}" "${dest_dir}/new-api"
  rm -rf "$tmp"
  log_ok "二进制已安装到 ${dest_dir}/new-api"
}

load_or_generate_secrets() {
  step "准备密钥"

  SESSION_SECRET="$(env_get SESSION_SECRET)"
  CRYPTO_SECRET="$(env_get CRYPTO_SECRET)"
  local saved_port
  saved_port="$(env_get PORT)"

  if [ "$PORT_SET" = "false" ] && [ -n "$saved_port" ]; then
    PORT="$saved_port"
  fi

  SESSION_SECRET="${SESSION_SECRET:-$(rand_hex 32)}"
  CRYPTO_SECRET="${CRYPTO_SECRET:-$(rand_hex 32)}"

  DB_PATH="${ST_DB_PATH:-${DATA_DIR}/new-api.db}"
}

write_env_file() {
  local host="$1"
  umask 077
  {
    printf '# New API 运行配置（由 deploy.sh 生成）\n'
    printf 'PORT=%s\n' "$PORT"
    printf 'SQLITE_PATH=%s\n' "$DB_PATH"
    printf 'SESSION_SECRET=%s\n' "$SESSION_SECRET"
    printf 'CRYPTO_SECRET=%s\n' "$CRYPTO_SECRET"
    printf 'GIN_MODE=release\n'
    printf 'TZ=%s\n' "$TIMEZONE"
    printf 'SERVER_HOST=%s\n' "$host"
    umask 022
  } > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  chown root:root "$ENV_FILE"
}

write_unit_file() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=New API - AI gateway
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/new-api --port ${PORT} --log-dir ${DATA_DIR}/logs
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
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
      return 0
    fi
    if ! systemctl is-active --quiet "$SERVICE"; then
      return 1
    fi
    sleep 2
  done
  return 1
}

start_service() {
  step "启动服务"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE"; then
    log_err "systemd 启动失败，最近日志："
    journalctl -u "$SERVICE" -n 60 --no-pager || true
    die "服务无法启动"
  fi

  log_info "等待服务就绪（首次启动要建库，可能需要 10-60 秒）..."
  if wait_health; then
    log_ok "服务已启动"
    return 0
  fi
  log_err "服务未能就绪，最近日志："
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  die "启动失败"
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

    client_max_body_size 512m;
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

    client_max_body_size 512m;
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

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/new-api.conf
  ST_NGINX_SITE_CREATED="true"
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
    log_err "Nginx 配置校验失败："
    nginx -t || true
    rm -f /etc/nginx/sites-enabled/new-api.conf
    rm -f "$tmp_http" "$tmp_tls"
    ST_NGINX_SITE_CREATED="false"
    return 1
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  if [ ! -f "${cert_dir}/fullchain.pem" ]; then
    log_info "正在申请 Let's Encrypt 证书（需域名已解析到本机、80 端口可访问）..."
    local cert_ok="false"
    if [ "$VERBOSE" = "true" ]; then
      if certbot certonly --nginx -d "$DOMAIN" -m "$TLS_EMAIL" \
          --agree-tos --non-interactive --keep-until-expiring; then cert_ok="true"; fi
    else
      if certbot certonly --nginx -d "$DOMAIN" -m "$TLS_EMAIL" \
          --agree-tos --non-interactive --keep-until-expiring >>"$APT_LOG" 2>&1; then cert_ok="true"; fi
    fi

    if [ "$cert_ok" != "true" ]; then
      [ "$VERBOSE" = "true" ] || { log_err "certbot 输出（最后 20 行）："; tail -n 20 "$APT_LOG" >&2 || true; }

      local dns_ips="" pub=""
      dns_ips="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')"
      pub="$(get_public_ip || true)"
      if [ -n "$dns_ips" ] && [ -n "$pub" ]; then
        case " ${dns_ips} " in
          *" ${pub} "*) ;;
          *)
            log_warn "域名解析到：${dns_ips}"
            log_warn "本机公网 IP：${pub}"
            log_warn "两者不一致，Let's Encrypt 会去旧地址验证，证书必然失败。"
            log_warn "请把 A 记录改成 ${pub}，生效后执行：sudo bash deploy.sh domain"
            ;;
        esac
      fi

      log_warn "证书申请失败，暂时保留 HTTP 访问"
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
  log_ok "HTTPS 已启用：https://${DOMAIN}"
  HTTPS_OK="true"
}

# ---------------------------------------------------------------- CPA（可选，仅本机）

cpa_env_get() {
  [ -f "${CPA_CONF_DIR}/cpa.env" ] || return 0
  sed -n "s/^$1=//p" "${CPA_CONF_DIR}/cpa.env" | sed -n '1p'
}

resolve_cpa_version() {
  local tag=""
  if [ -n "${CPA_VERSION_ARG:-}" ]; then
    tag="$CPA_VERSION_ARG"
    case "$tag" in v*) ;; *) tag="v${tag}" ;; esac
  else
    log_info "查询 CPA 最新版本..."
    local raw=""
    raw="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 \
      "https://api.github.com/repos/${CPA_REPO}/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s' "$raw" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
    [ -n "$tag" ] || die "获取 CPA 版本失败，可加 --cpa-version v8.x.y 指定"
  fi
  case "$tag" in v[0-9]*) ;; *) die "CPA 版本号格式异常：${tag}" ;; esac
  CPA_VERSION="$tag"
  log_info "CPA 目标版本：${CPA_VERSION}"
}

download_cpa() {
  local ver="${CPA_VERSION#v}"
  local asset="CLIProxyAPI_${ver}_linux_${ARCH}.tar.gz"
  local base="https://github.com/${CPA_REPO}/releases/download/${CPA_VERSION}"
  local url="${base}/${asset}"
  local tmp
  tmp="$(mktemp -d)"

  [ -n "$GH_PROXY" ] && url="${GH_PROXY}/${url}"

  log_info "下载 ${asset}（约 24MB）..."
  if ! curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
      -o "${tmp}/${asset}" "$url"; then
    rm -rf "$tmp"
    die "下载 CPA 失败：${url}"
  fi

  if curl -fsSL --retry 2 --max-time 40 -o "${tmp}/checksums.txt" \
      "${GH_PROXY:+${GH_PROXY}/}${base}/checksums.txt" 2>/dev/null; then
    local expected actual
    expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1; exit }' "${tmp}/checksums.txt")"
    actual="$(sha256sum "${tmp}/${asset}" | awk '{ print $1 }')"
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
      rm -rf "$tmp"
      die "CPA SHA-256 校验失败"
    fi
  fi

  tar -xzf "${tmp}/${asset}" -C "$tmp"
  local found=""
  found="$(find "$tmp" -maxdepth 3 -type f -name 'cli-proxy-api*' -perm -u+x | sed -n '1p')"
  if [ -z "$found" ]; then
    found="$(find "$tmp" -maxdepth 3 -type f -perm -u+x -size +1M | sed -n '1p')"
  fi
  [ -n "$found" ] || { rm -rf "$tmp"; die "CPA 压缩包里没找到可执行文件"; }

  install -m 0755 "$found" "$CPA_BIN"
  rm -rf "$tmp"
  log_ok "CPA 已安装到 ${CPA_BIN}"
}

write_cpa_conf() {
  umask 077
  {
    printf '# CPA 配置（由 deploy.sh 生成）\n'
    printf '# 只监听本机：公网无法访问，管理界面走 SSH 隧道\n'
    printf 'host: "127.0.0.1"\n'
    printf 'port: %s\n' "$CPA_PORT"
    printf 'auth-dir: "%s"\n' "$CPA_AUTH_DIR"
    printf '\n'
    printf 'remote-management:\n'
    printf '  allow-remote: false\n'
    printf '  secret-key: "%s"\n' "$CPA_MANAGE_KEY"
    printf '\n'
    printf 'api-keys:\n'
    printf '  - "%s"\n' "$CPA_API_KEY"
    umask 022
  } > "$CPA_CONF"
  chmod 0640 "$CPA_CONF"
  chown "root:${CPA_USER}" "$CPA_CONF"

  umask 077
  {
    printf 'CPA_MANAGE_KEY=%s\n' "$CPA_MANAGE_KEY"
    printf 'CPA_API_KEY=%s\n' "$CPA_API_KEY"
  } > "${CPA_CONF_DIR}/cpa.env"
  chmod 0600 "${CPA_CONF_DIR}/cpa.env"
  umask 022
}

write_cpa_unit() {
  cat > "$CPA_UNIT_FILE" <<EOF
[Unit]
Description=CLIProxyAPI (CPA) - local only
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CPA_USER}
Group=${CPA_USER}
WorkingDirectory=${CPA_DIR}
ExecStart=${CPA_BIN} --config ${CPA_CONF}
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${CPA_DIR}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$CPA_UNIT_FILE"
}

cpa_health() {
  curl -fsS --max-time 5 -H "Authorization: Bearer ${CPA_API_KEY}" \
    "http://127.0.0.1:${CPA_PORT}/v1/models" >/dev/null 2>&1
}

install_cpa() {
  step "安装 CPA（仅监听 127.0.0.1:${CPA_PORT}）"

  if ! id -u "$CPA_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/sh -d "$CPA_DIR" "$CPA_USER"
    log_ok "已创建系统用户 ${CPA_USER}"
  fi
  install -d -m 0755 "$CPA_DIR"
  install -d -m 0700 "$CPA_AUTH_DIR"
  install -d -m 0750 "$CPA_CONF_DIR"
  chown -R "${CPA_USER}:${CPA_USER}" "$CPA_DIR"
  chown "root:${CPA_USER}" "$CPA_CONF_DIR"
  chmod 0750 "$CPA_CONF_DIR"

  CPA_MANAGE_KEY="$(cpa_env_get CPA_MANAGE_KEY)"
  CPA_API_KEY="$(cpa_env_get CPA_API_KEY)"
  CPA_MANAGE_KEY="${CPA_MANAGE_KEY:-$(rand_hex 32)}"
  CPA_API_KEY="${CPA_API_KEY:-sk-$(rand_hex 24)}"

  resolve_cpa_version
  if [ -x "$CPA_BIN" ]; then
    log_info "CPA 二进制已存在，跳过下载"
  else
    download_cpa
  fi
  chown "${CPA_USER}:${CPA_USER}" "$CPA_BIN"

  write_cpa_conf
  write_cpa_unit

  systemctl daemon-reload
  systemctl enable "$CPA_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$CPA_SERVICE"

  local i
  for i in $(seq 1 30); do
    if cpa_health; then
      log_ok "CPA 已就绪（127.0.0.1:${CPA_PORT}，仅本机）"
      return 0
    fi
    if ! systemctl is-active --quiet "$CPA_SERVICE"; then
      journalctl -u "$CPA_SERVICE" -n 40 --no-pager || true
      die "CPA 启动失败"
    fi
    sleep 2
  done
  journalctl -u "$CPA_SERVICE" -n 40 --no-pager || true
  die "CPA 未就绪（检查 ${CPA_CONF}）"
}

# ---------------------------------------------------------------- 摘要

get_public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 5 https://ipinfo.io/ip 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  printf '%s' "$ip"
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

app_version() {
  "${INSTALL_DIR}/new-api" --version 2>/dev/null | sed -n '1p' || true
}

write_credentials() {
  umask 077
  {
    printf '# New API 部署凭据（由 deploy.sh 生成）\n'
    printf '# 生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '访问地址   : %s\n' "$1"
    printf '管理员     : 首次访问网页时自行创建\n'
    printf '\n# SQLite 数据库（本机文件）\n'
    printf 'DB_PATH=%s\n' "$DB_PATH"
    printf '\n# 应用配置\n'
    printf 'ENV_FILE=%s\n' "$ENV_FILE"
    printf 'SESSION_SECRET=%s\n' "$SESSION_SECRET"
    printf 'CRYPTO_SECRET=%s\n' "$CRYPTO_SECRET"
    if [ "$WITH_CPA" = "true" ] && [ -n "$CPA_API_KEY" ]; then
      printf '\n# CPA（只监听 127.0.0.1，不对外）\n'
      printf 'CPA_API_URL=%s\n' "http://127.0.0.1:${CPA_PORT}/v1"
      printf 'CPA_API_KEY=%s\n' "$CPA_API_KEY"
      printf 'CPA_MANAGE_KEY=%s\n' "$CPA_MANAGE_KEY"
      printf 'CPA管理界面: ssh -L %s:127.0.0.1:%s root@<服务器IP> 后打开 http://127.0.0.1:%s/management.html\n' \
        "$CPA_PORT" "$CPA_PORT" "$CPA_PORT"
    fi
    umask 022
  } > "$CRED_FILE"
  chmod 0600 "$CRED_FILE"
  chown root:root "$CRED_FILE"
}

print_summary() {
  local url="$1"
  echo ""
  printf '%s==============================================%s\n' "$C_GREEN" "$C_RESET"
  printf '%s  New API 部署完成%s\n' "$C_GREEN" "$C_RESET"
  printf '%s==============================================%s\n' "$C_GREEN" "$C_RESET"
  echo ""
  echo "  访问地址：${url}"
  echo "  管理员：首次打开网址时自行创建（脚本不生成账号）"
  echo ""
  echo "  版本：$(app_version)"
  echo "  数据库：SQLite（${DB_PATH}）"
  echo ""
  echo "  凭据文件：${CRED_FILE}（600，仅 root）"
  echo "  应用配置：${ENV_FILE}"
  echo "  安装状态：${STATE_FILE}（卸载依赖它）"
  if [ "$WITH_CPA" = "true" ] && [ -n "$CPA_API_KEY" ]; then
    echo ""
    echo "  CPA（只监听 127.0.0.1:${CPA_PORT}，公网访问不到）："
    echo "    New API 渠道地址：http://127.0.0.1:${CPA_PORT}/v1"
    echo "    New API 渠道密钥：${CPA_API_KEY}"
    echo "    CPA 管理密钥    ：${CPA_MANAGE_KEY}"
    echo "    管理界面        ：先 ssh -L ${CPA_PORT}:127.0.0.1:${CPA_PORT} root@<服务器IP>"
    echo "                      再打开 http://127.0.0.1:${CPA_PORT}/management.html"
  fi
  echo ""
  echo "  常用命令："
  echo "    napi                    再次打开本菜单"
  echo "    systemctl status ${SERVICE}"
  echo "    journalctl -u ${SERVICE} -f"
  echo ""
  if [ -n "$DOMAIN" ] && [ "${HTTPS_OK:-false}" = "true" ]; then
    echo "  首次登录后请在「设置」里确认站点地址为 https://${DOMAIN}"
  elif [ -n "$DOMAIN" ]; then
    echo "  域名 ${DOMAIN} 已配置，但 HTTPS 没成功（当前用 IP:端口 访问）。"
    echo "  修好 DNS/80 端口后执行：sudo bash deploy.sh domain"
  else
    echo "  要绑定域名并自动上 HTTPS：sudo bash deploy.sh domain"
  fi
  echo ""
  echo "  完全卸载：sudo bash deploy.sh uninstall"
  echo ""
}

# ---------------------------------------------------------------- 卸载辅助

nginx_other_sites() {
  local count=0 f
  for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      new-api.conf|default) continue ;;
    esac
    count=$((count + 1))
  done
  printf '%s' "$count"
}

purge_nginx_packages() {
  [ "${ST_NGINX_PACKAGES_CREATED:-false}" = "true" ] || return 0
  if [ "$(nginx_other_sites)" -gt 0 ]; then
    log_warn "Nginx 上还有其他站点，保留 Nginx 软件包"
    return 0
  fi
  log_info "卸载脚本安装的 Nginx 软件包..."
  apt-get "${APT_OPTS[@]}" purge -y -qq nginx nginx-common >/dev/null 2>&1 \
    || log_warn "Nginx 卸载未完全成功，可手动检查 dpkg -l | grep nginx"

  if [ "${ST_CERTBOT_PACKAGES_CREATED:-false}" = "true" ]; then
    apt-get "${APT_OPTS[@]}" purge -y -qq certbot python3-certbot-nginx >/dev/null 2>&1 \
      || log_warn "certbot 卸载未完全成功"
  fi
}

verify_clean() {
  step "残留自检"
  local issues=0 f u

  for f in "$INSTALL_DIR" "$CONF_DIR" "$SUB_BIN" "$APT_LOG" "$CPA_DIR" "$CPA_CONF_DIR"; do
    if [ -e "$f" ]; then
      log_warn "残留：$f"
      issues=$((issues + 1))
    fi
  done

  for u in newapi.service cpa.service; do
    if systemctl list-unit-files 2>/dev/null | awk -v u="$u" '$1 == u { found = 1 } END { exit !found }'; then
      log_warn "残留服务单元：$u"
      issues=$((issues + 1))
    fi
  done

  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log_warn "残留系统用户：$SERVICE_USER"
    issues=$((issues + 1))
  fi
  if id -u "$CPA_USER" >/dev/null 2>&1; then
    log_warn "残留系统用户：$CPA_USER"
    issues=$((issues + 1))
  fi

  if is_listening "$PORT"; then
    log_warn "端口 ${PORT} 仍在监听（可能是其他程序）"
    issues=$((issues + 1))
  fi

  if [ "$issues" -eq 0 ]; then
    log_ok "未发现本项目的残留"
  else
    log_warn "发现 ${issues} 处残留，请按提示处理"
  fi
}

# ---------------------------------------------------------------- 交互辅助

prompt_confirm() {
  local prompt="$1" reply=""
  if have_tty; then
    printf '%s' "$prompt" > /dev/tty
    read -r reply < /dev/tty || reply=""
    printf '\n' > /dev/tty
  else
    printf '%s' "$prompt"
    read -r reply || reply=""
  fi
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

prompt_domain_config() {
  local ans="" d="" e=""
  printf '是否绑定域名并启用 HTTPS？(y/N) ' > /dev/tty
  read -r ans < /dev/tty || ans=""
  case "$ans" in [Yy]*) ;; *) return 1 ;; esac

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
    case "$e" in *@*.*) break ;; *) printf '  邮箱格式不对，请重试\n' > /dev/tty ;; esac
  done

  DOMAIN="$d"; TLS_EMAIL="$e"
  return 0
}

# ---------------------------------------------------------------- 命令

cmd_install() {
  require_root "$@"
  detect_os
  check_memory

  if [ -z "$DOMAIN" ] && [ "$FROM_MENU" = "true" ] && have_tty; then
    if prompt_domain_config; then
      log_info "已选择域名模式：${DOMAIN}"
    fi
  fi

  ensure_base_deps
  load_state
  if [ -z "$DOMAIN" ] && [ -n "${ST_DOMAIN:-}" ]; then
    DOMAIN="$ST_DOMAIN"
    TLS_EMAIL="${TLS_EMAIL:-${ST_TLS_EMAIL:-}}"
  fi

  ensure_user_dirs
  load_or_generate_secrets

  step "下载 New API"
  resolve_version
  if systemctl is-active --quiet "$SERVICE"; then
    systemctl stop "$SERVICE" || true
  fi
  if [ -x "${INSTALL_DIR}/new-api" ]; then
    cp -f "${INSTALL_DIR}/new-api" "${INSTALL_DIR}/new-api.bak"
    log_info "已备份旧二进制到 ${INSTALL_DIR}/new-api.bak"
  fi
  download_binary "$INSTALL_DIR"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/new-api"

  local server_host="0.0.0.0"
  if [ -n "$DOMAIN" ]; then server_host="127.0.0.1"; fi

  step "写入运行配置"
  write_env_file "$server_host"
  write_unit_file
  ST_SERVER_PORT="$PORT"
  ST_DB_PATH="$DB_PATH"
  log_ok "配置已写入 ${ENV_FILE}"

  start_service

  if [ "$WITH_CPA" = "true" ]; then
    install_cpa
  fi

  open_firewall

  local url="" nginx_ok="true"
  if [ -n "$DOMAIN" ]; then
    if ensure_domain_setup false; then
      url="https://${DOMAIN}"
      HTTPS_OK="true"
    else
      nginx_ok="false"; HTTPS_OK="false"
    fi
  fi
  if [ -z "$url" ]; then
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
    log_warn "HTTPS 没配成功：按提示排查后执行 sudo bash deploy.sh domain 重试"
  fi
}

ensure_domain_setup() {
  local restart_first="$1"
  if [ "$restart_first" = "true" ]; then
    write_env_file "127.0.0.1"
    systemctl restart "$SERVICE"
    wait_health || log_err "服务重启后未就绪"
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
  wait_health || log_err "服务重启后未就绪"
  save_state
  return 1
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
  log_info "已在 ufw 放行端口（卸载时移除）"
}

save_self() {
  # 优先从发布地址取最新版（这样 upgrade 会顺带更新脚本本身）；
  # 网络不可用时退回复制当前文件。
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$tmp" 2>/dev/null \
    && bash -n "$tmp" 2>/dev/null; then
    install -m 0755 "$tmp" "$LOCAL_SCRIPT"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"

  if [ -f "${BASH_SOURCE[0]:-}" ]; then
    if cp -f "${BASH_SOURCE[0]}" "$LOCAL_SCRIPT" 2>/dev/null; then
      chmod 0755 "$LOCAL_SCRIPT"
      log_warn "无法访问发布地址，已复制当前脚本（可能是旧版）"
      return 0
    fi
  fi
  return 1
}

cmd_self_update() {
  require_root "$@"
  local tmp
  tmp="$(mktemp)"
  log_info "下载最新脚本..."
  if ! curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "下载失败，请检查网络后重试"
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "下载的脚本语法校验失败，已中止（现有脚本未改动）"
  fi
  install -m 0755 "$tmp" "$LOCAL_SCRIPT"
  rm -f "$tmp"
  log_ok "脚本已更新：${LOCAL_SCRIPT}"
  log_info "重新运行 napi 即可使用新版本"
}

install_launcher() {
  save_self || log_warn "未能保存本地脚本副本，napi 会尝试从网络拉取"
  cat > "$SUB_BIN" <<EOF
#!/usr/bin/env bash
# New API 快捷入口（由 deploy.sh 安装）
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
  log_ok "已安装快捷命令：输入 napi 打开菜单"
}

cmd_upgrade() {
  require_root "$@"
  detect_os
  [ -x "${INSTALL_DIR}/new-api" ] || die "尚未安装，请先执行：sudo bash deploy.sh install"
  [ -f "$ENV_FILE" ] || die "找不到 ${ENV_FILE}，安装可能已损坏"

  load_state
  PORT="$(env_get PORT)"; [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-3000}"
  DB_PATH="${ST_DB_PATH:-${DATA_DIR}/new-api.db}"
  ensure_base_deps

  resolve_version
  log_info "当前版本：$(app_version)"

  step "升级"
  systemctl stop "$SERVICE" 2>/dev/null || true
  cp -f "${INSTALL_DIR}/new-api" "${INSTALL_DIR}/new-api.bak"
  download_binary "$INSTALL_DIR"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/new-api"
  start_service
  save_self >/dev/null 2>&1 || true
  log_ok "升级完成：$(app_version)"
  log_info "回滚：cp ${INSTALL_DIR}/new-api.bak ${INSTALL_DIR}/new-api && systemctl restart ${SERVICE}"
}

cmd_status() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/new-api" ] || die "尚未安装"

  load_state
  PORT="$(env_get PORT)"; [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-3000}"
  DB_PATH="${ST_DB_PATH:-${DATA_DIR}/new-api.db}"

  local url domain="${ST_DOMAIN:-}"
  url="$(access_url)"

  echo ""
  echo "访问地址：${url}"
  if [ -n "$domain" ]; then echo "域名    ：${domain}"; fi
  echo "版本    ：$(app_version)"
  echo "端口    ：${PORT}"
  echo "数据库  ：${DB_PATH}"
  if [ -f "$DB_PATH" ]; then
    echo "数据大小：$(du -h "$DB_PATH" 2>/dev/null | awk '{ print $1 }')"
  fi
  echo ""
  if systemctl is-active "$SERVICE" >/dev/null 2>&1; then echo "服务      ：运行中"; else echo "服务      ：未运行"; fi
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
    echo "健康检查  ：通过"
  else
    echo "健康检查  ：失败"
  fi

  local setup_state=""
  setup_state="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/api/setup" 2>/dev/null || true)"
  case "$setup_state" in
    *'"status":true'*) echo "管理后台  ：首次访问需创建管理员" ;;
    *) echo "管理后台  ：已初始化" ;;
  esac

  if [ -x "$CPA_BIN" ] && [ -f "$CPA_CONF" ]; then
    CPA_API_KEY="$(cpa_env_get CPA_API_KEY)"
    if systemctl is-active "$CPA_SERVICE" >/dev/null 2>&1 && cpa_health; then
      echo "CPA       ：运行中（127.0.0.1:${CPA_PORT}，仅本机）"
    else
      echo "CPA       ：未运行或不可用"
    fi
  fi
  echo ""

  if [ -n "$domain" ]; then
    local issues=0 dns_ips="" pub=""
    pub="$(get_public_ip || true)"
    dns_ips="$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')"
    echo "--- 域名检查 ---"
    if [ -n "$dns_ips" ]; then
      echo "DNS 解析  ：${dns_ips}"
      case " ${dns_ips} " in
        *" ${pub} "*) ;;
        *) log_warn "与公网 IP（${pub}）不一致"; issues=$((issues + 1)) ;;
      esac
    else
      log_warn "域名无法解析"; issues=$((issues + 1))
    fi
    if systemctl is-active nginx >/dev/null 2>&1; then
      echo "Nginx     ：运行中"
    else
      log_warn "Nginx 未运行"; issues=$((issues + 1))
    fi
    if is_listening 80; then
      echo "80 端口   ：监听中"
    else
      log_warn "本机未监听 80"; issues=$((issues + 1))
    fi
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
      echo "证书      ：已签发"
    else
      log_warn "证书未签发"; issues=$((issues + 1))
    fi
    echo ""
    echo "  云服务器需在控制台安全组放行 80、443（脚本改不了）"
    if [ "$issues" -eq 0 ]; then log_ok "域名检查未发现问题"; else log_warn "发现 ${issues} 处问题"; fi
    echo ""
  fi

  systemctl status "$SERVICE" --no-pager -l | sed -n '1,15p' || true
}

cmd_domain() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/new-api" ] || die "尚未安装，请先完成安装"
  load_state

  if [ -z "$DOMAIN" ]; then
    have_tty || die "请用 --domain 与 --email 指定"
    prompt_domain_config || { log_info "已取消"; return 0; }
  fi
  [ -n "$TLS_EMAIL" ] || die "域名模式必须提供证书通知邮箱（--email）"

  PORT="$(env_get PORT)"; [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-3000}"
  DB_PATH="${ST_DB_PATH:-${DATA_DIR}/new-api.db}"

  step "配置域名与 HTTPS"
  if ensure_domain_setup true; then
    log_ok "已启用：https://${DOMAIN}"
    echo ""
    echo "  访问地址：https://${DOMAIN}"
    echo "  如果打不开：检查安全组 80/443、DNS 解析，再跑 sudo bash deploy.sh status"
  else
    log_warn "HTTPS 未成功，应用已回退到 IP:${PORT} 访问"
  fi
}

cmd_cred() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/new-api" ] || die "尚未安装"

  load_state
  PORT="$(env_get PORT)"; [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-3000}"
  DB_PATH="${ST_DB_PATH:-${DATA_DIR}/new-api.db}"
  SESSION_SECRET="$(env_get SESSION_SECRET)"
  CRYPTO_SECRET="$(env_get CRYPTO_SECRET)"

  CPA_API_KEY="$(cpa_env_get CPA_API_KEY)"
  CPA_MANAGE_KEY="$(cpa_env_get CPA_MANAGE_KEY)"
  if [ -n "$CPA_API_KEY" ]; then
    WITH_CPA="true"
  else
    WITH_CPA="false"
  fi

  local url
  url="$(access_url)"
  write_credentials "$url"
  log_ok "已重新生成 ${CRED_FILE}"
  echo ""
  echo "访问地址：${url}"
  if [ -n "$CPA_API_KEY" ]; then
    echo "CPA 渠道地址：http://127.0.0.1:${CPA_PORT}/v1"
  fi
  echo ""
}

cmd_show() {
  require_root "$@"
  [ -f "$CRED_FILE" ] || die "找不到 ${CRED_FILE}（可能尚未安装）"
  load_state
  echo ""
  sed -n '1,40p' "$CRED_FILE"
  echo ""
  PORT="$(env_get PORT)"
  if [ -n "$PORT" ]; then echo "应用端口：${PORT}"; fi
  echo ""
}

cmd_restart() {
  require_root "$@"
  [ -x "${INSTALL_DIR}/new-api" ] || die "尚未安装"
  load_state
  PORT="$(env_get PORT)"; [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-3000}"

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
  [ -x "${INSTALL_DIR}/new-api" ] || die "尚未安装"
  log_info "跟踪日志（最近 ${LOG_LINES} 行，Ctrl+C 退出）"
  journalctl -u "$SERVICE" -n "$LOG_LINES" -f
}

cmd_clean() {
  require_root "$@"
  local bak="${INSTALL_DIR}/new-api.bak"
  if [ ! -f "$bak" ]; then
    log_info "没有旧版本备份，无需清理"
    return 0
  fi
  local size
  size="$(du -h "$bak" 2>/dev/null | awk '{ print $1 }')"
  rm -f "$bak"
  log_ok "已删除 ${bak}（释放 ${size:-未知}）"
}

cmd_uninstall() {
  require_root "$@"
  detect_os
  load_state

  local domain="${ST_DOMAIN:-$DOMAIN}" ufw_ports="${ST_UFW_PORTS:-}"
  PORT="$(env_get PORT)"; [ -n "$PORT" ] || PORT="${ST_SERVER_PORT:-3000}"

  echo ""
  log_warn "即将卸载 New API 并清理本脚本创建的全部资源："
  echo "  - 服务与 systemd 单元、/opt/new-api、/etc/new-api、/usr/local/bin/napi"
  echo "  - SQLite 数据库 ${ST_DB_PATH:-${DATA_DIR}/new-api.db}"
  echo "  - Nginx 站点与脚本申请的证书"
  echo "  - 系统用户 ${SERVICE_USER}"
  if [ "$KEEP_DATA" = "true" ]; then
    echo "  - 数据库：先备份到 /var/backups 再删除"
  else
    echo "  - 数据库：一并删除"
  fi
  echo ""
  echo "  不会动：系统原有的其他服务、Nginx 站点、数据库。"
  echo ""

  if [ "$ASSUME_YES" != "true" ]; then
    prompt_confirm '确认继续？(y/N) ' || { log_info "已取消"; return 0; }
  fi

  [ "$INSTALL_DIR" = "/opt/new-api" ] || die "安装路径异常，已中止"
  [ "$CONF_DIR" = "/etc/new-api" ] || die "配置路径异常，已中止"

  step "停止并移除应用"
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload

  local backup_dir="" db_file
  db_file="${ST_DB_PATH:-${DATA_DIR}/new-api.db}"
  if [ "$KEEP_DATA" = "true" ] && [ -f "$db_file" ]; then
    step "备份数据库"
    backup_dir="/var/backups/new-api-$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "$backup_dir"
    if cp -a "$db_file" "${backup_dir}/new-api.db" 2>/dev/null; then
      log_ok "已备份：${backup_dir}/new-api.db"
    else
      log_warn "数据库备份失败"
    fi
  fi

  step "移除 Nginx 站点"
  if [ -f /etc/nginx/sites-enabled/new-api.conf ] || [ -f "$NGINX_SITE" ]; then
    rm -f /etc/nginx/sites-enabled/new-api.conf "$NGINX_SITE"
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    fi
    log_info "已移除 Nginx 站点（其他站点不受影响）"
  fi

  if [ "${ST_CERT_CREATED:-false}" = "true" ] && [ -n "$domain" ]; then
    if [ -d "/etc/letsencrypt/live/${domain}" ]; then
      certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 \
        || log_warn "证书删除失败，可手动：certbot delete --cert-name ${domain}"
    fi
  fi

  if [ -f "$CPA_UNIT_FILE" ] || [ -d "$CPA_DIR" ]; then
    step "移除 CPA"
    systemctl stop "$CPA_SERVICE" 2>/dev/null || true
    systemctl disable "$CPA_SERVICE" 2>/dev/null || true
    rm -f "$CPA_UNIT_FILE"
    systemctl daemon-reload
    rm -rf "$CPA_DIR" "$CPA_CONF_DIR"
    userdel "$CPA_USER" 2>/dev/null || true
    log_info "已移除 CPA（含账号凭据与配置）"
  fi

  step "移除用户与目录"
  rm -rf "$INSTALL_DIR"
  rm -rf "$CONF_DIR"
  rm -f "$SUB_BIN"
  rm -f "$APT_LOG"
  userdel "$SERVICE_USER" 2>/dev/null || true

  if [ -n "$ufw_ports" ] && command -v ufw >/dev/null 2>&1; then
    local p
    for p in $(printf '%s' "$ufw_ports" | tr ',' '\n'); do
      [ -n "$p" ] || continue
      ufw delete allow "$p" >/dev/null 2>&1 || true
    done
    log_info "已移除 ufw 放行规则"
  fi

  if [ -n "$backup_dir" ]; then
    log_info "数据已备份到 ${backup_dir}"
  fi

  step "清理软件包"
  purge_nginx_packages

  verify_clean
  echo ""
  log_ok "卸载完成"
  echo ""
}

# ---------------------------------------------------------------- 菜单

dispatch() {
  case "$1" in
    install)   cmd_install ;;
    upgrade)   cmd_upgrade ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    domain)    cmd_domain ;;
    show)      cmd_show ;;
    restart)   cmd_restart ;;
    logs)      cmd_logs ;;
    clean)     cmd_clean ;;
    cred)      cmd_cred ;;
    self-update) cmd_self_update ;;
  esac
}

menu_quit() {
  tui_leave
  echo ""
  echo "已退出菜单。服务日志：journalctl -u newapi -n 50"
  echo ""
  exit 0
}

menu_unreadable() {
  tui_leave
  echo ""
  echo "无法从当前终端读取输入，交互菜单不可用。"
  echo "请改用带参数的命令，例如：sudo bash ${LOCAL_SCRIPT} install"
  echo ""
  exit 1
}

menu_read() {
  local __var="$1" __val=""
  if read -r __val < /dev/tty 2>/dev/null; then
    printf -v "$__var" '%s' "$__val"; return 0
  fi
  if [ -t 0 ] && read -r __val 2>/dev/null; then
    printf -v "$__var" '%s' "$__val"; return 0
  fi
  return 1
}

run_menu() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行，例如：sudo bash deploy.sh"

  local choice="" again="" state=""
  while true; do
    state="未安装"
    if [ -x "${INSTALL_DIR}/new-api" ]; then
      state="已安装 $(app_version)"
    fi

    tui_enter
    tui_clear
    echo "=============================================="
    echo "        New API 一键部署 / 卸载"
    echo "=============================================="
    echo ""
    echo "  当前状态：${state}"
    echo ""
    echo "  1) 安装 / 重装（自动使用最新版）"
    echo "  2) 配置域名 / HTTPS"
    echo "  3) 查看状态"
    echo "  4) 升级到最新版"
    echo "  5) 卸载"
    echo "  6) 查看凭据"
    echo "  7) 重启应用"
    echo "  8) 查看日志"
    echo "  9) 清理旧版本备份"
    echo " 10) 重新生成凭据"
    echo " 11) 更新脚本本身"
    echo "  0) 退出"
    echo ""

    printf '请选择: ' > /dev/tty 2>/dev/null || true
    if ! menu_read choice; then
      tui_leave
      printf '请选择: ' > /dev/tty 2>/dev/null || true
      menu_read choice || menu_unreadable
    fi

    case "$choice" in
      0) menu_quit ;;
      1|2|3|4|5|6|7|8|9|10|11) ;;
      *) continue ;;
    esac

    FROM_MENU="true"
    case "$choice" in
      1) dispatch install ;;
      2) dispatch domain ;;
      3) dispatch status ;;
      4) dispatch upgrade ;;
      5) dispatch uninstall ;;
      6) dispatch show ;;
      7) dispatch restart ;;
      8) dispatch logs ;;
      9) dispatch clean ;;
      10) dispatch cred ;;
      11) dispatch self-update ;;
    esac

    printf '\n按回车返回菜单（q 退出）: ' > /dev/tty 2>/dev/null || true
    menu_read again || menu_unreadable
    case "$again" in q|Q) menu_quit ;; esac
  done
}

main() {
  if [ "$#" -eq 0 ] && have_tty; then
    if [ -x "${INSTALL_DIR}/new-api" ]; then
      run_menu
    else
      FROM_MENU="true"
      dispatch install
    fi
    return 0
  fi

  parse_args "$@"
  dispatch "$ACTION"
}

main "$@"
