#!/bin/bash
# =====================================================================
# 项目名称: VPS Box (轻量级节点管理与网络优化引擎)
# 版本: v1.7.3 — 元数据回滚修复、README 重写与全局检查加固
# 推荐运行方式: bash <(curl -sL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh)
# =====================================================================
VPSBOX_VERSION="v1.7.9"

# =====================================================================
# curl|bash 兼容: 仅管道模式 [! -t 0] 重定向 stdin
# 终端模式（本地运行/vpsbox/bash <()）: 保持默认 stdin
# =====================================================================

# 颜色变量必须最先定义，后续加载提示需要用到
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 立即输出加载提示，防止 curl|bash 管道模式下长时间静默让用户以为卡死
echo -e "\n${GREEN}[VPSBox v${VPSBOX_VERSION#v}]${NC} 正在初始化..."
BACKUP_DIR="/etc/vpsbox_backups"
CUSTOM_CONF="/etc/sysctl.d/99-vpsbox-tcp.conf"
SHORTCUT_PATH="/usr/local/bin/vpsbox"
SCRIPT_URL="https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh"
NODE_RECORD_FILE="/etc/vpsbox_nodes.txt"
INSTALL_LOG="/tmp/vpsbox_install.log"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"
SINGBOX_CONFIG_FILE="/etc/sing-box/config.json"
XRAY_NODES_DIR="/usr/local/etc/xray/nodes.d"
SINGBOX_NODES_DIR="/etc/sing-box/nodes.d"
XRAY_RUNTIME_DIR="/usr/local/etc/xray"
SINGBOX_RUNTIME_DIR="/etc/sing-box"
NODE_RUNTIME_STATE_DIR="/etc/vpsbox_node_runtime"
XRAY_META_FILE="${NODE_RUNTIME_STATE_DIR}/xray_nodes.json"
SINGBOX_META_FILE="${NODE_RUNTIME_STATE_DIR}/singbox_nodes.json"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
SINGBOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"

mkdir -p "$BACKUP_DIR"
mkdir -p "$NODE_RUNTIME_STATE_DIR"
if [ "$EUID" -ne 0 ]; then
echo -e "\n${RED}[错误] 权限不足！请使用 root 用户运行。${NC}\n"
exit 1
fi
# 退出时清理临时测试配置文件
trap 'rm -f /tmp/vpsbox_test_config.json' EXIT
# 自动注册/同步全局命令（不联网检测更新；仅把当前运行脚本同步到 vpsbox）
_sync_shortcut_from_current() {
    [ "$0" = "$SHORTCUT_PATH" ] && return 0
    local shortcut_ver=""
    [ -s "$SHORTCUT_PATH" ] && shortcut_ver=$(grep -oP '^VPSBOX_VERSION="\K[^"]+' "$SHORTCUT_PATH" 2>/dev/null | head -1)
    [ "$shortcut_ver" = "$VPSBOX_VERSION" ] && return 0
    if [ -f "$0" ]; then
        install -m 755 "$0" "$SHORTCUT_PATH" 2>/dev/null || true
    fi
}
_sync_shortcut_from_current

# 启动时检测远程版本：只提示，不自动更新
REMOTE_VERSION=""
UPDATE_AVAILABLE=0
_check_startup_update() {
    local remote_ver local_ver newer i r l
    remote_ver=$(curl -sL --connect-timeout 2 --max-time 3 "$SCRIPT_URL" 2>/dev/null | grep -oP '^VPSBOX_VERSION="\K[^"]+' | head -1)
    [ -z "$remote_ver" ] && return 0
    REMOTE_VERSION="$remote_ver"
    remote_ver="${remote_ver#v}"
    local_ver="${VPSBOX_VERSION#v}"
    [ "$remote_ver" = "$local_ver" ] && return 0
    IFS='.' read -ra rmt_parts <<< "$remote_ver"
    IFS='.' read -ra loc_parts <<< "$local_ver"
    newer=0
    for i in 0 1 2; do
        r=${rmt_parts[$i]:-0}; l=${loc_parts[$i]:-0}
        if [ "$r" -gt "$l" ] 2>/dev/null; then newer=1; break; fi
        if [ "$r" -lt "$l" ] 2>/dev/null; then break; fi
    done
    [ "$newer" -eq 1 ] && UPDATE_AVAILABLE=1
}
_check_startup_update
if [ -f /etc/os-release ]; then
# shellcheck disable=SC1091
. /etc/os-release
# 允许所有主流 Linux 发行版运行
if [[ "$ID" =~ ^(debian|ubuntu|centos|rhel|almalinux|rocky|oracle|fedora|alpine|arch|manjaro|opensuse|kali|pop|linuxmint|deepin|elementary|armbian)$ ]] || \
   [[ "$ID_LIKE" =~ (debian|ubuntu|rhel|centos|fedora|arch|suse) ]]; then
  :
else
  echo -e "\n${RED}[错误] 不支持的操作系统: ${ID}${NC}\n"
  exit 1
fi
else
echo -e "\n${RED}[错误] 无法识别的操作系统！${NC}\n"
exit 1
fi
if ! grep -qE "^[[:space:]]*[0-9:.]+[[:space:]].*(^|[[:space:]])$(hostname)([[:space:]]|$)" /etc/hosts; then
echo "127.0.1.1 $(hostname)" >> /etc/hosts
fi

clear_screen() { [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ] && clear || printf '\n'; }

_CPU_CORES=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$(( (RAM_MB + 512) / 1024 ))
[ "$RAM_GB" -eq 0 ] && RAM_GB=1
CURRENT_TZ=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
[ -z "$CURRENT_TZ" ] && CURRENT_TZ="UTC"

# IP 懒加载：启动不检测，首次使用时自动获取（避免无 IPv6 机器卡死）
SERVER_IPV4=""; SERVER_IPV6=""; SERVER_IP=""; _IP_DONE=0
_ensure_ip() {
    [ "$_IP_DONE" -eq 1 ] && return
    _IP_DONE=1
    SERVER_IPV4=$(curl -fsS4 --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null)
    [ -z "$SERVER_IPV4" ] && SERVER_IPV4=$(curl -fsS4 --connect-timeout 1 --max-time 2 ip.sb 2>/dev/null)
    [ -z "$SERVER_IPV4" ] && SERVER_IPV4="未分配"
    SERVER_IPV6=$(curl -fsS6 --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null)
    [ -z "$SERVER_IPV6" ] && SERVER_IPV6=$(curl -fsS6 --connect-timeout 1 --max-time 2 ip.sb 2>/dev/null)
    [ -z "$SERVER_IPV6" ] && SERVER_IPV6="未分配"
    if [ "$SERVER_IPV4" != "未分配" ]; then SERVER_IP="$SERVER_IPV4"
    elif [ "$SERVER_IPV6" != "未分配" ]; then SERVER_IP="[${SERVER_IPV6}]"
    else SERVER_IP="未分配"; fi
}

_resolve_domain_ips() {
  local domain="$1"
  local line ip
  if command -v getent >/dev/null 2>&1; then
    while read -r ip _; do
      [ -n "$ip" ] && echo "$ip"
    done < <(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++')
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" 2>/dev/null
    dig +short AAAA "$domain" 2>/dev/null
    return 0
  fi
  return 1
}

_domain_points_to_server() {
  local domain="$1"
  local ip
  local matched=1
  while read -r ip; do
    [ -z "$ip" ] && continue
    if [ "$ip" = "$SERVER_IPV4" ] || [ "$ip" = "$SERVER_IPV6" ]; then
      matched=0
      break
    fi
  done < <(_resolve_domain_ips "$domain")
  return $matched
}

_domain_resolution_summary() {
  local domain="$1"
  local ips
  ips=$(_resolve_domain_ips "$domain" | paste -sd ',' -)
  echo "$ips"
}

get_term_width() {
local cols
cols=$(tput cols 2>/dev/null || echo 80)
if [ "$cols" -gt 100 ]; then echo 100
elif [ "$cols" -lt 40 ]; then echo 40
else echo "$cols"
fi
}

print_divider() {
local w
w=$(get_term_width)
echo -e "${CYAN}$(printf '%*s' "$w" '' | tr ' ' '=')${NC}"
}

print_center() {
local text="$1"
local color="$2"
local term_width plain_text
term_width=$(get_term_width)
plain_text=$(printf '%b' "$text" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
local text_len=${#plain_text}
local padding=$(( (term_width - text_len) / 2 ))
[ "$padding" -lt 0 ] && padding=0
printf "%${padding}s" ""
echo -e "${color}${text}${NC}"
}

pause_for_enter() {
echo ""
print_divider
echo -ne "${YELLOW}> 操作已完成，请按 [回车键] 返回主菜单...${NC}"
read -r
}

confirm_action() {
local action_name=$1
local default=${2:-y}
local hint
if [[ "$default" =~ ^[yY]$ ]]; then hint="Y/n"; else hint="y/N"; fi
echo ""
read -r -p "> 是否确认执行 [${action_name}]？(${hint}): " confirm
confirm="${confirm// /}"
[ -z "$confirm" ] && confirm="$default"
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
echo -e "\n${YELLOW}已取消 [${action_name}] 操作。${NC}"
return 1
fi
return 0
}

fix_dpkg() {
  if fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
    echo -e "${YELLOW}[警告] 检测到 apt/dpkg 正在运行，跳过自动修复以避免损坏包数据库。${NC}"
    return 1
  fi
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a
}

_svc_restart() {
  if command -v apk &>/dev/null; then service "$1" restart
  else /bin/systemctl restart "$1"; fi
}
_svc_start() {
  if command -v apk &>/dev/null; then service "$1" start
  else /bin/systemctl start "$1"; fi
}
_svc_stop() {
  if command -v apk &>/dev/null; then service "$1" stop
  else /bin/systemctl stop "$1"; fi
}
_svc_enable() {
  if command -v apk &>/dev/null; then rc-update add "$1" default
  else /bin/systemctl enable "$1"; fi
}
_svc_is_active() {
  if command -v apk &>/dev/null; then timeout 5 service "$1" status &>/dev/null
  else timeout 5 /bin/systemctl is-active --quiet "$1" 2>/dev/null; fi
}

_svc_main_pid() {
  if command -v systemctl &>/dev/null; then
    timeout 3 systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2
  else
    pgrep -f "$1" 2>/dev/null | head -1
  fi
}

_sshd_config_test() {
  if command -v sshd &>/dev/null; then sshd -t 2>/dev/null
  else return 0; fi
}

_collect_public_listen_entries() {
  ss -H -tlnu 2>/dev/null | awk '
    {
      proto=$1; local=$5
      n=split(local, a, ":")
      port=a[n]
      if (port !~ /^[0-9]+$/) next
      if (local ~ /127\.0\.0\.1:/) next
      if (local ~ /\[::1\]:/) next
      if (local ~ /localhost:/) next
      key=proto":"port
      if (!seen[key]++) print proto, port
    }
  '
}

_restart_ssh_service_safely() {
  local action_desc="$1"
  if ! _sshd_config_test; then
    echo -e "${RED}[错误] SSH 配置校验失败，已取消重启。${NC}"
    return 1
  fi
  [ -n "$action_desc" ] && echo -e "${YELLOW}[提示] ${action_desc}，SSH 服务已安排后台短暂重启，请留意新配置是否生效。${NC}"
  ( sleep 1; _svc_restart sshd >/dev/null 2>&1 || _svc_restart ssh >/dev/null 2>&1 ) &
}

_set_sshd_option() {
  local key="$1" value="$2" file="/etc/ssh/sshd_config" backup
  [ -f "$file" ] || { echo -e "${RED}[错误] 未找到 $file${NC}"; return 1; }
  backup="${file}.vpsbox.bak.$(date +%Y%m%d%H%M%S)"
  cp "$file" "$backup" 2>/dev/null || backup=""
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
  else
    printf '
%s %s
' "$key" "$value" >> "$file"
  fi
  if ! _sshd_config_test; then
    [ -n "$backup" ] && cp "$backup" "$file" 2>/dev/null
    echo -e "${RED}[错误] sshd 配置校验失败，已回滚更改。请检查 ${file}${NC}"
    return 1
  fi
}

_svc_reload() {
  if _svc_is_active "$1" 2>/dev/null; then
    local OLD_PID; OLD_PID=$(_svc_main_pid "$1")
    if command -v apk &>/dev/null; then
      timeout 10 service "$1" reload 2>/dev/null && { echo -e "${GREEN}  ✓ $1 热重载成功${NC}"; return 0; }
    else
      timeout 10 /bin/systemctl reload "$1" 2>/dev/null && { echo -e "${GREEN}  ✓ $1 热重载成功${NC}"; return 0; }
      [ -n "$OLD_PID" ] && timeout 5 /bin/kill -HUP "$OLD_PID" 2>/dev/null && { echo -e "${GREEN}  ✓ $1 热重载成功 (kill -HUP)${NC}"; return 0; }
    fi
    local NEW_PID; NEW_PID=$(_svc_main_pid "$1")
    if [ -n "$OLD_PID" ] && [ -n "$NEW_PID" ] && [ "$OLD_PID" != "$NEW_PID" ]; then
      echo -e "${RED}[错误] $1 意外重启 (PID $OLD_PID → $NEW_PID)，连接已中断！${NC}"
    else
      echo -e "${YELLOW}[警告] $1 热重载失败，新配置未生效。请稍后手动: systemctl restart $1${NC}"
    fi
    return 1
  else
    echo -e "${YELLOW}  $1 未运行，正在启动...${NC}"
    _svc_start "$1"
  fi
}
_svc_daemon_reload() {
  if command -v apk &>/dev/null; then return 0
  else /bin/systemctl daemon-reload 2>/dev/null; fi
}

_json_escape() {
  jq -Rn --arg v "$1" '$v'
}

_sanitize_filename_component() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

_fragment_file_for_node() {
  local core_name="$1" port="$2" protocol="$3"
  local node_dir proto_slug
  node_dir=$(_node_dir_for_core "$core_name") || return 1
  proto_slug=$(_sanitize_filename_component "$protocol")
  [ -z "$proto_slug" ] && proto_slug="node"
  echo "${node_dir}/${port}-${proto_slug}.json"
}

_node_meta_file_for_core() {
  case "$1" in
    Xray) echo "$XRAY_META_FILE" ;;
    Sing-box) echo "$SINGBOX_META_FILE" ;;
    *) return 1 ;;
  esac
}

_node_dir_for_core() {
  case "$1" in
    Xray) echo "$XRAY_NODES_DIR" ;;
    Sing-box) echo "$SINGBOX_NODES_DIR" ;;
    *) return 1 ;;
  esac
}

_config_file_for_core() {
  case "$1" in
    Xray) echo "$XRAY_CONFIG_FILE" ;;
    Sing-box) echo "$SINGBOX_CONFIG_FILE" ;;
    *) return 1 ;;
  esac
}

_service_name_for_core() {
  case "$1" in
    Xray) echo "xray" ;;
    Sing-box) echo "sing-box" ;;
    *) return 1 ;;
  esac
}

_runtime_dir_for_core() {
  case "$1" in
    Xray) echo "$XRAY_RUNTIME_DIR" ;;
    Sing-box) echo "$SINGBOX_RUNTIME_DIR" ;;
    *) return 1 ;;
  esac
}

_ensure_node_meta_file() {
  local meta_file="$1"
  mkdir -p "$(dirname "$meta_file")"
  if [ ! -s "$meta_file" ]; then
    printf '[]\n' > "$meta_file"
  elif ! jq empty "$meta_file" >/dev/null 2>&1; then
    printf '[]\n' > "$meta_file"
  fi
}

_node_meta_remove_port() {
  local core_name="$1" target_port="$2"
  local meta_file; meta_file=$(_node_meta_file_for_core "$core_name") || return 1
  _ensure_node_meta_file "$meta_file"
  local tmp; tmp=$(mktemp) || return 1
  if jq --argjson port "$target_port" 'map(select(.port != $port))' "$meta_file" > "$tmp"; then
    mv "$tmp" "$meta_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_node_meta_upsert() {
  local core_name="$1" target_port="$2" label="$3" link="$4" file_path="$5" protocol="$6"
  local meta_file; meta_file=$(_node_meta_file_for_core "$core_name") || return 1
  _ensure_node_meta_file "$meta_file"
  local tmp; tmp=$(mktemp) || return 1
  if jq \
      --argjson port "$target_port" \
      --arg core "$core_name" \
      --arg label "$label" \
      --arg link "$link" \
      --arg file "$file_path" \
      --arg protocol "$protocol" \
      'map(select(.port != $port)) + [{port:$port, core:$core, label:$label, link:$link, file:$file, protocol:$protocol}] | sort_by(.port)' \
      "$meta_file" > "$tmp"; then
    mv "$tmp" "$meta_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_ensure_xray_service_reload_support() {
  if [ ! -d /etc/systemd/system ]; then return 0; fi
  local bin_path
  bin_path=$(command -v xray || echo "/usr/local/bin/xray")
  if [ ! -x "$bin_path" ]; then return 0; fi
  if [ ! -f "$XRAY_SERVICE_FILE" ]; then
    cat > "$XRAY_SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${bin_path} run -config ${XRAY_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    _svc_daemon_reload >/dev/null 2>&1 || true
  elif ! grep -q '^ExecReload=' "$XRAY_SERVICE_FILE"; then
    local tmp_service; tmp_service=$(mktemp) || return 0
    if awk '1; /^ExecStart=/{print "ExecReload=/bin/kill -HUP \\$MAINPID"}' "$XRAY_SERVICE_FILE" > "$tmp_service"; then
      mv "$tmp_service" "$XRAY_SERVICE_FILE"
      _svc_daemon_reload >/dev/null 2>&1 || true
    else
      rm -f "$tmp_service"
    fi
  fi
}

_ensure_singbox_service_reload_support() {
  if [ ! -d /etc/systemd/system ]; then return 0; fi
  local bin_path
  bin_path=$(command -v sing-box || echo "/usr/local/bin/sing-box")
  if [ ! -x "$bin_path" ]; then return 0; fi
  if [ ! -f "$SINGBOX_SERVICE_FILE" ]; then
    cat > "$SINGBOX_SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${bin_path} run -c ${SINGBOX_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    _svc_daemon_reload >/dev/null 2>&1 || true
  elif ! grep -q '^ExecReload=' "$SINGBOX_SERVICE_FILE"; then
    local tmp_service; tmp_service=$(mktemp) || return 0
    if awk '1; /^ExecStart=/{print "ExecReload=/bin/kill -HUP \\$MAINPID"}' "$SINGBOX_SERVICE_FILE" > "$tmp_service"; then
      mv "$tmp_service" "$SINGBOX_SERVICE_FILE"
      _svc_daemon_reload >/dev/null 2>&1 || true
    else
      rm -f "$tmp_service"
    fi
  fi
}

