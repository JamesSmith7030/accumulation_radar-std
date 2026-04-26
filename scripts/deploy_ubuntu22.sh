#!/usr/bin/env bash
set -Eeuo pipefail

# One-command deployment for Ubuntu 22.04.
# Defaults are tuned for the "ubuntu" user with sudo privileges.

REPO_URL="${REPO_URL:-git@github.com:JamesSmith7030/accumulation_radar-std.git}"
APP_ROOT="${APP_ROOT:-/opt/accumulation_radar}"
APP_DIR="${APP_DIR:-$APP_ROOT/app}"
ENV_FILE="${ENV_FILE:-/etc/accumulation_radar.env}"
DEPLOY_REF="${DEPLOY_REF:-}"
POOL_TIME="${POOL_TIME:-10:00:00}"
OI_MINUTE="${OI_MINUTE:-30}"
RUN_NOW="${RUN_NOW:-1}"
NO_PROMPT="${NO_PROMPT:-0}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

DEFAULT_USER="${SUDO_USER:-$(id -un)}"
if [[ "$DEFAULT_USER" == "root" ]]; then
  DEFAULT_USER="ubuntu"
fi
APP_USER="${APP_USER:-$DEFAULT_USER}"
APP_GROUP="${APP_GROUP:-$APP_USER}"

SERVICE_NAME="accumulation-radar@.service"
POOL_TIMER="accumulation-radar-pool.timer"
OI_TIMER="accumulation-radar-oi.timer"