_emit_xray_merged_config() {
  local tmp_out="$1"
  mkdir -p "$XRAY_NODES_DIR" "$XRAY_RUNTIME_DIR"
  local nodes_json='[]'
  shopt -s nullglob
  local files=("$XRAY_NODES_DIR"/*.json)
  shopt -u nullglob
  if [ ${#files[@]} -gt 0 ]; then
    nodes_json=$(jq -s 'map(select(type=="object"))' "${files[@]}" 2>/dev/null) || return 1
  fi
  jq -n --argjson inbounds "$nodes_json" '{
    log:{loglevel:"warning"},
    inbounds:$inbounds,
    outbounds:[{protocol:"freedom", tag:"direct"}],
    routing:{domainStrategy:"AsIs", rules:[]}
  }' > "$tmp_out"
}

_emit_singbox_merged_config() {
  local tmp_out="$1"
  mkdir -p "$SINGBOX_NODES_DIR" "$SINGBOX_RUNTIME_DIR"
  local nodes_json='[]'
  shopt -s nullglob
  local files=("$SINGBOX_NODES_DIR"/*.json)
  shopt -u nullglob
  if [ ${#files[@]} -gt 0 ]; then
    nodes_json=$(jq -s 'map(select(type=="object"))' "${files[@]}" 2>/dev/null) || return 1
  fi
  jq -n --argjson inbounds "$nodes_json" '{
    log:{level:"warn"},
    inbounds:$inbounds,
    outbounds:[{type:"direct", tag:"direct"}],
    route:{rules:[]}
  }' > "$tmp_out"
}

_validate_generated_config() {
  local core_name="$1" tmp_file="$2"
  local validate_out; validate_out=$(mktemp)
  local ok=0
  if [ "$core_name" == "Sing-box" ]; then
    local sb_bin; sb_bin=$(command -v sing-box || echo "/usr/local/bin/sing-box")
    if timeout 10 "$sb_bin" check -c "$tmp_file" >"$validate_out" 2>&1; then
      ok=1
    fi
  else
    local x_bin; x_bin=$(command -v xray || echo "/usr/local/bin/xray")
    if "$x_bin" run -test -c "$tmp_file" >"$validate_out" 2>&1; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    rm -f "$validate_out"
    return 0
  fi
  echo -e "\n${RED}[校验错误]${NC}"
  cat "$validate_out" 2>/dev/null
  rm -f "$validate_out"
  return 1
}

_reload_core_without_disconnect() {
  local core_name="$1"
  local service_name; service_name=$(_service_name_for_core "$core_name") || return 1
  if [ "$core_name" == "Xray" ]; then
    _ensure_xray_service_reload_support
  elif [ "$core_name" == "Sing-box" ]; then
    _ensure_singbox_service_reload_support
  fi
  if _svc_is_active "$service_name" 2>/dev/null; then
    if _svc_reload "$service_name"; then
      return 0
    fi
    echo -e "${RED}[错误] ${service_name} 热重载失败。为保护现有连接，本次不会自动重启服务。${NC}"
    return 1
  fi
  echo -e "${YELLOW}[提示] ${service_name} 当前未运行，正在首次启动...${NC}"
  _svc_start "$service_name" && _svc_enable "$service_name" >/dev/null 2>&1
}

rebuild_core_config() {
  local core_name="$1"
  local config_file runtime_dir tmp_file
  config_file=$(_config_file_for_core "$core_name") || return 1
  runtime_dir=$(_runtime_dir_for_core "$core_name") || return 1
  mkdir -p "$runtime_dir"
  tmp_file=$(mktemp) || return 1
  if [ "$core_name" == "Xray" ]; then
    _emit_xray_merged_config "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  else
    _emit_singbox_merged_config "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  fi
  if ! _validate_generated_config "$core_name" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  mv "$tmp_file" "$config_file"
  return 0
}

write_node_fragment() {
  local core_name="$1" port="$2" protocol="$3" node_json="$4"
  local node_dir tmp_file final_file
  node_dir=$(_node_dir_for_core "$core_name") || return 1
  mkdir -p "$node_dir"
  tmp_file=$(mktemp) || return 1
  final_file=$(_fragment_file_for_node "$core_name" "$port" "$protocol") || { rm -f "$tmp_file"; return 1; }
  printf '%s\n' "$node_json" > "$tmp_file"
  if ! jq empty "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    echo -e "${RED}[错误] 节点片段 JSON 无效，已取消写入。${NC}"
    return 1
  fi
  mv "$tmp_file" "$final_file"
  echo "$final_file"
}

persist_node_runtime() {
  local core_name="$1" port="$2" label="$3" protocol="$4" link="$5" node_json="$6"
  local fragment_file
  fragment_file=$(write_node_fragment "$core_name" "$port" "$protocol" "$node_json") || return 1
  if ! rebuild_core_config "$core_name"; then
    rm -f "$fragment_file"
    rebuild_core_config "$core_name" >/dev/null 2>&1 || true
    return 1
  fi
  if ! _reload_core_without_disconnect "$core_name"; then
    rm -f "$fragment_file"
    rebuild_core_config "$core_name" >/dev/null 2>&1 || true
    return 1
  fi
  if ! _node_meta_upsert "$core_name" "$port" "$label" "$link" "$fragment_file" "$protocol"; then
    echo -e "${RED}[错误] 节点元数据写入失败，正在回滚本次节点变更。${NC}"
    rm -f "$fragment_file"
    rebuild_core_config "$core_name" >/dev/null 2>&1 || true
    _reload_core_without_disconnect "$core_name" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

remove_node_runtime() {
  local core_name="$1" port="$2"
  local meta_file fragment_file node_dir backup_fragment
  meta_file=$(_node_meta_file_for_core "$core_name") || return 1
  node_dir=$(_node_dir_for_core "$core_name") || return 1
  _ensure_node_meta_file "$meta_file"
  fragment_file=$(jq -r --argjson port "$port" '.[] | select(.port == $port) | .file' "$meta_file" 2>/dev/null | head -n 1)
  if [ -z "$fragment_file" ] || [ ! -f "$fragment_file" ]; then
    shopt -s nullglob
    local matches=("$node_dir/${port}-"*.json "$node_dir/${port}.json")
    shopt -u nullglob
    if [ ${#matches[@]} -eq 0 ]; then
      echo -e "${RED}[错误] 未找到端口 $port 对应的节点片段文件。${NC}"
      return 1
    fi
    fragment_file="${matches[0]}"
  fi
  backup_fragment="${fragment_file}.bak.$$"
  mv "$fragment_file" "$backup_fragment" || return 1
  if ! rebuild_core_config "$core_name"; then
    mv "$backup_fragment" "$fragment_file" >/dev/null 2>&1 || true
    rebuild_core_config "$core_name" >/dev/null 2>&1 || true
    echo -e "${RED}[错误] 重新生成 ${core_name} 主配置失败，已自动回滚节点片段。${NC}"
    return 1
  fi
  if ! _reload_core_without_disconnect "$core_name"; then
    mv "$backup_fragment" "$fragment_file" >/dev/null 2>&1 || true
    rebuild_core_config "$core_name" >/dev/null 2>&1 || true
    _reload_core_without_disconnect "$core_name" >/dev/null 2>&1 || true
    echo -e "${RED}[错误] ${core_name} 热重载失败，已自动回滚节点片段并恢复旧配置。${NC}"
    return 1
  fi
  rm -f "$backup_fragment"
  _node_meta_remove_port "$core_name" "$port" || true
  return 0
}

_pkg_install() {
  if command -v apt &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf &>/dev/null; then dnf install -y "$@"
  elif command -v yum &>/dev/null; then yum install -y "$@"
  elif command -v apk &>/dev/null; then apk add "$@"
  elif command -v pacman &>/dev/null; then pacman -S --noconfirm "$@"
  elif command -v zypper &>/dev/null; then zypper install -y "$@"
  else echo -e "${RED}[错误] 未识别的包管理器！${NC}"; fi
}
_pkg_remove() {
  if command -v apt &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$@"
  elif command -v dnf &>/dev/null; then dnf remove -y "$@"
  elif command -v yum &>/dev/null; then yum remove -y "$@"
  elif command -v apk &>/dev/null; then apk del "$@"
  elif command -v pacman &>/dev/null; then pacman -Rns --noconfirm "$@"
  elif command -v zypper &>/dev/null; then zypper remove -y "$@"
  else echo -e "${RED}[错误] 未识别的包管理器！${NC}"; fi
}

_run_remote_bash() {
  local url="$1" tmp rc first_line
  shift
  tmp=$(mktemp) || return 1
  if ! curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$tmp"; then
    rm -f "$tmp"
    echo -e "${RED}[错误] 远程脚本下载失败: $url${NC}"
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo -e "${RED}[错误] 远程脚本内容为空: $url${NC}"
    return 1
  fi
  first_line=$(head -n 1 "$tmp" 2>/dev/null || true)
  if grep -qiE '<(html|!doctype html)' "$tmp"; then
    rm -f "$tmp"
    echo -e "${RED}[错误] 下载到的内容看起来像 HTML 页面，已拒绝执行: $url${NC}"
    return 1
  fi
  if [[ "$first_line" != '#!'* ]] && ! grep -qE '(^|[[:space:]])(bash|sh)[[:space:]]' "$tmp"; then
    rm -f "$tmp"
    echo -e "${RED}[错误] 下载内容不像可执行 shell 脚本，已拒绝执行: $url${NC}"
    return 1
  fi
  bash "$tmp" "$@"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

_harden_sshd_dropins() {
  if [ -d /etc/ssh/sshd_config.d ] && [ -n "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^\(PubkeyAuthentication\|PasswordAuthentication\|PermitRootLogin\|ChallengeResponseAuthentication\) /#\0/' "$f" 2>/dev/null
    done
  fi
}

_valid_ssh_key_lines() {
  grep -Ev '^[[:space:]]*$' | grep -Eqv '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+) ' && return 1
  return 0
}

install_dependencies() {
local apps=("curl" "wget" "jq" "openssl" "socat" "unzip" "qrencode")
local missing_apps=()
for app in "${apps[@]}"; do
if ! command -v "$app" &> /dev/null; then missing_apps+=("$app"); fi
done
if ! command -v crond &>/dev/null && ! command -v cron &>/dev/null; then
  missing_apps+=("cron")
fi
[ ${#missing_apps[@]} -eq 0 ] && return

echo -e "\n${CYAN}[系统] 检测到缺失必要底层组件，正在自动补全...${NC}"
if command -v apt &>/dev/null; then
  fix_dpkg
  DEBIAN_FRONTEND=noninteractive apt-get update -y > "$INSTALL_LOG" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils qrencode cron lsb-release >> "$INSTALL_LOG" 2>&1
elif command -v dnf &>/dev/null; then
  dnf install -y curl wget sudo unzip tar openssl socat psmisc iputils jq gnupg2 bind-utils qrencode cronie >> "$INSTALL_LOG" 2>&1
elif command -v yum &>/dev/null; then
  yum install -y curl wget sudo unzip tar openssl socat psmisc iputils jq gnupg2 bind-utils qrencode cronie >> "$INSTALL_LOG" 2>&1
elif command -v apk &>/dev/null; then
  apk add curl wget sudo unzip tar openssl socat psmisc iputils jq gnupg qrencode dcron >> "$INSTALL_LOG" 2>&1
elif command -v pacman &>/dev/null; then
  pacman -S --noconfirm curl wget sudo unzip tar openssl socat psmisc iputils jq gnupg qrencode cronie >> "$INSTALL_LOG" 2>&1
elif command -v zypper &>/dev/null; then
  zypper install -y curl wget sudo unzip tar openssl socat psmisc iputils jq gpg2 bind-utils qrencode cronie >> "$INSTALL_LOG" 2>&1
fi
_svc_enable cron 2>>"$INSTALL_LOG" || _svc_enable crond 2>>"$INSTALL_LOG" || true
_svc_start cron 2>>"$INSTALL_LOG" || _svc_start crond 2>>"$INSTALL_LOG" || true
}

system_update() {
clear_screen; print_divider
print_center "[ 更新系统与安装必备组件 ]" "$CYAN"
if ! confirm_action "更新系统与安装组件"; then pause_for_enter; return; fi
echo -e "\n${CYAN}>>> 正在检测包管理器并执行系统更新...${NC}"

if command -v dnf &>/dev/null; then
  dnf -y update
elif command -v yum &>/dev/null; then
  yum -y update
elif command -v apt &>/dev/null; then
  fix_dpkg
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
elif command -v apk &>/dev/null; then
  apk update && apk upgrade
elif command -v pacman &>/dev/null; then
  pacman -Syu --noconfirm
elif command -v zypper &>/dev/null; then
  zypper refresh
  zypper update -y
elif command -v opkg &>/dev/null; then
  opkg update
else
  echo -e "\n${RED}[错误] 未识别的包管理器！${NC}"; pause_for_enter; return
fi

echo -e "\n${GREEN}[成功] 系统更新完毕！${NC}"
pause_for_enter
}

system_clean() {
clear_screen; print_divider
print_center "[ 系统垃圾与废弃依赖清理 ]" "$CYAN"
if ! confirm_action "清理系统垃圾与冗余日志"; then pause_for_enter; return; fi
echo -e "\n${CYAN}>>> 正在检测包管理器并执行系统清理...${NC}"

if command -v dnf &>/dev/null; then
  rpm --rebuilddb
  dnf autoremove -y
  dnf clean all
  dnf makecache
  journalctl --rotate 2>/dev/null
  journalctl --vacuum-time=1s 2>/dev/null
  journalctl --vacuum-size=500M 2>/dev/null
elif command -v yum &>/dev/null; then
  rpm --rebuilddb
  yum autoremove -y
  yum clean all
  yum makecache
  journalctl --rotate 2>/dev/null
  journalctl --vacuum-time=1s 2>/dev/null
  journalctl --vacuum-size=500M 2>/dev/null
elif command -v apt &>/dev/null; then
  fix_dpkg
  apt autoremove --purge -y
  apt clean -y
  apt autoclean -y
  journalctl --rotate 2>/dev/null
  journalctl --vacuum-time=1s 2>/dev/null
  journalctl --vacuum-size=500M 2>/dev/null
elif command -v apk &>/dev/null; then
  apk cache clean
  rm -rf /var/cache/apk/*
  find /tmp -mindepth 1 -mtime +1 -delete 2>/dev/null
  find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null
elif command -v pacman &>/dev/null; then
  local pacman_orphans
  pacman_orphans=$(pacman -Qdtq 2>/dev/null || true)
  if [ -n "$pacman_orphans" ]; then
    # shellcheck disable=SC2086
    pacman -Rns $pacman_orphans --noconfirm 2>/dev/null || true
  fi
  pacman -Scc --noconfirm
  journalctl --rotate 2>/dev/null
  journalctl --vacuum-time=1s 2>/dev/null
  journalctl --vacuum-size=500M 2>/dev/null
elif command -v zypper &>/dev/null; then
  zypper clean --all
  zypper refresh
  journalctl --rotate 2>/dev/null
  journalctl --vacuum-time=1s 2>/dev/null
  journalctl --vacuum-size=500M 2>/dev/null
elif command -v opkg &>/dev/null; then
  find /tmp -mindepth 1 -mtime +1 -delete 2>/dev/null
  find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null
else
  echo -e "\n${RED}[错误] 未识别的包管理器！${NC}"; pause_for_enter; return
fi

echo -e "\n${GREEN}[成功] 系统清理完毕，存储空间已释放！${NC}"
pause_for_enter
}

change_root_password() {
clear_screen; print_divider
print_center "[ 修改 root 密码 ]" "$CYAN"
echo -e "  ${YELLOW}提示：输入密码时屏幕不会显示字符，属于正常安全机制。${NC}\n"
if ! confirm_action "修改 root 密码"; then return; fi
echo ""
while true; do
  if passwd root; then
    echo -e "\n${GREEN}[成功] 密码已成功修改！${NC}"; break
  else
    echo -e "\n${RED}[错误] 密码修改失败！${NC}"
    read -r -p "> 是否继续重试？(y/n, 默认 y): " retry_pwd
    [[ "${retry_pwd// /}" =~ ^[nN]$ ]] && { echo -e "${YELLOW}已退出。${NC}"; break; }
    echo -e "\n${CYAN}>>> 请重新设置密码：${NC}"
  fi
done
pause_for_enter
}

manage_ssh_security() {
while true; do
clear_screen; print_divider
print_center "[ SSH 密钥与登录安全管理 ]" "$CYAN"
echo -e "  ${GREEN}1.${NC} 添加/覆盖 SSH 公钥\n  ${GREEN}2.${NC} 删除所有 SSH 公钥\n  ${GREEN}3.${NC} 禁用密码登录 (强制使用密钥)\n  ${GREEN}4.${NC} 开启密码登录\n  ${GREEN}0.${NC} 返回主菜单"
echo ""
read -r -p "> 请选择操作 [0-4]: " ssh_opt
ssh_opt="${ssh_opt// /}"
case $ssh_opt in
1)
while true; do
read -r -p "> 请粘贴您的公钥 (通常以 ssh-rsa 开头, 输入 0 取消): " pub_key
if [ "$pub_key" == "0" ]; then break; fi
if [ -z "$pub_key" ]; then echo -e "${RED}[错误] 密钥内容不能为空，请重新输入！${NC}"; continue; fi
if ! echo "$pub_key" | grep -Eq '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+) '; then echo -e "${RED}[错误] SSH 公钥格式不正确，请粘贴完整公钥。${NC}"; continue; fi
if ! confirm_action "导入此 SSH 公钥"; then break; fi
mkdir -p ~/.ssh; chmod 700 ~/.ssh
if [ -s ~/.ssh/authorized_keys ]; then
echo -e "\n${YELLOW}[发现] 系统中已存在其他 SSH 密钥记录。${NC}"
read -r -p "> 是否清空旧密钥并覆盖？(y-覆盖清空 / n-保留追加, 默认 n): " overwrite_opt
overwrite_opt="${overwrite_opt// /}"
if [[ "$overwrite_opt" =~ ^[yY]$ ]]; then : > ~/.ssh/authorized_keys; echo -e "${CYAN}>>> 已清空历史废弃密钥。${NC}"; fi
fi
if ! echo "$pub_key" >> ~/.ssh/authorized_keys; then
  echo -e "\n${RED}[错误] 写入密钥失败，请检查系统权限或磁盘空间。${NC}"
else
  chmod 600 ~/.ssh/authorized_keys
  echo -e "\n${GREEN}[成功] 密钥已成功添加！请先测试使用密钥登录，再关闭密码登录功能。${NC}"
fi
pause_for_enter; break
done ;;
2)
if ! confirm_action "删除系统中所有的 SSH 公钥" "n"; then continue; fi
if : > ~/.ssh/authorized_keys; then echo -e "\n${GREEN}[成功] 所有 SSH 公钥已彻底清空！${NC}"; else echo -e "\n${RED}[错误] 清空密钥失败！${NC}"; fi
pause_for_enter ;;
3)
if ! confirm_action "禁用密码登录 (⚠️ 请确保您已成功配置密钥)" "n"; then continue; fi
_set_sshd_option PasswordAuthentication no || { pause_for_enter; continue; }
_restart_ssh_service_safely "已应用禁用密码登录设置" || { pause_for_enter; continue; }
echo -e "\n${GREEN}[成功] 密码登录已成功禁用！现在只能通过密钥连接服务器。${NC}"; pause_for_enter ;;
4)
if ! confirm_action "开启密码登录"; then continue; fi
_set_sshd_option PasswordAuthentication yes || { pause_for_enter; continue; }
_restart_ssh_service_safely "已应用开启密码登录设置" || { pause_for_enter; continue; }
echo -e "\n${GREEN}[成功] 密码登录已成功开启！${NC}"; pause_for_enter ;;
0) return ;;
*) echo -e "\n${RED}输入无效！${NC}"; sleep 1 ;;
esac
done
}

change_ssh_port() {
clear_screen; print_divider
print_center "[ 修改 SSH 端口 ]" "$CYAN"
local cur_port; cur_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$cur_port" ] && cur_port=22
echo -e "  当前 SSH 端口: ${YELLOW}${cur_port}${NC}"
echo -e "  ${CYAN}建议使用 10000-65535 范围的端口，避免与常用服务冲突。${NC}\n"
while true; do
  read -r -p "> 请输入新端口 (0 取消 / 22 恢复默认): " new_port
  new_port="${new_port// /}"
  [ "$new_port" = "0" ] || [ -z "$new_port" ] && return
  [[ "$new_port" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误] 请输入纯数字。${NC}"; continue; }
  [ "$new_port" -ne 22 ] && [ "$new_port" -le 1024 ] && { echo -e "${RED}[错误] 端口须为 22 或 1025-65534。${NC}"; continue; }
  [ "$new_port" -ge 65535 ] && { echo -e "${RED}[错误] 端口须小于 65535。${NC}"; continue; }
  break
done
if ! confirm_action "将 SSH 端口改为 ${new_port}"; then return; fi
_set_sshd_option Port "$new_port" || { pause_for_enter; return; }
if _restart_ssh_service_safely "SSH 端口已更新为 ${new_port}"; then
  echo -e "\n${GREEN}[成功] SSH 端口已改为 ${new_port}！${NC}"
  echo -e "  ${RED}[重要] 请立即在云服务商控制台放行端口 ${new_port}，否则下次无法连接！${NC}"
  echo -e "  ${YELLOW}[提示] 请使用新端口重新连接验证。${NC}"
else
  echo -e "\n${RED}[错误] SSH 服务重启失败，端口可能未生效，请手动检查。${NC}"
fi
pause_for_enter
}

change_hostname() {
clear_screen; print_divider
print_center "[ 修改主机名 ]" "$CYAN"
echo -e "  当前主机名: ${YELLOW}$(hostname)${NC}\n"
while true; do
  read -r -p "> 请输入新主机名 (字母/数字/连字符, 0 取消): " new_hostname
  new_hostname="${new_hostname// /}"
  [ "$new_hostname" = "0" ] && return
  [ -z "$new_hostname" ] && { echo -e "${RED}[错误] 主机名不能为空。${NC}"; continue; }
  [[ "$new_hostname" =~ ^[a-zA-Z0-9-]+$ ]] || { echo -e "${RED}[错误] 仅允许字母、数字和连字符(-)。${NC}"; continue; }
  break
done
if ! confirm_action "将主机名改为 ${new_hostname}"; then return; fi
hostnamectl set-hostname "$new_hostname" || { echo -e "\n${RED}[错误] 修改失败。${NC}"; pause_for_enter; return; }
if grep -q '^127\.0\.1\.1' /etc/hosts; then
sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $new_hostname/" /etc/hosts
else
echo "127.0.1.1 $new_hostname" >> /etc/hosts
fi
echo -e "\n${GREEN}[成功] 主机名已改为 ${new_hostname}！重新连接 SSH 后生效。${NC}"
pause_for_enter
}

set_china_timezone() {
clear_screen; print_divider
print_center "[ 修改系统时区 ]" "$CYAN"
local cur_tz; cur_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || date +%Z)
echo -e "  当前时区: ${YELLOW}${cur_tz}${NC}\n"
echo -e "  ${GREEN}1.${NC} 设为北京时间 (Asia/Shanghai)  ${CYAN}[推荐]${NC}"
echo -e "  ${GREEN}2.${NC} 自定义时区"
echo -e "  ${GREEN}0.${NC} 返回"
echo ""
read -r -p "> 请选择: " tz_opt
case "${tz_opt// /}" in
1)
  if ! confirm_action "设置时区为 Asia/Shanghai"; then return; fi
  timedatectl set-timezone Asia/Shanghai && echo -e "\n${GREEN}[成功] 时区已设为北京时间！当前时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}" \
    || echo -e "\n${RED}[错误] 设置失败，请检查 timedatectl。${NC}"
  ;;
2)
  echo -e "\n  ${CYAN}常用时区参考:${NC}"
  echo -e "    Asia/Shanghai     Asia/Tokyo      Asia/Singapore"
  echo -e "    Europe/London     US/Eastern      US/Pacific"
  echo ""
  read -r -p "> 请输入时区名称: " custom_tz
  [ -z "$custom_tz" ] && return
  if ! confirm_action "设置时区为 ${custom_tz}"; then return; fi
  timedatectl set-timezone "$custom_tz" && echo -e "\n${GREEN}[成功] 时区已设为 ${custom_tz}！${NC}" \
    || echo -e "\n${RED}[错误] 时区名称无效或设置失败。${NC}"
  ;;
esac
pause_for_enter
}

manage_swap() {
while true; do
clear_screen; print_divider
print_center "[ 虚拟内存 (Swap) 管理 ]" "$CYAN"

local swap_total swap_used swap_file
swap_total=$(free -m | awk 'NR==3{print $2}')
swap_used=$(free -m | awk 'NR==3{print $3}')
swap_file=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | head -1)

if [ "$swap_total" -gt 0 ]; then
  echo -e "  当前 Swap: ${GREEN}${swap_total} MB${NC}  已用: ${YELLOW}${swap_used} MB${NC}"
  [ -n "$swap_file" ] && echo -e "  Swap 设备: ${CYAN}${swap_file}${NC}"
else
  echo -e "  当前 Swap: ${RED}未启用${NC}"
fi
echo ""

echo -e "  ${GREEN}1.${NC} 创建/修改 Swap"
echo -e "  ${GREEN}2.${NC} 关闭并删除 Swap"
echo -e "  ${GREEN}0.${NC} 返回"
echo ""
read -r -p "> 请选择 [0-2]: " swap_opt
swap_opt="${swap_opt// /}"
case $swap_opt in
1)
  echo ""
  echo -e "  ${CYAN}推荐大小参考:${NC}"
  echo -e "    内存 ≤ 1G  → 推荐 1024MB"
  echo -e "    内存 1~4G → 推荐 2048MB"
  echo -e "    内存 > 4G → 推荐 4096MB"
  echo ""
  while true; do
    read -r -p "> 请输入 Swap 大小 (MB，如 1024 / 2048): " input_size
    input_size="${input_size// /}"
    [[ "$input_size" =~ ^[0-9]+$ ]] && break
    echo -e "${RED}[错误] 请输入纯数字。${NC}"
  done
  if ! confirm_action "设置 ${input_size}MB Swap"; then continue; fi
  echo -e "\n${CYAN}>>> 正在释放旧 Swap...${NC}"
  # 仅管理 VPSBox 创建的 /swapfile，避免误改系统已有 swap 分区
  swapoff /swapfile 2>/dev/null
  rm -f /swapfile
  echo -e "${CYAN}>>> 正在创建 ${input_size}MB Swap...${NC}"
  if ! fallocate -l "${input_size}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$input_size" status=progress 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count="$input_size" 2>/dev/null || \
    { echo -e "${RED}[错误] 磁盘空间不足！${NC}"; rm -f /swapfile; pause_for_enter; continue; }
  fi
  chmod 600 /swapfile
  mkswap /swapfile || { echo -e "${RED}[错误] mkswap 失败！${NC}"; rm -f /swapfile; pause_for_enter; continue; }
  swapon /swapfile || { echo -e "${RED}[错误] 挂载 Swap 失败！${NC}"; pause_for_enter; continue; }
  sed -i '/\/swapfile/d' /etc/fstab
  echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
  if [ -f /etc/alpine-release ]; then
    echo "nohup swapon /swapfile" > /etc/local.d/swap.start
    chmod +x /etc/local.d/swap.start
    rc-update add local 2>/dev/null
  fi
  echo -e "\n${GREEN}[成功] Swap 已设置为 ${input_size}MB！${NC}"
  echo -e "  当前: $(free -m | awk 'NR==3{print $2}') MB"
  pause_for_enter ;;
2)
  if ! confirm_action "关闭并删除现有 Swap" "n"; then continue; fi
  swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab
  echo -e "\n${GREEN}[成功] Swap 已清除！${NC}"; pause_for_enter ;;
0) return ;;
*) echo -e "\n${RED}[错误] 无效输入。${NC}"; sleep 1 ;;
esac
done
}

optimize_dns() {
while true; do
clear_screen; print_divider
print_center "[ 系统 DNS 优化 ]" "$CYAN"

echo -e "  ${CYAN}当前 DNS 配置:${NC}"
echo "  ─────────────────────────────"
if _svc_is_active systemd-resolved >/dev/null 2>&1; then
  local _dns_servers; _dns_servers=$(resolvectl dns 2>/dev/null | grep -v "^Link\|^$" | awk '{for(i=2;i<=NF;i++) print "nameserver "$i}' | sort -u)
  if [ -n "$_dns_servers" ]; then
    echo "$_dns_servers" | while read -r line; do echo -e "  ${YELLOW}${line}${NC}"; done
  else
    resolvectl status 2>/dev/null | grep "DNS Servers:" | head -1 | sed 's/.*DNS Servers: /  nameserver /' | while read -r line; do echo -e "  ${YELLOW}${line}${NC}"; done
  fi
else
  grep '^nameserver' /etc/resolv.conf 2>/dev/null | while read -r line; do
    echo -e "  ${YELLOW}${line}${NC}"
  done
fi
echo "  ─────────────────────────────"
echo ""
echo -e "  ${GREEN}1.${NC} 国际优化  CF 1.1.1.1 + Google 8.8.8.8"
echo -e "             IPv6: 2606:4700:4700::1111 + 2001:4860:4860::8888"
echo -e "  ${GREEN}2.${NC} 国内优化  阿里 223.5.5.5 + 腾讯 183.60.83.19"
echo -e "             IPv6: 2400:3200::1 + 2400:da00::6666"
echo -e "  ${GREEN}3.${NC} 自动检测  根据服务器所在地区自动选择最优 DNS"
echo -e "  ${GREEN}4.${NC} 手动设置  自定义 DNS 地址"
echo -e "  ${GREEN}5.${NC} 解锁文件  取消 resolv.conf 写保护"
echo -e "  ${GREEN}0.${NC} 返回"
echo ""
read -r -p "> 请选择 [0-5]: " dns_opt
dns_opt="${dns_opt// /}"

_apply_dns() {
  local d1v4="$1" d2v4="$2" d1v6="$3" d2v6="$4"
  local has_v4 has_v6 resolv_tmp
  has_v4=$(ip -4 addr show scope global 2>/dev/null | grep -c 'inet ')
  has_v6=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ')
  if _svc_is_active systemd-resolved >/dev/null 2>&1; then
    # 1) 全局 DNS 持久化配置
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/vpsbox-dns.conf << EOF
[Resolve]
DNS=$d1v4 $d2v4
EOF
    if [ "$has_v6" -gt 0 ] && [ -n "$d1v6" ]; then
      sed -i "/^DNS=/s/$/ $d1v6 $d2v6/" /etc/systemd/resolved.conf.d/vpsbox-dns.conf
    fi
    # 2) 覆盖所有活跃链路的 DHCP DNS
    for _link in $(ip -o link show up | awk -F': ' '{print $2}' | grep -v lo); do
      if [ "$has_v6" -gt 0 ] && [ -n "$d1v6" ]; then
        resolvectl dns "$_link" "$d1v4" "$d2v4" "$d1v6" "$d2v6" 2>/dev/null
      else
        resolvectl dns "$_link" "$d1v4" "$d2v4" 2>/dev/null
      fi
    done
    systemctl restart systemd-resolved 2>/dev/null
    echo -e "${GREEN}[成功] DNS 已写入 systemd-resolved 并重启！${NC}"
    echo -e "${YELLOW}[提示] 已全局锁定，DHCP 续租不会覆盖。${NC}"
  else
    resolv_tmp=$(mktemp) || { echo -e "${RED}[错误] 无法创建临时 DNS 文件。${NC}"; return 1; }
    [ "$has_v4" -gt 0 ] && { echo "nameserver $d1v4" >> "$resolv_tmp"; echo "nameserver $d2v4" >> "$resolv_tmp"; }
    [ "$has_v6" -gt 0 ] && [ -n "$d1v6" ] && { echo "nameserver $d1v6" >> "$resolv_tmp"; echo "nameserver $d2v6" >> "$resolv_tmp"; }
    [ -s "$resolv_tmp" ] || { echo "nameserver $d1v4" >> "$resolv_tmp"; echo "nameserver $d2v4" >> "$resolv_tmp"; }
    chattr -i /etc/resolv.conf 2>/dev/null
    cat "$resolv_tmp" > /etc/resolv.conf
    rm -f "$resolv_tmp"
    chattr +i /etc/resolv.conf 2>/dev/null
    echo -e "${GREEN}[成功] DNS 已写入并锁定！${NC}"
  fi
  echo ""
  echo -e "  ${CYAN}生效后的 DNS:${NC}"
  if _svc_is_active systemd-resolved >/dev/null 2>&1; then
    resolvectl dns 2>/dev/null | grep -v "^Link\|^$" | awk '{for(i=2;i<=NF;i++) print "nameserver "$i}' | sort -u | while read -r line; do echo -e "  ${GREEN}${line}${NC}"; done
  else
    grep '^nameserver' /etc/resolv.conf | while read -r line; do echo -e "  ${GREEN}${line}${NC}"; done
  fi
}

case $dns_opt in
1)
  _apply_dns "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888"
  pause_for_enter ;;
2)
  _apply_dns "223.5.5.5" "183.60.83.19" "2400:3200::1" "2400:da00::6666"
  pause_for_enter ;;
3)
  echo -e "\n${CYAN}>>> 正在检测服务器所在地区...${NC}"
  local _country; _country=$(curl -s --max-time 5 ipinfo.io/country 2>/dev/null)
  echo -e "  地区代码: ${YELLOW}${_country:-未知}${NC}"
  if [ "$_country" = "CN" ]; then
    echo -e "  → 选用国内 DNS（阿里/腾讯）"
    _apply_dns "223.5.5.5" "183.60.83.19" "2400:3200::1" "2400:da00::6666"
  else
    echo -e "  → 选用国际 DNS（CF/Google）"
    _apply_dns "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888"
  fi
  pause_for_enter ;;
4)
  echo ""
  read -r -p "> 请输入主 DNS (IPv4): " _d1
  read -r -p "> 请输入备 DNS (IPv4，可留空): " _d2
  [ -z "$_d1" ] && continue
  [ -z "$_d2" ] && _d2="$_d1"
  _apply_dns "$_d1" "$_d2" "" ""
  pause_for_enter ;;
5)
  chattr -i /etc/resolv.conf 2>/dev/null && echo -e "${GREEN}[成功] 已解除写保护，可自由编辑 /etc/resolv.conf${NC}" || echo -e "${YELLOW}[提示] 文件未被锁定。${NC}"
  pause_for_enter ;;
0) return ;;
*) echo -e "\n${RED}[错误] 无效输入。${NC}"; sleep 1 ;;
esac
done
}

get_bbr_status() {
local cc qdisc kern
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
kern=$(uname -r)
if [[ "$cc" == "bbr" ]]; then
  if echo "$kern" | grep -qi "xanmod"; then
    echo -e "${YELLOW}BBRv3/XanMod${NC} + ${CYAN}${qdisc}${NC}"
  elif echo "$kern" | grep -qi "bbrplus"; then
    echo -e "${YELLOW}BBRplus${NC} + ${CYAN}${qdisc}${NC}"
  else
    echo -e "${GREEN}BBRv1 (原生)${NC} + ${CYAN}${qdisc}${NC}"
  fi
elif [[ "$cc" == "bbrplus" ]]; then
  echo -e "${YELLOW}BBRplus${NC} + ${CYAN}${qdisc}${NC}"
else
  echo -e "${RED}未开启 (当前: $cc / $qdisc)${NC}"
fi
}

_bbr_check_sys() {
  BBR_ARCH=$(uname -m)
  BBR_OS_ID=""; BBR_OS_TYPE=""; BBR_OS_VER=""; BBR_OS_LIKE=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    BBR_OS_ID="${ID:-unknown}"
    BBR_OS_VER="${VERSION_ID:-}"
    BBR_OS_LIKE="${ID_LIKE:-}"
    if [[ -z "$BBR_OS_VER" && "$BBR_OS_ID" == "debian" && -f /etc/debian_version ]]; then
      BBR_OS_VER=$(grep -oE '^[0-9]+' /etc/debian_version | head -1)
      [[ -z "$BBR_OS_VER" ]] && BBR_OS_VER=$(awk -F'/' '{print $1}' /etc/debian_version)
    fi
    [[ -z "$BBR_OS_VER" ]] && BBR_OS_VER="unknown"
  fi
  if [[ "$BBR_OS_ID" =~ ^(centos|rhel|almalinux|rocky|oracle|fedora)$ ]] || [[ "$BBR_OS_LIKE" =~ (rhel|centos|fedora) ]]; then
    BBR_OS_TYPE="CentOS"
    BBR_OS_VER=$(echo "$BBR_OS_VER" | awk -F'.' '{print $1}')
  elif [[ "$BBR_OS_ID" =~ ^(debian|ubuntu|pop|kali|linuxmint|deepin|elementary|armbian)$ ]] || [[ "$BBR_OS_LIKE" =~ (debian|ubuntu) ]]; then
    BBR_OS_TYPE="Debian"
  else
    BBR_OS_TYPE="Unknown"
  fi
}

_bbr_check_cn() {
  BBR_IS_CN=0
  local cf_trace; cf_trace=$(curl -sL --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  echo "$cf_trace" | grep -q "loc=CN" && BBR_IS_CN=1
}

_bbr_safe_wget() {
  local url="$1" dest="$2"
  local mirrors=("" "https://gh-proxy.com/" "https://ghfast.top/" "https://hub.gitmirror.com/")
  [[ "${BBR_IS_CN:-0}" -eq 0 ]] && mirrors=("")
  for prefix in "${mirrors[@]}"; do
    local target="$url"
    [[ -n "$prefix" ]] && target="${prefix}${url#https://}"
    echo -e "  ${CYAN}>>> 下载: $(basename "$dest")...${NC}"
    if wget --no-check-certificate -qT 15 -t 2 -O "$dest" "$target" 2>/dev/null; then
      echo -e "  ${GREEN}下载成功${NC}"; return 0
    fi
    [[ "${BBR_IS_CN:-0}" -eq 1 ]] && echo -e "  ${YELLOW}镜像失败，切换下一个...${NC}"
  done
  echo -e "  ${RED}[错误] 所有下载节点均失败！${NC}"; return 1
}

_bbr_github_asset() {
  local repo="$1" tag_kw="$2" ast_kw="$3" arch_kw="${4:-}"
  local api_url="https://api.github.com/repos/${repo}/releases"
  local resp; resp=$(curl -sL --max-time 12 "$api_url" 2>/dev/null)
  if echo "$resp" | grep -q "API rate limit"; then
    echo -e "  ${RED}[错误] GitHub API 频率限制！${NC}" >&2; return 1
  fi
  local all_urls; all_urls=$(echo "$resp" | grep -oE '"browser_download_url": "[^"]+"' | awk -F'"' '{print $4}')
  if [[ -z "$all_urls" ]]; then
    echo -e "  ${RED}[错误] 无法获取 ${repo} 资产列表！${NC}" >&2; return 1
  fi
  local result; result=$(echo "$all_urls" | grep -iE "$tag_kw" | grep -iE "$ast_kw")
  [[ -n "$arch_kw" ]] && result=$(echo "$result" | grep -iE "$arch_kw")
  if [[ "$arch_kw" != *"arm64"* && "$BBR_ARCH" != "aarch64" ]]; then
    result=$(echo "$result" | grep -viE "arm64|aarch64")
  fi
  local asset_url; asset_url=$(echo "$result" | head -1)
  if [[ -z "$asset_url" ]]; then
    echo -e "  ${RED}[错误] 未找到匹配文件 (${tag_kw}/${ast_kw})${NC}" >&2; return 1
  fi
  echo "$asset_url"
}

_bbr_remove_old_headers() {
  echo -e "  ${CYAN}>>> 清理旧 Headers...${NC}"
  local current_kernel current_version
  current_kernel=$(uname -r)
  current_version=${current_kernel%%-*}
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    rpm -qa | grep -E '^kernel-headers' | grep -vF "$current_kernel" | grep -vF "$current_version" | xargs -r rpm -e --nodeps >/dev/null 2>&1
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    dpkg-query -W -f='${Package}\n' 'linux-headers-*' 2>/dev/null | grep -vF "$current_kernel" | grep -vF "$current_version" | xargs -r apt-get purge -y >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
  fi
}

_bbr_grub() {
  echo -e "  ${CYAN}>>> 更新系统引导...${NC}"
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    if command -v grubby &>/dev/null; then
      local lk; lk=$(grubby --info=ALL | awk -F= '/^kernel/{print $2}' | head -1)
      [[ -n "$lk" ]] && grubby --set-default="$lk" >/dev/null 2>&1
    else
      [[ -f /boot/grub2/grub.cfg ]] && grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
      grub2-set-default 0
    fi
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    command -v update-grub &>/dev/null || apt-get install -y grub2-common >/dev/null 2>&1
    update-grub >/dev/null 2>&1
  fi
}

_bbr_install_kernel() {
  local desc="$1" head_url="$2" img_url="$3"
  echo -e "\n  ${CYAN}========================================${NC}"
  echo -e "  ${CYAN}>>> 开始安装: ${YELLOW}${desc}${NC}"
  echo -e "  ${CYAN}========================================${NC}"
  [[ -z "$img_url" ]] && { echo -e "  ${RED}[错误] 镜像下载链接为空！${NC}"; return 1; }
  _bbr_remove_old_headers
  local wdir="/tmp/bbr_install_$$"
  mkdir -p "$wdir" && cd "$wdir" || return 1
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    [[ -n "$head_url" ]] && { _bbr_safe_wget "$head_url" "kernel-headers.rpm" || { cd /tmp || return 1; rm -rf "$wdir"; return 1; }; }
    _bbr_safe_wget "$img_url" "kernel-image.rpm" || { cd /tmp || return 1; rm -rf "$wdir"; return 1; }
    echo -e "  ${CYAN}>>> 执行 YUM 安装...${NC}"
    if [[ -n "$head_url" ]]; then
      yum install -y kernel-image.rpm kernel-headers.rpm || { cd /tmp || return 1; rm -rf "$wdir"; echo -e "  ${RED}[错误] 内核安装失败。${NC}"; return 1; }
    else
      yum install -y kernel-image.rpm || { cd /tmp || return 1; rm -rf "$wdir"; echo -e "  ${RED}[错误] 内核安装失败。${NC}"; return 1; }
    fi
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    [[ -n "$head_url" ]] && { _bbr_safe_wget "$head_url" "linux-headers.deb" || { cd /tmp || return 1; rm -rf "$wdir"; return 1; }; }
    _bbr_safe_wget "$img_url" "linux-image.deb" || { cd /tmp || return 1; rm -rf "$wdir"; return 1; }
    echo -e "  ${CYAN}>>> 执行 DPKG 安装...${NC}"
    dpkg -i linux-image.deb || { cd /tmp || return 1; rm -rf "$wdir"; echo -e "  ${RED}[错误] 内核镜像安装失败。${NC}"; return 1; }
    [[ -n "$head_url" ]] && dpkg -i linux-headers.deb || [[ -z "$head_url" ]] || { cd /tmp || return 1; rm -rf "$wdir"; echo -e "  ${RED}[错误] 内核头文件安装失败。${NC}"; return 1; }
    echo -e "  ${CYAN}>>> 修复依赖...${NC}"
    apt-get install -f -y || { cd /tmp || return 1; rm -rf "$wdir"; echo -e "  ${RED}[错误] 内核依赖修复失败。${NC}"; return 1; }
  fi
  cd /tmp && rm -rf "$wdir"
  _bbr_grub
  echo -e "\n  ${GREEN}[完成] ${desc} 内核包安装完毕！${NC}"
}

_bbr_apply_sysctl_file() {
  local target_conf="$1"
  if sysctl -p "$target_conf" >/dev/null 2>&1; then
    return 0
  fi
  sysctl --system >/dev/null 2>&1
}

_bbr_psabi_level() {
  awk 'BEGIN {
    while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
    if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
    if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
    if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
    if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
    if (level > 0) { print level; exit }
    exit 1
  }' /proc/cpuinfo 2>/dev/null | tr -dc '0-9' | head -c 1
}

_bbr_ceil_div() {
  local num="$1" den="$2"
  echo $(((num + den - 1) / den))
}

_bbr_int_sqrt() {
  local n="$1"
  python3 - <<PY
import math
n=max(0,int(${n}))
print(int(math.isqrt(n)))
PY
}

_bbr_clamp() {
  local val="$1" minv="$2" maxv="$3"
  (( val < minv )) && val=$minv
  (( val > maxv )) && val=$maxv
  echo "$val"
}

_bbr_detect_memory_mb() {
  awk '/MemTotal/ {printf "%d\n", int($2/1024)}' /proc/meminfo 2>/dev/null | head -1
}

_bbr_dynamic_defaults() {
  BBR_TUNE_LOCAL_BW="1000"
  BBR_TUNE_VPS_BW="1000"
  BBR_TUNE_LATENCY="80"
  BBR_TUNE_MEMORY_MB=$(_bbr_detect_memory_mb)
  [[ -z "$BBR_TUNE_MEMORY_MB" ]] && BBR_TUNE_MEMORY_MB=1024
  BBR_TUNE_MEMORY_MB=$(_bbr_clamp "$BBR_TUNE_MEMORY_MB" 64 32768)
  BBR_TUNE_RAMP="0.80"
  BBR_TUNE_CC="bbr"
  BBR_TUNE_ECN="0"
}

_tcp_profile_collect_inputs() {
  local prefix="$1"
  local default_cc="${2:-bbr}"
  local default_ecn="${3:-0}"
  local detected_mem ans qdisc_mode
  local cc_default_label cc_default_idx current_val

  case "$default_cc" in
    bbrplus)
      cc_default_idx="2"
      cc_default_label="BBRplus"
      ;;
    cubic)
      cc_default_idx="3"
      cc_default_label="CUBIC"
      ;;
    *)
      cc_default_idx="1"
      cc_default_label="BBR"
      ;;
  esac

  detected_mem=$(_bbr_detect_memory_mb)
  [[ -z "$detected_mem" ]] && detected_mem=1024
  detected_mem=$(_bbr_clamp "$detected_mem" 64 32768)

  eval "${prefix}_LOCAL_BW=1000"
  eval "${prefix}_VPS_BW=1000"
  eval "${prefix}_LATENCY=80"
  eval "${prefix}_MEMORY_MB=$detected_mem"
  eval "${prefix}_RAMP=0.80"
  eval "${prefix}_CC=$default_cc"
  eval "${prefix}_ECN=$default_ecn"
  eval "${prefix}_QDISC=auto"

  echo -e "\n${CYAN}>>> 请输入网络环境参数，直接回车使用推荐默认值。${NC}"

  current_val=$(eval "printf '%s' \"\${${prefix}_LOCAL_BW}\"")
  read -r -p "> 本地带宽 Mbps [${current_val}]: " ans
  [[ "$ans" =~ ^[0-9]+$ ]] && eval "${prefix}_LOCAL_BW=$ans"

  current_val=$(eval "printf '%s' \"\${${prefix}_VPS_BW}\"")
  read -r -p "> 服务器带宽 Mbps [${current_val}]: " ans
  [[ "$ans" =~ ^[0-9]+$ ]] && eval "${prefix}_VPS_BW=$ans"

  current_val=$(eval "printf '%s' \"\${${prefix}_LATENCY}\"")
  read -r -p "> 网络延迟 RTT ms [${current_val}]: " ans
  [[ "$ans" =~ ^[0-9]+$ ]] && eval "${prefix}_LATENCY=$ans"

  current_val=$(eval "printf '%s' \"\${${prefix}_MEMORY_MB}\"")
  read -r -p "> 可用内存 MB [${current_val}]: " ans
  [[ "$ans" =~ ^[0-9]+$ ]] && eval "${prefix}_MEMORY_MB=$ans"

  echo -e "\n${YELLOW}--- 小白科普：TCP 爬升曲线 (Ramp-up) 该怎么选？ ---${NC}"
  echo -e "  ${GREEN}0.1 - 0.3 (保守平稳型)${NC} : 适合建站、写博客。"
  echo -e "  ${CYAN}0.4 - 0.6 (均衡通用型)${NC} : 适合代理、日常通用。"
  echo -e "  ${RED}0.7 - 1.0 (激进吞吐型)${NC} : 适合视频与大文件。"
  echo -e "${YELLOW}--------------------------------------------------${NC}"
  current_val=$(eval "printf '%s' \"\${${prefix}_RAMP}\"")
  read -r -p "> 请输入爬升曲线调节 (0.1 - 1.0) [${current_val}]: " ans
  if [[ "$ans" =~ ^(0\.[0-9]+|1(\.0+)?)$ ]]; then
    eval "${prefix}_RAMP=$ans"
  fi

  echo ""
  echo -e "  1) BBR"
  echo -e "  2) BBRplus"
  echo -e "  3) CUBIC"
  read -r -p "> 拥塞算法 [${cc_default_idx} - ${cc_default_label}]: " ans
  case "$ans" in
    2) eval "${prefix}_CC=bbrplus" ;;
    3) eval "${prefix}_CC=cubic" ;;
    *) eval "${prefix}_CC=bbr" ;;
  esac

  echo ""
  echo -e "  1) 自动按链路选择"
  echo -e "  2) 开启 ECN"
  echo -e "  3) 关闭 ECN"
  read -r -p "> ECN 选项 [1]: " ans
  case "$ans" in
    2) eval "${prefix}_ECN=1" ;;
    3) eval "${prefix}_ECN=0" ;;
  esac

  local latency_now
  latency_now=$(eval "printf '%s' \"\${${prefix}_LATENCY}\"")
  if [ "$latency_now" -le 120 ]; then
    qdisc_mode="cake"
    echo -e "${CYAN}[提示] 当前 RTT ≤ 120ms，非激进模式默认偏向 ${GREEN}CAKE${NC}。${NC}"
  else
    qdisc_mode="fq"
    echo -e "${CYAN}[提示] 当前 RTT > 120ms，非激进模式默认偏向 ${GREEN}FQ${NC}。${NC}"
  fi
  echo -e "  1) 保持网站默认"
  echo -e "  2) 强制 FQ"
  echo -e "  3) 强制 CAKE"
  read -r -p "> 队列算法 [1]: " ans
  case "$ans" in
    2) qdisc_mode="fq" ;;
    3) qdisc_mode="cake" ;;
  esac
  eval "${prefix}_QDISC=$qdisc_mode"

  current_val=$(eval "printf '%s' \"\${${prefix}_LOCAL_BW}\"")
  current_val=$(_bbr_clamp "$current_val" 1 100000)
  eval "${prefix}_LOCAL_BW=$current_val"
  current_val=$(eval "printf '%s' \"\${${prefix}_VPS_BW}\"")
  current_val=$(_bbr_clamp "$current_val" 1 100000)
  eval "${prefix}_VPS_BW=$current_val"
  current_val=$(eval "printf '%s' \"\${${prefix}_LATENCY}\"")
  current_val=$(_bbr_clamp "$current_val" 1 2000)
  eval "${prefix}_LATENCY=$current_val"
  current_val=$(eval "printf '%s' \"\${${prefix}_MEMORY_MB}\"")
  current_val=$(_bbr_clamp "$current_val" 64 32768)
  eval "${prefix}_MEMORY_MB=$current_val"
}

manage_bbr() {

_bbr_collect_dynamic_inputs() {
  _tcp_profile_collect_inputs "BBR_TUNE" "bbr" "0"
}

_bbr_generate_dynamic_profile() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  mkdir -p /etc/systemd/system.conf.d /etc/security/limits.d /etc/sysctl.d

  local local_bw="$BBR_TUNE_LOCAL_BW" vps_bw="$BBR_TUNE_VPS_BW" latency="$BBR_TUNE_LATENCY" mem_mb="$BBR_TUNE_MEMORY_MB" cc="$BBR_TUNE_CC" ecn="$BBR_TUNE_ECN" ramp="$BBR_TUNE_RAMP"
  local json
  json=$(python3 - <<'PY'
import json, math, os

def clamp(x, lo, hi):
    return min(max(x, lo), hi)

def ceildiv(a, b):
    return (a + b - 1) // b

def sigmoid(x, steepness=4.0, midpoint=0.3):
    return 1.0 / (1.0 + math.exp(-steepness * (x - midpoint)))

def piecewise(x, points):
    if x <= points[0][0]:
        return points[0][1]
    for i in range(1, len(points)):
        x0, y0 = points[i-1]
        x1, y1 = points[i]
        if x <= x1:
            if x1 == x0:
                return y1
            return y0 + (y1-y0) * ((x-x0)/(x1-x0))
    return points[-1][1]

def qtheory(e, service, utilization):
    return service / (1 - min(utilization, 0.95)) * e

def tcpcong(x, mode, scale):
    if mode == 'slow_start':
        return min(scale * (1 + 0.5 * x), scale + 10 * x)
    return scale + 0.1 * x

def memory_cap(target, mem_mb, frac):
    return min(target, int(1024 * mem_mb * 1024 * frac))

def clamp_tcp_window_scale(value):
    return int(clamp(value, -31, 31))

def clamp_kernel_buffer(value):
    return int(clamp(math.floor(value), 4096, 1073741824))

def clamp_tcp_triplet(min_value, default_value, max_value):
    min_value = clamp_kernel_buffer(min_value)
    default_value = clamp_kernel_buffer(default_value)
    max_value = clamp_kernel_buffer(max_value)
    if default_value < min_value:
        default_value = min_value
    if max_value < default_value:
        max_value = default_value
    return f'{min_value} {default_value} {max_value}'

def small_mem_buffer_cap(mem_mb):
    if mem_mb <= 64:
        return 8 * 1024 * 1024
    if mem_mb <= 128:
        return 16 * 1024 * 1024
    if mem_mb <= 256:
        return 32 * 1024 * 1024
    if mem_mb <= 512:
        return 64 * 1024 * 1024
    return 128 * 1024 * 1024

def medium_mem_buffer_cap(latency_ms, mem_mb):
    if mem_mb <= 1024:
        return 128 * 1024 * 1024 if latency_ms > 900 else 96 * 1024 * 1024 if latency_ms > 650 else 64 * 1024 * 1024
    if mem_mb <= 2048:
        return 256 * 1024 * 1024 if latency_ms > 1100 else 192 * 1024 * 1024 if latency_ms > 800 else 128 * 1024 * 1024
    if mem_mb <= 4096:
        return 384 * 1024 * 1024 if latency_ms > 1300 else 320 * 1024 * 1024 if latency_ms > 900 else 224 * 1024 * 1024
    if mem_mb <= 8192:
        return 640 * 1024 * 1024 if latency_ms > 1300 else 512 * 1024 * 1024 if latency_ms > 900 else 384 * 1024 * 1024
    if mem_mb <= 32768:
        return 768 * 1024 * 1024 if latency_ms > 1300 else 640 * 1024 * 1024 if latency_ms > 900 else 512 * 1024 * 1024
    return 896 * 1024 * 1024 if latency_ms > 1300 else 768 * 1024 * 1024

def tuned_min_free_kbytes(mem_mb, target_kbytes, high_latency=False):
    floor = 16384 if mem_mb <= 64 else 24576 if mem_mb <= 128 else 32768 if mem_mb <= 256 else 49152 if mem_mb <= 512 else 65536
    ceiling = int(mem_mb * (384 if mem_mb <= 128 else 320 if mem_mb <= 256 else 256 if mem_mb <= 512 else 192 if mem_mb <= 1024 else 160))
    if high_latency:
        ceiling = int(ceiling * 1.15)
    ceiling = max(floor, min(1048576, ceiling))
    return int(clamp(target_kbytes, floor, ceiling))

local_bw = int(os.environ['LOCAL_BW'])
vps_bw = int(os.environ['VPS_BW'])
latency = int(os.environ['LATENCY'])
mem = int(os.environ['MEM_MB'])
ramp = float(os.environ['RAMP'])
cc = os.environ['CC']
ecn = int(os.environ['ECN'])

base = {
    'kernel.pid_max': 65535,
    'kernel.panic': 1,
    'kernel.sysrq': 1,
    'kernel.core_pattern': 'core_%e',
    'kernel.printk': '3 4 1 3',
    'kernel.numa_balancing': 0,
    'kernel.sched_autogroup_enabled': 0,
    'vm.panic_on_oom': 1,
    'vm.overcommit_memory': 1,
    'vm.vfs_cache_pressure': 100,
    'vm.dirty_expire_centisecs': 3000,
    'vm.dirty_writeback_centisecs': 500,
    'net.ipv4.tcp_fastopen': 3,
    'net.ipv4.tcp_timestamps': 1,
    'net.ipv4.tcp_tw_reuse': 1,
    'net.ipv4.tcp_fin_timeout': 10,
    'net.ipv4.tcp_slow_start_after_idle': 0,
    'net.ipv4.tcp_max_tw_buckets': 32768,
    'net.ipv4.tcp_sack': 1,
    'net.ipv4.tcp_mtu_probing': 1,
    'net.ipv4.tcp_congestion_control': cc,
    'net.ipv4.tcp_window_scaling': 1,
    'net.ipv4.tcp_moderate_rcvbuf': 1,
    'net.ipv4.tcp_abort_on_overflow': 0,
    'net.ipv4.tcp_stdurg': 0,
    'net.ipv4.tcp_rfc1337': 0,
    'net.ipv4.tcp_syncookies': 1,
    'net.ipv4.tcp_ecn': ecn,
    'net.ipv4.ip_forward': 0,
    'net.ipv4.ip_local_port_range': '1024 65535',
    'net.ipv4.ip_no_pmtu_disc': 0,
    'net.ipv4.route.gc_timeout': 100,
    'net.ipv4.neigh.default.gc_stale_time': 120,
    'net.ipv4.conf.all.accept_redirects': 0,
    'net.ipv4.conf.default.accept_redirects': 0,
    'net.ipv4.conf.all.secure_redirects': 0,
    'net.ipv4.conf.default.secure_redirects': 0,
    'net.ipv4.conf.all.accept_source_route': 0,
    'net.ipv4.conf.default.accept_source_route': 0,
    'net.ipv4.conf.all.forwarding': 0,
    'net.ipv4.conf.default.forwarding': 0,
    'net.ipv4.conf.all.rp_filter': 1,
    'net.ipv4.conf.default.rp_filter': 1,
    'net.ipv4.conf.all.arp_announce': 2,
    'net.ipv4.conf.default.arp_announce': 2,
    'net.ipv4.conf.all.arp_ignore': 1,
    'net.ipv4.conf.default.arp_ignore': 1,
}

if latency <= 120:
    mode = '低延迟画像'
    qdisc = 'cake'
    responsiveness = 2.0
    jitter_tolerance = 0.3
    burst_handling = 0.7
    memory_efficiency = 1.0
    buffer_aggression = 0.8
    queue_pref = 0.8
    conn_density = 1.2
    win_base = 1.2
    latency_sensitivity = 1.5
    win_max = 4
    if mem <= 256:
        responsiveness = 2.5
        jitter_tolerance = 0.2
        burst_handling = 0.5
        memory_efficiency = 0.8
        buffer_aggression = 0.6
        queue_pref = 0.6
        conn_density = 1.0
        win_base = 1.0
        win_max = 3
    elif mem <= 512:
        responsiveness = 2.2
        jitter_tolerance = 0.25
        burst_handling = 0.6
        memory_efficiency = 0.9
        buffer_aggression = 0.7
    elif mem > 1024:
        responsiveness = 1.8
        jitter_tolerance = 0.4
        burst_handling = 0.9
        memory_efficiency = 1.2
        buffer_aggression = 1.0
        queue_pref = 1.0
        conn_density = 1.5
        win_base = 1.4
        win_max = 6

    F = clamp(1.5 * math.sqrt(local_bw / vps_bw), 1, 2)
    T = math.floor(1024 * min(local_bw * F, vps_bw) * 1024 / 8)
    ratio = local_bw / vps_bw
    B = 1.0
    if ratio > 1:
        B = max(0.3, 1 / math.sqrt(min(ratio, 100)))
        if latency > 200:
            B = min(1.0, 1.2 * B)
    N = math.ceil(T * latency / 1000)
    P = max(N, 24576)
    A = 0.1 if mem <= 256 else 0.125
    I = 4194304 if mem <= 256 else 8388608
    U = max(memory_cap(math.ceil(1.5 * ramp * B * N), mem, A), I)

    curve1 = clamp(sigmoid(ramp, 4, 0.3) * (responsiveness / 2), 0.3, 2)
    latency_factor = clamp((2 ** (latency / 120 - 1)) * curve1 * responsiveness, 0.8, 5)
    buffer_factor = clamp(latency_factor * tcpcong(curve1, 'slow_start', 1) * memory_efficiency * buffer_aggression * burst_handling, 0.5, 3)
    queue_factor = clamp((math.log(qtheory(T / 65536 * conn_density, latency / 1000 * 2, 0.8 * curve1) + 1) / math.log(1000)) * queue_pref * (1 + jitter_tolerance), 0.3, 2)
    adv_factor = max(0, math.ceil(math.log2(max(1, 2 * math.ceil(T * latency / 1000) / 65535))))
    adv_win_scale = clamp_tcp_window_scale(max(2, math.ceil(clamp(latency_factor / latency_sensitivity * adv_factor * win_base * curve1, 1, win_max))))

    Vmul = 2.5 if mem <= 256 else 3 if mem <= 512 else 4
    Hmul = 1.2 if mem <= 256 else 1.5 if mem <= 1024 else 2
    U = clamp_kernel_buffer(U)
    tcp_rmem_max = clamp_kernel_buffer(min(math.floor(P * Vmul * buffer_factor), U))
    tcp_wmem_max = clamp_kernel_buffer(min(math.floor(P * Hmul * buffer_factor), U))
    Q = math.ceil(min(2 * max(100, T / 65536), 10000) * queue_factor)
    X = 0.6 if mem <= 256 else 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.2
    somaxconn = int(clamp(math.floor(0.2 * Q * X), 256, 2048))
    backlog = int(clamp(math.floor(0.4 * Q * X), 2000, 4000))
    max_syn = int(clamp(math.floor(0.8 * Q * X), 2048, 16384))
    min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.015 if mem <= 256 else 0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03) + math.floor(0.5 * math.ceil(T / 1024))), high_latency=False)

    data = {
        **base,
        'mode': mode,
        'net.core.default_qdisc': qdisc,
        'vm.swappiness': 10,
        'vm.dirty_ratio': 10,
        'vm.dirty_background_ratio': 5,
        'vm.min_free_kbytes': min_free,
        'net.core.netdev_max_backlog': backlog,
        'net.core.rmem_max': U,
        'net.core.wmem_max': U,
        'net.core.rmem_default': 87380,
        'net.core.wmem_default': 65536,
        'net.core.somaxconn': somaxconn,
        'net.core.optmem_max': math.floor(min(65536, P / 4)),
        'net.ipv4.tcp_fack': 0,
        'net.ipv4.tcp_rmem': clamp_tcp_triplet(8192, 87380, tcp_rmem_max),
        'net.ipv4.tcp_wmem': clamp_tcp_triplet(8192, 65536, tcp_wmem_max),
        'net.ipv4.tcp_notsent_lowat': 4096,
        'net.ipv4.tcp_adv_win_scale': adv_win_scale,
        'net.ipv4.tcp_no_metrics_save': 0,
        'net.ipv4.tcp_max_syn_backlog': max_syn,
        'net.ipv4.tcp_max_orphans': 65536,
        'net.ipv4.tcp_synack_retries': 2,
        'net.ipv4.tcp_syn_retries': 3,
        'net.ipv4.neigh.default.gc_thresh1': 1024,
        'net.ipv4.neigh.default.gc_thresh2': 4096,
        'net.ipv4.neigh.default.gc_thresh3': 8192,
    }
else:
    mode = '高延迟画像'
    qdisc = 'fq'
    throughput_priority = 2.0
    stability = 1.5
    buffer_aggression = 2.0
    queue_depth = 2.5
    conn_scaling = 2.0
    memory_util = 1.5
    win_base = 2.0
    latency_tolerance = 2.0
    win_max = 8
    latency_curve_tolerance = 1.5
    if mem <= 512:
        throughput_priority = 1.8
        stability = 1.8
        buffer_aggression = 1.5
        queue_depth = 2.0
        conn_scaling = 1.5
        memory_util = 1.2
        win_base = 1.5
        win_max = 6
    elif mem <= 2048 and mem > 1024:
        throughput_priority = 2.2
        buffer_aggression = 2.3
        queue_depth = 3.0
        conn_scaling = 2.5
        memory_util = 1.8
        win_base = 2.5
        win_max = 12
    elif mem > 2048:
        throughput_priority = 2.5
        buffer_aggression = 2.5
        queue_depth = 3.5
        conn_scaling = 3.0
        memory_util = 2.0
        win_base = 3.0
        win_max = 16

    F = clamp(latency / 40, 1, 5)
    T = clamp(2 * math.sqrt(local_bw / vps_bw) * F, 1.5, 5)
    S = math.floor(1024 * min(local_bw * T, 2 * vps_bw) * 1024 / 8)
    ratio = local_bw / vps_bw
    Ndamp = 1.0
    if ratio > 100: Ndamp = 0.06
    elif ratio > 50: Ndamp = 0.12
    elif ratio > 20: Ndamp = 0.2
    elif ratio > 10: Ndamp = 0.3
    elif ratio > 5: Ndamp = 0.5
    elif ratio > 2: Ndamp = 0.7

    G = math.ceil(S * latency / 1000)
    if mem <= 512:
        L = max(max(G, 131072), S * latency / 1200)
    elif mem <= 1024:
        L = max(max(G, 262144), S * latency / 1000)
    else:
        L = max(max(G, 524288), S * latency / 800)
    V = math.ceil(S * latency / 1000)
    H = memory_cap(math.ceil(2 * ramp * Ndamp * V), mem, 0.125)
    W = max(H, math.ceil(0.5 * V)) if latency > 500 else H
    if mem <= 512:
        W = min(W, small_mem_buffer_cap(mem))
    else:
        medium_cap = medium_mem_buffer_cap(latency, mem)
        if medium_cap is not None:
            W = min(W, medium_cap)

    curve1 = clamp((math.log(ramp * (math.e - 1) + 1) / math.log(math.e)) * stability * (buffer_aggression / 2), 0.5, 3)
    latency_input = min(1, (latency - 120) / 1880)
    latency_ramp = clamp((latency - 120) / 680, 0, 1)
    pre_extreme_penalty = clamp((980 - latency) / 260, 0, 1)
    ratio_guard = clamp((1.6 - min(ratio, 1.6)) / 1.2, 0, 1)
    ramp_guard = clamp((ramp - 0.55) / 0.45, 0, 1)
    latency_factor = clamp((math.log(latency_input * (latency_curve_tolerance - 1) + 1) / math.log(latency_curve_tolerance)) * latency_tolerance * curve1 if latency_input > 0 else 0, 1, 8)
    buffer_factor = clamp(latency_factor * tcpcong(curve1, 'congestion_avoidance', 10) * throughput_priority * buffer_aggression * memory_util * piecewise(curve1, [(0,1),(0.3,1.5),(0.6,2.5),(1,4)]), 1, 8)
    queue_factor = clamp(latency_factor / 3 * (math.log(qtheory(S / 131072 * conn_scaling, latency / 1000 * 3, min(0.9, 0.85 * curve1)) + 1) / math.log(10000) * queue_depth), 0.8, 4)
    adv_factor = max(0, math.ceil(math.log2(max(1, 4 * math.ceil(S * latency / 1000) / 65535))))
    adv_component = clamp(latency_factor / (latency_tolerance * (3.0 - 0.9 * latency_ramp)) * adv_factor * (win_base * (0.26 + 0.14 * latency_ramp)) * ((0.62 + 0.26 * latency_ramp) * curve1 + (0.34 + 0.12 * latency_ramp)), 1.5, max(3, math.ceil(win_max - (5.5 - 2.5 * latency_ramp))))
    adv_value = clamp_tcp_window_scale(max(2, math.ceil(F * adv_component)))
    if mem >= 2048 and ratio <= 1.6:
        if latency <= 650 and ramp >= 0.8:
            adv_value = min(adv_value, 24)
        elif latency <= 820:
            if ramp >= 0.8:
                adv_value = min(adv_value, 28 if ratio <= 1 else 29)
            elif ramp <= 0.55:
                adv_value = min(adv_value, 30)
        elif latency <= 900 and ramp >= 0.8:
            adv_value = min(adv_value, 28 if ratio <= 1 else 29)
        elif latency <= 1400 and ramp >= 0.8:
            adv_value = min(adv_value, 30)
    if mem <= 512:
        K = clamp(1.5 * F, 3, 6) * buffer_factor
        Q = clamp(1.5 * F, 3, 6)
    elif mem <= 1024:
        K = clamp(1.8 * F, 4, 8) * buffer_factor
        Q = clamp(1.8 * F, 4, 8)
    else:
        K = clamp(2 * F, 5, 10) * buffer_factor
        Q = clamp(2 * F, 5, 10)
    W = clamp_kernel_buffer(max(W, 32768))
    tcp_rmem_max = clamp_kernel_buffer(min(math.floor(L * Q), W))
    tcp_wmem_max = clamp_kernel_buffer(min(math.floor(L * K), W))
    J = math.ceil(min(3 * max(50, S / 131072), 20000) * queue_factor)
    Z = 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.3 if mem <= 2048 else 1.5
    somaxconn = int(clamp(math.floor(0.15 * J * Z), 2560, 8192 if mem <= 512 else 16384))
    backlog = int(clamp(math.floor(0.3 * J * Z), 8192, 16384 if mem <= 512 else 32768))
    max_syn = int(clamp(math.floor(0.6 * J * Z), 8192, 32768 if mem <= 512 else 65536))
    min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03 if mem <= 2048 else 0.035) + math.floor(0.6 * math.ceil(S / 1024))), high_latency=True)
    data = {
        **base,
        'mode': mode,
        'net.core.default_qdisc': qdisc,
        'vm.swappiness': 5,
        'vm.dirty_ratio': 5,
        'vm.dirty_background_ratio': 2,
        'vm.min_free_kbytes': min_free,
        'net.core.netdev_max_backlog': backlog,
        'net.core.rmem_max': W,
        'net.core.wmem_max': W,
        'net.core.rmem_default': 262144,
        'net.core.wmem_default': 262144,
        'net.core.somaxconn': somaxconn,
        'net.core.optmem_max': math.floor(min(262144, L / 2)),
        'net.ipv4.tcp_fack': 1,
        'net.ipv4.tcp_rmem': clamp_tcp_triplet(32768, 262144, tcp_rmem_max),
        'net.ipv4.tcp_wmem': clamp_tcp_triplet(32768, 262144, tcp_wmem_max),
        'net.ipv4.tcp_notsent_lowat': math.floor(min(L / 2, 524288)),
        'net.ipv4.tcp_adv_win_scale': adv_value,
        'net.ipv4.tcp_no_metrics_save': 1,
        'net.ipv4.tcp_max_syn_backlog': max_syn,
        'net.ipv4.tcp_max_orphans': 16384 if mem <= 256 else 32768,
        'net.ipv4.tcp_synack_retries': 2,
        'net.ipv4.tcp_syn_retries': 2,
        'net.ipv4.neigh.default.gc_thresh1': 256 if mem <= 512 else 512,
        'net.ipv4.neigh.default.gc_thresh2': 1024 if mem <= 512 else 2048,
        'net.ipv4.neigh.default.gc_thresh3': 2048 if mem <= 512 else 4096,
    }

print(json.dumps(data, ensure_ascii=False))
PY
  )

  export PROFILE_JSON="$json"
  python3 - <<'PY'
import json, os, pathlib
conf = pathlib.Path('/etc/sysctl.d/99-vpsbox-bbr.conf')
limits = pathlib.Path('/etc/security/limits.d/99-vpsbox-tcp.conf')
systemd = pathlib.Path('/etc/systemd/system.conf.d/99-vpsbox-tcp.conf')
data = json.loads(os.environ['PROFILE_JSON'])
mode = data.pop('mode')
header = [
    '# VPSBox Dynamic TCP Profile',
    f'# Mode: {mode}',
    f"# Input: local={os.environ['LOCAL_BW']}Mbps vps={os.environ['VPS_BW']}Mbps rtt={os.environ['LATENCY']}ms mem={os.environ['MEM_MB']}MB cc={os.environ['CC']} ecn={os.environ['ECN']}",
]
lines = header + [f'{k} = {v}' for k,v in data.items()]
conf.write_text('\n'.join(lines) + '\n')
limits.write_text('* soft nofile 1048576\n* hard nofile 1048576\n')
systemd.write_text('DefaultLimitNOFILE=1048576\nDefaultLimitNPROC=65535\n')
PY

  _svc_daemon_reload >/dev/null 2>&1 || true
  local mode
  mode=$(python3 - <<'PY'
import json, os
print(json.loads(os.environ['PROFILE_JSON'])['mode'])
PY
  )
  echo -e "\n${CYAN}>>> 即将应用新的 TCP 调优画像${NC}"
  echo -e "  模式: ${YELLOW}${mode}${NC}"
  echo -e "  拥塞算法: ${YELLOW}${cc}${NC} | ECN: ${YELLOW}${ecn}${NC}"
  echo -e "  输入: ${YELLOW}${local_bw}Mbps / ${vps_bw}Mbps / ${latency}ms / ${mem_mb}MB / ramp=${ramp}${NC}"
  if _bbr_apply_sysctl_file "$conf"; then
    echo -e "\n${GREEN}[完成] TCP 调优画像已写入并生效。${NC}"
  else
    echo -e "\n${YELLOW}[警告] TCP 调优画像已写入，但 sysctl 应用失败，请手动检查。${NC}"
  fi
  pause_for_enter
}

_bbr_show_dynamic_plan() {
  clear_screen; print_divider
  print_center "[ TCP 动态调优说明 ]" "$CYAN"
  echo ""
  echo -e "  ${CYAN}当前方案会根据以下变量自动生成参数:${NC}"
  echo -e "  - 本地带宽 / 服务器带宽"
  echo -e "  - RTT 延迟"
  echo -e "  - 可用内存"
  echo -e "  - 拥塞算法"
  echo ""
  echo -e "  ${CYAN}调优逻辑:${NC}"
  echo -e "  - RTT <= 120ms: 偏低延迟画像，优先使用 CAKE"
  echo -e "  - RTT > 120ms : 偏长肥管道画像，优先使用 FQ"
  echo -e "  - 高延迟画像会按 RTT + 内存分级限制缓冲上限，避免大内存/高 RTT 直接顶到内核 cap"
  echo -e "  - 高延迟窗口缩放采用渐进抬升曲线，减少中高 RTT 场景过早打满 adv_win_scale"
  echo -e "  - 自动联动生成缓冲、队列、窗口、邻居阈值、limits/systemd"
  echo ""
  pause_for_enter
}

_bbr_show_generated_profile() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  clear_screen; print_divider
  print_center "[ 当前 TCP 调优画像 ]" "$CYAN"
  echo ""
  if [[ -f "$conf" ]]; then
    sed 's/^/  /' "$conf"
  else
    echo -e "  ${YELLOW}尚未生成调优画像。${NC}"
  fi
  echo ""
  pause_for_enter
}

_bbr_set_ecn() {
  local status="$1"
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  if [[ "$status" != "0" && "$status" != "1" ]]; then
    echo -e "\n${RED}[错误] ECN 参数无效，仅支持 0 或 1。${NC}"
    pause_for_enter
    return 1
  fi
  [[ ! -f "$conf" ]] && { echo -e "\n${YELLOW}[提示] 请先生成 TCP 调优画像。${NC}"; pause_for_enter; return 1; }
  sed -i '/net.ipv4.tcp_ecn/d' "$conf" /etc/sysctl.conf 2>/dev/null
  echo "net.ipv4.tcp_ecn = $status" >> "$conf"
  if _bbr_apply_sysctl_file "$conf"; then
    [[ "$status" == "1" ]] && echo -e "\n${GREEN}[成功] ECN 已开启！${NC}" || echo -e "\n${GREEN}[成功] ECN 已关闭！${NC}"
  else
    [[ "$status" == "1" ]] && echo -e "\n${YELLOW}[警告] ECN 配置已写入，但应用失败，请手动检查。${NC}" || echo -e "\n${YELLOW}[警告] ECN 关闭配置已写入，但应用失败，请手动检查。${NC}"
  fi
  pause_for_enter
}

_bbr_show_kernels() {
  clear_screen; print_divider
  print_center "[ 已安装内核 ]" "$CYAN"
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    rpm -qa | grep -E "^kernel(-ml|-lt)?-" | sort -V 2>/dev/null || echo "  未检测到内核包"
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    dpkg -l | grep -E "^ii  linux-(image|headers)" | awk '{print $2, $3}' | column -t | sort -V
  fi
  echo -e "\n  ${CYAN}当前运行内核:${NC} ${YELLOW}$(uname -r)${NC}"
  echo -e "\n  ${CYAN}/boot 目录下:${NC}"
  ls -1v /boot/vmlinuz-* 2>/dev/null || echo "  无"
  pause_for_enter
}

_bbr_delete_kernel() {
  clear_screen; print_divider
  print_center "[ 删除内核 ]" "$RED"
  local current_kernel; current_kernel=$(uname -r)
  local kernel_list=()
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    mapfile -t kernel_list < <(rpm -qa | grep -E "^kernel(-ml|-lt)?-" | sort -V)
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    mapfile -t kernel_list < <(dpkg-query -W -f='${Package}\n' | grep -E "^linux-(image|headers)" | sort -V)
  fi
  if [[ ${#kernel_list[@]} -eq 0 ]]; then echo -e "  未检测到内核包。"; pause_for_enter; return; fi
  echo -e "  ${CYAN}当前运行:${NC} ${GREEN}${current_kernel}${NC}\n"
  for i in "${!kernel_list[@]}"; do
    local pkg="${kernel_list[$i]}"
    if [[ "$pkg" == *"$current_kernel"* ]]; then echo -e "  ${GREEN}[$i] ${pkg} [当前运行]${NC}"
    else echo -e "  [$i] ${pkg}"; fi
  done
  echo ""
  read -r -p "> 输入要删除的内核编号（空格分隔多个，回车取消）: " del_choices
  [[ -z "$del_choices" ]] && return
  local pkgs_to_del=""; local is_del_current=0
  for idx in $del_choices; do
    [[ "$idx" =~ ^[0-9]+$ && "$idx" -lt ${#kernel_list[@]} ]] || continue
    pkgs_to_del="$pkgs_to_del ${kernel_list[$idx]}"
    [[ "${kernel_list[$idx]}" == *"$current_kernel"* ]] && is_del_current=1
  done
  [[ -z "$pkgs_to_del" ]] && { echo -e "${YELLOW}无有效选择。${NC}"; pause_for_enter; return; }
  echo -e "\n${RED}即将删除:${NC}${pkgs_to_del}"
  if [[ $is_del_current -eq 1 ]]; then
    echo -e "\n${RED}⚠ 包含当前运行内核！请确保有另一内核可用，否则重启后变砖！${NC}"
    read -r -p "> 输入大写的 YES 确认: " confirm; [[ "$confirm" != "YES" ]] && return
  else
    read -r -p "> 确认删除？(Y/n): " confirm; [[ "$confirm" =~ ^[nN]$ ]] && return
  fi
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    # shellcheck disable=SC2086
    rpm -e --nodeps $pkgs_to_del
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    # shellcheck disable=SC2086
    apt-get purge -y $pkgs_to_del
    apt-get autoremove -y >/dev/null 2>&1
  fi
  _bbr_grub
  echo -e "\n${GREEN}[完成] 内核已删除。${NC}"; pause_for_enter
}

_bbr_remove_all() {
  echo -e "\n${CYAN}>>> 清除加速与优化配置...${NC}"
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  rm -f "$conf" /etc/systemd/system.conf.d/99-vpsbox-tcp.conf /etc/security/limits.d/99-vpsbox-tcp.conf
  sed -i '/net\.core\.default_qdisc/d; /net\.ipv4\.tcp_congestion_control/d; /net\.ipv4\.tcp_ecn/d' /etc/sysctl.conf 2>/dev/null
  sed -i '/net\.ipv6\.conf\.all\.disable_ipv6/d; /net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null
  sed -i '/net\.ipv4\.tcp_syncookies/d; /net\.ipv4\.tcp_max_syn_backlog/d; /net\.ipv4\.tcp_synack_retries/d' /etc/sysctl.conf 2>/dev/null
  sysctl --system >/dev/null 2>&1
  _svc_daemon_reload
  echo -e "\n${GREEN}[完成] 系统已恢复原生状态。${NC}"; pause_for_enter
}

_bbr_ipv6_off() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' "$conf" /etc/sysctl.conf 2>/dev/null
  echo "net.ipv6.conf.all.disable_ipv6 = 1" >> "$conf"
  echo "net.ipv6.conf.default.disable_ipv6 = 1" >> "$conf"
  if sysctl --system >/dev/null 2>&1; then
    echo -e "\n${GREEN}[完成] IPv6 已禁用！${NC}"
  else
    echo -e "\n${YELLOW}[警告] IPv6 配置已写入，但 sysctl 应用过程中存在异常，请手动检查。${NC}"
  fi
  pause_for_enter
}

_bbr_ipv6_on() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' "$conf" /etc/sysctl.conf 2>/dev/null
  echo "net.ipv6.conf.all.disable_ipv6 = 0" >> "$conf"
  echo "net.ipv6.conf.default.disable_ipv6 = 0" >> "$conf"
  if sysctl --system >/dev/null 2>&1; then
    echo -e "\n${GREEN}[完成] IPv6 已开启！${NC}"
  else
    echo -e "\n${YELLOW}[警告] IPv6 配置已写入，但 sysctl 应用过程中存在异常，请手动检查。${NC}"
  fi
  pause_for_enter
}

_bbr_sysctl_merge() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  echo -e "\n${CYAN}>>> 逐行输入参数 (格式: key = value)，空行结束。${NC}"
  local line; while IFS= read -r -p "> " line; do
    [[ -z "${line// /}" ]] && break
    [[ "$line" =~ ^[[:space:]]*[#\;] ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9._-]+)[[:space:]]*=[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
      sed -i "/^[[:space:]]*${key//./\\.}[[:space:]]*=/d" "$conf" 2>/dev/null
      echo "$key = $val" >> "$conf"
      echo -e "  ${GREEN}已写入:${NC} $key = $val"
    else
      echo -e "  ${RED}格式无效，跳过:${NC} $line"
    fi
  done
  if _bbr_apply_sysctl_file "$conf"; then
    echo -e "\n${GREEN}[完成] 参数已合并并生效！${NC}"
  else
    echo -e "\n${YELLOW}[警告] 参数已写入，但应用失败，请手动检查。${NC}"
  fi
  pause_for_enter
}

_bbr_sysctl_edit() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  if command -v nano &>/dev/null; then nano "$conf"
  elif command -v vim &>/dev/null; then vim "$conf"
  elif command -v vi &>/dev/null; then echo -e "  ${YELLOW}使用 vi: i=编辑 Esc=退出 :wq=保存 :q!=放弃${NC}"; sleep 2; vi "$conf"
  else echo -e "\n${RED}[错误] 未找到编辑器 (nano/vim)。${NC}"; pause_for_enter; return; fi
  if _bbr_apply_sysctl_file "$conf"; then
    echo -e "\n${GREEN}[完成] 参数已应用！${NC}"
  else
    echo -e "\n${YELLOW}[警告] 参数文件已保存，但应用失败，请手动检查。${NC}"
  fi
  pause_for_enter
}

_bbr_install_bbr_cloud() {
  [[ "$BBR_ARCH" == "x86_64" || "$BBR_ARCH" == "aarch64" ]] || { echo -e "\n${RED}[错误] 不支持架构: $BBR_ARCH${NC}"; pause_for_enter; return; }
  local tag_kw="Debian_Kernel_Cloud"; local arch_kw="amd64"; local img_kw="image"
  [[ "$BBR_OS_TYPE" == "CentOS" ]] && { tag_kw="CentOS_Kernel_Cloud"; arch_kw="x86_64"; img_kw="kernel-[0-9]"; }
  [[ "$BBR_ARCH" == "aarch64" ]] && { tag_kw="Debian_Kernel_Cloud_arm64"; arch_kw="arm64"; }
  echo -e "\n${CYAN}>>> 正在向 ylx2016/kernel 请求最新 Cloud 内核...${NC}"
  local head_url; head_url=$(_bbr_github_asset "ylx2016/kernel" "$tag_kw" "headers" "$arch_kw")
  local img_url; img_url=$(_bbr_github_asset "ylx2016/kernel" "$tag_kw" "$img_kw" "$arch_kw")
  [[ -z "$img_url" ]] && { echo -e "${RED}[错误] 未获取到发行版链接。${NC}"; pause_for_enter; return; }
  _bbr_install_kernel "BBR Cloud 优化内核" "$head_url" "$img_url"
  pause_for_enter
}

_bbr_install_bbrplus_new() {
  [[ "$BBR_ARCH" == "x86_64" || "$BBR_ARCH" == "aarch64" ]] || { echo -e "\n${RED}[错误] 不支持架构: $BBR_ARCH${NC}"; pause_for_enter; return; }
  local ext="deb"; local arch_kw="amd64"
  [[ "$BBR_OS_TYPE" == "CentOS" ]] && ext="rpm"
  [[ "$BBR_ARCH" == "aarch64" ]] && arch_kw="arm64"
  local tag_kw="bbrplus-6."
  echo -e "\n${CYAN}>>> 正在向 UJX6N/bbrplus-6.x_stable 请求数据...${NC}"
  local head_url; head_url=$(_bbr_github_asset "UJX6N/bbrplus-6.x_stable" "$tag_kw" "headers" "${arch_kw}.*${ext}")
  local img_url; img_url=$(_bbr_github_asset "UJX6N/bbrplus-6.x_stable" "$tag_kw" "image" "${arch_kw}.*${ext}")
  [[ -z "$img_url" ]] && { echo -e "${RED}[错误] 未获取到发行版链接。${NC}"; pause_for_enter; return; }
  _bbr_install_kernel "BBRplus(UJX6N) 新版内核" "$head_url" "$img_url"
  pause_for_enter
}

_bbr_install_debian_cloud() {
  [[ "$BBR_OS_TYPE" != "Debian" ]] && { echo -e "\n${RED}[错误] Cloud 内核仅支持 Debian 系。${NC}"; pause_for_enter; return; }
  local img_url_base img_pattern
  if [[ "$BBR_ARCH" == "x86_64" ]]; then
    img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-amd64/"
    img_pattern='linux-image-[^"]+cloud-amd64_[^"]+_amd64\.deb'
  elif [[ "$BBR_ARCH" == "aarch64" ]]; then
    img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-arm64/"
    img_pattern='linux-image-[^"]+cloud-arm64_[^"]+_arm64\.deb'
  else
    echo -e "\n${RED}[错误] 不支持的架构。${NC}"; pause_for_enter; return
  fi
  echo -e "\n${CYAN}>>> 从 Debian 官方源获取 Cloud 内核列表...${NC}"
  local deb_files; deb_files=$(curl -sL --max-time 10 "$img_url_base" | grep -oE "$img_pattern" | sort -V | uniq)
  [[ -z "$deb_files" ]] && { echo -e "${RED}[错误] 未找到可用版本。${NC}"; pause_for_enter; return; }
  local selected; selected=$(echo "$deb_files" | tail -1)
  echo -e "  ${CYAN}>>> 选择最新版本: ${YELLOW}$(echo "$selected" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')${NC}"
  _bbr_install_kernel "Debian 官方 Cloud" "" "${img_url_base}${selected}"
  pause_for_enter
}

_bbr_install_official_stable() {
  echo -e "\n${CYAN}>>> 安装官方稳定内核...${NC}"
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    [[ "$BBR_ARCH" != "x86_64" ]] && { echo -e "${RED}[错误] 仅支持 x86_64。${NC}"; pause_for_enter; return; }
    [[ "$BBR_OS_VER" == 7 ]] && yum install kernel kernel-headers -y --skip-broken
    [[ "$BBR_OS_VER" =~ ^(8|9|10)$ ]] && yum install kernel kernel-core kernel-headers -y --skip-broken
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    apt-get update >/dev/null 2>&1
    if [[ "$BBR_OS_ID" == "ubuntu" || "$BBR_OS_ID" == "pop" || "$BBR_OS_LIKE" == *"ubuntu"* ]]; then
      apt-get install linux-image-generic linux-headers-generic -y
    elif [[ "$BBR_ARCH" == "x86_64" ]]; then
      apt-get install linux-image-amd64 linux-headers-amd64 -y
    elif [[ "$BBR_ARCH" == "aarch64" ]]; then
      apt-get install linux-image-arm64 linux-headers-arm64 -y
    fi
  fi
  _bbr_grub
  echo -e "\n${GREEN}[完成] 官方稳定内核安装完毕。${NC}"; pause_for_enter
}

_bbr_install_official_latest() {
  echo -e "\n${CYAN}>>> 安装官方最新内核...${NC}"
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    [[ "$BBR_ARCH" != "x86_64" ]] && { echo -e "${RED}[错误] 仅支持 x86_64。${NC}"; pause_for_enter; return; }
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
    yum install "https://www.elrepo.org/elrepo-release-${BBR_OS_VER}.el${BBR_OS_VER}.elrepo.noarch.rpm" -y
    yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    apt-get update >/dev/null 2>&1
    if [[ "$BBR_OS_ID" == "ubuntu" || "$BBR_OS_ID" == "pop" || "$BBR_OS_LIKE" == *"ubuntu"* ]]; then
      if apt-cache show "linux-generic-hwe-${BBR_OS_VER}" &>/dev/null; then
        apt-get install --install-recommends "linux-generic-hwe-${BBR_OS_VER}" -y
      else
        apt-get install linux-image-generic linux-headers-generic -y
      fi
    elif [[ "$BBR_OS_ID" == "debian" ]]; then
      local codename; codename=$(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release | tr -d '"')
      [[ -z "$codename" ]] && codename=$(awk -F= '/^VERSION=/{print $2}' /etc/os-release | grep -oP '(?<=\\().*(?=\\))')
      [[ -n "$codename" ]] && echo "deb http://deb.debian.org/debian ${codename}-backports main" > "/etc/apt/sources.list.d/${codename}-backports.list" && apt-get update >/dev/null 2>&1
      if [[ "$BBR_ARCH" == "x86_64" ]]; then apt-get install linux-image-amd64 linux-headers-amd64 -y
      elif [[ "$BBR_ARCH" == "aarch64" ]]; then apt-get install linux-image-arm64 linux-headers-arm64 -y; fi
    fi
  fi
  _bbr_grub
  echo -e "\n${GREEN}[完成] 官方最新内核安装完毕。${NC}"; pause_for_enter
}

_bbr_install_xanmod() {
  local edition="$1"
  [[ "$BBR_ARCH" != "x86_64" ]] && { echo -e "\n${RED}[错误] XanMod 仅支持 x86_64。${NC}"; pause_for_enter; return; }
  [[ "$BBR_OS_TYPE" != "Debian" ]] && { echo -e "\n${RED}[错误] XanMod 仅支持 Debian/Ubuntu。${NC}"; pause_for_enter; return; }
  echo -e "\n${CYAN}>>> 安装 XanMod (${edition}) 内核...${NC}"
  apt-get update >/dev/null 2>&1
  apt-get install gnupg wget -y >/dev/null 2>&1
  rm -f /etc/apt/sources.list.d/xanmod-kernel.list /etc/apt/sources.list.d/xanmod-release.list
  wget -qO - https://dl.xanmod.org/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg
  echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null
  local cpu_level; cpu_level=$(_bbr_psabi_level)
  [[ -z "$cpu_level" ]] && cpu_level=1
  echo -e "  ${CYAN}CPU 等级: ${YELLOW}x86-64-v${cpu_level}${NC}"
  apt-get update >/dev/null 2>&1
  local pkg_name="linux-xanmod"; [[ "$edition" != "main" ]] && pkg_name="linux-xanmod-${edition}"
  if [[ "$cpu_level" -ge 3 ]]; then apt-get install "${pkg_name}-x64v3" -y
  elif [[ "$cpu_level" == 2 ]]; then apt-get install "${pkg_name}-x64v2" -y
  else apt-get install "${pkg_name}-x64v1" -y; fi
  _bbr_grub
  echo -e "\n${GREEN}[完成] XanMod (${edition}) 内核安装完毕，重启后生效。${NC}"; pause_for_enter
}

_bbr_check_sys
_bbr_check_cn

while true; do
clear_screen; print_divider
print_center "[ BBR 拥塞控制与内核管理 ]" "$PURPLE"

local cur_kernel cur_cc cur_qd
cur_kernel=$(uname -r)
cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
echo -e "  系统: ${CYAN}${BBR_OS_TYPE} ${BBR_OS_ID} ${BBR_OS_VER}${NC} | 架构: ${CYAN}${BBR_ARCH}${NC} | CN: ${CYAN}$([ "${BBR_IS_CN:-0}" -eq 1 ] && echo '是' || echo '否')${NC}"
echo -e "  内核: ${YELLOW}${cur_kernel}${NC}"
echo -e "  拥塞算法: ${YELLOW}${cur_cc}${NC} | 队列: ${YELLOW}${cur_qd}${NC}"
echo ""
echo -e "  ─────────────── ${CYAN}内核安装${NC} ───────────────"
echo -e "  ${GREEN} 1.${NC} BBR Cloud 内核     ${GREEN} 4.${NC} Debian Cloud 内核"
echo -e "  ${GREEN} 2.${NC} BBRplus 新版内核    ${GREEN} 5.${NC} 官方稳定内核"
echo -e "  ${GREEN} 3.${NC} BBRv3 内核 (推荐)   ${GREEN} 6.${NC} 官方最新内核"
if [[ "$BBR_ARCH" == "aarch64" ]]; then
  echo -e "  ${YELLOW}[提示]${NC} 当前为 ARM 架构，内核已内置 BBR，更换内核可能不兼容"
fi
echo ""
echo -e "  ─────────────── ${CYAN}加速卸载 / 内核管理${NC} ───────────────"
echo -e "  ${GREEN} 7.${NC} 卸载全部加速配置"
echo ""
echo -e "  ─────────────── ${CYAN}内核管理${NC} ───────────────"
echo -e "  ${GREEN} 8.${NC} 查看已安装内核      ${GREEN} 9.${NC} 删除指定内核"
echo ""
echo -e "  ${GREEN} 0.${NC} 返回主菜单"
echo ""
read -r -p "> 请输入选择: " bbr_opt
bbr_opt="${bbr_opt// /}"

case $bbr_opt in
1)  _bbr_install_bbr_cloud ;;
2)  _bbr_install_bbrplus_new ;;
3)  _bbr_install_xanmod main ;;         4)  _bbr_install_debian_cloud ;;
5)  _bbr_install_official_stable ;;
6)  _bbr_install_official_latest ;;
7)  _bbr_remove_all ;;
8)  _bbr_show_kernels ;;
9)  _bbr_delete_kernel ;;
0)  break ;;
*)  echo -e "\n${RED}[错误] 无效输入。${NC}"; sleep 1 ;;
esac
done
}

system_overview() {
clear_screen; print_divider
print_center "[ 系统信息与资源概览 ]" "$CYAN"
_ensure_ip

local os_info cpu_model cpu_arch cpu_cores cpu_freq virt_type
os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
[ -z "$os_info" ] && os_info="$(uname -o) $(uname -r)"
cpu_model=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ *//')
[ -z "$cpu_model" ] && cpu_model="$(uname -m)"
cpu_arch=$(uname -m)
cpu_cores=$(nproc)
cpu_freq=$(awk '/^cpu MHz/{printf "%.1f GHz\n", $4/1000; exit}' /proc/cpuinfo 2>/dev/null)
[ -z "$cpu_freq" ] && cpu_freq="N/A"
virt_type=$(systemd-detect-virt 2>/dev/null)
[ -z "$virt_type" ] || [ "$virt_type" = "none" ] && virt_type=$(grep -q 'hypervisor' /proc/cpuinfo 2>/dev/null && echo "虚拟化" || echo "物理机")

local cpu_usage
cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if(NR==1){u1=u;t1=t;} else printf "%.0f\n",(($2+$4-u1)*100/(t-t1))}' \
  <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null)
[ -z "$cpu_usage" ] && cpu_usage="N/A"

local mem_info swap_info disk_info
mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2f MB (%.0f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')
swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if(total==0){printf "未启用"} else {printf "%dM/%dM (%.0f%%)", used, total, used*100/total}}')
disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')

local load runtime tcp_count udp_count
load=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
runtime=$(awk -F. '{run_days=int($1/86400); run_hours=int(($1%86400)/3600); run_minutes=int(($1%3600)/60);
  if(run_days>0) printf("%d天 ",run_days);
  if(run_hours>0) printf("%d时 ",run_hours);
  printf("%d分\n",run_minutes)}' /proc/uptime)
tcp_count=$(ss -t 2>/dev/null | wc -l)
udp_count=$(ss -u 2>/dev/null | wc -l)

local ifaces rx_total tx_total
ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '!/lo/{gsub(/@.*/,"",$2); print $2}' | head -5)
rx_total=0; tx_total=0
for iface in $ifaces; do
  local r t
  r=$(awk "/${iface}/{print \$2}" /proc/net/dev 2>/dev/null | head -1)
  t=$(awk "/${iface}/{print \$10}" /proc/net/dev 2>/dev/null | head -1)
  [ -n "$r" ] && rx_total=$(awk "BEGIN{printf \"%.2f\", ($rx_total*1073741824+${r:-0})/1073741824}")
  [ -n "$t" ] && tx_total=$(awk "BEGIN{printf \"%.2f\", ($tx_total*1073741824+${t:-0})/1073741824}")
done

local ipinfo country city isp_info
ipinfo=$(curl -s --max-time 5 ipinfo.io 2>/dev/null)
country=$(echo "$ipinfo" | grep '"country"' | awk -F': ' '{print $2}' | tr -d '",')
city=$(echo "$ipinfo"    | grep '"city"'    | awk -F': ' '{print $2}' | tr -d '",')
isp_info=$(echo "$ipinfo"| grep '"org"'     | awk -F': ' '{print $2}' | tr -d '",')
[ -z "$country" ] && country="未知"
[ -z "$city"    ] && city="未知"
[ -z "$isp_info" ] && isp_info="未知"

local dns_info
dns_info=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)

local cc_algo qdisc_algo
cc_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
qdisc_algo=$(sysctl -n net.core.default_qdisc 2>/dev/null)

local cur_time
cur_time=$(date "+%Y-%m-%d %H:%M:%S")

echo ""
echo -e "  ${CYAN}主机名   :${NC} $(hostname)"
echo -e "  ${CYAN}系统     :${NC} $os_info"
echo -e "  ${CYAN}内核     :${NC} $(uname -r)"
echo -e "  ${CYAN}虚拟化   :${NC} $virt_type"
print_divider
echo -e "  ${CYAN}CPU 架构 :${NC} $cpu_arch"
echo -e "  ${CYAN}CPU 型号 :${NC} $cpu_model"
echo -e "  ${CYAN}CPU 核心 :${NC} ${cpu_cores} 核"
echo -e "  ${CYAN}CPU 频率 :${NC} $cpu_freq"
print_divider
echo -e "  ${CYAN}CPU 占用 :${NC} ${cpu_usage}%"
echo -e "  ${CYAN}系统负载 :${NC} $load"
echo -e "  ${CYAN}连接数   :${NC} TCP ${tcp_count} | UDP ${udp_count}"
echo -e "  ${CYAN}物理内存 :${NC} $mem_info"
echo -e "  ${CYAN}虚拟内存 :${NC} $swap_info"
echo -e "  ${CYAN}磁盘占用 :${NC} $disk_info"
print_divider
echo -e "  ${CYAN}总接收   :${NC} ${rx_total} GB"
echo -e "  ${CYAN}总发送   :${NC} ${tx_total} GB"
print_divider
echo -e "  ${CYAN}网络算法 :${NC} ${cc_algo} / ${qdisc_algo}"
print_divider
echo -e "  ${CYAN}运营商   :${NC} $isp_info"
[ -n "$SERVER_IPV4" ] && [ "$SERVER_IPV4" != "未分配" ] && echo -e "  ${CYAN}IPv4     :${NC} $SERVER_IPV4"
[ -n "$SERVER_IPV6" ] && [ "$SERVER_IPV6" != "未分配" ] && echo -e "  ${CYAN}IPv6     :${NC} $SERVER_IPV6"
echo -e "  ${CYAN}DNS      :${NC} $dns_info"
echo -e "  ${CYAN}地理位置 :${NC} $country $city"
echo -e "  ${CYAN}系统时间 :${NC} ${CURRENT_TZ}  $cur_time"
print_divider
echo -e "  ${CYAN}运行时长 :${NC} $runtime"
echo -e "  ${CYAN}BBR     :${NC} $(get_bbr_status)"
echo ""
echo -e "  ${YELLOW}已部署核心状态:${NC}"
local svc
for svc in xray sing-box docker fail2ban; do
    local s_status
    if command -v systemctl &>/dev/null && systemctl list-unit-files "${svc}.service" &>/dev/null; then
        s_status=$(_svc_is_active "$svc" && echo "active" || echo "inactive")
    else
        s_status="未安装"
    fi
    printf "    %-9s: %s\n" "$svc" "$s_status"