if [[ "$EUID" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  die "部署失败，出错行号: $1。可用 journalctl -u 'accumulation-radar@*.service' -n 100 --no-pager 查看服务日志。"
}
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<EOF
Usage:
  bash scripts/deploy_ubuntu22.sh

Common environment overrides:
  REPO_URL=git@github.com:JamesSmith7030/accumulation_radar-std.git
  DEPLOY_REF=main
  APP_USER=ubuntu
  APP_ROOT=/opt/accumulation_radar
  ENV_FILE=/etc/accumulation_radar.env
  TG_BOT_TOKEN=...
  TG_CHAT_ID=...
  RUN_NOW=0
  NO_PROMPT=1

Examples:
  bash scripts/deploy_ubuntu22.sh
  TG_BOT_TOKEN=xxx TG_CHAT_ID=yyy bash scripts/deploy_ubuntu22.sh
  RUN_NOW=0 DEPLOY_REF=main bash scripts/deploy_ubuntu22.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

validate_inputs() {
  [[ "$POOL_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]] || die "POOL_TIME 必须形如 10:00:00"
  [[ "$OI_MINUTE" =~ ^[0-5]?[0-9]$ ]] || die "OI_MINUTE 必须是 0-59"
  local oi_minute_num=$((10#$OI_MINUTE))
  if (( oi_minute_num < 0 || oi_minute_num > 59 )); then
    die "OI_MINUTE 必须是 0-59"
  fi
  OI_MINUTE="$(printf '%02d' "$oi_minute_num")"
  id "$APP_USER" >/dev/null 2>&1 || die "用户不存在: $APP_USER"
  getent group "$APP_GROUP" >/dev/null 2>&1 || die "用户组不存在: $APP_GROUP"
}

warn_if_not_ubuntu_2204() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
      log "提示: 当前系统是 ${PRETTY_NAME:-unknown}，脚本按 Ubuntu 22.04 设计，继续执行。"
    fi
  fi
}

install_packages() {
  log "安装系统依赖"
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv
}

prepare_app_dir() {
  log "准备目录: $APP_ROOT"
  "${SUDO[@]}" mkdir -p "$APP_ROOT"
  "${SUDO[@]}" chown -R "$APP_USER:$APP_GROUP" "$APP_ROOT"
}

run_as_app_user() {
  if [[ "$(id -un)" == "$APP_USER" && "$EUID" -ne 0 ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    runuser -u "$APP_USER" -- "$@"
  else
    "${SUDO[@]}" -u "$APP_USER" "$@"
  fi
}

pull_current_branch_if_possible() {
  if run_as_app_user git -C "$APP_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    run_as_app_user git -C "$APP_DIR" pull --ff-only
  else
    log "当前 Git ref 没有 upstream，跳过 pull --ff-only。"
  fi
}

checkout_code() {
  log "拉取或更新代码: $REPO_URL"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    run_as_app_user git clone "$REPO_URL" "$APP_DIR"
  else
    run_as_app_user git -C "$APP_DIR" remote set-url origin "$REPO_URL"
    run_as_app_user git -C "$APP_DIR" fetch --prune origin
    if [[ -n "$DEPLOY_REF" ]]; then
      run_as_app_user git -C "$APP_DIR" checkout "$DEPLOY_REF"
      pull_current_branch_if_possible
    else
      pull_current_branch_if_possible
    fi
  fi

  if [[ -n "$DEPLOY_REF" && ! -d "$APP_DIR/.git/rebase-merge" ]]; then
    run_as_app_user git -C "$APP_DIR" checkout "$DEPLOY_REF"
  fi
}

install_python_deps() {
  log "创建虚拟环境并安装 Python 依赖"
  run_as_app_user "$PYTHON_BIN" -m venv "$APP_DIR/.venv"
  run_as_app_user "$APP_DIR/.venv/bin/python" -m pip install --upgrade pip
  run_as_app_user "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"
  run_as_app_user "$APP_DIR/.venv/bin/python" -m compileall -q "$APP_DIR/accumulation_radar"
}

read_env_value() {
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    "${SUDO[@]}" awk -v key="$key" 'BEGIN { FS = "=" } $1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE" 2>/dev/null || true
  fi
}

write_env_file() {
  local token="$1"
  local chat_id="$2"
  local timezone="${3:-Asia/Shanghai}"
  local tmp_file
  tmp_file="$(mktemp)"
  chmod 600 "$tmp_file"
  {
    printf '# Managed by scripts/deploy_ubuntu22.sh\n'
    printf '# Leave Telegram values empty to print reports to journald/stdout.\n'
    printf 'TG_BOT_TOKEN=%s\n' "$token"
    printf 'TG_CHAT_ID=%s\n' "$chat_id"
    printf 'TZ=%s\n' "$timezone"
  } >"$tmp_file"
  "${SUDO[@]}" install -o "$APP_USER" -g "$APP_GROUP" -m 600 "$tmp_file" "$ENV_FILE"
  rm -f "$tmp_file"
}

configure_env_file() {
  log "配置环境文件: $ENV_FILE"

  local token="${TG_BOT_TOKEN:-}"
  local chat_id="${TG_CHAT_ID:-}"
  local timezone="${TZ:-Asia/Shanghai}"

  if [[ -f "$ENV_FILE" ]]; then
    [[ -n "$token" ]] || token="$(read_env_value TG_BOT_TOKEN)"
    [[ -n "$chat_id" ]] || chat_id="$(read_env_value TG_CHAT_ID)"
    timezone="$(read_env_value TZ || true)"
    [[ -n "$timezone" ]] || timezone="Asia/Shanghai"
  fi

  if [[ "$NO_PROMPT" != "1" && -t 0 ]]; then
    if [[ -z "$token" ]]; then
      printf 'Telegram Bot Token，可留空跳过: '
      IFS= read -r -s token
      printf '\n'
    fi
    if [[ -z "$chat_id" ]]; then
      printf 'Telegram Chat ID，可留空跳过: '
      IFS= read -r chat_id
    fi
  fi

  write_env_file "$token" "$chat_id" "$timezone"
  log "环境文件已写入，权限为 600；未输出任何密钥值。"
}

write_systemd_unit() {
  log "写入 systemd service/timer"

  local service_tmp pool_tmp oi_tmp
  service_tmp="$(mktemp)"
  pool_tmp="$(mktemp)"
  oi_tmp="$(mktemp)"

  cat >"$service_tmp" <<EOF
[Unit]
Description=Accumulation Radar %i job
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=-$ENV_FILE
ExecStart=$APP_DIR/.venv/bin/python -m accumulation_radar %i
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR
EOF

  cat >"$pool_tmp" <<EOF
[Unit]
Description=Run accumulation pool scan daily

[Timer]
OnCalendar=*-*-* $POOL_TIME
AccuracySec=1min
Persistent=true
RandomizedDelaySec=300
Unit=accumulation-radar@pool.service

[Install]
WantedBy=timers.target
EOF

  cat >"$oi_tmp" <<EOF
[Unit]
Description=Run accumulation OI scan hourly

[Timer]
OnCalendar=*-*-* *:$OI_MINUTE:00
AccuracySec=1min
Persistent=true
RandomizedDelaySec=120
Unit=accumulation-radar@oi.service

[Install]
WantedBy=timers.target
EOF

  "${SUDO[@]}" install -o root -g root -m 0644 "$service_tmp" "/etc/systemd/system/$SERVICE_NAME"
  "${SUDO[@]}" install -o root -g root -m 0644 "$pool_tmp" "/etc/systemd/system/$POOL_TIMER"
  "${SUDO[@]}" install -o root -g root -m 0644 "$oi_tmp" "/etc/systemd/system/$OI_TIMER"

  rm -f "$service_tmp" "$pool_tmp" "$oi_tmp"

  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable --now "$POOL_TIMER" "$OI_TIMER"
}

run_initial_jobs() {
  if [[ "$RUN_NOW" != "1" ]]; then
    log "跳过立即运行；timer 会按计划执行。"
    return
  fi

  log "立即运行 pool 初始化标的池"
  "${SUDO[@]}" systemctl start accumulation-radar@pool.service

  log "立即运行 oi 生成策略报告"
  "${SUDO[@]}" systemctl start accumulation-radar@oi.service
}

print_summary() {
  log "部署完成"
  printf '代码目录: %s\n' "$APP_DIR"
  printf '环境文件: %s\n' "$ENV_FILE"
  printf 'Pool timer: %s，每天 %s\n' "$POOL_TIMER" "$POOL_TIME"
  printf 'OI timer: %s，每小时第 %s 分钟\n' "$OI_TIMER" "$OI_MINUTE"
  printf '\n常用命令:\n'
  printf '  systemctl list-timers "accumulation-radar*"\n'
  printf '  sudo systemctl start accumulation-radar@full.service\n'
  printf "  sudo journalctl -u 'accumulation-radar@*.service' -n 100 --no-pager\n"
  printf '  sudo nano %s\n' "$ENV_FILE"
}

main() {
  validate_inputs
  warn_if_not_ubuntu_2204
  install_packages
  prepare_app_dir
  checkout_code
  install_python_deps
  configure_env_file
  write_systemd_unit
  run_initial_jobs
  print_summary
}

main "$@"