done
echo ""
echo -e "  ${YELLOW}网络接口流量:${NC}"
for iface in $ifaces; do
  local rx tx if_ip
  rx=$(awk "/${iface}/"'{printf "%.1f", $2/1024/1024/1024}' /proc/net/dev 2>/dev/null)
  tx=$(awk "/${iface}/"'{printf "%.1f", $10/1024/1024/1024}' /proc/net/dev 2>/dev/null)
  if_ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
  [ "$rx" != "0.0" ] || [ "$tx" != "0.0" ] && \
    echo -e "    ${GREEN}${iface}${NC}${if_ip:+ ($if_ip)}: 收 ${rx}GB | 发 ${tx}GB"
done
pause_for_enter
}

resolve_docker_codename() {
    local os_id="${ID:-debian}"
    local os_codename
    os_codename=$(lsb_release -cs 2>/dev/null || echo '')
    if [ "$os_id" = "debian" ]; then
        case "$os_codename" in
            bullseye|bookworm) echo "$os_codename" ;;
            *) echo "bookworm" ;;
        esac
    elif [ "$os_id" = "ubuntu" ]; then
        case "$os_codename" in
            focal|jammy|noble) echo "$os_codename" ;;
            *) echo "noble" ;;
        esac
    else
        echo "bookworm"
    fi
}

docker_install() {
clear_screen; print_divider
print_center "[ Docker 与 Docker Compose 一键安装 ]" "$CYAN"
if command -v docker &>/dev/null; then
echo -e "\n  ${GREEN}Docker 已安装:${NC} $(docker --version 2>/dev/null)"
if command -v docker-compose &>/dev/null; then echo -e "  ${GREEN}Compose 已安装:${NC} $(docker-compose --version 2>/dev/null)"; fi
echo -e "\n${YELLOW}如需重装请先卸载: apt purge docker-ce docker-ce-cli containerd.io${NC}"
pause_for_enter; return
fi
if ! confirm_action "安装 Docker 与 Docker Compose"; then pause_for_enter; return; fi
install_dependencies
echo -e "\n${CYAN}>>> 正在通过 linuxmirrors.cn 安装 Docker...${NC}\n${YELLOW}   请耐心等待，约需 1-3 分钟${NC}"

local _country
_country=$(curl -s --max-time 5 ipinfo.io/country 2>/dev/null)

if [ "$_country" = "CN" ]; then
  _run_remote_bash https://linuxmirrors.cn/docker.sh \
    --source mirrors.huaweicloud.com/docker-ce \
    --source-registry docker.1ms.run \
    --protocol https \
    --use-intranet-source false \
    --install-latest true \
    --close-firewall false \
    --ignore-backup-tips
else
  _run_remote_bash https://linuxmirrors.cn/docker.sh \
    --source download.docker.com \
    --source-registry registry.hub.docker.com \
    --protocol https \
    --use-intranet-source false \
    --install-latest true \
    --close-firewall false \
    --ignore-backup-tips
fi

if [ "$_country" = "CN" ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://hub.rat.dev",
    "https://dockerproxy.net",
    "https://hub1.nat.tf",
    "https://hub2.nat.tf",
    "https://docker.amingg.com"
  ]
}
EOF
  echo -e "  ${CYAN}[已配置] CN 镜像加速源${NC}"
fi

_svc_enable docker >/dev/null 2>&1
_svc_restart docker >/dev/null 2>&1

if command -v docker &>/dev/null; then
echo -e "\n${GREEN}[成功] Docker 安装完成！${NC}"
echo -e "  Docker: $(docker --version 2>/dev/null)"
echo -e "  Compose: $(docker compose version 2>/dev/null)"
else
echo -e "\n${RED}[错误] Docker 安装失败，请检查系统兼容性或手动安装。${NC}"
fi
pause_for_enter
}

fail2ban_install() {
clear_screen; print_divider
print_center "[ Fail2Ban 暴力破解防护 ]" "$CYAN"
local FB_LOG="" FB_BACKEND="auto"
if [ -f /var/log/auth.log ]; then FB_LOG="/var/log/auth.log"
elif [ -f /var/log/secure ]; then FB_LOG="/var/log/secure"
elif [ -f /var/log/messages ]; then FB_LOG="/var/log/messages"
else FB_BACKEND="systemd"; fi
if command -v fail2ban-client &>/dev/null; then
echo -e "\n  ${GREEN}Fail2Ban 已安装${NC}"
echo -e "  ${CYAN}SSH 监狱状态:${NC}"
fail2ban-client status sshd 2>/dev/null | grep -E 'Status|Banned|Total' || echo -e "  ${YELLOW}SSH 监狱未激活${NC}"
echo -e "\n  ${GREEN}1.${NC} 重新配置 SSH 防护\n  ${GREEN}2.${NC} 查看封禁列表\n  ${GREEN}0.${NC} 返回"
read -r -p "> 请选择: " fb_opt
case "${fb_opt// /}" in
1)
    local FB_SSH_PORT
    FB_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [ -z "$FB_SSH_PORT" ] && FB_SSH_PORT=22
    cat > /etc/fail2ban/jail.local << FBEOL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${FB_SSH_PORT}
backend = ${FB_BACKEND}
${FB_LOG:+logpath = ${FB_LOG}}
maxretry = 3
bantime = 86400
FBEOL
    _svc_restart fail2ban >/dev/null 2>&1
    echo -e "\n${GREEN}[成功] SSH 防护已重新配置 (端口: ${FB_SSH_PORT})${NC}"
    pause_for_enter; return ;;
2) fail2ban-client status sshd 2>/dev/null && fail2ban-client get sshd banned 2>/dev/null; pause_for_enter; return ;;
*) return ;;
esac
fi
if ! confirm_action "安装并配置 Fail2Ban (SSH 暴力破解防护)"; then pause_for_enter; return; fi
install_dependencies
echo -e "\n${CYAN}>>> 正在安装 Fail2Ban...${NC}"
if command -v apt &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1
elif command -v dnf &>/dev/null; then dnf install -y fail2ban >/dev/null 2>&1
elif command -v yum &>/dev/null; then yum install -y fail2ban >/dev/null 2>&1
elif command -v apk &>/dev/null; then apk add fail2ban >/dev/null 2>&1
elif command -v pacman &>/dev/null; then pacman -S --noconfirm fail2ban >/dev/null 2>&1
elif command -v zypper &>/dev/null; then zypper install -y fail2ban >/dev/null 2>&1
else echo -e "${RED}[错误] 未识别的包管理器。${NC}"; pause_for_enter; return; fi
if ! command -v fail2ban-client &>/dev/null; then echo -e "${RED}[错误] 安装失败。${NC}"; pause_for_enter; return; fi
local SSH_PORT
SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$SSH_PORT" ] && SSH_PORT=22
cat > /etc/fail2ban/jail.local << FBEOL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
backend = ${FB_BACKEND}
${FB_LOG:+logpath = ${FB_LOG}}
maxretry = 3
bantime = 86400
FBEOL
_svc_restart fail2ban >/dev/null 2>&1 && _svc_enable fail2ban >/dev/null 2>&1
if fail2ban-client status sshd >/dev/null 2>&1; then
echo -e "\n${GREEN}[成功] Fail2Ban 已配置完成！${NC}"
echo -e "  ${YELLOW}规则: SSH 端口 ${SSH_PORT}，最大 3 次失败 → 封禁 24 小时${NC}"
else
echo -e "\n${RED}[错误] Fail2Ban 启动失败，请检查日志: journalctl -u fail2ban${NC}"
fi
pause_for_enter
}

apply_tuning() {
while true; do
clear_screen; print_divider
print_center "[ TCP 调优 ]" "$CYAN"
echo -e "  ${GREEN}1.${NC} 智能 TCP 调优"
echo -e "  ${GREEN}2.${NC} 生成智能调优画像     ${GREEN}3.${NC} 查看当前调优画像"
echo -e "  ${GREEN}4.${NC} 调优逻辑说明         ${GREEN}5.${NC} 开启 ECN"
echo -e "  ${GREEN}6.${NC} 关闭 ECN             ${GREEN}7.${NC} 禁用 IPv6"
echo -e "  ${GREEN}8.${NC} 开启 IPv6           ${GREEN}9.${NC} 合并内核参数"
echo -e "  ${GREEN}10.${NC} 编辑内核参数       ${GREEN}11.${NC} 调优备份/还原"
echo -e "  ${GREEN}0.${NC} 返回主菜单"
echo ""
read -r -p "> 请输入选择: " t_opt
t_opt="${t_opt// /}"
case "$t_opt" in
1) run_tcp_tuning ;;
2) _bbr_collect_dynamic_inputs; _bbr_generate_dynamic_profile ;;
3) _bbr_show_generated_profile ;;
4) _bbr_show_dynamic_plan ;;
5) _bbr_set_ecn 1 ;;
6) _bbr_set_ecn 0 ;;
7) _bbr_ipv6_off ;;
8) _bbr_ipv6_on ;;
9) _bbr_sysctl_merge ;;
10) _bbr_sysctl_edit ;;
11) tcp_tuning_backup_menu ;;
0) return ;;
*) echo -e "\n${RED}[错误] 无效输入。${NC}"; sleep 1 ;;
esac
done
}

run_tcp_tuning() {
clear_screen; print_divider
print_center "[ VPS Box 自研动态 TCP 智能调优引擎 ]" "$CYAN"
local local_bw server_bw latency ramp_up bbr_ver qdisc w_ram tune_ecn
_tcp_profile_collect_inputs "TCPRUN" "bbr" "0"
local_bw="$TCPRUN_LOCAL_BW"
server_bw="$TCPRUN_VPS_BW"
latency="$TCPRUN_LATENCY"
ramp_up="$TCPRUN_RAMP"
bbr_ver="$TCPRUN_CC"
qdisc="$TCPRUN_QDISC"
w_ram="$TCPRUN_MEMORY_MB"
tune_ecn="$TCPRUN_ECN"

if ! confirm_action "执行并使上述 TCP 调优参数生效"; then pause_for_enter; return; fi

if [[ -z "$local_bw" || -z "$server_bw" || -z "$latency" || -z "$ramp_up" || -z "$bbr_ver" || -z "$qdisc" || -z "$w_ram" || -z "$tune_ecn" ]]; then
  echo -e "\n${RED}[错误] 调优参数采集失败，已取消本次应用。${NC}"
  pause_for_enter
  return
fi

read -r -p "> 是否在调优前备份当前参数？(y/n, 默认 y): " NEED_BACKUP
NEED_BACKUP="${NEED_BACKUP// /}"
[[ -z "$NEED_BACKUP" || "$NEED_BACKUP" =~ ^[yY]$ ]] && backup_config_silently

echo -e "\n${CYAN}>>> 正在运行 VPS Box 自研引擎计算并安全注入配置...${NC}"

: > "$CUSTOM_CONF"

PROFILE_JSON=$(LOCAL_BW="$local_bw" VPS_BW="$server_bw" LATENCY="$latency" MEM_MB="$w_ram" RAMP="$ramp_up" CC="$bbr_ver" QDISC="$qdisc" ECN="$tune_ecn" python3 - <<'PY'
import json, math, os

def clamp(x, lo, hi):
    return min(max(x, lo), hi)

def sigmoid(x, steepness=4.0, midpoint=0.3):
    return 1.0 / (1.0 + math.exp(-steepness * (x - midpoint)))

def piecewise(x, points):
    if x <= points[0][0]:
        return points[0][1]
    for i in range(1, len(points)):
        x0, y0 = points[i-1]
        x1, y1 = points[i]
        if x <= x1:
            return y0 + (y1-y0) * ((x-x0)/(x1-x0)) if x1 != x0 else y1
    return points[-1][1]

def qtheory(e, service, utilization):
    return service / (1 - min(utilization, 0.95)) * e

def tcpcong(x, mode, scale):
    if mode == 'slow_start':
        return min(scale * (1 + 0.5 * x), scale + 10 * x)
    return scale + 0.1 * x

def memory_cap(target, mem_mb, frac):
    return min(target, int(1024 * mem_mb * 1024 * frac))

def clamp_tcp_window_scale(value):
    return int(clamp(value, -31, 31))

def clamp_kernel_buffer(value):
    return int(clamp(math.floor(value), 4096, 1073741824))

def clamp_tcp_triplet(min_value, default_value, max_value):
    min_value = clamp_kernel_buffer(min_value)
    default_value = clamp_kernel_buffer(default_value)
    max_value = clamp_kernel_buffer(max_value)
    if default_value < min_value:
        default_value = min_value
    if max_value < default_value:
        max_value = default_value
    return f'{min_value} {default_value} {max_value}'

def small_mem_buffer_cap(mem_mb):
    if mem_mb <= 64:
        return 8 * 1024 * 1024
    if mem_mb <= 128:
        return 16 * 1024 * 1024
    if mem_mb <= 256:
        return 32 * 1024 * 1024
    if mem_mb <= 512:
        return 64 * 1024 * 1024
    return 128 * 1024 * 1024

def medium_mem_buffer_cap(latency_ms, mem_mb):
    if mem_mb <= 1024:
        return 128 * 1024 * 1024 if latency_ms > 900 else 96 * 1024 * 1024 if latency_ms > 650 else 64 * 1024 * 1024
    if mem_mb <= 2048:
        return 256 * 1024 * 1024 if latency_ms > 1100 else 192 * 1024 * 1024 if latency_ms > 800 else 128 * 1024 * 1024
    if mem_mb <= 4096:
        return 384 * 1024 * 1024 if latency_ms > 1300 else 320 * 1024 * 1024 if latency_ms > 900 else 224 * 1024 * 1024
    if mem_mb <= 8192:
        return 640 * 1024 * 1024 if latency_ms > 1300 else 512 * 1024 * 1024 if latency_ms > 900 else 384 * 1024 * 1024
    if mem_mb <= 32768:
        return 768 * 1024 * 1024 if latency_ms > 1300 else 640 * 1024 * 1024 if latency_ms > 900 else 512 * 1024 * 1024
    return 896 * 1024 * 1024 if latency_ms > 1300 else 768 * 1024 * 1024

def tuned_min_free_kbytes(mem_mb, target_kbytes, high_latency=False):
    floor = 16384 if mem_mb <= 64 else 24576 if mem_mb <= 128 else 32768 if mem_mb <= 256 else 49152 if mem_mb <= 512 else 65536
    ceiling = int(mem_mb * (384 if mem_mb <= 128 else 320 if mem_mb <= 256 else 256 if mem_mb <= 512 else 192 if mem_mb <= 1024 else 160))
    if high_latency:
        ceiling = int(ceiling * 1.15)
    ceiling = max(floor, min(1048576, ceiling))
    return int(clamp(target_kbytes, floor, ceiling))

local_bw = int(os.environ['LOCAL_BW'])
vps_bw = int(os.environ['VPS_BW'])
latency = int(os.environ['LATENCY'])
mem = int(os.environ['MEM_MB'])
ramp = float(os.environ['RAMP'])
cc = os.environ['CC']
ecn = int(os.environ.get('ECN', '0'))
qdisc_override = os.environ.get('QDISC','').strip()

base = {
    'kernel.pid_max': 65535,
    'kernel.panic': 1,
    'kernel.sysrq': 1,
    'kernel.core_pattern': 'core_%e',
    'kernel.printk': '3 4 1 3',
    'kernel.numa_balancing': 0,
    'kernel.sched_autogroup_enabled': 0,
    'vm.panic_on_oom': 1,
    'vm.overcommit_memory': 1,
    'vm.vfs_cache_pressure': 100,
    'vm.dirty_expire_centisecs': 3000,
    'vm.dirty_writeback_centisecs': 500,
    'net.ipv4.tcp_fastopen': 3,
    'net.ipv4.tcp_timestamps': 1,
    'net.ipv4.tcp_tw_reuse': 1,
    'net.ipv4.tcp_fin_timeout': 10,
    'net.ipv4.tcp_slow_start_after_idle': 0,
    'net.ipv4.tcp_max_tw_buckets': 32768,
    'net.ipv4.tcp_sack': 1,
    'net.ipv4.tcp_mtu_probing': 1,
    'net.ipv4.tcp_congestion_control': cc,
    'net.ipv4.tcp_window_scaling': 1,
    'net.ipv4.tcp_moderate_rcvbuf': 1,
    'net.ipv4.tcp_abort_on_overflow': 0,
    'net.ipv4.tcp_stdurg': 0,
    'net.ipv4.tcp_rfc1337': 0,
    'net.ipv4.tcp_syncookies': 1,
    'net.ipv4.tcp_ecn': ecn,
    'net.ipv4.ip_forward': 0,
    'net.ipv4.ip_local_port_range': '1024 65535',
    'net.ipv4.ip_no_pmtu_disc': 0,
    'net.ipv4.route.gc_timeout': 100,
    'net.ipv4.neigh.default.gc_stale_time': 120,
    'net.ipv4.icmp_echo_ignore_broadcasts': 1,
    'net.ipv4.icmp_ignore_bogus_error_responses': 1,
    'net.ipv4.conf.all.accept_redirects': 0,
    'net.ipv4.conf.default.accept_redirects': 0,
    'net.ipv4.conf.all.secure_redirects': 0,
    'net.ipv4.conf.default.secure_redirects': 0,
    'net.ipv4.conf.all.accept_source_route': 0,
    'net.ipv4.conf.default.accept_source_route': 0,
    'net.ipv4.conf.all.forwarding': 0,
    'net.ipv4.conf.default.forwarding': 0,
    'net.ipv4.conf.all.rp_filter': 1,
    'net.ipv4.conf.default.rp_filter': 1,
    'net.ipv4.conf.all.arp_announce': 2,
    'net.ipv4.conf.default.arp_announce': 2,
    'net.ipv4.conf.all.arp_ignore': 1,
    'net.ipv4.conf.default.arp_ignore': 1,
}

if latency <= 120:
    qdisc = qdisc_override or 'cake'
    responsiveness = 2.0; jitter_tolerance = 0.3; burst_handling = 0.7; memory_efficiency = 1.0; buffer_aggression = 0.8; queue_pref = 0.8; conn_density = 1.2; win_base = 1.2; latency_sensitivity = 1.5; win_max = 4
    if mem <= 256:
        responsiveness = 2.5; jitter_tolerance = 0.2; burst_handling = 0.5; memory_efficiency = 0.8; buffer_aggression = 0.6; queue_pref = 0.6; conn_density = 1.0; win_base = 1.0; win_max = 3
    elif mem <= 512:
        responsiveness = 2.2; jitter_tolerance = 0.25; burst_handling = 0.6; memory_efficiency = 0.9; buffer_aggression = 0.7
    elif mem > 1024:
        responsiveness = 1.8; jitter_tolerance = 0.4; burst_handling = 0.9; memory_efficiency = 1.2; buffer_aggression = 1.0; queue_pref = 1.0; conn_density = 1.5; win_base = 1.4; win_max = 6
    F = clamp(1.5 * math.sqrt(local_bw / vps_bw), 1, 2)
    T = math.floor(1024 * min(local_bw * F, vps_bw) * 1024 / 8)
    ratio = local_bw / vps_bw
    B = 1.0
    if ratio > 1:
        B = max(0.3, 1 / math.sqrt(min(ratio, 100)))
        if latency > 200:
            B = min(1.0, 1.2 * B)
    N = math.ceil(T * latency / 1000)
    P = max(N, 24576)
    A = 0.1 if mem <= 256 else 0.125
    I = 4194304 if mem <= 256 else 8388608
    U = max(memory_cap(math.ceil(1.5 * ramp * B * N), mem, A), I)
    curve1 = clamp(sigmoid(ramp, 4, 0.3) * (responsiveness / 2), 0.3, 2)
    latency_factor = clamp((2 ** (latency / 120 - 1)) * curve1 * responsiveness, 0.8, 5)
    buffer_factor = clamp(latency_factor * tcpcong(curve1, 'slow_start', 1) * memory_efficiency * buffer_aggression * burst_handling, 0.5, 3)
    queue_factor = clamp((math.log(qtheory(T / 65536 * conn_density, latency / 1000 * 2, 0.8 * curve1) + 1) / math.log(1000)) * queue_pref * (1 + jitter_tolerance), 0.3, 2)
    adv_factor = max(0, math.ceil(math.log2(max(1, 2 * math.ceil(T * latency / 1000) / 65535))))
    adv_win_scale = clamp_tcp_window_scale(max(2, math.ceil(clamp(latency_factor / latency_sensitivity * adv_factor * win_base * curve1, 1, win_max))))
    Vmul = 2.5 if mem <= 256 else 3 if mem <= 512 else 4
    Hmul = 1.2 if mem <= 256 else 1.5 if mem <= 1024 else 2
    U = clamp_kernel_buffer(U)
    tcp_rmem_max = clamp_kernel_buffer(min(math.floor(P * Vmul * buffer_factor), U))
    tcp_wmem_max = clamp_kernel_buffer(min(math.floor(P * Hmul * buffer_factor), U))
    Q = math.ceil(min(2 * max(100, T / 65536), 10000) * queue_factor)
    X = 0.6 if mem <= 256 else 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.2
    somaxconn = int(clamp(math.floor(0.2 * Q * X), 256, 2048))
    backlog = int(clamp(math.floor(0.4 * Q * X), 2000, 4000))
    max_syn = int(clamp(math.floor(0.8 * Q * X), 2048, 16384))
    min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.015 if mem <= 256 else 0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03) + math.floor(0.5 * math.ceil(T / 1024))), high_latency=False)
    data = {**base,'net.core.default_qdisc':qdisc,'vm.swappiness':10,'vm.dirty_ratio':10,'vm.dirty_background_ratio':5,'vm.min_free_kbytes':min_free,'net.core.netdev_max_backlog':backlog,'net.core.rmem_max':U,'net.core.wmem_max':U,'net.core.rmem_default':87380,'net.core.wmem_default':65536,'net.core.somaxconn':somaxconn,'net.core.optmem_max':math.floor(min(65536, P / 4)),'net.ipv4.tcp_fack':0,'net.ipv4.tcp_rmem':f'8192 87380 {tcp_rmem_max}','net.ipv4.tcp_wmem':f'8192 65536 {tcp_wmem_max}','net.ipv4.tcp_notsent_lowat':4096,'net.ipv4.tcp_adv_win_scale':adv_win_scale,'net.ipv4.tcp_no_metrics_save':0,'net.ipv4.tcp_max_syn_backlog':max_syn,'net.ipv4.tcp_max_orphans':65536,'net.ipv4.tcp_synack_retries':2,'net.ipv4.tcp_syn_retries':3,'net.ipv4.neigh.default.gc_thresh1':1024,'net.ipv4.neigh.default.gc_thresh2':4096,'net.ipv4.neigh.default.gc_thresh3':8192}
else:
    qdisc = qdisc_override or 'fq'
    throughput_priority = 2.0; stability = 1.5; buffer_aggression = 2.0; queue_depth = 2.5; conn_scaling = 2.0; memory_util = 1.5; win_base = 2.0; latency_tolerance = 2.0; win_max = 8; latency_curve_tolerance = 1.5
    if mem <= 512:
        throughput_priority = 1.8; stability = 1.8; buffer_aggression = 1.5; queue_depth = 2.0; conn_scaling = 1.5; memory_util = 1.2; win_base = 1.5; win_max = 6
    elif mem <= 2048 and mem > 1024:
        throughput_priority = 2.2; buffer_aggression = 2.3; queue_depth = 3.0; conn_scaling = 2.5; memory_util = 1.8; win_base = 2.5; win_max = 12
    elif mem > 2048:
        throughput_priority = 2.5; buffer_aggression = 2.5; queue_depth = 3.5; conn_scaling = 3.0; memory_util = 2.0; win_base = 3.0; win_max = 16
    F = clamp(latency / 40, 1, 5)
    T = clamp(2 * math.sqrt(local_bw / vps_bw) * F, 1.5, 5)
    S = math.floor(1024 * min(local_bw * T, 2 * vps_bw) * 1024 / 8)
    ratio = local_bw / vps_bw
    Ndamp = 1.0
    if ratio > 100: Ndamp = 0.06
    elif ratio > 50: Ndamp = 0.12
    elif ratio > 20: Ndamp = 0.2
    elif ratio > 10: Ndamp = 0.3
    elif ratio > 5: Ndamp = 0.5
    elif ratio > 2: Ndamp = 0.7
    G = math.ceil(S * latency / 1000)
    if mem <= 512: L = max(max(G, 131072), S * latency / 1200)
    elif mem <= 1024: L = max(max(G, 262144), S * latency / 1000)
    else: L = max(max(G, 524288), S * latency / 800)
    V = math.ceil(S * latency / 1000)
    H = memory_cap(math.ceil(2 * ramp * Ndamp * V), mem, 0.125)
    W = max(H, math.ceil(0.5 * V)) if latency > 500 else H
    if mem <= 512:
        W = min(W, small_mem_buffer_cap(mem))
    else:
        medium_cap = medium_mem_buffer_cap(latency, mem)
        if medium_cap is not None:
            W = min(W, medium_cap)
    curve1 = clamp((math.log(ramp * (math.e - 1) + 1) / math.log(math.e)) * stability * (buffer_aggression / 2), 0.5, 3)
    latency_input = min(1, (latency - 120) / 1880)
    latency_ramp = clamp((latency - 120) / 680, 0, 1)
    pre_extreme_penalty = clamp((980 - latency) / 260, 0, 1)
    ratio_guard = clamp((1.6 - min(ratio, 1.6)) / 1.2, 0, 1)
    ramp_guard = clamp((ramp - 0.55) / 0.45, 0, 1)
    latency_factor = clamp((math.log(latency_input * (latency_curve_tolerance - 1) + 1) / math.log(latency_curve_tolerance)) * latency_tolerance * curve1 if latency_input > 0 else 0, 1, 8)
    buffer_factor = clamp(latency_factor * tcpcong(curve1, 'congestion_avoidance', 10) * throughput_priority * buffer_aggression * memory_util * piecewise(curve1, [(0,1),(0.3,1.5),(0.6,2.5),(1,4)]), 1, 8)
    queue_factor = clamp(latency_factor / 3 * (math.log(qtheory(S / 131072 * conn_scaling, latency / 1000 * 3, min(0.9, 0.85 * curve1)) + 1) / math.log(10000) * queue_depth), 0.8, 4)
    adv_factor = max(0, math.ceil(math.log2(max(1, 4 * math.ceil(S * latency / 1000) / 65535))))
    adv_component = clamp(latency_factor / (latency_tolerance * (3.0 - 0.9 * latency_ramp)) * adv_factor * (win_base * (0.26 + 0.14 * latency_ramp)) * ((0.62 + 0.26 * latency_ramp) * curve1 + (0.34 + 0.12 * latency_ramp)), 1.5, max(3, math.ceil(win_max - (5.5 - 2.5 * latency_ramp))))
    adv_value = clamp_tcp_window_scale(max(2, math.ceil(F * adv_component)))
    if mem >= 2048 and ratio <= 1.6:
        if latency <= 650 and ramp >= 0.8:
            adv_value = min(adv_value, 24)
        elif latency <= 820:
            if ramp >= 0.8:
                adv_value = min(adv_value, 28 if ratio <= 1 else 29)
            elif ramp <= 0.55:
                adv_value = min(adv_value, 30)
        elif latency <= 900 and ramp >= 0.8:
            adv_value = min(adv_value, 28 if ratio <= 1 else 29)
        elif latency <= 1400 and ramp >= 0.8:
            adv_value = min(adv_value, 30)
    if mem <= 512:
        K = clamp(1.5 * F, 3, 6) * buffer_factor; Q = clamp(1.5 * F, 3, 6)
    elif mem <= 1024:
        K = clamp(1.8 * F, 4, 8) * buffer_factor; Q = clamp(1.8 * F, 4, 8)
    else:
        K = clamp(2 * F, 5, 10) * buffer_factor; Q = clamp(2 * F, 5, 10)
    W = clamp_kernel_buffer(max(W, 32768))
    tcp_rmem_max = clamp_kernel_buffer(min(math.floor(L * Q), W))
    tcp_wmem_max = clamp_kernel_buffer(min(math.floor(L * K), W))
    J = math.ceil(min(3 * max(50, S / 131072), 20000) * queue_factor)
    Z = 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.3 if mem <= 2048 else 1.5
    somaxconn = int(clamp(math.floor(0.15 * J * Z), 2560, 8192 if mem <= 512 else 16384))
    backlog = int(clamp(math.floor(0.3 * J * Z), 8192, 16384 if mem <= 512 else 32768))
    max_syn = int(clamp(math.floor(0.6 * J * Z), 8192, 32768 if mem <= 512 else 65536))
    min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03 if mem <= 2048 else 0.035) + math.floor(0.6 * math.ceil(S / 1024))), high_latency=True)
    data = {**base,'net.core.default_qdisc':qdisc,'vm.swappiness':5,'vm.dirty_ratio':5,'vm.dirty_background_ratio':2,'vm.min_free_kbytes':min_free,'net.core.netdev_max_backlog':backlog,'net.core.rmem_max':W,'net.core.wmem_max':W,'net.core.rmem_default':262144,'net.core.wmem_default':262144,'net.core.somaxconn':somaxconn,'net.core.optmem_max':math.floor(min(262144, L / 2)),'net.ipv4.tcp_fack':1,'net.ipv4.tcp_rmem':f'32768 262144 {tcp_rmem_max}','net.ipv4.tcp_wmem':f'32768 262144 {tcp_wmem_max}','net.ipv4.tcp_notsent_lowat':math.floor(min(L / 2, 524288)),'net.ipv4.tcp_adv_win_scale':adv_value,'net.ipv4.tcp_no_metrics_save':1,'net.ipv4.tcp_max_syn_backlog':max_syn,'net.ipv4.tcp_max_orphans':16384 if mem <= 256 else 32768,'net.ipv4.tcp_synack_retries':2,'net.ipv4.tcp_syn_retries':2,'net.ipv4.neigh.default.gc_thresh1':256 if mem <= 512 else 512,'net.ipv4.neigh.default.gc_thresh2':1024 if mem <= 512 else 2048,'net.ipv4.neigh.default.gc_thresh3':2048 if mem <= 512 else 4096}
print(json.dumps(data, ensure_ascii=False))
PY
)

TUNING_VARS=$(PROFILE_JSON="$PROFILE_JSON" python3 - <<'PY'
import json, os
obj=json.loads(os.environ['PROFILE_JSON'])
for k,v in obj.items():
    print(json.dumps({"key": k, "value": v}, ensure_ascii=False))
PY
)

modprobe tcp_bbr > /dev/null 2>&1 || true

while IFS= read -r line; do
if [ -n "$line" ]; then
key=$(JSON_LINE="$line" python3 - <<'PY'
import json, os
obj = json.loads(os.environ['JSON_LINE'])
print(obj['key'])
PY
)
val=$(JSON_LINE="$line" python3 - <<'PY'
import json, os
obj = json.loads(os.environ['JSON_LINE'])
value = obj['value']
if isinstance(value, str):
    print(value)
else:
    print(json.dumps(value, ensure_ascii=False))
PY
)
if [ -n "$key" ] && [ -n "$val" ]; then
if sysctl -w "$key=$val" >/dev/null 2>&1; then
printf '%s = %s\n' "$key" "$val" >> "$CUSTOM_CONF"
fi
fi
fi
done <<< "$TUNING_VARS"

if [ ! -s "$CUSTOM_CONF" ]; then
echo -e "\n${RED}[错误] 动态参数注入完全失败！请检查系统权限或虚拟化架构限制。${NC}"
else
echo -e "\n${GREEN}[成功] TCP 动态调优参数已安全注入并生效！${NC}"
echo -e "${YELLOW}(注: 系统已智能跳过了当前内核不支持的参数指令，防止了重启后 sysctl 奔溃配置丢失)${NC}"
echo -e "[提示] 当前 BBR 状态: $(get_bbr_status)"
fi
pause_for_enter
}

backup_config_silently() {
local ts
ts=$(date +"%Y%m%d_%H%M%S")
if sysctl -a 2>/dev/null | grep -E "net\.ipv4\.tcp_(rmem|wmem|congestion|sack)" > "${BACKUP_DIR}/backup_${ts}.conf"; then echo -e "${GREEN}[成功] 参数已自动备份。${NC}"; else echo -e "${YELLOW}[警告] 自动备份异常或不支持当前系统。${NC}"; fi
}

manage_backup() {
while true; do
clear_screen; print_divider
print_center "[ 网络调优参数备份与还原管理 ]" "$CYAN"
echo -e "  ${GREEN}1.${NC} 立即备份当前参数\n  ${GREEN}2.${NC} 还原历史备份\n  ${GREEN}3.${NC} 删除历史备份\n  ${GREEN}0.${NC} 返回主菜单"
echo ""; read -r -p "> 请选择操作 [0-3]: " b_opt
b_opt="${b_opt// /}"
case $b_opt in
1)
if ! confirm_action "备份当前网络参数"; then continue; fi
local ts
ts=$(date +"%Y%m%d_%H%M%S")
if sysctl -a 2>/dev/null | grep -E "net\.ipv4\.tcp_(rmem|wmem|congestion|sack)" > "${BACKUP_DIR}/backup_${ts}.conf"; then echo -e "\n${GREEN}[成功] TCP 参数备份成功！${NC}"; else echo -e "\n${RED}[错误] 备份执行失败。${NC}"; fi
pause_for_enter ;;
2)
shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${RED}无备份记录。${NC}"; pause_for_enter; continue; fi
while true; do
echo -e "\n${CYAN}请选择要恢复的时间点：${NC}"
for i in "${!backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
read -r -p "> 请输入编号 (0取消): " res_opt
res_opt="${res_opt// /}"
if [ "$res_opt" == "0" ]; then break; fi
if [[ "$res_opt" =~ ^[0-9]+$ ]] && [ "$res_opt" -ge 1 ] && [ "$res_opt" -le "${#backups[@]}" ]; then
if ! confirm_action "覆盖当前配置并还原至此备份" "n"; then break; fi
if sysctl -p "${backups[$((res_opt-1))]}" > /dev/null 2>&1; then rm -f "$CUSTOM_CONF"; echo -e "\n${GREEN}[成功] 参数已成功还原！${NC}"; else echo -e "\n${RED}[错误] 还原参数失败。${NC}"; fi
pause_for_enter; break
else
echo -e "${RED}[错误] 输入无效编号，请重新输入！${NC}"
fi
done ;;
3)
shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${YELLOW}备份目录为空。${NC}"; pause_for_enter; continue; fi
while true; do
echo -e "\n${CYAN}请选择要删除的备份：${NC}"
for i in "${!backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
echo -e "  ${RED}99.${NC} 清空所有"
read -r -p "> 请输入编号 (0取消): " del_opt
del_opt="${del_opt// /}"
if [ "$del_opt" == "0" ]; then break; fi
if [[ "$del_opt" =~ ^[0-9]+$ ]] && [ "$del_opt" -ge 1 ] && [ "$del_opt" -le "${#backups[@]}" ]; then
if ! confirm_action "永久删除此备份" "n"; then break; fi
rm -f "${backups[$((del_opt-1))]}"; echo -e "\n${GREEN}[成功] 记录已删除。${NC}"; pause_for_enter; break
elif [[ "$del_opt" == "99" ]]; then
if ! confirm_action "永久清空所有备份" "n"; then break; fi
rm -f "${BACKUP_DIR}"/backup_*.conf; echo -e "\n${GREEN}[成功] 已清空所有备份。${NC}"; pause_for_enter; break
else
echo -e "${RED}[错误] 编号输入无效，请重新选择列表中存在的选项！${NC}"
fi
done ;;
0) return ;;
*) echo -e "\n${RED}[错误] 输入无效，请输入 0-3 之间的数字！${NC}"; sleep 1 ;;
esac
done
}

check_media_unlock() {
clear_screen; print_divider
print_center "[ IP 质量检测与流媒体解锁 ]" "$CYAN"
install_dependencies
echo -e "${CYAN}>>> 正在启动权威检测引擎...${NC}\n"
local CHECK_TMP; CHECK_TMP=$(mktemp)
local check_ret=2
if curl -fsSL --connect-timeout 10 --max-time 60 https://Check.Place -o "$CHECK_TMP"; then
    if grep -Eq '^#!/|(^|[[:space:]])(bash|sh)[[:space:]]' "$CHECK_TMP"; then
        bash "$CHECK_TMP"
        check_ret=$?
    else
        echo -e "${RED}[错误] 检测脚本内容校验失败，已拒绝执行可疑返回内容。${NC}"
    fi
fi
rm -f "$CHECK_TMP"
if [ $check_ret -ne 0 ] && [ $check_ret -ne 1 ]; then
    echo -e "\n${RED}[错误] 网络不通、下载失败或检测脚本不可用，请检查服务器出墙连通性。${NC}"
fi
pause_for_enter
}

view_deployed_nodes() {
while true; do
clear_screen; print_divider
print_center "[ 节点状态、分享与配置备份管理 ]" "$CYAN"
install_dependencies
echo -e "${CYAN}--- 服务端底层配置状态 ---${NC}"
_ensure_node_meta_file "$XRAY_META_FILE"
_ensure_node_meta_file "$SINGBOX_META_FILE"
if jq -e 'length > 0' "$XRAY_META_FILE" >/dev/null 2>&1; then
  jq -r '.[] | "【Xray】 端口: \(.port) | 协议: \(.protocol) | 文件: \(.file)"' "$XRAY_META_FILE" 2>/dev/null || echo -e "${YELLOW}Xray 节点索引解析失败。${NC}"
else
  echo -e "${YELLOW}未检测到 Xray 节点配置。${NC}"
fi
if jq -e 'length > 0' "$SINGBOX_META_FILE" >/dev/null 2>&1; then
  jq -r '.[] | "【Sing-box】 端口: \(.port) | 协议: \(.protocol) | 文件: \(.file)"' "$SINGBOX_META_FILE" 2>/dev/null || echo -e "${YELLOW}Sing-box 节点索引解析失败。${NC}"
else
  echo -e "${YELLOW}未检测到 Sing-box 节点配置。${NC}"
fi
echo -e "\n${CYAN}--- 已保存的节点分享链接 ---${NC}"
local links=()
if [ -f "$NODE_RECORD_FILE" ]; then
mapfile -t links < "$NODE_RECORD_FILE"
if [ ${#links[@]} -eq 0 ]; then
echo -e "${YELLOW}暂无保存的分享链接。${NC}"
else
for i in "${!links[@]}"; do
local info
info=$(echo "${links[$i]}" | awk -F' \\| ' '{print $1" "$2}')
echo -e "  ${GREEN}$((i+1)).${NC} $info"
done
fi
else
echo -e "${YELLOW}暂无保存的分享链接记录。${NC}"
fi

echo -e "  [${GREEN}1-${#links[@]}${NC}] 输入编号：查看对应节点的二维码与完整链接"
echo -e "  [${GREEN}B${NC}] 备份：为所有节点配置文件创建快照\n  [${GREEN}R${NC}] 还原：从历史快照恢复节点配置\n  [${GREEN}0${NC}] 返回主菜单"
echo ""; read -r -p "> 请选择操作: " vn_opt
vn_opt="${vn_opt// /}"
if [ "$vn_opt" == "0" ]; then break; fi
if [[ "$vn_opt" =~ ^[0-9]+$ ]] && [ "$vn_opt" -ge 1 ] && [ "$vn_opt" -le "${#links[@]}" ]; then
local target_link
target_link=$(echo "${links[$((vn_opt-1))]}" | awk -F' \\| ' '{print $3}')
echo -e "\n${CYAN}>>> 节点分享链接：${NC}\n${target_link}\n"
echo -e "${YELLOW}>>> 节点二维码 (手机扫码)：${NC}"
qrencode -t UTF8 -s 1 -m 2 "$target_link"
pause_for_enter
elif [[ "$vn_opt" =~ ^[bB]$ ]]; then
if ! confirm_action "备份当前节点配置"; then continue; fi
local ts
ts=$(date +"%Y%m%d_%H%M%S")
local bk_path="${BACKUP_DIR}/node_backup_${ts}"
mkdir -p "$bk_path"
[ -f "$XRAY_CONFIG_FILE" ] && cp "$XRAY_CONFIG_FILE" "$bk_path/xray_config.json"
[ -f "$SINGBOX_CONFIG_FILE" ] && cp "$SINGBOX_CONFIG_FILE" "$bk_path/singbox_config.json"
[ -d "$XRAY_NODES_DIR" ] && cp -r "$XRAY_NODES_DIR" "$bk_path/xray_nodes.d"
[ -d "$SINGBOX_NODES_DIR" ] && cp -r "$SINGBOX_NODES_DIR" "$bk_path/singbox_nodes.d"
[ -f "$XRAY_META_FILE" ] && cp "$XRAY_META_FILE" "$bk_path/xray_nodes_meta.json"
[ -f "$SINGBOX_META_FILE" ] && cp "$SINGBOX_META_FILE" "$bk_path/singbox_nodes_meta.json"
[ -f "$NODE_RECORD_FILE" ] && cp "$NODE_RECORD_FILE" "$bk_path/vpsbox_nodes.txt"
echo -e "\n${GREEN}[成功] 节点配置已成功备份至: $bk_path ${NC}"; pause_for_enter
elif [[ "$vn_opt" =~ ^[rR]$ ]]; then
shopt -s nullglob; local n_backups=("${BACKUP_DIR}"/node_backup_*); shopt -u nullglob
if [ ${#n_backups[@]} -eq 0 ]; then echo -e "\n${RED}未找到节点备份记录。${NC}"; pause_for_enter; continue; fi
echo -e "\n${CYAN}请选择要还原的备份：${NC}"
for i in "${!n_backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份时间: $(basename "${n_backups[$i]}" | sed 's/node_backup_//')"; done
read -r -p "> 请输入编号 (0取消): " n_res_opt
n_res_opt="${n_res_opt// /}"
if [ "$n_res_opt" == "0" ]; then continue; fi
if [[ "$n_res_opt" =~ ^[0-9]+$ ]] && [ "$n_res_opt" -ge 1 ] && [ "$n_res_opt" -le "${#n_backups[@]}" ]; then
if ! confirm_action "还原此备份 (当前配置将被覆盖，并尝试热重载服务)" "n"; then continue; fi
local sel_bk="${n_backups[$((n_res_opt-1))]}"
local restore_notes=()
local restore_failed=0
if [ -d "$sel_bk/xray_nodes.d" ]; then
  rm -rf "$XRAY_NODES_DIR" && cp -r "$sel_bk/xray_nodes.d" "$XRAY_NODES_DIR"
fi
if [ -d "$sel_bk/singbox_nodes.d" ]; then
  rm -rf "$SINGBOX_NODES_DIR" && cp -r "$sel_bk/singbox_nodes.d" "$SINGBOX_NODES_DIR"
fi
if [ -f "$sel_bk/xray_nodes_meta.json" ]; then
  cp "$sel_bk/xray_nodes_meta.json" "$XRAY_META_FILE"
fi
if [ -f "$sel_bk/singbox_nodes_meta.json" ]; then
  cp "$sel_bk/singbox_nodes_meta.json" "$SINGBOX_META_FILE"
fi
[ -f "$sel_bk/xray_config.json" ] && cp "$sel_bk/xray_config.json" "$XRAY_CONFIG_FILE"
[ -f "$sel_bk/singbox_config.json" ] && cp "$sel_bk/singbox_config.json" "$SINGBOX_CONFIG_FILE"

if [ -d "$XRAY_NODES_DIR" ] || [ -f "$XRAY_CONFIG_FILE" ]; then
  if rebuild_core_config "Xray" >/dev/null 2>&1; then
    if _reload_core_without_disconnect "Xray" >/dev/null 2>&1; then
      restore_notes+=("Xray: 已恢复并热重载成功")
    else
      restore_notes+=("Xray: 配置已恢复，但热重载失败")
      restore_failed=1
    fi
  else
    restore_notes+=("Xray: 配置重建失败")
    restore_failed=1
  fi
fi

if [ -d "$SINGBOX_NODES_DIR" ] || [ -f "$SINGBOX_CONFIG_FILE" ]; then
  if rebuild_core_config "Sing-box" >/dev/null 2>&1; then
    if _reload_core_without_disconnect "Sing-box" >/dev/null 2>&1; then
      restore_notes+=("Sing-box: 已恢复并热重载成功")
    else
      restore_notes+=("Sing-box: 配置已恢复，但热重载失败")
      restore_failed=1
    fi
  else
    restore_notes+=("Sing-box: 配置重建失败")
    restore_failed=1
  fi
fi

[ -f "$sel_bk/vpsbox_nodes.txt" ] && cp "$sel_bk/vpsbox_nodes.txt" "$NODE_RECORD_FILE"

if [ ${#restore_notes[@]} -gt 0 ]; then
  echo ""
  printf '  - %s\n' "${restore_notes[@]}"
fi
if [ "$restore_failed" -eq 0 ]; then
  echo -e "\n${GREEN}[成功] 节点配置已还原，相关服务热重载成功。${NC}"; pause_for_enter
else
  echo -e "\n${YELLOW}[警告] 节点文件已还原，但部分核心的重建或热重载失败，请按上方结果检查。${NC}"; pause_for_enter
fi
else
echo -e "${RED}[错误] 输入无效编号！${NC}"; sleep 1
fi
else
echo -e "\n${RED}[错误] 输入无效，请重新选择！${NC}"; sleep 1
fi
done
}

delete_node() {
clear_screen; print_divider
print_center "[ 删除指定的已部署节点 ]" "$CYAN"
echo -e "正在扫描当前已部署的节点...\n"
local nodes_found=0
_ensure_node_meta_file "$XRAY_META_FILE"
_ensure_node_meta_file "$SINGBOX_META_FILE"
if jq -e 'length > 0' "$XRAY_META_FILE" >/dev/null 2>&1; then
echo -e "${CYAN}【Xray 节点】${NC}"
jq -r '.[] | "  - 端口: \(.port) | 协议: \(.protocol) | 文件: \(.file)"' "$XRAY_META_FILE" 2>/dev/null
nodes_found=1
fi
if jq -e 'length > 0' "$SINGBOX_META_FILE" >/dev/null 2>&1; then
echo -e "\n${CYAN}【Sing-box 节点】${NC}"
jq -r '.[] | "  - 端口: \(.port) | 协议: \(.protocol) | 文件: \(.file)"' "$SINGBOX_META_FILE" 2>/dev/null
nodes_found=1
fi
if [ "$nodes_found" -eq 0 ]; then echo -e "${YELLOW}未检测到任何已部署的节点，无需删除。${NC}"; pause_for_enter; return; fi
echo ""
while true; do
read -r -p "> 请输入要删除的节点【端口号】 (输入 0 取消): " del_port
del_port="${del_port// /}"
if [ "$del_port" == "0" ]; then return; fi
if [ -z "$del_port" ] || ! [[ "$del_port" =~ ^[0-9]+$ ]]; then echo -e "${RED}[错误] 端口号必须是有效的纯数字！请重新输入。${NC}"; continue; fi
local core_for_port=""
if jq -e --argjson port "$del_port" '.[] | select(.port == $port)' "$XRAY_META_FILE" >/dev/null 2>&1; then core_for_port="Xray"; fi
if jq -e --argjson port "$del_port" '.[] | select(.port == $port)' "$SINGBOX_META_FILE" >/dev/null 2>&1; then core_for_port="Sing-box"; fi
if [ -z "$core_for_port" ]; then echo -e "${RED}[错误] 当前部署中未找到端口为 $del_port 的节点，请检查！${NC}"; continue; fi
break
done
if ! confirm_action "永久删除端口为 $del_port 的节点" "n"; then pause_for_enter; return; fi
if remove_node_runtime "$core_for_port" "$del_port"; then
echo -e "${GREEN}[成功] 已成功移除 ${core_for_port} 中占用端口 $del_port 的节点配置，并完成无感热重载！${NC}"
else
echo -e "${RED}[错误] ${core_for_port} 节点删除失败，原有连接未被强制重启。${NC}"
fi
if [ -f "$NODE_RECORD_FILE" ]; then sed -i "/端口:${del_port} /d" "$NODE_RECORD_FILE" 2>/dev/null; fi
pause_for_enter
}

append_inbound() {
local NEW_INBOUND=$2; local TARGET_PORT=$3; local CORE_NAME=$4; local LABEL=$5; local PROTOCOL_NAME=$6; local LINK=$7
echo -e "${YELLOW}[系统] 正在写入独立节点片段并热重载 ${CORE_NAME}...${NC}"
if persist_node_runtime "$CORE_NAME" "$TARGET_PORT" "${LABEL:-Node}" "${PROTOCOL_NAME:-Node}" "$LINK" "$NEW_INBOUND"; then
    echo -e "${GREEN}  ✓ 节点片段写入成功，核心已无感热重载${NC}"
    return 0
fi
echo -e "${RED}[错误] 节点片段写入或热重载失败，已取消本次变更。${NC}"
return 1
}

select_core() {
    while true; do
        echo "" >&2
        echo "  ┌─────────────────────────────┐" >&2
        echo "  │      选择运行内核:          │" >&2
        echo "  │  1) Xray-core               │" >&2
        echo "  │  2) Sing-box                │" >&2
        echo "  └─────────────────────────────┘" >&2
        read -r -p "> 请输入 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return 1; fi
        [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" == "1" || "$core_choice" == "2" ]]; then
            echo "$core_choice"
            return 0
        fi
    done
}

# 统一输出节点部署结果 (修改版：先输出并保存记录，防止后续断网导致信息丢失)
output_node_result() {
    local LINK=$1
    local LABEL=$2
    local PORT=$3
    local CORE_NAME=$4
    local PROTOCOL_NAME=${5:-$LABEL}

    echo -e "\n${GREEN}[成功] ${LABEL} 节点配置已生成！${NC}"
    echo -e "核心服务: ${CYAN}${CORE_NAME}${NC}"
    echo -e "节点链接:\n${CYAN}${LINK}${NC}\n"
    echo -e "${YELLOW}>>> 扫描下方二维码快速导入节点：${NC}"
    qrencode -t UTF8 -s 1 -m 2 "$LINK"
    
    # 持久化记录
    sed -i "/端口:${PORT} /d" "$NODE_RECORD_FILE" 2>/dev/null
    echo "${CORE_NAME}-${LABEL} | 端口:${PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
}

install_reality_node() {
clear_screen; print_divider
print_center "[ 部署 VLESS-Reality 节点 ]" "$CYAN"
_ensure_ip
echo -e "${YELLOW}>>> 小白科普：VLESS-Reality 是一种先进的伪装技术。不需要您购买域名，直接借用大厂（如苹果、微软）的域名进行伪装，安全性极高，非常适合防封锁。${NC}\n"

while true; do
read -r -p "> 请输入监听端口 (默认 50000, 0 取消): " PORT
PORT="${PORT// /}"
if [ "$PORT" == "0" ]; then return; fi; [ -z "$PORT" ] && PORT=50000
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then echo -e "${RED}[错误] 端口号必须是 1 到 65535 之间的纯数字！请重新输入。${NC}"; continue; fi
if ss -tulpn | grep -qE ":${PORT}[[:space:]]|:${PORT}$"; then echo -e "${RED}[错误] 端口 $PORT 已被占用！${NC}"; continue; fi
break
done
core_choice=$(select_core) || return
echo -e "\n  ${GREEN}1.${NC} gateway.icloud.com (苹果官网)\n  ${GREEN}2.${NC} www.microsoft.com (微软官网)"
read -r -p "> 选择伪装 SNI [输入 1-2 选择，或直接输入自定义域名, 默认 1, 0 取消]: " sni_choice
sni_choice="${sni_choice// /}"
if [ "$sni_choice" == "0" ]; then return; fi
if [[ -z "$sni_choice" || "$sni_choice" == "1" ]]; then SNI_DOMAIN="gateway.icloud.com"; elif [[ "$sni_choice" == "2" ]]; then SNI_DOMAIN="www.microsoft.com"; else SNI_DOMAIN="$sni_choice"; fi
if ! confirm_action "开始部署 Reality 节点"; then pause_for_enter; return; fi
install_dependencies
UUID=$(cat /proc/sys/kernel/random/uuid); SHORT_ID=$(openssl rand -hex 8)
LINK_IP="$SERVER_IP"
if [ "$SERVER_IPV4" == "未分配" ] && [ "$SERVER_IPV6" != "未分配" ]; then 
    echo -e "${YELLOW}[提示] IPv4 未分配，自动使用 IPv6: [${SERVER_IPV6}]${NC}"
    LINK_IP="[${SERVER_IPV6}]"
fi
if [ "$core_choice" == "1" ]; then
CORE_NAME="Xray"
if ! command -v xray &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Xray 核心，请耐心等待...${NC}"; _run_remote_bash https://github.com/XTLS/Xray-install/raw/main/install-release.sh install > /dev/null 2>&1; hash -r; command -v xray &>/dev/null || { echo -e "\n${RED}[错误] Xray 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
X_BIN=$(command -v xray || echo "/usr/local/bin/xray"); KEYS=$("$X_BIN" x25519)
PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
NEW_INBOUND='{"port":'$PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"'$SNI_DOMAIN':443","serverNames":["'$SNI_DOMAIN'"],"privateKey":"'$PRI'","shortIds":["'$SHORT_ID'"]}}}'
else
CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心，请耐心等待...${NC}"; _run_remote_bash https://sing-box.app/install.sh > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box"); KEYS=$("$SB_BIN" generate reality-keypair)
PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$PORT',"users":[{"uuid":"'$UUID'","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"'$SNI_DOMAIN'","reality":{"enabled":true,"handshake":{"server":"'$SNI_DOMAIN'","server_port":443},"private_key":"'$PRI'","short_id":["'$SHORT_ID'"]}}}'
fi

LINK="vless://${UUID}@${LINK_IP}:${PORT}?encryption=none&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&flow=xtls-rprx-vision#R"

if append_inbound "$(_config_file_for_core "$CORE_NAME")" "$NEW_INBOUND" "$PORT" "$CORE_NAME" "Reality" "vless-reality" "$LINK"; then
    output_node_result "$LINK" "Reality" "$PORT" "$CORE_NAME" "vless-reality"
    echo -e "\n${GREEN}>>> 已通过独立端口配置文件完成接入，并执行无感热重载。旧连接不会因新增节点被整体重启。${NC}"
else
    echo -e "\n${RED}[错误] 配置校验失败 — 生成的 JSON 不符合要求，未修改任何文件。${NC}"
fi
pause_for_enter
}

install_anytls_node() {
clear_screen; print_divider
print_center "[ 部署 AnyTLS 节点 ]" "$CYAN"
_ensure_ip
echo -e "${YELLOW}>>> 小白科普：AnyTLS 是 sing-box 专属协议。使用自有域名 + Let's Encrypt 真证书，密码认证。${NC}\n"

while true; do
read -r -p "> 请输入域名 (输入 0 取消): " DOMAIN
DOMAIN="${DOMAIN// /}"
if [ "$DOMAIN" == "0" ]; then return; fi
if [ -z "$DOMAIN" ]; then continue; fi
DOMAIN_IP=$(_domain_resolution_summary "$DOMAIN")
break
done

echo -e "\n${CYAN}>>> 证书申请模式选择${NC}"
echo -e "  ${GREEN}1.${NC} 【API模式】使用 Cloudflare API 申请\n  ${GREEN}2.${NC} 【独立模式】使用常规 80 端口申请"
while true; do
read -r -p "> 选择模式 [1-2, 默认 2, 0 取消]: " cert_mode
cert_mode="${cert_mode// /}"
if [ "$cert_mode" == "0" ]; then return; fi; [ -z "$cert_mode" ] && cert_mode=2
if [[ "$cert_mode" != "1" && "$cert_mode" != "2" ]]; then continue; fi
if [ "$cert_mode" == "1" ]; then
    read -r -s -p "> CF API Token: " CF_Token; echo ""; [ -z "$CF_Token" ] && continue
    export CF_Token="$CF_Token"; break
else
    if [ -n "$DOMAIN_IP" ] && ! _domain_points_to_server "$DOMAIN"; then
        echo -e "\n${YELLOW}[警告] 域名解析结果 ($DOMAIN_IP) 与本机 IP 不符！${NC}"
        echo -e "${YELLOW}  ⚠️  可能开了 CF 小黄云，请关闭代理或换 API 模式。${NC}"
        read -r -p "> 强行继续？(y/n): " force_continue
        [[ ! "${force_continue// /}" =~ ^[yY]$ ]] && continue
    fi
    break
fi
done

while true; do
read -r -p "> 监听端口 (默认 443, 0 取消): " PORT
PORT="${PORT// /}"
if [ "$PORT" == "0" ]; then return; fi; [ -z "$PORT" ] && PORT=443
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then continue; fi
if ss -tulpn | grep -qE ":${PORT}[[:space:]]|:${PORT}$"; then echo -e "${RED}端口 $PORT 已被占用！${NC}"; continue; fi
break
done

if ! confirm_action "开始部署 AnyTLS 并申请证书"; then pause_for_enter; return; fi
acquire_cert "$DOMAIN" "$cert_mode" "$CF_Token" "" || { pause_for_enter; return; }
if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
    echo -e "\n${RED}[错误] 证书文件缺失: $CERT_DIR/${NC}"; ls -la "$CERT_DIR/" 2>/dev/null; pause_for_enter; return
fi

CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心...${NC}"; _run_remote_bash https://sing-box.app/install.sh > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败。${NC}"; pause_for_enter; return; }; fi

PASSWORD=$(openssl rand -base64 12 | tr -d '+/=' | head -c 16)
NEW_INBOUND='{"type":"anytls","listen":"::","listen_port":'$PORT',"users":[{"password":"'$PASSWORD'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
LINK="anytls://${PASSWORD}@${DOMAIN}:${PORT}?peer=${DOMAIN}#AnyTLS-${PORT}"

if append_inbound "$(_config_file_for_core "$CORE_NAME")" "$NEW_INBOUND" "$PORT" "$CORE_NAME" "AnyTLS" "anytls" "$LINK"; then
    output_node_result "$LINK" "AnyTLS" "$PORT" "$CORE_NAME" "anytls"
    echo -e "\n${GREEN}>>> 已通过独立端口配置文件完成接入，并执行无感热重载。${NC}"
else
    echo -e "\n${RED}[错误] 配置校验失败。${NC}"
fi
pause_for_enter
}

# =====================================================================
# 统一证书申请函数 (修复版 v1.3: 按域名分离 CERT_DIR + 彻底清理失败残留)
# =====================================================================
acquire_cert() {
    local DOMAIN="$1"
    local cert_mode="$2"
    local CF_Token="$3"
    local acme_domain_dir="/root/.acme.sh/${DOMAIN}_ecc"

    cert_matches_domain() {
        local cert_file="$1" domain="$2"
        [ -f "$cert_file" ] || return 1
        openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -Eq "DNS:(\*\.)?${domain//./\\.}([,[:space:]]|$)"
    }

    # 按域名分离证书目录，杜绝不同域名复用同一证书
    CERT_DIR="/etc/vpsbox-cert/${DOMAIN}"
    mkdir -p "$CERT_DIR"

    install_dependencies
    [ ! -d "/root/.acme.sh" ] && _run_remote_bash https://get.acme.sh email=dummy@vpsbox.com >/dev/null 2>&1
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then echo -e "\n${RED}[错误] Acme.sh 安装失败！${NC}"; return 1; fi
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m dummy@vpsbox.com >/dev/null 2>&1
    echo -e "\n${CYAN}>>> 正在为 ${YELLOW}${DOMAIN}${CYAN} 申请 SSL 证书...${NC}\n${YELLOW}   DNS 验证可能需要 30-60 秒，请耐心等待${NC}"

    local CERT_RES=1

    # 修复：不仅看 acme.sh list 还要检查物理文件 + 目标目录证书有效性
    if [ -d "$acme_domain_dir" ] && [ -f "$acme_domain_dir/${DOMAIN}.cer" ]; then
            # 进一步验证：目标 CERT_DIR 中的证书是否存在且属于该域名
            if cert_matches_domain "$CERT_DIR/fullchain.pem" "$DOMAIN"; then
                echo -e "${GREEN}[成功] 检测到本地有效证书（域名匹配），复用机制触发！${NC}"
                CERT_RES=0
            else
                echo -e "${YELLOW}[提示] 检测到 acme.sh 证书记录但目标证书目录不匹配，将重新安装证书到 ${CERT_DIR}${NC}"
            fi
    elif [ -d "$acme_domain_dir" ]; then
        echo -e "${YELLOW}[警告] 检测到损坏的历史证书记录，正在深度清理并重新申请...${NC}"
        /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
        rm -rf "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"
    fi

    if [ "$CERT_RES" -ne 0 ]; then
        if [ "$cert_mode" == "1" ]; then
            export CF_Token="$CF_Token"
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256; CERT_RES=$?
        else
            if ss -tlnp | grep -q "\b:80\b"; then
                echo -e "\n${RED}[错误] 检测到 80 端口已被占用，独立模式不会再强行停服务或杀进程。${NC}"
                echo -e "${YELLOW}请先手动释放 80 端口，或改用 Cloudflare API 模式申请证书。${NC}"
                ss -tlnp | grep "\b:80\b" || true
                return 1
            fi
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; CERT_RES=$?
        fi
    fi

    # 修复：移除死条件 (CERT_RES 永不为 2)，直接判断是否失败
    if [ "$CERT_RES" -ne 0 ]; then
        echo -e "\n${RED}[错误] 证书申请失败，彻底清理所有残留以防后续无限复用错误记录。${NC}"
        # 清理 acme.sh 记录
        /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
        rm -rf "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"
        # 清理目标证书目录（防止旧证书被下一个部署复用）
        rm -rf "$CERT_DIR"
        return 1
    fi

    echo -e "\n${CYAN}>>> 正在安装证书到 ${CERT_DIR}...${NC}"
    local INSTALL_OUT; INSTALL_OUT=$(mktemp)
    if /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --key-file "$CERT_DIR/privkey.pem" \
        >"$INSTALL_OUT" 2>&1; then
        cat "$INSTALL_OUT"; rm -f "$INSTALL_OUT"
        echo -e "${GREEN}[成功] 证书已安装至 ${CERT_DIR}${NC}"
    else
        echo -e "\n${RED}[错误] 证书安装失败，acme.sh 输出:${NC}"
        cat "$INSTALL_OUT"; rm -f "$INSTALL_OUT"
        # 安装失败也要清理目标目录，防止残留
        rm -rf "$CERT_DIR"
        return 1
    fi

    if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -dates 2>/dev/null; then
        echo -e "${RED}[错误] 证书文件无效或格式错误${NC}"
        rm -rf "$CERT_DIR"
        return 1
    fi
    if ! cert_matches_domain "$CERT_DIR/fullchain.pem" "$DOMAIN"; then
        echo -e "${RED}[错误] 证书 SAN 与目标域名不匹配: ${DOMAIN}${NC}"
        rm -rf "$CERT_DIR"
        return 1
    fi
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem; chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    return 0
}

install_ws_tls_node() {
clear_screen; print_divider
print_center "[ 部署 VLESS-WS-TLS 节点 ]" "$CYAN"
echo -e "${YELLOW}>>> 小白科普：WS+TLS 是非常经典的节点协议。最大的优势是可以搭配 Cloudflare 等 CDN 使用。如果您服务器的 IP 已经被墙，用这个协议配合 CDN 就能起死回生。${NC}\n"

while true; do
read -r -p "> 请输入域名 (输入 0 取消): " DOMAIN
DOMAIN="${DOMAIN// /}"
if [ "$DOMAIN" == "0" ]; then return; fi
if [ -z "$DOMAIN" ]; then continue; fi
DOMAIN_IP=$(_domain_resolution_summary "$DOMAIN")
break
done
while true; do
read -r -p "> 监听端口 (默认 443, 0 取消): " WS_PORT
WS_PORT="${WS_PORT// /}"
if [ "$WS_PORT" == "0" ]; then return; fi; [ -z "$WS_PORT" ] && WS_PORT=443
if ! [[ "$WS_PORT" =~ ^[0-9]+$ ]] || [ "$WS_PORT" -lt 1 ] || [ "$WS_PORT" -gt 65535 ]; then continue; fi
if ss -tulpn | grep -qE ":${WS_PORT}[[:space:]]|:${WS_PORT}$"; then echo -e "${RED}端口 $WS_PORT 已被占用！${NC}"; continue; fi
break
done
core_choice=$(select_core) || return
echo -e "\n${YELLOW}>>> 如何获取 Cloudflare API Token？${NC}"
echo -e "  ${GREEN}1.${NC} 登录 Cloudflare 控制台: https://dash.cloudflare.com"
echo -e "  ${GREEN}2.${NC} 点击右上角头像 →「我的个人资料」→「API 令牌」"
echo -e "  ${GREEN}3.${NC} 点击「创建令牌」→ 选择「编辑区域 DNS」模板"
echo -e "  ${GREEN}4.${NC} 权限选「区域 - DNS - 编辑」，区域选你的域名，创建后复制 Token"
echo ""
while true; do
read -r -s -p "> 请输入您的 Cloudflare API Token (输入 0 取消): " CF_Token
echo ""
CF_Token="${CF_Token// /}"
if [ "$CF_Token" == "0" ]; then return; fi
if [ -z "$CF_Token" ]; then continue; fi
export CF_Token="$CF_Token"; break
done
cert_mode=1
if ! confirm_action "开始部署 WS+TLS 节点并申请证书"; then pause_for_enter; return; fi
acquire_cert "$DOMAIN" "$cert_mode" "$CF_Token" "" || { pause_for_enter; return; }
UUID=$(cat /proc/sys/kernel/random/uuid); WSPATH="/$(openssl rand -hex 4)"
if [ "$core_choice" == "1" ]; then
CORE_NAME="Xray"
if ! command -v xray &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Xray 核心，请耐心等待...${NC}"; _run_remote_bash https://github.com/XTLS/Xray-install/raw/main/install-release.sh install > /dev/null 2>&1; hash -r; command -v xray &>/dev/null || { echo -e "\n${RED}[错误] Xray 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"port":'$WS_PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"wsSettings":{"path":"'$WSPATH'"}}}'
else
CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心，请耐心等待...${NC}"; _run_remote_bash https://sing-box.app/install.sh > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$WS_PORT',"users":[{"uuid":"'$UUID'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"},"transport":{"type":"ws","path":"'$WSPATH'"}}'
fi

LINK="vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&alpn=h2%2Chttp%2F1.1&type=ws&host=${DOMAIN}&path=${WSPATH}#WS"

if append_inbound "$(_config_file_for_core "$CORE_NAME")" "$NEW_INBOUND" "$WS_PORT" "$CORE_NAME" "WS-TLS" "vless-ws-tls" "$LINK"; then
    output_node_result "$LINK" "WS-TLS" "$WS_PORT" "$CORE_NAME" "vless-ws-tls"
    echo -e "\n${GREEN}>>> 已通过独立端口配置文件完成接入，并执行无感热重载。${NC}"
else
    echo -e "\n${RED}[错误] 配置校验失败。${NC}"
fi

echo ""
echo -e "${YELLOW}>>> 小白提示：必须开启 Cloudflare 小黄云（CDN 代理）${NC}"
echo -e "  WS-TLS 搭配 CDN 优选才能发挥最佳效果。开启后："
echo -e "     ✅ 隐藏真实服务器 IP，防 DDoS 攻击"
echo -e "     ✅ 被墙的 IP 能「起死回生」"
echo -e "     🔧 操作：CF 控制台 → DNS 记录 → 编辑 → 代理状态打开（橙色云朵）"
echo -e "  ⚠️  记得在 CF 的 SSL/TLS 设置中开启「完全（严格）」模式"
echo ""
pause_for_enter
}

install_hy2_node() {
clear_screen; print_divider
print_center "[ 部署 Hysteria2 节点 ]" "$CYAN"
_ensure_ip
echo -e "${YELLOW}>>> 小白科普：Hysteria2 是一种基于 UDP 协议的暴力加速代理方案。如果您的服务器到国内的线路非常差（比如晚高峰卡顿），这个协议能无视拥塞强行拉满网速，体验飞跃！${NC}\n"

while true; do
read -r -p "> 请输入域名 (输入 0 取消): " DOMAIN
DOMAIN="${DOMAIN// /}"
if [ "$DOMAIN" == "0" ]; then return; fi
if [ -z "$DOMAIN" ]; then continue; fi
DOMAIN_IP=$(_domain_resolution_summary "$DOMAIN")
break
done
while true; do
read -r -p "> 监听端口 (默认 8443, 0 取消): " HY2_PORT
HY2_PORT="${HY2_PORT// /}"
if [ "$HY2_PORT" == "0" ]; then return; fi; [ -z "$HY2_PORT" ] && HY2_PORT=8443
if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || [ "$HY2_PORT" -lt 1 ] || [ "$HY2_PORT" -gt 65535 ]; then continue; fi
if ss -tulpn | grep -qE ":${HY2_PORT}[[:space:]]|:${HY2_PORT}$"; then echo -e "${RED}端口 $HY2_PORT 已被占用！${NC}"; continue; fi
break
done
core_choice=$(select_core) || return
echo -e "\n${CYAN}>>> 证书申请模式选择${NC}"
echo -e "  ${GREEN}1.${NC} 【API模式】使用 Cloudflare API 申请\n  ${GREEN}2.${NC} 【独立模式】使用常规 80 端口申请"
while true; do
read -r -p "> 选择模式 [1-2, 默认 2, 0 取消]: " cert_mode
cert_mode="${cert_mode// /}"
if [ "$cert_mode" == "0" ]; then return; fi; [ -z "$cert_mode" ] && cert_mode=2
if [[ "$cert_mode" != "1" && "$cert_mode" != "2" ]]; then continue; fi
if [ "$cert_mode" == "1" ]; then
echo -e "\n${YELLOW}>>> 如何获取 Cloudflare API Token？${NC}"
echo -e "  ${GREEN}1.${NC} 登录 Cloudflare 控制台: https://dash.cloudflare.com"
echo -e "  ${GREEN}2.${NC} 点击右上角头像 →「我的个人资料」→「API 令牌」"
echo -e "  ${GREEN}3.${NC} 点击「创建令牌」→ 选择「编辑区域 DNS」模板"
echo -e "  ${GREEN}4.${NC} 权限选「区域 - DNS - 编辑」，区域选你的域名，创建后复制 Token"
echo ""
read -r -s -p "> 请输入您的 Cloudflare API Token: " CF_Token
echo ""
if [ -z "$CF_Token" ]; then continue; fi
export CF_Token="$CF_Token"; break
elif [ "$cert_mode" == "2" ]; then
if [ -n "$DOMAIN_IP" ] && ! _domain_points_to_server "$DOMAIN"; then 
echo -e "\n${YELLOW}[警告] 域名解析结果 ($DOMAIN_IP) 与本机 IP 不符！${NC}"
echo -e "${YELLOW}  ⚠️  可能开启了 Cloudflare 小黄云，Hysteria2 无法通过 CDN 代理！${NC}"
echo -e "${YELLOW}  请去 CF 控制台关闭该域名的代理（改为灰色云朵），或者换用 API 模式申请证书。${NC}"
read -r -p "> 是否强行继续？(y/n, 默认 n): " force_continue
if [[ ! "${force_continue// /}" =~ ^[yY]$ ]]; then continue; fi
fi
break
fi
done
if ! confirm_action "开始部署 Hysteria2 节点并申请证书"; then pause_for_enter; return; fi
acquire_cert "$DOMAIN" "$cert_mode" "$CF_Token" "" || { pause_for_enter; return; }
HY2_PASS=$(openssl rand -hex 8)
if [ "$core_choice" == "1" ]; then
CORE_NAME="Xray"
if ! command -v xray &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Xray 核心，请耐心等待...${NC}"; _run_remote_bash https://github.com/XTLS/Xray-install/raw/main/install-release.sh install > /dev/null 2>&1; hash -r; command -v xray &>/dev/null || { echo -e "\n${RED}[错误] Xray 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"listen":"0.0.0.0","port":'$HY2_PORT',"protocol":"hysteria2","settings":{"password":"'$HY2_PASS'"},"streamSettings":{"network":"udp","security":"tls","tlsSettings":{"serverName":"'$DOMAIN'","alpn":["h3"],"minVersion":"1.3","certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]}}}'
else
CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心，请耐心等待...${NC}"; _run_remote_bash https://sing-box.app/install.sh > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"type":"hysteria2","listen":"::","listen_port":'$HY2_PORT',"users":[{"password":"'$HY2_PASS'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
fi

LINK="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#H2"

if append_inbound "$(_config_file_for_core "$CORE_NAME")" "$NEW_INBOUND" "$HY2_PORT" "$CORE_NAME" "Hys2" "hysteria2" "$LINK"; then
    output_node_result "$LINK" "Hys2" "$HY2_PORT" "$CORE_NAME" "hysteria2"
    echo -e "\n${GREEN}>>> 已通过独立端口配置文件完成接入，并执行无感热重载。${NC}"
else
    echo -e "\n${RED}[错误] 配置校验失败。${NC}"
fi

echo ""
echo -e "${YELLOW}>>> 小白提示：不要开启 Cloudflare 小黄云！${NC}"
echo -e "  Hysteria2 基于 UDP 协议，无法通过 CDN 代理。"
echo -e "  DNS 解析必须指向服务器真实 IP（灰色云朵），否则无法连接。"
echo ""
pause_for_enter
}

install_warp() {
clear_screen; print_divider
print_center "[ Cloudflare WARP 一键解锁 ]" "$CYAN"
if ! confirm_action "部署 Cloudflare WARP"; then pause_for_enter; return; fi
install_dependencies
echo -e "\n${CYAN}>>> 正在启动 WARP 脚本...${NC}\n${YELLOW}   脚本下载与安装可能需要 1-2 分钟，请耐心等待${NC}"
if wget -P /tmp https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/menu.sh 2>/dev/null; then
    bash /tmp/menu.sh || true
else
    echo -e "\n${RED}[错误] WARP 脚本下载失败，请检查网络。${NC}"
fi
pause_for_enter
}

manage_ufw() {
while true; do
clear_screen; print_divider
print_center "[ UFW 防火墙端口管理 ]" "$CYAN"
if ! command -v ufw &> /dev/null; then
echo -e "${YELLOW}[系统] 正在自动安装 UFW 防火墙...${NC}"
if command -v apt &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >/dev/null 2>&1
elif command -v dnf &>/dev/null; then dnf install -y ufw >/dev/null 2>&1
elif command -v yum &>/dev/null; then yum install -y ufw >/dev/null 2>&1
elif command -v apk &>/dev/null; then apk add ufw >/dev/null 2>&1
elif command -v pacman &>/dev/null; then pacman -S --noconfirm ufw >/dev/null 2>&1
elif command -v zypper &>/dev/null; then zypper install -y ufw >/dev/null 2>&1
fi || echo -e "${RED}[错误] UFW 安装失败。${NC}"
_svc_stop netfilter-persistent 2>/dev/null
while iptables -L INPUT -n --line-numbers 2>/dev/null | grep -q "REJECT"; do
    local N
    N=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep "REJECT" | head -1 | awk '{print $1}')
    iptables -D INPUT "$N" 2>/dev/null
done
fi
install_dependencies
echo -e "  ${GREEN}1.${NC} 查看当前防火墙状态与已放行端口\n  ${GREEN}2.${NC} 放行指定新端口 (TCP/UDP)\n  ${GREEN}3.${NC} 删除某个端口规则\n  ${GREEN}4.${NC} 开启防火墙\n  ${GREEN}5.${NC} 彻底关闭防火墙\n  ${GREEN}6.${NC} 一键仅放行正在使用的端口 (关闭所有未占用)\n  ${GREEN}7.${NC} 一键打开所有入站端口\n  ${GREEN}0.${NC} 返回主菜单"
echo ""
read -r -p "> 请选择操作 [0-7]: " ufw_opt
ufw_opt="${ufw_opt// /}"
case $ufw_opt in
1) echo -e "\n${CYAN}>>> 防火墙状态：${NC}"; ufw status numbered || echo -e "${RED}[错误] 读取状态失败。${NC}"; pause_for_enter ;;
2)
read -r -p "> 请输入要放行的端口号: " port
port="${port// /}"
if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then ufw allow "$port"; echo -e "${GREEN}[成功] 端口 $port 已成功添加放行规则！${NC}"; ufw reload > /dev/null 2>&1; else echo -e "${RED}[错误] 端口号输入无效！${NC}"; fi
pause_for_enter ;;
3)
echo -e "\n${CYAN}>>> 当前规则列表：${NC}"; ufw status numbered; echo ""
read -r -p "> 请输入要删除的【规则编号】: " rule_num
rule_num="${rule_num// /}"
if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
  if ufw --force delete "$rule_num"; then
    echo -e "${GREEN}[成功] 规则 $rule_num 已删除。${NC}"
  else
    echo -e "${RED}[错误] 删除规则失败。${NC}"
  fi
fi
pause_for_enter ;;
4)
if ! confirm_action "开启防火墙并默认拦截外部访问 (系统将自动防呆放行 SSH)"; then continue; fi
CURRENT_SSH_PORT=$(ss -tlnp | grep -w sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=22
echo -e "\n${CYAN}>>> 检测到当前 SSH 登录端口为: ${CURRENT_SSH_PORT}${NC}"
ufw default deny incoming > /dev/null 2>&1; ufw default allow outgoing > /dev/null 2>&1
ufw allow "$CURRENT_SSH_PORT"/tcp > /dev/null 2>&1
ufw --force enable || { echo -e "\n${RED}[错误] 开启防火墙失败。${NC}"; pause_for_enter; continue; }
echo -e "\n${GREEN}[成功] 防火墙已成功开启！当前 SSH 端口 $CURRENT_SSH_PORT 已安全放行。${NC}"; pause_for_enter ;;
5)
if ! confirm_action "彻底关闭防火墙" "n"; then continue; fi
ufw disable || { echo -e "${RED}[错误] 关闭防火墙失败。${NC}"; pause_for_enter; continue; }
echo -e "${GREEN}[成功] 防火墙已完全关闭！${NC}"; pause_for_enter ;;
6)
if ! confirm_action "⚠️ 重置所有规则，仅放行正在使用的端口 (之前手动加的规则会丢失)"; then continue; fi
SSHPORT=$(ss -tlnp 2>/dev/null | grep -w sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
[ -z "$SSHPORT" ] && SSHPORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$SSHPORT" ] && SSHPORT=22
echo -e "\n${CYAN}>>> 检测到 SSH 端口: ${SSHPORT}${NC}"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw allow "$SSHPORT"/tcp > /dev/null 2>&1
echo -e "${GREEN}  ✓ 放行 SSH: ${SSHPORT}/tcp${NC}"
USED_LISTENS=$(_collect_public_listen_entries)
while read -r proto p; do
  [ -z "$proto" ] && continue
  [ -z "$p" ] && continue
  [ "$p" = "$SSHPORT" ] && continue
  case "$proto" in
    tcp)
      ufw allow "$p/tcp" > /dev/null 2>&1 && echo -e "${GREEN}  ✓ 放行 TCP 端口: ${p}${NC}" || echo -e "${YELLOW}  - TCP 端口 ${p} 放行失败${NC}"
      ;;
    udp)
      ufw allow "$p/udp" > /dev/null 2>&1 && echo -e "${GREEN}  ✓ 放行 UDP 端口: ${p}${NC}" || echo -e "${YELLOW}  - UDP 端口 ${p} 放行失败${NC}"
      ;;
  esac
done <<< "$USED_LISTENS"
ufw --force enable > /dev/null 2>&1
ufw reload > /dev/null 2>&1
echo -e "\n${GREEN}[成功] 防火墙已重新配置！仅放行正在使用的端口。${NC}"
pause_for_enter ;;
7)
if ! confirm_action "打开所有入站端口 (⚠️ 安全风险)"; then continue; fi
ufw --force reset > /dev/null 2>&1
ufw default allow incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
ufw reload > /dev/null 2>&1
echo -e "\n${GREEN}[成功] 所有入站端口已全部打开！${NC}"
pause_for_enter ;;
0) break ;;
*) echo -e "\n${RED}输入无效！${NC}"; sleep 1 ;;
esac
done
}

tools_manager() {
local TOOL_LIST=(
  "1|curl|curl   HTTP下载工具 ★"
  "2|wget|wget   后台下载工具 ★"
  "3|sudo|sudo   超级权限工具"
  "4|socat|socat  通信连接工具"
  "5|htop|htop   系统资源监控"
  "6|iftop|iftop  网络流量监控"
  "7|unzip|unzip  ZIP解压工具"
  "8|tar|tar    GZ压缩解压"
  "9|tmux|tmux   多窗口后台"
  "10|ffmpeg|ffmpeg 视频编码工具"
  "11|btop|btop  现代化监控 ★"
  "12|ranger|ranger 终端文件管理"
  "13|ncdu|ncdu  磁盘占用分析"
  "14|fzf|fzf   全局模糊搜索"
  "15|vim|vim   文本编辑器"
  "16|nano|nano  文本编辑器 ★"
  "17|git|git   版本控制系统"
)

_tool_cmd()  { echo "${TOOL_LIST[$1-1]}" | cut -d'|' -f2; }
_tool_desc() { echo "${TOOL_LIST[$1-1]}" | cut -d'|' -f3; }

while true; do
clear_screen; print_divider
print_center "[ 基础工具箱 ]" "$CYAN"

local PM="未知"
command -v apt    &>/dev/null && PM="apt"
command -v dnf    &>/dev/null && PM="dnf"
command -v yum    &>/dev/null && PM="yum"
command -v apk    &>/dev/null && PM="apk"
command -v pacman &>/dev/null && PM="pacman"
echo -e "  包管理器: ${CYAN}${PM}${NC}\n"

local i=1
while [ $i -le 17 ]; do
  local id1=$i
  local id2=$((i+1))
  local cmd1; cmd1=$(_tool_cmd $id1)
  local desc1; desc1=$(_tool_desc $id1)
  local s1; command -v "$cmd1" &>/dev/null && s1="${GREEN}✅${NC}" || s1="${RED}❌${NC}"
  local left; left=$(printf "  ${CYAN}%2d.${NC} %-26s %b" "$id1" "$desc1" "$s1")

  if [ $id2 -le 17 ]; then
    local cmd2; cmd2=$(_tool_cmd $id2)
    local desc2; desc2=$(_tool_desc $id2)
    local s2; command -v "$cmd2" &>/dev/null && s2="${GREEN}✅${NC}" || s2="${RED}❌${NC}"
    echo -e "${left}    ${CYAN}${id2}.${NC} ${desc2} ${s2}"
  else
    echo -e "${left}"
  fi
  i=$((i+2))
done

echo ""
echo -e "  ─────────────────────────────────────────────────────"
echo -e "  ${GREEN}18.${NC} 全部安装           ${GREEN}19.${NC} 全部卸载"
echo -e "  ─────────────────────────────────────────────────────"
echo -e "  ${GREEN} 0.${NC} 返回主菜单"
echo ""
echo -ne "  ${YELLOW}[提示] 直接输入序号安装，输入 d+序号 卸载 (如 d6 卸载 iftop)${NC}\n"
read -r -p "> 请输入选择: " t_opt
t_opt="${t_opt// /}"

if [[ "$t_opt" =~ ^[dD]([0-9]+)$ ]]; then
  local _uninst_idx=${BASH_REMATCH[1]}
  if [ "$_uninst_idx" -ge 1 ] && [ "$_uninst_idx" -le 17 ]; then
    local _uninst_name; _uninst_name=$(_tool_cmd "$_uninst_idx")
    if ! confirm_action "卸载 ${_uninst_name}" "n"; then continue; fi
    echo -e "\n${CYAN}>>> 卸载 ${_uninst_name}...${NC}"
    _pkg_remove "$_uninst_name"
    echo -e "\n${GREEN}[完成]${NC}"; pause_for_enter; continue
  fi
fi

case $t_opt in
1)  echo -e "\n${CYAN}>>> 安装 curl...${NC}"; _pkg_install curl
    echo -e "\n${GREEN}[完成]${NC} 版本: $(curl --version 2>/dev/null | head -1)"; pause_for_enter ;;
2)  echo -e "\n${CYAN}>>> 安装 wget...${NC}"; _pkg_install wget
    echo -e "\n${GREEN}[完成]${NC} 版本: $(wget --version 2>/dev/null | head -1)"; pause_for_enter ;;
3)  echo -e "\n${CYAN}>>> 安装 sudo...${NC}"; _pkg_install sudo
    echo -e "\n${GREEN}[完成]${NC}"; pause_for_enter ;;
4)  echo -e "\n${CYAN}>>> 安装 socat...${NC}"; _pkg_install socat
    echo -e "\n${GREEN}[完成]${NC} 版本: $(socat -V 2>/dev/null | head -1)"; pause_for_enter ;;
5)  echo -e "\n${CYAN}>>> 安装 htop...${NC}"; _pkg_install htop
    echo -e "\n${GREEN}[完成] 输入 htop 启动监控。${NC}"; pause_for_enter ;;
6)  echo -e "\n${CYAN}>>> 安装 iftop...${NC}"; _pkg_install iftop
    echo -e "\n${GREEN}[完成] 输入 iftop 启动网络监控（需 root）。${NC}"; pause_for_enter ;;
7)  echo -e "\n${CYAN}>>> 安装 unzip...${NC}"; _pkg_install unzip
    echo -e "\n${GREEN}[完成]${NC}"; pause_for_enter ;;
8)  echo -e "\n${CYAN}>>> 安装 tar...${NC}"; _pkg_install tar
    echo -e "\n${GREEN}[完成]${NC}"; pause_for_enter ;;
9)  echo -e "\n${CYAN}>>> 安装 tmux...${NC}"; _pkg_install tmux
    echo -e "\n${GREEN}[完成] 输入 tmux 启动多窗口终端。${NC}"; pause_for_enter ;;
10) echo -e "\n${CYAN}>>> 安装 ffmpeg...${NC}"; _pkg_install ffmpeg
    echo -e "\n${GREEN}[完成]${NC} 版本: $(ffmpeg -version 2>/dev/null | head -1)"; pause_for_enter ;;
11) echo -e "\n${CYAN}>>> 安装 btop...${NC}"; _pkg_install btop
    echo -e "\n${GREEN}[完成] 输入 btop 启动现代化监控界面。${NC}"; pause_for_enter ;;
12) echo -e "\n${CYAN}>>> 安装 ranger...${NC}"; _pkg_install ranger
    echo -e "\n${GREEN}[完成] 输入 ranger 启动文件管理器。${NC}"; pause_for_enter ;;
13) echo -e "\n${CYAN}>>> 安装 ncdu...${NC}"; _pkg_install ncdu
    echo -e "\n${GREEN}[完成] 输入 ncdu / 扫描磁盘占用。${NC}"; pause_for_enter ;;
14) echo -e "\n${CYAN}>>> 安装 fzf...${NC}"; _pkg_install fzf
    echo -e "\n${GREEN}[完成] 输入 fzf 启动模糊搜索。${NC}"; pause_for_enter ;;
15) echo -e "\n${CYAN}>>> 安装 vim...${NC}"; _pkg_install vim
    echo -e "\n${GREEN}[完成]${NC} 版本: $(vim --version 2>/dev/null | head -1)"; pause_for_enter ;;
16) echo -e "\n${CYAN}>>> 安装 nano...${NC}"; _pkg_install nano
    echo -e "\n${GREEN}[完成]${NC} 版本: $(nano --version 2>/dev/null | head -1)"; pause_for_enter ;;
17) echo -e "\n${CYAN}>>> 安装 git...${NC}"; _pkg_install git
    echo -e "\n${GREEN}[完成]${NC} 版本: $(git --version 2>/dev/null)"; pause_for_enter ;;
18) if ! confirm_action "安装全部 17 个常用工具"; then continue; fi
    echo -e "\n${CYAN}>>> 正在批量安装，请稍候...${NC}"
    _pkg_install curl wget sudo socat htop iftop unzip tar tmux ffmpeg btop ranger ncdu fzf vim nano git
    echo -e "\n${GREEN}[成功] 全部工具安装完毕！${NC}"; pause_for_enter ;;
19) if ! confirm_action "卸载全部工具" "n"; then continue; fi
    echo -e "\n${CYAN}>>> 正在批量卸载...${NC}"
    _pkg_remove htop iftop tmux ffmpeg btop ranger ncdu fzf vim nano git socat unzip
    echo -e "\n${GREEN}[完成] 已卸载可卸载的工具（curl/wget/sudo/tar 为系统基础组件，已跳过）。${NC}"; pause_for_enter ;;
0)  return ;;
*)  echo -e "\n${RED}[提示] 无效输入！${NC}"; sleep 1 ;;
esac
done
}

manage_sshkey() {
while true; do
clear_screen; print_divider
print_center "[ SSH 密钥登录管理 ]" "$CYAN"

local _pubkey_status _paswd_status
if grep -iq "^PubkeyAuthentication yes" /etc/ssh/sshd_config 2>/dev/null; then
  _pubkey_status="${GREEN}已启用${NC}"
else
  _pubkey_status="${RED}未启用${NC}"
fi
if grep -iq "^PasswordAuthentication yes" /etc/ssh/sshd_config 2>/dev/null; then
  _paswd_status="${GREEN}允许${NC}"
else
  _paswd_status="${YELLOW}禁用${NC}"
fi

echo -e "  密钥登录状态: $(echo -e "$_pubkey_status")  |  密码登录: $(echo -e "$_paswd_status")"
echo ""
echo -e "  ${GREEN}1.${NC} 生成新密钥对（ed25519）并开启密钥登录"
echo -e "  ${GREEN}2.${NC} 手动导入已有公钥"
echo -e "  ${GREEN}3.${NC} 从 GitHub 导入公钥（按用户名）"
echo -e "  ${GREEN}4.${NC} 从 URL 导入公钥"
echo -e "  ${GREEN}5.${NC} 查看当前 authorized_keys"
echo -e "  ${GREEN}6.${NC} 开启密码登录（兼容模式）"
echo -e "  ${GREEN}7.${NC} 关闭密码登录（仅密钥模式）"
echo -e "  ${GREEN}0.${NC} 返回主菜单"
echo ""
read -r -p "> 请输入编号: " sk_opt
sk_opt="${sk_opt// /}"

case $sk_opt in
1)
  chmod 700 "${HOME}"
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"
  ssh-keygen -t ed25519 -C "vpsbox-key" -f "${HOME}/.ssh/vpsbox_key" -N "" -q
  cat "${HOME}/.ssh/vpsbox_key.pub" >> "${HOME}/.ssh/authorized_keys"
  chmod 600 "${HOME}/.ssh/authorized_keys"
  echo ""
  echo -e "${YELLOW}>>> 私钥内容如下（请立即复制保存，命名为 vpsbox_key）:${NC}"
  echo "--------------------------------"
  cat "${HOME}/.ssh/vpsbox_key"
  echo "--------------------------------"
  echo ""
  echo -e "${RED}⚠ 下一步将关闭密码登录并仅允许密钥登录！${NC}"
  echo -e "${RED}⚠ 如果私钥未保存或丢失，将无法登录服务器！${NC}"
  if ! confirm_action "关闭密码登录并启用密钥登录" "n"; then
    echo -e "${YELLOW}已跳过 SSH 配置修改，密钥文件已生成可稍后手动配置。${NC}"
    pause_for_enter; continue
  fi
  _set_sshd_option PermitRootLogin prohibit-password || { pause_for_enter; continue; }
  _set_sshd_option PasswordAuthentication no || { pause_for_enter; continue; }
  _set_sshd_option PubkeyAuthentication yes || { pause_for_enter; continue; }
  _set_sshd_option ChallengeResponseAuthentication no || { pause_for_enter; continue; }
  _harden_sshd_dropins
  _restart_ssh_service_safely "已应用仅密钥登录设置" || { pause_for_enter; continue; }
  echo ""
  echo -e "${GREEN}[成功] 密钥已生成，密码登录已关闭。请用私钥文件登录。${NC}"
  pause_for_enter ;;
2)
  echo ""
  read -r -p "> 请粘贴您的公钥（ssh-ed25519 或 ssh-rsa 开头）: " _pubkey
  if [[ -z "$_pubkey" ]] || [[ ! "$_pubkey" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
    echo -e "${RED}[错误] 无效的公钥格式。${NC}"; sleep 2; continue
  fi
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"
  if grep -Fxq "$_pubkey" "${HOME}/.ssh/authorized_keys" 2>/dev/null; then
    echo -e "${YELLOW}该公钥已存在，无需重复添加。${NC}"; sleep 2; continue
  fi
  echo "$_pubkey" >> "${HOME}/.ssh/authorized_keys"
  _set_sshd_option PubkeyAuthentication yes || { pause_for_enter; continue; }
  _harden_sshd_dropins
  _restart_ssh_service_safely "已应用公钥登录设置" || { pause_for_enter; continue; }
  echo -e "${GREEN}[成功] 公钥已导入并启用密钥登录。${NC}"; pause_for_enter ;;
3)
  echo ""
  read -r -p "> 请输入 GitHub 用户名: " _ghuser
  [ -z "$_ghuser" ] && continue
  local _ghkeys
  _ghkeys=$(curl -fsSL --max-time 10 "https://github.com/${_ghuser}.keys" 2>/dev/null)
  if [ -z "$_ghkeys" ]; then
    echo -e "${RED}[错误] 无法获取 GitHub 公钥，请检查用户名或网络。${NC}"; sleep 2; continue
  fi
  if ! echo "$_ghkeys" | _valid_ssh_key_lines; then
    echo -e "${RED}[错误] GitHub 返回内容不是有效 SSH 公钥，已拒绝导入。${NC}"; sleep 2; continue
  fi
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"
  echo "$_ghkeys" >> "${HOME}/.ssh/authorized_keys"
  _set_sshd_option PubkeyAuthentication yes || { pause_for_enter; continue; }
  _harden_sshd_dropins
  _restart_ssh_service_safely "已应用 GitHub 公钥登录设置" || { pause_for_enter; continue; }
  echo -e "${GREEN}[成功] 已从 GitHub(${_ghuser}) 导入公钥。${NC}"; pause_for_enter ;;
4)
  echo ""
  read -r -p "> 请输入公钥 URL: " _kurl
  [ -z "$_kurl" ] && continue
  local _remote_keys
  _remote_keys=$(curl -fsSL --max-time 10 "$_kurl" 2>/dev/null)
  if [ -z "$_remote_keys" ]; then
    echo -e "${RED}[错误] 无法从 URL 获取公钥。${NC}"; sleep 2; continue
  fi
  if ! echo "$_remote_keys" | _valid_ssh_key_lines; then
    echo -e "${RED}[错误] URL 返回内容不是有效 SSH 公钥，已拒绝导入。${NC}"; sleep 2; continue
  fi
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"
  echo "$_remote_keys" >> "${HOME}/.ssh/authorized_keys"
  _set_sshd_option PubkeyAuthentication yes || { pause_for_enter; continue; }
  _harden_sshd_dropins
  _restart_ssh_service_safely "已应用 URL 公钥登录设置" || { pause_for_enter; continue; }
  echo -e "${GREEN}[成功] 已从 URL 导入公钥。${NC}"; pause_for_enter ;;
5)
  echo ""
  echo -e "${CYAN}--- authorized_keys 内容 ---${NC}"
  cat "${HOME}/.ssh/authorized_keys" 2>/dev/null || echo "(文件为空或不存在)"
  echo -e "${CYAN}----------------------------${NC}"
  pause_for_enter ;;
6)
  _set_sshd_option PasswordAuthentication yes || { pause_for_enter; continue; }
  _set_sshd_option PermitRootLogin yes || { pause_for_enter; continue; }
  _harden_sshd_dropins
  _restart_ssh_service_safely "已应用密码登录开启设置" || { pause_for_enter; continue; }
  echo -e "${GREEN}[成功] 密码登录已开启。${NC}"; pause_for_enter ;;
7)
  _set_sshd_option PasswordAuthentication no || { pause_for_enter; continue; }
  _set_sshd_option PermitRootLogin prohibit-password || { pause_for_enter; continue; }
  _set_sshd_option PubkeyAuthentication yes || { pause_for_enter; continue; }
  _harden_sshd_dropins
  _restart_ssh_service_safely "已应用仅密钥登录设置" || { pause_for_enter; continue; }
  echo -e "${GREEN}[成功] 密码登录已关闭，仅允许密钥登录。${NC}"; pause_for_enter ;;
0) break ;;
*) echo -e "${RED}[提示] 编号错误。${NC}"; sleep 1 ;;
esac
done
}

disk_manager() {
while true; do
clear_screen; print_divider
print_center "[ 磁盘分区管理 ]" "$CYAN"
echo -e "  ${YELLOW}⚠ 注意：格式化操作不可逆，请谨慎操作！${NC}"
echo ""
echo -e "  ${CYAN}当前分区列表:${NC}"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v "sr\|loop"
echo ""
echo -e "  ${GREEN}1.${NC} 挂载分区（持久化写入 fstab）"
echo -e "  ${GREEN}2.${NC} 卸载分区"
echo -e "  ${GREEN}3.${NC} 查看已挂载分区"
echo -e "  ${GREEN}4.${NC} 格式化分区（ext4/xfs/vfat）"
echo -e "  ${GREEN}5.${NC} 检查分区状态（fsck）"
echo -e "  ${GREEN}0.${NC} 返回主菜单"
echo ""
read -r -p "> 请输入编号: " dm_opt
dm_opt="${dm_opt// /}"
case $dm_opt in
1)
  read -r -p "> 请输入要挂载的分区名（如 sdb1）: " _part
  [ -z "$_part" ] && continue
  local _dev="/dev/$_part" _mnt="/mnt/$_part"
  if ! lsblk -no NAME | grep -qw "$_part"; then echo -e "${RED}分区不存在！${NC}"; sleep 2; continue; fi
  if mount | grep -qw "$_dev"; then echo -e "${YELLOW}分区已挂载！${NC}"; sleep 2; continue; fi
  local _uuid _fstype
  _uuid=$(blkid -s UUID -o value "$_dev" 2>/dev/null)
  _fstype=$(blkid -s TYPE -o value "$_dev" 2>/dev/null)
  [ -z "$_uuid" ] && echo -e "${RED}无法获取 UUID！${NC}" && sleep 2 && continue
  [ -z "$_fstype" ] && echo -e "${RED}无法获取文件系统类型！${NC}" && sleep 2 && continue
  mkdir -p "$_mnt"
  if mount "$_dev" "$_mnt"; then
    if ! grep -qE "UUID=$_uuid|[[:space:]]${_mnt}[[:space:]]" /etc/fstab; then
      echo "UUID=$_uuid $_mnt $_fstype defaults,nofail 0 2" >> /etc/fstab
    fi
    echo -e "${GREEN}[成功] 已挂载 $_dev → $_mnt（已写入 fstab）${NC}"
  else
    echo -e "${RED}挂载失败！${NC}"; rmdir "$_mnt" 2>/dev/null
  fi
  pause_for_enter ;;
2)
  read -r -p "> 请输入要卸载的分区名（如 sdb1）: " _part
  [ -z "$_part" ] && continue
  if ! mount | grep -qw "/dev/$_part"; then echo -e "${YELLOW}分区未挂载！${NC}"; sleep 2; continue; fi
  umount "/dev/$_part" && echo -e "${GREEN}[成功] 已卸载 /dev/$_part${NC}" || echo -e "${RED}卸载失败！${NC}"
  pause_for_enter ;;
3)
  echo ""
  df -h | grep -v "tmpfs\|udev\|overlay"
  pause_for_enter ;;
4)
  read -r -p "> 请输入要格式化的分区名（如 sdb1）: " _part
  [ -z "$_part" ] && continue
  if ! lsblk -no NAME | grep -qw "$_part"; then echo -e "${RED}分区不存在！${NC}"; sleep 2; continue; fi
  if lsblk -no MOUNTPOINT "/dev/$_part" 2>/dev/null | grep -q '/'; then echo -e "${RED}分区已挂载，请先卸载！${NC}"; sleep 2; continue; fi
  echo -e "  选择文件系统: ${GREEN}1.${NC}ext4  ${GREEN}2.${NC}xfs  ${GREEN}3.${NC}vfat"
  read -r -p "> 请选择: " _fsidx
  case $_fsidx in 1) _fst=ext4 ;; 2) _fst=xfs ;; 3) _fst=vfat ;; *) continue ;; esac
  read -r -p "> 确认格式化 /dev/$_part 为 $_fst？(y/N): " _yesno
  [[ "$_yesno" =~ ^[yY]$ ]] || continue
  "mkfs.$_fst" "/dev/$_part" && echo -e "${GREEN}[成功] 格式化完成！${NC}" || echo -e "${RED}格式化失败！${NC}"
  pause_for_enter ;;
5)
  read -r -p "> 请输入要检查的分区名（如 sdb1）: " _part
  [ -z "$_part" ] && continue
  if ! lsblk -no NAME | grep -qw "$_part"; then echo -e "${RED}分区不存在！${NC}"; sleep 2; continue; fi
  fsck "/dev/$_part"
  pause_for_enter ;;
0) break ;;
*) echo -e "${RED}[提示] 编号错误。${NC}"; sleep 1 ;;
esac
done
}

crontab_manager() {
if ! command -v crontab &>/dev/null; then
  echo -e "${CYAN}[系统] 正在安装 cron...${NC}"
  _pkg_install cron cronie 2>/dev/null || true
  _svc_enable cron 2>/dev/null; _svc_start cron 2>/dev/null
fi

while true; do
clear_screen; print_divider
print_center "[ 定时任务管理 ]" "$CYAN"
echo ""
echo -e "  ${CYAN}当前定时任务列表:${NC}"
echo "  ─────────────────────────────────────────"
local _tasks
_tasks=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$')
if [ -z "$_tasks" ]; then
  echo -e "  ${YELLOW}（暂无定时任务）${NC}"
else
  local _lno=1
  while IFS= read -r line; do
    echo -e "  ${GREEN}[$_lno]${NC} $line"
    _lno=$((_lno+1))
  done <<< "$_tasks"
fi
echo "  ─────────────────────────────────────────"
echo ""
echo -e "  ${GREEN}1.${NC} 添加定时任务"
echo -e "  ${GREEN}2.${NC} 删除定时任务（按编号）"
echo -e "  ${GREEN}3.${NC} 编辑全部任务（nano）"
echo -e "  ${GREEN}4.${NC} 立即执行指定任务"
echo -e "  ${GREEN}0.${NC} 返回主菜单"
echo ""
read -r -p "> 请输入编号: " ct_opt
ct_opt="${ct_opt// /}"
case $ct_opt in
1)
  echo ""
  echo -e "  ${CYAN}Cron 格式: 分 时 日 月 周 命令${NC}"
  echo -e "  示例: 0 2 * * 1 /root/backup.sh  （每周一 02:00 执行）"
  echo -e "  示例: */30 * * * * /usr/bin/curl -s url  （每30分钟）"
  echo ""
  read -r -p "> 请输入 Cron 时间表达式（分 时 日 月 周）: " _cron_time
  read -r -p "> 请输入命令或脚本路径: " _cron_cmd
  [ -z "$_cron_time" ] || [ -z "$_cron_cmd" ] && continue
  (crontab -l 2>/dev/null; echo "$_cron_time $_cron_cmd") | crontab -
  echo -e "${GREEN}[成功] 定时任务已添加！${NC}"; pause_for_enter ;;
2)
  local _lines=()
  while IFS= read -r line; do _lines+=("$line"); done <<< "$_tasks"
  [ ${#_lines[@]} -eq 0 ] && echo -e "${YELLOW}暂无任务可删除。${NC}" && sleep 2 && continue
  echo ""
  read -r -p "> 请输入要删除的任务编号: " _del_idx
  [[ "$_del_idx" =~ ^[0-9]+$ ]] || continue
  local _del_no=$((_del_idx-1))
  [ $_del_no -lt 0 ] || [ $_del_no -ge ${#_lines[@]} ] && echo -e "${RED}编号超出范围！${NC}" && sleep 2 && continue
  local _del_line="${_lines[$_del_no]}"
  (crontab -l 2>/dev/null | grep -Fxv "$_del_line") | crontab -
  echo -e "${GREEN}[成功] 已删除: $_del_line${NC}"; pause_for_enter ;;
3)
  _pkg_install nano 2>/dev/null; crontab -e; pause_for_enter ;;
4)
  local _exec_lines=()
  while IFS= read -r line; do _exec_lines+=("$line"); done <<< "$_tasks"
  [ ${#_exec_lines[@]} -eq 0 ] && echo -e "${YELLOW}暂无任务。${NC}" && sleep 2 && continue
  read -r -p "> 请输入要立即执行的任务编号: " _exec_idx
  [[ "$_exec_idx" =~ ^[0-9]+$ ]] || continue
  local _exec_no=$((_exec_idx-1))
  [ $_exec_no -lt 0 ] || [ $_exec_no -ge ${#_exec_lines[@]} ] && echo -e "${RED}编号超出范围！${NC}" && sleep 2 && continue
  local _exec_cmd
  _exec_cmd=$(echo "${_exec_lines[$_exec_no]}" | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^[[:space:]]*//')
  echo -e "${CYAN}>>> 正在执行: $_exec_cmd${NC}"
  bash -lc "$_exec_cmd"; pause_for_enter ;;
0) break ;;
*) echo -e "${RED}[提示] 编号错误。${NC}"; sleep 1 ;;
esac
done
}

manage_script() {
while true; do
clear_screen; print_divider
print_center "[ VPSBox 脚本管理 ]" "$CYAN"
local local_ver remote_ver
local_ver="${VPSBOX_VERSION:-未知}"
remote_ver=$(curl -sL --connect-timeout 2 --max-time 3 https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh 2>/dev/null | grep -oP '^VPSBOX_VERSION="\K[^"]+' | head -1)
echo -e "  ${CYAN}本地版本:${NC} ${GREEN}${local_ver}${NC}"
if [ -n "$remote_ver" ]; then
  local _local_cmp _remote_cmp _remote_newer=0 _local_newer=0 _i _r _l
  _local_cmp="${local_ver#v}"
  _remote_cmp="${remote_ver#v}"
  if [ "$_remote_cmp" != "$_local_cmp" ]; then
    IFS='.' read -ra _remote_parts <<< "$_remote_cmp"
    IFS='.' read -ra _local_parts <<< "$_local_cmp"
    for _i in 0 1 2; do
      _r=${_remote_parts[$_i]:-0}; _l=${_local_parts[$_i]:-0}
      if [ "$_r" -gt "$_l" ] 2>/dev/null; then _remote_newer=1; break; fi
      if [ "$_r" -lt "$_l" ] 2>/dev/null; then _local_newer=1; break; fi
    done
  fi
  if [ "$_local_newer" -eq 1 ]; then
    echo -e "  ${CYAN}远端版本:${NC} ${YELLOW}${remote_ver}${NC}  ${GREEN}(本地较新)${NC}"
  else
    echo -e "  ${CYAN}最新版本:${NC} ${GREEN}${remote_ver}${NC}"
  fi
else
  echo -e "  ${YELLOW}无法获取远程版本${NC}"
fi

echo -e "  ${GREEN}1.${NC} 从 GitHub 更新到最新版本"
echo -e "  ${RED}2.${NC} 彻底卸载 VPSBox 及所有残留"
echo -e "  ${GREEN}0.${NC} 返回主菜单"; echo ""
read -r -p "> 请选择: " ms_opt
ms_opt="${ms_opt// /}"
case $ms_opt in
1)
if ! confirm_action "从 GitHub 拉取最新版覆盖当前脚本"; then continue; fi
echo -e "\n${CYAN}>>> 正在下载...${NC}"
curl -sL --connect-timeout 5 --max-time 30 "https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh" -o /tmp/vpsbox_update.sh
if [ -f /tmp/vpsbox_update.sh ] && grep -q "VPSBox" /tmp/vpsbox_update.sh; then
mv /tmp/vpsbox_update.sh "$SHORTCUT_PATH"; chmod +x "$SHORTCUT_PATH"
echo -e "\n${GREEN}[成功] 已更新！${NC}"
echo -e "${YELLOW}即将重启脚本...${NC}"; sleep 2; exec "$SHORTCUT_PATH"
else
echo -e "\n${RED}[错误] 下载失败或文件异常。${NC}"; rm -f /tmp/vpsbox_update.sh
fi
pause_for_enter ;;
2)
echo -e "\n${RED}[警告] 将删除快捷命令、本地备份、节点记录及所有缓存。${NC}"
if ! confirm_action "彻底卸载 VPSBox" "n"; then continue; fi
rm -f /usr/local/bin/vpsbox; rm -rf /etc/vpsbox_backups; rm -f "$NODE_RECORD_FILE"; rm -f "$INSTALL_LOG"
echo -e "\n${GREEN}[成功] VPSBox 已彻底卸载！${NC}"; exit 0 ;;
0) return ;;
*) echo -e "\n${RED}输入无效！${NC}"; sleep 1 ;;
esac
done
}

# =====================================================================
# 主菜单与少量二级菜单
# =====================================================================
menu_header() {
  clear_screen
  print_divider
  print_center "$1" "$PURPLE"
  print_divider
  echo ""
}

menu_logo() {
  clear_screen
  print_divider
  echo -e "${PURPLE}"
  echo " __      _______   _____ ____             "
  echo " \ \    / /  __ \ / ____|  _ \            "
  echo "  \ \  / /| |__) | (___ | |_) | _____  __"
  echo "   \ \/ / |  ___/ \___ \|  _ < / _ \ \/ /"
  echo "    \  /  | |     ____) | |_) | (_) >  < "
  echo "     \\/   |_|    |_____/|____/ \\___/_/\\_\\"
  echo -e "${NC}"
  print_center "轻量级节点管理与服务器优化工具  ·  ${VPSBOX_VERSION}" "$CYAN"
  print_center "快捷命令: vpsbox" "$YELLOW"
  if [ "${UPDATE_AVAILABLE:-0}" -eq 1 ]; then
    print_center "发现新版本: ${REMOTE_VERSION}  ·  请选择 22 脚本管理手动更新" "$GREEN"
  fi
  print_divider
  echo ""
}

_display_width() {
  # 近似计算终端显示宽度：ASCII=1，常见 CJK UTF-8 字符=2
  local text="$1" chars bytes cjk
  chars=${#text}
  bytes=$(printf "%s" "$text" | wc -c | tr -d ' ')
  cjk=$(( (bytes - chars) / 2 ))
  echo $(( chars + cjk ))
}

menu_pair() {
  # 参数: 左编号 左标题 右编号 右标题
  # 右侧编号固定到同一显示列；中文按显示宽度补空格，保证 2/4/6/8/10/14/16/18 纵向对齐
  local l_no="$1" l_title="$2" r_no="$3" r_title="$4"
  local left_plain left_width pad right_col=40
  left_plain=$(printf "%2s. %s" "$l_no" "$l_title")
  left_width=$(_display_width "$left_plain")
  # 行首固定两个空格；right_col 是整行中右侧编号开始的显示列
  pad=$(( right_col - 2 - left_width ))
  [ "$pad" -lt 2 ] && pad=2
  printf "  ${GREEN}%2s${NC}. %s%*s${GREEN}%2s${NC}. %s\n" "$l_no" "$l_title" "$pad" "" "$r_no" "$r_title"
}

menu_single() {
  local no="$1" title="$2"
  printf "  ${GREEN}%2s${NC}. %s\n" "$no" "$title"
}

menu_back_hint() {
  echo ""
  print_divider
  echo -e "  ${GREEN} 0${NC}. 返回主菜单"
  echo ""
}

_read_menu_choice() {
  local __var="$1" __prompt="$2" __choice
  read -r -p "$__prompt" __choice
  __choice="${__choice// /}"
  if [ -z "$__choice" ] && [ ! -t 0 ]; then
    echo -e "\n${RED}[提示] 检测到输入流异常，请使用 ${GREEN}bash <(curl -sL ${SCRIPT_URL})${NC} 方式运行。${NC}"
    exit 1
  fi
  printf -v "$__var" '%s' "$__choice"
}

menu_nodes() {
while true; do
menu_header "节点管理"
echo -e "  ${CYAN}部署新节点${NC}"
menu_pair 1 "VLESS-Reality" 2 "VLESS-WS-TLS"
menu_pair 3 "AnyTLS" 4 "Hysteria2"
echo ""
echo -e "  ${CYAN}已部署节点${NC}"
menu_pair 5 "查看节点" 6 "删除节点"
menu_back_hint
_read_menu_choice node_opt "> 请选择 [0-6]: "
[ -z "$node_opt" ] && continue
case $node_opt in
 1) install_reality_node ;;
 2) install_ws_tls_node ;;
 3) install_anytls_node ;;
 4) install_hy2_node ;;
 5) view_deployed_nodes ;;
 6) delete_node ;;
 0) return ;;
 *) echo -e "\n${RED}[提示] 编号不存在！${NC}"; sleep 1 ;;
esac
done
}

# 主循环函数，调用时 stdin 重定向到 /dev/tty
_vpsbox_main() {
while true; do
menu_logo

echo -e "  ${CYAN}系统维护${NC}"
menu_pair 1 "系统总览" 2 "更新系统"
menu_pair 3 "垃圾清理" 4 "Root 密码"
menu_pair 5 "修改主机名" 6 "系统时区"
menu_pair 7 "Swap 管理" 8 "DNS 优化"
menu_pair 9 "SSH 端口" 10 "SSH 密钥"

echo ""
echo -e "  ${CYAN}网络与安全${NC}"
menu_pair 11 "TCP 调优" 12 "BBR 管理"
menu_pair 13 "流媒体检测" 14 "Docker"
menu_pair 15 "Fail2Ban" 16 "WARP 解锁"
menu_pair 17 "UFW 防火墙" 18 "节点管理"

echo ""
echo -e "  ${CYAN}更多功能${NC}"
menu_pair 19 "磁盘分区" 20 "定时任务"
menu_pair 21 "基础工具箱" 22 "脚本管理"

echo ""
print_divider
echo -e "  ${GREEN} 0${NC}. 退出"
echo ""
_read_menu_choice OPTION "> 请选择 [0-22]: "
[ -z "$OPTION" ] && continue
case $OPTION in
 1) system_overview ;;
 2) system_update ;;
 3) system_clean ;;
 4) change_root_password ;;
 5) change_hostname ;;
 6) set_china_timezone ;;
 7) manage_swap ;;
 8) optimize_dns ;;
 9) change_ssh_port ;;
10) manage_sshkey ;;
11) apply_tuning ;;
12) manage_bbr ;;
13) check_media_unlock ;;
14) docker_install ;;
15) fail2ban_install ;;
16) install_warp ;;
17) manage_ufw ;;
18) menu_nodes ;;
19) disk_manager ;;
20) crontab_manager ;;
21) tools_manager ;;
22) manage_script ;;
 0) echo -e "\n${GREEN}[感谢使用] 正在退出...${NC}\n"; exit 0 ;;
 *) echo -e "\n${RED}[提示] 编号不存在！${NC}"; sleep 1 ;;
esac
done
}

# 仅在 stdin 非终端但存在可交互 tty 时切回 /dev/tty；否则保留当前 stdin，兼容 CI/管道回放场景
if [ ! -t 0 ] && [ -r /dev/tty ] && [ -t 1 ]; then
    _vpsbox_main </dev/tty
else
    _vpsbox_main
fi