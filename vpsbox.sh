#!/bin/bash
# =====================================================================
# 项目名称: VPS Box (轻量级节点管理与网络优化引擎)
# 版本: v1.6.0 — 极简方案: 函数调用一行重定向，无 exec 无子 shell
# 推荐运行方式: bash <(curl -sL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh)
# =====================================================================
VPSBOX_VERSION="v1.6.0"

# =====================================================================
# curl|bash 兼容: 脚本最后一行 _vpsbox_main </dev/tty
# bash <() 兼容: stdin 本来就是终端，重定向无副作用
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

mkdir -p "$BACKUP_DIR"
if [ "$EUID" -ne 0 ]; then
echo -e "\n${RED}[错误] 权限不足！请使用 root 用户运行。${NC}\n"
exit 1
fi
# 退出时清理临时测试配置文件
trap 'rm -f /tmp/vpsbox_test_config.json' EXIT
# 自动注册全局命令（后台异步，不阻塞启动）
if [ "$0" != "$SHORTCUT_PATH" ] && [ ! -s "$SHORTCUT_PATH" ]; then
    if [ ! -t 0 ]; then
        # 管道模式：后台下载，不阻塞菜单
        { curl -fsSL --connect-timeout 5 --max-time 10 "$SCRIPT_URL" -o "$SHORTCUT_PATH" 2>/dev/null && chmod +x "$SHORTCUT_PATH"; } &
    elif [ -f "$0" ] && cp "$0" "$SHORTCUT_PATH" 2>/dev/null; then
        chmod +x "$SHORTCUT_PATH"
    else
        { curl -fsSL --connect-timeout 5 --max-time 10 "$SCRIPT_URL" -o "$SHORTCUT_PATH" 2>/dev/null && chmod +x "$SHORTCUT_PATH"; } &
    fi
fi
if [ -f /etc/os-release ]; then
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
if ! grep -q "$(hostname)" /etc/hosts; then
echo "127.0.1.1 $(hostname)" >> /etc/hosts
fi

clear_screen() { clear; }

CPU_CORES=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$(( (RAM_MB + 512) / 1024 ))
[ "$RAM_GB" -eq 0 ] && RAM_GB=1
HW_PROFILE="${CPU_CORES}C${RAM_GB}G"
CURRENT_TZ=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
[ -z "$CURRENT_TZ" ] && CURRENT_TZ="UTC"

# IP 懒加载：启动不检测，首次使用时自动获取（避免无 IPv6 机器卡死）
SERVER_IPV4=""; SERVER_IPV6=""; SERVER_IP=""; _IP_DONE=0
_ensure_ip() {
    [ "$_IP_DONE" -eq 1 ] && return
    _IP_DONE=1
    SERVER_IPV4=$(curl -s4 --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null || curl -s4 --connect-timeout 1 --max-time 2 ip.sb 2>/dev/null)
    [ -z "$SERVER_IPV4" ] && SERVER_IPV4="未分配"
    SERVER_IPV6=$(curl -s6 --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null || curl -s6 --connect-timeout 1 --max-time 2 ip.sb 2>/dev/null)
    [ -z "$SERVER_IPV6" ] && SERVER_IPV6="未分配"
    if [ "$SERVER_IPV4" != "未分配" ]; then SERVER_IP="$SERVER_IPV4"
    elif [ "$SERVER_IPV6" != "未分配" ]; then SERVER_IP="[${SERVER_IPV6}]"
    else SERVER_IP="未分配"; fi
}

get_term_width() {
local cols=$(tput cols 2>/dev/null || echo 80)
if [ "$cols" -gt 100 ]; then echo 100
elif [ "$cols" -lt 40 ]; then echo 40
else echo "$cols"
fi
}

print_divider() {
local w=$(get_term_width)
echo -e "${CYAN}$(printf "%0.s=" $(seq 1 $w))${NC}"
}

print_center() {
local text="$1"
local color="$2"
local term_width=$(get_term_width)
local plain_text=$(echo -e "$text" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
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
  pkill -9 -f 'apt|dpkg' 2>/dev/null
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
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

_svc_reload() {
  if _svc_is_active "$1" 2>/dev/null; then
    local OLD_PID; OLD_PID=$(timeout 3 systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2)
    if command -v apk &>/dev/null; then
      timeout 10 service "$1" reload 2>/dev/null && { echo -e "${GREEN}  ✓ $1 热重载成功${NC}"; return 0; }
    else
      timeout 10 /bin/systemctl reload "$1" 2>/dev/null && { echo -e "${GREEN}  ✓ $1 热重载成功${NC}"; return 0; }
      [ -n "$OLD_PID" ] && timeout 5 /bin/kill -HUP "$OLD_PID" 2>/dev/null && { echo -e "${GREEN}  ✓ $1 热重载成功 (kill -HUP)${NC}"; return 0; }
    fi
    local NEW_PID; NEW_PID=$(timeout 3 systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2)
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
  rm -rf /var/log/* /var/cache/apk/* /tmp/*
elif command -v pacman &>/dev/null; then
  pacman -Rns $(pacman -Qdtq 2>/dev/null) --noconfirm 2>/dev/null || true
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
  rm -rf /var/log/* /tmp/*
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
  passwd root
  if [ $? -eq 0 ]; then
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
if ! confirm_action "导入此 SSH 公钥"; then break; fi
mkdir -p ~/.ssh; chmod 700 ~/.ssh
if [ -s ~/.ssh/authorized_keys ]; then
echo -e "\n${YELLOW}[发现] 系统中已存在其他 SSH 密钥记录。${NC}"
read -r -p "> 是否清空旧密钥并覆盖？(y-覆盖清空 / n-保留追加, 默认 n): " overwrite_opt
overwrite_opt="${overwrite_opt// /}"
if [[ "$overwrite_opt" =~ ^[yY]$ ]]; then > ~/.ssh/authorized_keys; echo -e "${CYAN}>>> 已清空历史废弃密钥。${NC}"; fi
fi
echo "$pub_key" >> ~/.ssh/authorized_keys
if [ $? -ne 0 ]; then echo -e "\n${RED}[错误] 写入密钥失败，请检查系统权限或磁盘空间。${NC}"; else chmod 600 ~/.ssh/authorized_keys; echo -e "\n${GREEN}[成功] 密钥已成功添加！请先测试使用密钥登录，再关闭密码登录功能。${NC}"; fi
pause_for_enter; break
done ;;
2)
if ! confirm_action "删除系统中所有的 SSH 公钥" "n"; then continue; fi
> ~/.ssh/authorized_keys
if [ $? -eq 0 ]; then echo -e "\n${GREEN}[成功] 所有 SSH 公钥已彻底清空！${NC}"; else echo -e "\n${RED}[错误] 清空密钥失败！${NC}"; fi
pause_for_enter ;;
3)
if ! confirm_action "禁用密码登录 (⚠️ 请确保您已成功配置密钥)" "n"; then continue; fi
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/g' /etc/ssh/sshd_config
_svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null || { echo -e "\n${RED}[错误] SSH 服务重启失败，设置可能未生效。${NC}"; pause_for_enter; continue; }
echo -e "\n${GREEN}[成功] 密码登录已成功禁用！现在只能通过密钥连接服务器。${NC}"; pause_for_enter ;;
4)
if ! confirm_action "开启密码登录"; then continue; fi
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
_svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null || { echo -e "\n${RED}[错误] SSH 服务重启失败。${NC}"; pause_for_enter; continue; }
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
sed -i "s/^#\?Port .*/Port $new_port/g" /etc/ssh/sshd_config
_svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
if [ $? -eq 0 ]; then
  echo -e "\n${GREEN}[成功] SSH 端口已改为 ${new_port}！${NC}"
  echo -e "  ${RED}[重要] 请立即在云服务商控制台放行端口 ${new_port}，否则下次无法连接！${NC}"
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
sed -i "s/127.0.1.1.*/127.0.1.1 $new_hostname/g" /etc/hosts
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

local swap_total=$(free -m | awk 'NR==3{print $2}')
local swap_used=$(free -m | awk 'NR==3{print $3}')
local swap_file=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | head -1)

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
  for partition in $(grep -E '^/dev/' /proc/swaps | awk '{print $1}'); do
    swapoff "$partition" 2>/dev/null
    wipefs -a "$partition" 2>/dev/null
    mkswap -f "$partition" 2>/dev/null
  done
  swapoff /swapfile 2>/dev/null
  rm -f /swapfile
  echo -e "${CYAN}>>> 正在创建 ${input_size}MB Swap...${NC}"
  if ! fallocate -l ${input_size}M /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count=$input_size status=progress 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count=$input_size 2>/dev/null || \
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
  swapoff -a 2>/dev/null; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab
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
grep '^nameserver' /etc/resolv.conf 2>/dev/null | while read -r line; do
  echo -e "  ${YELLOW}${line}${NC}"
done
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
  chattr -i /etc/resolv.conf 2>/dev/null
  > /etc/resolv.conf
  local has_v4; has_v4=$(ip -4 addr show scope global 2>/dev/null | grep -c 'inet ')
  local has_v6; has_v6=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ')
  [ "$has_v4" -gt 0 ] && { echo "nameserver $d1v4" >> /etc/resolv.conf; echo "nameserver $d2v4" >> /etc/resolv.conf; }
  [ "$has_v6" -gt 0 ] && [ -n "$d1v6" ] && { echo "nameserver $d1v6" >> /etc/resolv.conf; echo "nameserver $d2v6" >> /etc/resolv.conf; }
  [ -s /etc/resolv.conf ] || { echo "nameserver $d1v4" >> /etc/resolv.conf; echo "nameserver $d2v4" >> /etc/resolv.conf; }
  if _svc_is_active systemd-resolved >/dev/null 2>&1; then
    echo -e "${YELLOW}[提示] systemd-resolved 接管中，重启后 DNS 可能被覆盖。${NC}"
  else
    chattr +i /etc/resolv.conf 2>/dev/null
    echo -e "${GREEN}[成功] DNS 已写入并锁定！${NC}"
  fi
  echo ""
  echo -e "  ${CYAN}生效后的 DNS:${NC}"
  grep '^nameserver' /etc/resolv.conf | while read -r line; do echo -e "  ${GREEN}${line}${NC}"; done
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
local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
local kern=$(uname -r)
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

manage_bbr() {

_bbr_check_sys() {
  BBR_ARCH=$(uname -m)
  BBR_OS_ID=""; BBR_OS_TYPE=""; BBR_OS_VER=""; BBR_OS_LIKE=""
  if [[ -f /etc/os-release ]]; then
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
    [[ -n "$prefix" ]] && target="${prefix}$(echo "$url" | sed 's|^https://||')"
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
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then
    rpm -qa | grep 'kernel-headers' | grep -v "$(uname -r)" | xargs -r rpm -e --nodeps >/dev/null 2>&1
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    dpkg -l | grep 'linux-headers' | awk '{print $2}' | grep -v "$(uname -r)" | xargs -r apt-get purge -y >/dev/null 2>&1
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
    [[ -n "$head_url" ]] && { _bbr_safe_wget "$head_url" "kernel-headers.rpm" || { cd /tmp; rm -rf "$wdir"; return 1; }; }
    _bbr_safe_wget "$img_url" "kernel-image.rpm" || { cd /tmp; rm -rf "$wdir"; return 1; }
    echo -e "  ${CYAN}>>> 执行 YUM 安装...${NC}"
    if [[ -n "$head_url" ]]; then yum install -y kernel-image.rpm kernel-headers.rpm
    else yum install -y kernel-image.rpm; fi
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then
    [[ -n "$head_url" ]] && { _bbr_safe_wget "$head_url" "linux-headers.deb" || { cd /tmp; rm -rf "$wdir"; return 1; }; }
    _bbr_safe_wget "$img_url" "linux-image.deb" || { cd /tmp; rm -rf "$wdir"; return 1; }
    echo -e "  ${CYAN}>>> 执行 DPKG 安装...${NC}"
    dpkg -i linux-image.deb
    [[ -n "$head_url" ]] && dpkg -i linux-headers.deb
    echo -e "  ${CYAN}>>> 修复依赖...${NC}"
    apt-get install -f -y
  fi
  cd /tmp && rm -rf "$wdir"
  _bbr_grub
  echo -e "\n  ${GREEN}[完成] ${desc} 内核包安装完毕！${NC}"
}

_bbr_apply_sysctl() {
  local qdisc="${1:-fq}" cc="${2:-bbr}"
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  mkdir -p /etc/sysctl.d
  sed -i '/net.ipv4.tcp_congestion_control/d; /net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null
  [[ -f "$conf" ]] && sed -i '/net.ipv4.tcp_congestion_control/d; /net.core.default_qdisc/d' "$conf"
  echo "net.core.default_qdisc=$qdisc" >> "$conf"
  echo "net.ipv4.tcp_congestion_control=$cc" >> "$conf"
  sysctl -p "$conf" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
}

_bbr_clean_accel() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  [[ -f "$conf" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d' "$conf"
  sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
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

_bbr_set_ecn() {
  local status="$1"
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  sed -i '/net.ipv4.tcp_ecn/d' "$conf" /etc/sysctl.conf 2>/dev/null
  echo "net.ipv4.tcp_ecn=$status" >> "$conf"
  sysctl --system >/dev/null 2>&1
  [[ "$status" == "1" ]] && echo -e "\n${GREEN}[成功] ECN 已开启！${NC}" || echo -e "\n${GREEN}[成功] ECN 已关闭！${NC}"
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
  if [[ "$BBR_OS_TYPE" == "CentOS" ]]; then rpm -e --nodeps $pkgs_to_del
  elif [[ "$BBR_OS_TYPE" == "Debian" ]]; then apt-get purge -y $pkgs_to_del; apt-get autoremove -y >/dev/null 2>&1; fi
  _bbr_grub
  echo -e "\n${GREEN}[完成] 内核已删除。${NC}"; pause_for_enter
}

_bbr_remove_all() {
  echo -e "\n${CYAN}>>> 清除加速与优化配置...${NC}"
  # 只删除 vpsbox 写入的参数，保留系统原有配置
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  rm -f "$conf"
  # 仅从 /etc/sysctl.conf 中删除 vpsbox 相关的参数行（不破坏其他内容）
  sed -i '/net\.core\.default_qdisc/d; /net\.ipv4\.tcp_congestion_control/d; /net\.ipv4\.tcp_ecn/d' /etc/sysctl.conf 2>/dev/null
  sed -i '/net\.ipv6\.conf\.all\.disable_ipv6/d; /net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null
  sed -i '/net\.ipv4\.tcp_syncookies/d; /net\.ipv4\.tcp_max_syn_backlog/d; /net\.ipv4\.tcp_synack_retries/d' /etc/sysctl.conf 2>/dev/null
  sysctl --system >/dev/null 2>&1
  sed -i '/DefaultLimitNOFILE/d; /DefaultLimitNPROC/d' /etc/systemd/system.conf 2>/dev/null
  sed -i '/soft   nofile/d; /hard   nofile/d' /etc/security/limits.conf 2>/dev/null
  _svc_daemon_reload
  echo -e "\n${GREEN}[完成] 系统已恢复原生状态。${NC}"; pause_for_enter
}

_bbr_optimizing_ddcc() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  sed -i '/net.ipv4.tcp_syncookies/d; /net.ipv4.tcp_max_syn_backlog/d; /net.ipv4.tcp_synack_retries/d' "$conf" 2>/dev/null
  cat >> "$conf" <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024000
net.ipv4.tcp_synack_retries = 1
EOF
  sysctl --system >/dev/null 2>&1
  echo -e "\n${GREEN}[完成] 防CC基础参数已写入！${NC}"; pause_for_enter
}

_bbr_ipv6_off() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' "$conf" /etc/sysctl.conf 2>/dev/null
  echo "net.ipv6.conf.all.disable_ipv6 = 1" >> "$conf"
  echo "net.ipv6.conf.default.disable_ipv6 = 1" >> "$conf"
  sysctl --system >/dev/null 2>&1
  echo -e "\n${GREEN}[完成] IPv6 已禁用！${NC}"; pause_for_enter
}

_bbr_ipv6_on() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' "$conf" /etc/sysctl.conf 2>/dev/null
  echo "net.ipv6.conf.all.disable_ipv6 = 0" >> "$conf"
  echo "net.ipv6.conf.default.disable_ipv6 = 0" >> "$conf"
  sysctl --system >/dev/null 2>&1
  echo -e "\n${GREEN}[完成] IPv6 已开启！${NC}"; pause_for_enter
}

_bbr_sysctl_merge() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  echo -e "\n${CYAN}>>> 逐行输入参数 (格式: key = value)，空行结束。${NC}"
  echo -e "  参考: https://omnitt.com/\n"
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
  sysctl --system >/dev/null 2>&1
  echo -e "\n${GREEN}[完成] 参数已合并！${NC}"; pause_for_enter
}

_bbr_sysctl_edit() {
  local conf="/etc/sysctl.d/99-vpsbox-bbr.conf"
  if command -v nano &>/dev/null; then nano "$conf"
  elif command -v vim &>/dev/null; then vim "$conf"
  elif command -v vi &>/dev/null; then echo -e "  ${YELLOW}使用 vi: i=编辑 Esc=退出 :wq=保存 :q!=放弃${NC}"; sleep 2; vi "$conf"
  else echo -e "\n${RED}[错误] 未找到编辑器 (nano/vim)。${NC}"; pause_for_enter; return; fi
  sysctl -p "$conf" >/dev/null 2>&1
  echo -e "\n${GREEN}[完成] 参数已应用！${NC}"; pause_for_enter
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
  local img_url_base img_pattern arch_ext
  if [[ "$BBR_ARCH" == "x86_64" ]]; then
    img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-amd64/"
    img_pattern='linux-image-[^"]+cloud-amd64_[^"]+_amd64\.deb'; arch_ext="amd64"
  elif [[ "$BBR_ARCH" == "aarch64" ]]; then
    img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-arm64/"
    img_pattern='linux-image-[^"]+cloud-arm64_[^"]+_arm64\.deb'; arch_ext="arm64"
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
      apt-cache show "linux-generic-hwe-${BBR_OS_VER}" &>/dev/null \
        && apt-get install --install-recommends "linux-generic-hwe-${BBR_OS_VER}" -y \
        || apt-get install linux-image-generic linux-headers-generic -y
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

local cur_kernel; cur_kernel=$(uname -r)
local cur_cc; cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
local cur_qd; cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
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
echo -e "  ─────────────── ${CYAN}加速启用${NC} ───────────────"
echo -e "  ${GREEN} 7.${NC} BBR + FQ            ${GREEN} 8.${NC} BBR + FQ_PIE"
echo -e "  ${GREEN} 9.${NC} BBR + CAKE          ${GREEN}10.${NC} BBRplus + FQ"
echo ""
echo -e "  ─────────────── ${CYAN}系统配置${NC} ───────────────"
echo -e "  ${GREEN}11.${NC} 开启 ECN            ${GREEN}12.${NC} 关闭 ECN"
echo -e "  ${GREEN}13.${NC} 防CC/DDOS优化        ${GREEN}14.${NC} 禁用 IPv6"
echo -e "  ${GREEN}15.${NC} 开启 IPv6           ${GREEN}16.${NC} 合并内核参数"
echo -e "  ${GREEN}17.${NC} 编辑内核参数"
echo ""
echo -e "  ─────────────── ${CYAN}内核管理${NC} ───────────────"
echo -e "  ${GREEN}18.${NC} 查看已安装内核      ${GREEN}19.${NC} 删除指定内核"
echo -e "  ${GREEN}20.${NC} 卸载全部加速配置"
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
7)  _bbr_clean_accel; _bbr_apply_sysctl fq bbr
    echo -e "\n${GREEN}[成功] BBR + FQ 已启用！${NC}"; pause_for_enter ;;
8)  _bbr_clean_accel; _bbr_apply_sysctl fq_pie bbr
    echo -e "\n${GREEN}[成功] BBR + FQ_PIE 已启用！${NC}"; pause_for_enter ;;
9)  _bbr_clean_accel; _bbr_apply_sysctl cake bbr
    echo -e "\n${GREEN}[成功] BBR + CAKE 已启用！${NC}"; pause_for_enter ;;
10) _bbr_clean_accel; _bbr_apply_sysctl fq bbrplus
    echo -e "\n${GREEN}[成功] BBRplus + FQ 已启用！${NC}"; pause_for_enter ;;
11) _bbr_set_ecn 1 ;; 12) _bbr_set_ecn 0 ;;
13) _bbr_optimizing_ddcc ;; 14) _bbr_ipv6_off ;;
15) _bbr_ipv6_on ;;
16) _bbr_sysctl_merge ;;
17) _bbr_sysctl_edit ;;
18) _bbr_show_kernels ;; 19) _bbr_delete_kernel ;;
20) _bbr_remove_all ;;
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
    local os_codename="$(lsb_release -cs 2>/dev/null || echo '')"
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
  bash <(curl -sSL https://linuxmirrors.cn/docker.sh) \
    --source mirrors.huaweicloud.com/docker-ce \
    --source-registry docker.1ms.run \
    --protocol https \
    --use-intranet-source false \
    --install-latest true \
    --close-firewall false \
    --ignore-backup-tips
else
  bash <(curl -sSL https://linuxmirrors.cn/docker.sh) \
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
local FB_LOG="/var/log/auth.log"
[ -f /var/log/secure ] && FB_LOG="/var/log/secure"
[ -f /var/log/messages ] && [ ! -f "$FB_LOG" ] && FB_LOG="/var/log/messages"
if command -v fail2ban-client &>/dev/null; then
echo -e "\n  ${GREEN}Fail2Ban 已安装${NC}"
echo -e "  ${CYAN}SSH 监狱状态:${NC}"
fail2ban-client status sshd 2>/dev/null | grep -E 'Status|Banned|Total' || echo -e "  ${YELLOW}SSH 监狱未激活${NC}"
echo -e "\n  ${GREEN}1.${NC} 重新配置 SSH 防护\n  ${GREEN}2.${NC} 查看封禁列表\n  ${GREEN}0.${NC} 返回"
read -r -p "> 请选择: " fb_opt
case "${fb_opt// /}" in
1)
    local FB_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [ -z "$FB_SSH_PORT" ] && FB_SSH_PORT=22
    cat > /etc/fail2ban/jail.local << FBEOL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${FB_SSH_PORT}
logpath = ${FB_LOG}
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
if [ $? -ne 0 ]; then echo -e "${RED}[错误] 安装失败。${NC}"; pause_for_enter; return; fi
local SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$SSH_PORT" ] && SSH_PORT=22
cat > /etc/fail2ban/jail.local << FBEOL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = ${FB_LOG}
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
clear_screen; print_divider
print_center "[ VPS Box 自研动态 TCP 智能调优引擎 ]" "$CYAN"
local local_bw server_bw latency ramp_up bbr_ver qdisc
while true; do
read -r -p "> 请输入本地/客户端下行带宽 (Mbps, 例如 500): " local_bw
[[ "${local_bw// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
done
while true; do
read -r -p "> 请输入服务器上行带宽 (Mbps, 例如 1000): " server_bw
[[ "${server_bw// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
done
while true; do
read -r -p "> 请输入预估网络延迟 (ms, 例如 150): " latency
[[ "${latency// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
done

echo -e "\n${YELLOW}--- 小白科普：TCP 爬升曲线 (Ramp-up) 该怎么选？ ---${NC}"
echo -e "  ${GREEN}0.1 - 0.3 (保守平稳型)${NC} : 适合建站、写博客。不抢占过多网络，提供极度稳定的连接质量。"
echo -e "  ${CYAN}0.4 - 0.6 (均衡通用型)${NC} : 适合日常科学上网代理。速度与稳定兼顾，是绝大多数人的默认最佳选择。"
echo -e "  ${RED}0.7 - 1.0 (激进吞吐型)${NC} : 适合看 4K/8K 视频、大文件传输。极具侵略性，能榨干线路带宽，但极差网络下可能丢包。"
echo -e "${YELLOW}--------------------------------------------------${NC}"

while true; do
read -r -p "> 请输入爬升曲线调节 (0.1 - 1.0) [默认 0.5]: " ramp_up
ramp_up="${ramp_up// /}"; [ -z "$ramp_up" ] && ramp_up="0.5"
awk -v r="$ramp_up" 'BEGIN{if(r>=0.1 && r<=1.0) exit 0; else exit 1}' && break
echo -e "${RED}[错误] 请输入 0.1 到 1.0 之间的有效数字！${NC}"
done
while true; do
read -r -p "> 请选择拥塞控制算法 (1: bbr, 2: cubic) [默认 1]: " bbr_choice
bbr_choice="${bbr_choice// /}"; [ -z "$bbr_choice" ] && bbr_choice=1
if [ "$bbr_choice" == "1" ]; then bbr_ver="bbr"; break; fi
if [ "$bbr_choice" == "2" ]; then bbr_ver="cubic"; break; fi
done
while true; do
read -r -p "> 请选择队列算法 (1: fq, 2: cake) [默认 1]: " qdisc_choice
qdisc_choice="${qdisc_choice// /}"; [ -z "$qdisc_choice" ] && qdisc_choice=1
if [ "$qdisc_choice" == "1" ]; then qdisc="fq"; break; fi
if [ "$qdisc_choice" == "2" ]; then qdisc="cake"; break; fi
done

local w_ram=$(free -m | awk '/^Mem:/{print $2}')
[ -z "$w_ram" ] || [ "$w_ram" -le 0 ] && w_ram=1024
echo -e "\n${CYAN}>>> 系统自动探测内存: ${GREEN}${w_ram} MB${NC}"
if ! confirm_action "执行并使上述 TCP 调优参数生效"; then pause_for_enter; return; fi

read -r -p "> 是否在调优前备份当前参数？(y/n, 默认 y): " NEED_BACKUP
NEED_BACKUP="${NEED_BACKUP// /}"
[[ -z "$NEED_BACKUP" || "$NEED_BACKUP" =~ ^[yY]$ ]] && backup_config_silently

echo -e "\n${CYAN}>>> 正在运行 VPS Box 自研引擎计算并安全注入配置...${NC}"

> "$CUSTOM_CONF"

TUNING_VARS=$(awk -v lb="$local_bw" -v sb="$server_bw" -v lat="$latency" \
-v mem="$w_ram" -v ramp="$ramp_up" -v bbr="$bbr_ver" -v qd="$qdisc" '
function min(x,y){return x<y?x:y}
function max(x,y){return x>y?x:y}
function clamp(v,lo,hi){return v<lo?lo:v>hi?hi:v}
function ceil(x){y=int(x);return y<x?y+1:y}
function sigmoid(e,t,n){return 1/(1+exp(-t*(e-n)))}
function tcpcong(e,n){return min(n*(1+.5*e),n+10*e)}
function qtheory(e,t,n){return t/(1-min(n,.95))*e}
function memawe(e,t,n){return min(e,1024*t*1024*n)}
BEGIN {
lb=clamp(lb,1,100000);sb=clamp(sb,1,100000)
lat=clamp(lat,1,2000);mem=clamp(mem,64,32768)
ramp=clamp(ramp,.1,1)

if(lat<=120){
f=max(1,min(2,1.5*sqrt(lb/sb)))
T=1024*min(lb*f,sb)*1024/8
n_bdp=ceil(T*lat/1000);p_bdp=max(n_bdp,24576)
ar=mem<=256?.1:.125;ib=mem<=256?4194304:8388608
u=max(memawe(ceil(1.5*ramp*n_bdp),mem,ar),ib)
resp=mem<=256?2.5:mem<=512?2.2:mem<=1024?2:1.8
bfm=mem<=256?.24:mem<=512?.378:mem<=1024?.56:1.08
cf=sigmoid(ramp,4,.3)*resp/2;cf=clamp(cf,.3,2)
lfe=exp((lat/120-1)*log(2));lf=clamp(lfe*cf*resp,.8,5)
ef=max(lat,50);lbe=exp((ef/120-1)*log(2));lbf=clamp(lbe*cf*resp,.8,5)
bf=clamp(lbf*tcpcong(cf,1)*(cf<.877?bfm*(1+1.8*(1-cf/.877)):bfm),.5,3)
ci=qtheory(T/65536*1.2,lat/1000*2,.8*cf)
qf=clamp(log(ci+1)/log(1000)*.8*1.3,.3,2)
bb=ceil(T*lat/1000);ws=bb>0?ceil(log(2*bb/65535)/log(2)):0
aw=clamp(lf/1.5*ws*1.2*cf,1,4);aws=max(2,ceil(aw))
V=mem<=256?2.5:mem<=512?3:mem<=1024?3:4
H=mem<=256?1.2:mem<=512?1.5:mem<=1024?1.5:2
w2=min(int(p_bdp*V*bf),u);k2=min(int(p_bdp*H*bf),u)
qq=ceil(max(100,min(10000,2*T/65536))*qf)
xm=mem<=256?.6:mem<=512?.8:mem<=1024?1:1.2
so=int(clamp(.2*qq*xm,256,2048))
nd=int(clamp(.4*qq*xm,2000,4000))
sy=int(clamp(.8*qq*xm,2048,16384))
r2=mem<=256?.015:mem<=512?.02:mem<=1024?.025:.03
mf=int(clamp(1024*mem*r2+.5*T/1024,32768,1048576))
op=int(min(65536,p_bdp/4))
rd=87380;wd=65536;sw=10;ft=10;ts=1;mt=1;ns=3
nl=4096;mr=1;fack=0;nms=0;mo=65536
nt3=8192;nt2=4096;nt1=1024
br=0;bp=0;ko=0;ki=0;kp=0;tm=""
} else {
f=max(1,min(5,lat/40))
tr=max(1.5,min(5,2*sqrt(lb/sb)*f))
T=1024*min(lb*tr,2*sb)*1024/8
vhl=ceil(T*lat/1000)
hv=memawe(ceil(2*ramp*vhl),mem,.125)
u=hv;if(lat>500)u=max(hv,ceil(.5*vhl))
lhl=max(vhl,T*lat/800)
km=clamp(1.8*f,4,8)*ramp
qm=clamp(2.5*f,5,10)*ramp
w2=min(int(lhl*qm),u);k2=min(int(lhl*km),u)
j=ceil(max(50,min(20000,3*T/131072))*ramp)
z=mem<=512?.8:mem<=1024?1:mem<=2048?1.3:1.5
so=int(clamp(.15*j*z,2560,16384))
nd=int(clamp(.3*j*z,8192,32768))
sy=int(clamp(.6*j*z,8192,65536))
r2=mem<=512?.02:mem<=1024?.025:mem<=2048?.03:.035
mf=int(clamp(1024*mem*r2+.6*T/1024,65536,1048576))
op=int(min(262144,lhl/2));aws=max(2,ceil(f*8))
mo=mem<=256?16384:32768;ns=2
nt3=mem<=512?2048:4096;nt2=mem<=512?1024:2048;nt1=mem<=512?256:512
rd=262144;wd=262144;sw=5;ft=10;ts=1;mt=1;mr=1
nl=int(min(lhl/2,524288));fack=1;nms=1
br=0;bp=0;ko=0;ki=0;kp=0;tm=""
}
printf("kernel.pid_max=65535\nkernel.panic=1\nkernel.sysrq=1\nkernel.core_pattern=core_%%e\n")
printf("kernel.printk=3 4 1 3\nkernel.numa_balancing=0\nkernel.sched_autogroup_enabled=0\n")
printf("vm.swappiness=%d\nvm.dirty_ratio=10\nvm.dirty_background_ratio=5\n",sw)
printf("vm.panic_on_oom=1\nvm.overcommit_memory=1\nvm.min_free_kbytes=%d\n",mf)
printf("vm.vfs_cache_pressure=100\nvm.dirty_expire_centisecs=3000\nvm.dirty_writeback_centisecs=500\n")
printf("net.core.default_qdisc=%s\nnet.core.netdev_max_backlog=%d\n",qd,nd)
printf("net.core.rmem_max=%d\nnet.core.wmem_max=%d\n",int(u),int(u))
printf("net.core.rmem_default=%d\nnet.core.wmem_default=%d\n",rd,wd)
printf("net.core.somaxconn=%d\nnet.core.optmem_max=%d\n",so,op)
if(br+0>0)printf("net.core.busy_read=%d\n",br)
if(bp+0>0)printf("net.core.busy_poll=%d\n",bp)
printf("net.ipv4.tcp_fastopen=3\nnet.ipv4.tcp_timestamps=%d\nnet.ipv4.tcp_tw_reuse=1\n",ts)
printf("net.ipv4.tcp_fin_timeout=%d\nnet.ipv4.tcp_slow_start_after_idle=0\n",ft)
printf("net.ipv4.tcp_max_tw_buckets=32768\nnet.ipv4.tcp_sack=1\nnet.ipv4.tcp_fack=%d\n",fack)
printf("net.ipv4.tcp_rmem=%d %d %d\n",8192,rd,int(w2))
printf("net.ipv4.tcp_wmem=%d %d %d\n",8192,wd,int(k2))
printf("net.ipv4.tcp_mtu_probing=%d\nnet.ipv4.tcp_congestion_control=%s\n",mt,bbr)
printf("net.ipv4.tcp_notsent_lowat=%d\nnet.ipv4.tcp_window_scaling=1\n",nl)
printf("net.ipv4.tcp_adv_win_scale=%d\nnet.ipv4.tcp_moderate_rcvbuf=%d\n",aws,mr)
printf("net.ipv4.tcp_no_metrics_save=%d\nnet.ipv4.tcp_max_syn_backlog=%d\n",nms,sy)
printf("net.ipv4.tcp_max_orphans=%d\n",mo)
printf("net.ipv4.tcp_synack_retries=2\nnet.ipv4.tcp_syn_retries=%d\n",ns)
printf("net.ipv4.tcp_abort_on_overflow=0\nnet.ipv4.tcp_stdurg=0\n")
printf("net.ipv4.tcp_rfc1337=0\nnet.ipv4.tcp_syncookies=1\n")
if(ko+0>0)printf("net.ipv4.tcp_keepalive_time=%d\n",ko)
if(ki+0>0)printf("net.ipv4.tcp_keepalive_intvl=%d\n",ki)
if(kp+0>0)printf("net.ipv4.tcp_keepalive_probes=%d\n",kp)
if(length(tm)>0)printf("net.ipv4.tcp_mem=%s\n",tm)
printf("net.ipv4.ip_forward=0\nnet.ipv4.ip_local_port_range=1024 65535\n")
printf("net.ipv4.ip_no_pmtu_disc=0\nnet.ipv4.route.gc_timeout=100\n")
printf("net.ipv4.neigh.default.gc_stale_time=120\n")
printf("net.ipv4.neigh.default.gc_thresh3=%d\n",nt3)
printf("net.ipv4.neigh.default.gc_thresh2=%d\n",nt2)
printf("net.ipv4.neigh.default.gc_thresh1=%d\n",nt1)
printf("net.ipv4.icmp_echo_ignore_broadcasts=1\n")
printf("net.ipv4.icmp_ignore_bogus_error_responses=1\n")
printf("net.ipv4.conf.all.rp_filter=1\nnet.ipv4.conf.default.rp_filter=1\n")
printf("net.ipv4.conf.all.arp_announce=2\nnet.ipv4.conf.default.arp_announce=2\n")
printf("net.ipv4.conf.all.arp_ignore=1\nnet.ipv4.conf.default.arp_ignore=1\n")
printf("net.ipv4.conf.all.accept_redirects=0\nnet.ipv4.conf.default.accept_redirects=0\n")
printf("net.ipv4.conf.all.secure_redirects=0\nnet.ipv4.conf.default.secure_redirects=0\n")
printf("net.ipv4.conf.all.accept_source_route=0\nnet.ipv4.conf.default.accept_source_route=0\n")
printf("net.ipv4.conf.all.forwarding=0\nnet.ipv4.conf.default.forwarding=0\n")
}')

modprobe tcp_bbr > /dev/null 2>&1 || true

while IFS='=' read -r key val; do
if [ -n "$key" ] && [ -n "$val" ]; then
if sysctl -w "$key=$val" >/dev/null 2>&1; then
echo "$key = $val" >> "$CUSTOM_CONF"
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
local ts=$(date +"%Y%m%d_%H%M%S")
sysctl -a 2>/dev/null | grep -E "net\.ipv4\.tcp_(rmem|wmem|congestion|sack)" > "${BACKUP_DIR}/backup_${ts}.conf"
if [ $? -eq 0 ]; then echo -e "${GREEN}[成功] 参数已自动备份。${NC}"; else echo -e "${YELLOW}[警告] 自动备份异常或不支持当前系统。${NC}"; fi
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
local ts=$(date +"%Y%m%d_%H%M%S")
sysctl -a 2>/dev/null | grep -E "net\.ipv4\.tcp_(rmem|wmem|congestion|sack)" > "${BACKUP_DIR}/backup_${ts}.conf"
if [ $? -eq 0 ]; then echo -e "\n${GREEN}[成功] TCP 参数备份成功！${NC}"; else echo -e "\n${RED}[错误] 备份执行失败。${NC}"; fi
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
sysctl -p "${backups[$((res_opt-1))]}" > /dev/null 2>&1
if [ $? -eq 0 ]; then rm -f "$CUSTOM_CONF"; echo -e "\n${GREEN}[成功] 参数已成功还原！${NC}"; else echo -e "\n${RED}[错误] 还原参数失败。${NC}"; fi
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
bash <(curl -sL --connect-timeout 10 https://Check.Place)
local check_ret=$?
if [ $check_ret -ne 0 ] && [ $check_ret -ne 1 ]; then
    echo -e "\n${RED}[错误] 网络不通或检测脚本无法下载，请检查服务器出墙连通性。${NC}"
fi
pause_for_enter
}

view_deployed_nodes() {
while true; do
clear_screen; print_divider
print_center "[ 节点状态、分享与配置备份管理 ]" "$CYAN"
install_dependencies
echo -e "${CYAN}--- 服务端底层配置状态 ---${NC}"
if [ -f "/usr/local/etc/xray/config.json" ] && grep -q "inbounds" "/usr/local/etc/xray/config.json"; then
jq -r '.inbounds[] | "【Xray】 端口: \(.port) | 协议: \(.protocol) | 网络: \(if .protocol == "hysteria" then "udp" else (.streamSettings.network // "tcp") end) | 安全: \(.streamSettings.security // "none")"' /usr/local/etc/xray/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
else
echo -e "${YELLOW}未检测到 Xray 节点配置。${NC}"
fi
if [ -f "/etc/sing-box/config.json" ] && grep -q "inbounds" "/etc/sing-box/config.json"; then
jq -r '.inbounds[] | "【Sing-box】 端口: \(.listen_port) | 协议: \(.type) | 网络: \(if .type == "hysteria2" then "udp" else (.transport.type // "tcp") end) | 安全: \(if (.tls?.reality?.enabled? // false) then "reality" elif (.tls?.enabled? // false) then "tls" else "none" end)"' /etc/sing-box/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
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
local info=$(echo "${links[$i]}" | awk -F' \\| ' '{print $1" "$2}')
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
local target_link=$(echo "${links[$((vn_opt-1))]}" | awk -F' \\| ' '{print $3}')
echo -e "\n${CYAN}>>> 节点分享链接：${NC}\n${target_link}\n"
echo -e "${YELLOW}>>> 节点二维码 (手机扫码)：${NC}"
qrencode -t UTF8 -s 1 -m 2 "$target_link"
pause_for_enter
elif [[ "$vn_opt" =~ ^[bB]$ ]]; then
if ! confirm_action "备份当前节点配置"; then continue; fi
local ts=$(date +"%Y%m%d_%H%M%S")
local bk_path="${BACKUP_DIR}/node_backup_${ts}"
mkdir -p "$bk_path"
[ -f "/usr/local/etc/xray/config.json" ] && cp /usr/local/etc/xray/config.json "$bk_path/xray_config.json"
[ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json "$bk_path/singbox_config.json"
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
if ! confirm_action "还原此备份 (当前配置将被覆盖，且服务会在后台重启)" "n"; then continue; fi
local sel_bk="${n_backups[$((n_res_opt-1))]}"
[ -f "$sel_bk/xray_config.json" ] && cp "$sel_bk/xray_config.json" /usr/local/etc/xray/config.json && ( sleep 1; _svc_restart xray >/dev/null 2>&1 ) &
[ -f "$sel_bk/singbox_config.json" ] && cp "$sel_bk/singbox_config.json" /etc/sing-box/config.json && ( sleep 1; _svc_reload sing-box >/dev/null 2>&1 ) &
[ -f "$sel_bk/vpsbox_nodes.txt" ] && cp "$sel_bk/vpsbox_nodes.txt" "$NODE_RECORD_FILE"
echo -e "\n${GREEN}[成功] 节点配置已成功还原！服务将在后台重启。${NC}"; pause_for_enter
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
if [ -f "/usr/local/etc/xray/config.json" ] && grep -q "inbounds" "/usr/local/etc/xray/config.json"; then
echo -e "${CYAN}【Xray 节点】${NC}"
jq -r '.inbounds[] | "  - 端口: \(.port) | 协议: \(.protocol) | 网络: \(if .protocol == "hysteria" then "udp" else (.streamSettings.network // "tcp") end) | 安全: \(.streamSettings.security // "none")"' /usr/local/etc/xray/config.json 2>/dev/null
nodes_found=1
fi
if [ -f "/etc/sing-box/config.json" ] && grep -q "inbounds" "/etc/sing-box/config.json"; then
echo -e "\n${CYAN}【Sing-box 节点】${NC}"
jq -r '.inbounds[] | "  - 端口: \(.listen_port) | 协议: \(.type) | 网络: \(if .type == "hysteria2" then "udp" else (.transport.type // "tcp") end) | 安全: \(if (.tls?.reality?.enabled? // false) then "reality" elif (.tls?.enabled? // false) then "tls" else "none" end)"' /etc/sing-box/config.json 2>/dev/null
nodes_found=1
fi
if [ "$nodes_found" -eq 0 ]; then echo -e "${YELLOW}未检测到任何已部署的节点，无需删除。${NC}"; pause_for_enter; return; fi
echo ""
while true; do
read -r -p "> 请输入要删除的节点【端口号】 (输入 0 取消): " del_port
del_port="${del_port// /}"
if [ "$del_port" == "0" ]; then return; fi
if [ -z "$del_port" ] || ! [[ "$del_port" =~ ^[0-9]+$ ]]; then echo -e "${RED}[错误] 端口号必须是有效的纯数字！请重新输入。${NC}"; continue; fi
local port_exists=0
if [ -f "/usr/local/etc/xray/config.json" ] && jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then port_exists=1; fi
if [ -f "/etc/sing-box/config.json" ] && jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then port_exists=1; fi
if [ "$port_exists" -eq 0 ]; then echo -e "${RED}[错误] 当前部署中未找到端口为 $del_port 的节点，请检查！${NC}"; continue; fi
break
done
if ! confirm_action "永久删除端口为 $del_port 的节点" "n"; then pause_for_enter; return; fi
if [ -f "/usr/local/etc/xray/config.json" ]; then
if jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then
jq "del(.inbounds[] | select(.port == $del_port))" /usr/local/etc/xray/config.json > /tmp/xray_tmp.json
if [ -s /tmp/xray_tmp.json ]; then
mv /tmp/xray_tmp.json /usr/local/etc/xray/config.json
echo -e "${GREEN}[成功] 已成功移除 Xray 中占用端口 $del_port 的节点配置！${NC}"
( sleep 1; _svc_restart xray >/dev/null 2>&1 ) &
else
rm -f /tmp/xray_tmp.json; echo -e "${RED}[错误] Xray 节点删除失败，配置可能受损！${NC}"
fi
fi
fi
if [ -f "/etc/sing-box/config.json" ]; then
if jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then
jq "del(.inbounds[] | select(.listen_port == $del_port))" /etc/sing-box/config.json > /tmp/sb_tmp.json
if [ -s /tmp/sb_tmp.json ]; then
mv /tmp/sb_tmp.json /etc/sing-box/config.json
echo -e "${GREEN}[成功] 已成功移除 Sing-box 中占用端口 $del_port 的节点配置！${NC}"
( sleep 1; _svc_reload sing-box >/dev/null 2>&1 ) &
else
rm -f /tmp/sb_tmp.json; echo -e "${RED}[错误] Sing-box 节点删除失败，配置可能受损！${NC}"
fi
fi
fi
if [ -f "$NODE_RECORD_FILE" ]; then sed -i "/端口:${del_port} /d" "$NODE_RECORD_FILE" 2>/dev/null; fi
pause_for_enter
}

append_inbound() {
local CONFIG_FILE=$1; local NEW_INBOUND=$2; local TARGET_PORT=$3; local CORE_NAME=$4
local TMP_FILE="/tmp/vpsbox_test_config.json"
if [ -f "$CONFIG_FILE" ] && grep -q "inbounds" "$CONFIG_FILE"; then
echo -e "${YELLOW}[系统] 检测到已有配置，正在生成并验证测试配置...${NC}"
if [ "$CORE_NAME" == "Sing-box" ]; then timeout 10 jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.listen_port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > "$TMP_FILE" 2>/dev/null
else timeout 10 jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > "$TMP_FILE" 2>/dev/null; fi
if [ ! -s "$TMP_FILE" ]; then echo -e "\n${RED}[错误] 配置合并失败，可能是已有配置文件格式异常${NC}"; echo -e "${YELLOW}当前配置内容:${NC}"; head -20 "$CONFIG_FILE"; return 1; fi
echo -e "${GREEN}  ✓ 配置初步合并完毕${NC}"
else
echo -e "${YELLOW}[系统] 首次部署，正在初始化并验证配置文件...${NC}"
if [ "$CORE_NAME" == "Sing-box" ]; then cat > "$TMP_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"type":"direct"}]}
EOF
else cat > "$TMP_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"protocol":"freedom"}]}
EOF
fi
fi
local TEST_PASS=0
local VALIDATE_OUT; VALIDATE_OUT=$(mktemp)
if [ "$CORE_NAME" == "Sing-box" ]; then
    local SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
    if _svc_is_active sing-box 2>/dev/null; then
        if timeout 10 "$SB_BIN" check -c "$TMP_FILE" >"$VALIDATE_OUT" 2>&1; then
            TEST_PASS=1
            echo -e "${GREEN}  ✓ JSON 语法校验通过${NC}"
        else
            echo "sing-box check 失败" >> "$VALIDATE_OUT"
        fi
    else
        if "$SB_BIN" run -c "$TMP_FILE" >"$VALIDATE_OUT" 2>&1 & local SB_PID=$!; then :; fi
        sleep 3
        if kill -0 "$SB_PID" 2>/dev/null; then
            TEST_PASS=1
            kill "$SB_PID" 2>/dev/null; wait "$SB_PID" 2>/dev/null
        else
            wait "$SB_PID" 2>/dev/null; local SB_EXIT=$?
            echo "sing-box 启动后立即退出 (exit=$SB_EXIT)" >> "$VALIDATE_OUT"
        fi
    fi
else
    local X_BIN=$(command -v xray || echo "/usr/local/bin/xray")
    if "$X_BIN" run -test -c "$TMP_FILE" >"$VALIDATE_OUT" 2>&1; then TEST_PASS=1; fi
fi

if [ "$TEST_PASS" -eq 1 ]; then 
    mv "$TMP_FILE" "$CONFIG_FILE"
    rm -f "$VALIDATE_OUT"
    return 0
else 
    echo -e "\n${RED}[校验错误]${NC}"
    cat "$VALIDATE_OUT" 2>/dev/null
    rm -f "$TMP_FILE" "$VALIDATE_OUT"
    return 1; 
fi
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
echo -e "${YELLOW}>>> 小白科普：VLESS-Reality 是一种先进的伪装技术。不需要您购买域名，直接“借用”大厂（如苹果、微软）的域名进行伪装，安全性极高，非常适合防封锁。${NC}\n"

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
if ! command -v xray &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Xray 核心，请耐心等待...${NC}"; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; hash -r; command -v xray &>/dev/null || { echo -e "\n${RED}[错误] Xray 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
X_BIN=$(command -v xray || echo "/usr/local/bin/xray"); KEYS=$("$X_BIN" x25519)
PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
NEW_INBOUND='{"port":'$PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"'$SNI_DOMAIN':443","serverNames":["'$SNI_DOMAIN'"],"privateKey":"'$PRI'","shortIds":["'$SHORT_ID'"]}}}'
else
CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心，请耐心等待...${NC}"; bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box"); KEYS=$("$SB_BIN" generate reality-keypair)
PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$PORT',"users":[{"uuid":"'$UUID'","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"'$SNI_DOMAIN'","reality":{"enabled":true,"handshake":{"server":"'$SNI_DOMAIN'","server_port":443},"private_key":"'$PRI'","short_id":["'$SHORT_ID'"]}}}'
fi

LINK="vless://${UUID}@${LINK_IP}:${PORT}?encryption=none&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&flow=xtls-rprx-vision#R"

if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$PORT" "Xray" 2>/dev/null || append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$PORT" "Sing-box" 2>/dev/null; then
    # 先输出节点信息，防止重载断网导致用户看不到信息
    output_node_result "$LINK" "Reality" "$PORT" "$CORE_NAME"
    echo -e "\n${YELLOW}>>> [注意] 正在后台重载代理核心以应用新配置...${NC}"
    echo -e "${YELLOW}>>> 节点信息已保存，若当前 SSH 通过本节点代理连接，重载时可能短暂卡顿，稍后重连即可。${NC}"
    
    # 修复：后台异步重载，输出重定向防止阻塞 SSH 会话
    if [ "$CORE_NAME" == "Xray" ]; then
        ( sleep 1; _svc_restart xray && _svc_enable xray >/dev/null 2>&1 ) &
    else
        ( sleep 1; _svc_reload sing-box && _svc_enable sing-box >/dev/null 2>&1 ) &
    fi
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
DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
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
    read -r -p "> CF API Token: " CF_Token; [ -z "$CF_Token" ] && continue
    read -r -p "> CF Account ID: " CF_Account_ID; [ -z "$CF_Account_ID" ] && continue
    export CF_Token="$CF_Token"; export CF_Account_ID="$CF_Account_ID"; break
else
    if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IPV6" ]; then
        echo -e "\n${YELLOW}[警告] 域名解析 IP ($DOMAIN_IP) 与本机 IP 不符！${NC}"
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
acquire_cert "$DOMAIN" "$cert_mode" "$CF_Token" "$CF_Account_ID" || { pause_for_enter; return; }
if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
    echo -e "\n${RED}[错误] 证书文件缺失: $CERT_DIR/${NC}"; ls -la "$CERT_DIR/" 2>/dev/null; pause_for_enter; return
fi

CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心...${NC}"; bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败。${NC}"; pause_for_enter; return; }; fi

PASSWORD=$(openssl rand -base64 12 | tr -d '+/=' | head -c 16)
NEW_INBOUND='{"type":"anytls","listen":"::","listen_port":'$PORT',"users":[{"password":"'$PASSWORD'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
LINK="anytls://${PASSWORD}@${DOMAIN}:${PORT}?peer=${DOMAIN}&udp=1#AnyTLS-${PORT}"

if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$PORT" "Sing-box"; then
    output_node_result "$LINK" "AnyTLS" "$PORT" "$CORE_NAME"
    echo -e "\n${YELLOW}>>> [注意] 正在后台重载核心服务以应用新配置...${NC}"
    ( sleep 1; _svc_reload sing-box && _svc_enable sing-box >/dev/null 2>&1 ) &
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
    local CF_Account_ID="$4"

    # 按域名分离证书目录，杜绝不同域名复用同一证书
    CERT_DIR="/etc/vpsbox-cert/${DOMAIN}"
    mkdir -p "$CERT_DIR"

    install_dependencies
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh -s email=dummy@vpsbox.com >/dev/null 2>&1
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then echo -e "\n${RED}[错误] Acme.sh 安装失败！${NC}"; return 1; fi
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m dummy@vpsbox.com >/dev/null 2>&1
    echo -e "\n${CYAN}>>> 正在为 ${YELLOW}${DOMAIN}${CYAN} 申请 SSL 证书...${NC}\n${YELLOW}   DNS 验证可能需要 30-60 秒，请耐心等待${NC}"

    local PORT_80_SERVICE=""
    local CERT_RES=1

    # 修复：不仅看 acme.sh list 还要检查物理文件 + 目标目录证书有效性
    if /root/.acme.sh/acme.sh --list | grep -q "$DOMAIN"; then
        if [ -f "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer" ] || [ -f "/root/.acme.sh/${DOMAIN}/${DOMAIN}.cer" ]; then
            # 进一步验证：目标 CERT_DIR 中的证书是否存在且属于该域名
            if [ -f "$CERT_DIR/fullchain.pem" ] && openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject 2>/dev/null | grep -qi "$DOMAIN"; then
                echo -e "${GREEN}[成功] 检测到本地有效证书（域名匹配），复用机制触发！${NC}"
                CERT_RES=0
            else
                echo -e "${YELLOW}[提示] 检测到 acme.sh 证书记录但目标证书目录不匹配，将重新安装证书到 ${CERT_DIR}${NC}"
            fi
        else
            echo -e "${YELLOW}[警告] 检测到损坏的历史证书记录，正在深度清理并重新申请...${NC}"
            /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
            rm -rf "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"
        fi
    fi

    if [ "$CERT_RES" -ne 0 ]; then
        if [ "$cert_mode" == "1" ]; then
            export CF_Token="$CF_Token"; export CF_Account_ID="$CF_Account_ID"
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256; CERT_RES=$?
        else
            if ss -tlnp | grep -q "\b:80\b"; then
                PORT_80_SERVICE=$(ss -tlnp | grep "\b:80\b" | awk -F'"' '{print $2}' | grep -v "^$" | head -n 1)
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE=$(fuser 80/tcp 2>/dev/null | awk '{print $1}')
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE="未知程序"
                echo -e "\n${YELLOW}[警告] 检测到 80 端口正被 [ ${PORT_80_SERVICE} ] 占用！${NC}"
                read -r -p "> 是否仍要临时关闭强行申请？(y/n, 默认 n): " force_kill_80
                if [[ ! "${force_kill_80// /}" =~ ^[yY]$ ]]; then echo -e "${CYAN}已取消操作。${NC}"; return 1; fi
                _svc_stop "$PORT_80_SERVICE" > /dev/null 2>&1; fuser -k 80/tcp > /dev/null 2>&1; sleep 2
            fi
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; CERT_RES=$?
            if [ -n "$PORT_80_SERVICE" ] && [ "$PORT_80_SERVICE" != "未知程序" ]; then
                _svc_start "$PORT_80_SERVICE" >/dev/null 2>&1 || echo -e "${RED}[注意] ${PORT_80_SERVICE} 恢复失败。${NC}"
            fi
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
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem; chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    return 0
}

install_ws_tls_node() {
clear_screen; print_divider
print_center "[ 部署 VLESS-WS-TLS 节点 ]" "$CYAN"
echo -e "${YELLOW}>>> 小白科普：WS+TLS 是非常经典的节点协议。最大的优势是可以搭配 Cloudflare 等 CDN 使用。如果您服务器的 IP 已经被墙，用这个协议配合 CDN 就能“起死回生”。${NC}\n"

while true; do
read -r -p "> 请输入域名 (输入 0 取消): " DOMAIN
DOMAIN="${DOMAIN// /}"
if [ "$DOMAIN" == "0" ]; then return; fi
if [ -z "$DOMAIN" ]; then continue; fi
DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
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
echo -e "\n${YELLOW}>>> 如何获取 Cloudflare API Token 和 Account ID？${NC}"
echo -e "  ${GREEN}1.${NC} 登录 Cloudflare 控制台: https://dash.cloudflare.com"
echo -e "  ${GREEN}2.${NC} 点击右上角头像 →「我的个人资料」→「API 令牌」"
echo -e "  ${GREEN}3.${NC} 点击「创建令牌」→ 选择「编辑区域 DNS」模板"
echo -e "  ${GREEN}4.${NC} 权限选「区域 - DNS - 编辑」，区域选你的域名，创建后复制 Token"
echo -e "  ${GREEN}5.${NC} Account ID: 返回仪表盘主页，右侧「⋮」→ 复制账户 ID"
echo ""
while true; do
read -r -p "> 请输入您的 Cloudflare API Token (输入 0 取消): " CF_Token
CF_Token="${CF_Token// /}"
if [ "$CF_Token" == "0" ]; then return; fi
if [ -z "$CF_Token" ]; then continue; fi
read -r -p "> 请输入您的 Cloudflare Account ID (输入 0 取消): " CF_Account_ID
CF_Account_ID="${CF_Account_ID// /}"
if [ "$CF_Account_ID" == "0" ]; then return; fi
if [ -z "$CF_Account_ID" ]; then continue; fi
export CF_Token="$CF_Token"; export CF_Account_ID="$CF_Account_ID"; break
done
cert_mode=1
if ! confirm_action "开始部署 WS+TLS 节点并申请证书"; then pause_for_enter; return; fi
acquire_cert "$DOMAIN" "$cert_mode" "$CF_Token" "$CF_Account_ID" || { pause_for_enter; return; }
UUID=$(cat /proc/sys/kernel/random/uuid); WSPATH="/$(openssl rand -hex 4)"
if [ "$core_choice" == "1" ]; then
CORE_NAME="Xray"
if ! command -v xray &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Xray 核心，请耐心等待...${NC}"; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; hash -r; command -v xray &>/dev/null || { echo -e "\n${RED}[错误] Xray 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"port":'$WS_PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"wsSettings":{"path":"'$WSPATH'"}}}'
else
CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心，请耐心等待...${NC}"; bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$WS_PORT',"users":[{"uuid":"'$UUID'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"},"transport":{"type":"ws","path":"'$WSPATH'"}}'
fi

LINK="vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&alpn=h2,http/1.1&type=ws&host=${DOMAIN}&path=${WSPATH}#WS"

if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$WS_PORT" "Xray" 2>/dev/null || append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$WS_PORT" "Sing-box" 2>/dev/null; then
    output_node_result "$LINK" "WS-TLS" "$WS_PORT" "$CORE_NAME"
    echo -e "\n${YELLOW}>>> [注意] 正在后台重载核心服务以应用新配置...${NC}"
    if [ "$CORE_NAME" == "Xray" ]; then
        ( sleep 1; _svc_restart xray && _svc_enable xray >/dev/null 2>&1 ) &
    else
        ( sleep 1; _svc_reload sing-box && _svc_enable sing-box >/dev/null 2>&1 ) &
    fi
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
DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
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
echo -e "\n${YELLOW}>>> 如何获取 Cloudflare API Token 和 Account ID？${NC}"
echo -e "  ${GREEN}1.${NC} 登录 Cloudflare 控制台: https://dash.cloudflare.com"
echo -e "  ${GREEN}2.${NC} 点击右上角头像 →「我的个人资料」→「API 令牌」"
echo -e "  ${GREEN}3.${NC} 点击「创建令牌」→ 选择「编辑区域 DNS」模板"
echo -e "  ${GREEN}4.${NC} 权限选「区域 - DNS - 编辑」，区域选你的域名，创建后复制 Token"
echo -e "  ${GREEN}5.${NC} Account ID: 返回仪表盘主页，右侧「⋮」→ 复制账户 ID"
echo ""
read -r -p "> 请输入您的 Cloudflare API Token: " CF_Token
if [ -z "$CF_Token" ]; then continue; fi
read -r -p "> 请输入您的 Cloudflare Account ID: " CF_Account_ID
if [ -z "$CF_Account_ID" ]; then continue; fi
export CF_Token="$CF_Token"; export CF_Account_ID="$CF_Account_ID"; break
elif [ "$cert_mode" == "2" ]; then
if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IPV6" ]; then 
echo -e "\n${YELLOW}[警告] 域名解析 IP ($DOMAIN_IP) 与本机 IP 不符！${NC}"
echo -e "${YELLOW}  ⚠️  可能开启了 Cloudflare 小黄云，Hysteria2 无法通过 CDN 代理！${NC}"
echo -e "${YELLOW}  请去 CF 控制台关闭该域名的代理（改为灰色云朵），或者换用 API 模式申请证书。${NC}"
read -r -p "> 是否强行继续？(y/n, 默认 n): " force_continue
if [[ ! "${force_continue// /}" =~ ^[yY]$ ]]; then continue; fi
fi
break
fi
done
if ! confirm_action "开始部署 Hysteria2 节点并申请证书"; then pause_for_enter; return; fi
acquire_cert "$DOMAIN" "$cert_mode" "$CF_Token" "$CF_Account_ID" || { pause_for_enter; return; }
HY2_PASS=$(openssl rand -hex 8)
if [ "$core_choice" == "1" ]; then
CORE_NAME="Xray"
if ! command -v xray &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Xray 核心，请耐心等待...${NC}"; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; hash -r; command -v xray &>/dev/null || { echo -e "\n${RED}[错误] Xray 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"listen":"0.0.0.0","port":'$HY2_PORT',"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"'$HY2_PASS'","email":"user@vpsbox"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"minVersion":"1.3","certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"'$HY2_PASS'","udpIdleTimeout":60}}}'
else
CORE_NAME="Sing-box"
if ! command -v sing-box &> /dev/null; then echo -e "${YELLOW}   首次部署需下载 Sing-box 核心，请耐心等待...${NC}"; bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; hash -r; command -v sing-box &>/dev/null || { echo -e "\n${RED}[错误] Sing-box 核心下载失败，请检查网络连接。${NC}"; pause_for_enter; return; }; fi
NEW_INBOUND='{"type":"hysteria2","listen":"::","listen_port":'$HY2_PORT',"users":[{"password":"'$HY2_PASS'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
fi

LINK="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#H2"

if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$HY2_PORT" "Xray" 2>/dev/null || append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$HY2_PORT" "Sing-box" 2>/dev/null; then
    output_node_result "$LINK" "Hys2" "$HY2_PORT" "$CORE_NAME"
    echo -e "\n${YELLOW}>>> [注意] 正在后台重载核心服务以应用新配置...${NC}"
    if [ "$CORE_NAME" == "Xray" ]; then
        ( sleep 1; _svc_restart xray && _svc_enable xray >/dev/null 2>&1 ) &
    else
        ( sleep 1; _svc_reload sing-box && _svc_enable sing-box >/dev/null 2>&1 ) &
    fi
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
    local N=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep "REJECT" | head -1 | awk '{print $1}')
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
if [[ "$rule_num" =~ ^[0-9]+$ ]]; then ufw --force delete "$rule_num" || echo -e "${RED}[错误] 删除规则失败。${NC}"; echo -e "${GREEN}[成功] 规则 $rule_num 已尝试删除！${NC}"; fi
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
USED_PORTS=$(ss -tlnpu 2>/dev/null | awk 'NR>1 {split($5,a,":"); p=a[length(a)]; if(p~/^[0-9]+$/) print p}' | sort -n | uniq)
for p in $USED_PORTS; do
  [ "$p" = "$SSHPORT" ] && continue
  ufw allow "$p" > /dev/null 2>&1 && echo -e "${GREEN}  ✓ 放行端口: ${p}${NC}" || echo -e "${YELLOW}  - 端口 ${p} 放行失败${NC}"
done
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
  sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
         -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
         -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
         -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
  # 安全处理 sshd_config.d 覆盖：注释冲突配置而非直接删除文件
  if [ -d /etc/ssh/sshd_config.d ] && [ -n "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^\(PubkeyAuthentication\|PasswordAuthentication\|PermitRootLogin\|ChallengeResponseAuthentication\) /#\0/' "$f" 2>/dev/null
    done
  fi
  _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
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
  sed -i -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  # 安全处理 sshd_config.d 覆盖：注释冲突配置而非直接删除文件
  if [ -d /etc/ssh/sshd_config.d ] && [ -n "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^\(PubkeyAuthentication\|PasswordAuthentication\|PermitRootLogin\|ChallengeResponseAuthentication\) /#\0/' "$f" 2>/dev/null
    done
  fi
  _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
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
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"
  echo "$_ghkeys" >> "${HOME}/.ssh/authorized_keys"
  sed -i -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  # 安全处理 sshd_config.d 覆盖：注释冲突配置而非直接删除文件
  if [ -d /etc/ssh/sshd_config.d ] && [ -n "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^\(PubkeyAuthentication\|PasswordAuthentication\|PermitRootLogin\|ChallengeResponseAuthentication\) /#\0/' "$f" 2>/dev/null
    done
  fi
  _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
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
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"
  echo "$_remote_keys" >> "${HOME}/.ssh/authorized_keys"
  sed -i -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
  echo -e "${GREEN}[成功] 已从 URL 导入公钥。${NC}"; pause_for_enter ;;
5)
  echo ""
  echo -e "${CYAN}--- authorized_keys 内容 ---${NC}"
  cat "${HOME}/.ssh/authorized_keys" 2>/dev/null || echo "(文件为空或不存在)"
  echo -e "${CYAN}----------------------------${NC}"
  pause_for_enter ;;
6)
  sed -i -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
         -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  # 安全处理 sshd_config.d 覆盖：注释冲突配置而非直接删除文件
  if [ -d /etc/ssh/sshd_config.d ] && [ -n "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^\(PubkeyAuthentication\|PasswordAuthentication\|PermitRootLogin\|ChallengeResponseAuthentication\) /#\0/' "$f" 2>/dev/null
    done
  fi
  _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
  echo -e "${GREEN}[成功] 密码登录已开启。${NC}"; pause_for_enter ;;
7)
  sed -i -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
         -e 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
         -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  # 安全处理 sshd_config.d 覆盖：注释冲突配置而非直接删除文件
  if [ -d /etc/ssh/sshd_config.d ] && [ -n "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^\(PubkeyAuthentication\|PasswordAuthentication\|PermitRootLogin\|ChallengeResponseAuthentication\) /#\0/' "$f" 2>/dev/null
    done
  fi
  _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null
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
    if ! grep -qE "UUID=$_uuid|[[:space:]]$_mnt[[:space:]]" /etc/fstab; then
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
  mkfs.$_fst "/dev/$_part" && echo -e "${GREEN}[成功] 格式化完成！${NC}" || echo -e "${RED}格式化失败！${NC}"
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
  local _exec_cmd=$(echo "${_exec_lines[$_exec_no]}" | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^[[:space:]]*//')
  echo -e "${CYAN}>>> 正在执行: $_exec_cmd${NC}"
  eval "$_exec_cmd"; pause_for_enter ;;
0) break ;;
*) echo -e "${RED}[提示] 编号错误。${NC}"; sleep 1 ;;
esac
done
}

manage_script() {
while true; do
clear_screen; print_divider
print_center "[ VPSBox 脚本管理 ]" "$CYAN"
local local_ver="${VPSBOX_VERSION:-未知}"
local remote_ver=$(curl -sL --max-time 3 https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh 2>/dev/null | grep -oP '^VPSBOX_VERSION="\K[^"]+' | head -1)
echo -e "  ${CYAN}本地版本:${NC} ${GREEN}${local_ver}${NC}"
[ -n "$remote_ver" ] && echo -e "  ${CYAN}最新版本:${NC} ${GREEN}${remote_ver}${NC}" || echo -e "  ${YELLOW}无法获取远程版本${NC}"

echo -e "  ${GREEN}1.${NC} 从 GitHub 更新到最新版本"
echo -e "  ${RED}2.${NC} 彻底卸载 VPSBox 及所有残留"
echo -e "  ${GREEN}0.${NC} 返回主菜单"; echo ""
read -r -p "> 请选择: " ms_opt
ms_opt="${ms_opt// /}"
case $ms_opt in
1)
if ! confirm_action "从 GitHub 拉取最新版覆盖当前脚本"; then continue; fi
echo -e "\n${CYAN}>>> 正在下载...${NC}"
curl -sL "https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh" -o /tmp/vpsbox_update.sh
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

# 主循环函数，调用时 stdin 重定向到 /dev/tty
_vpsbox_main() {
_VER_CHECKED=0

while true; do
clear_screen; print_divider
print_center "VPS Box  节点部署与服务器管家" "$PURPLE"
print_divider

echo -e "  ${CYAN}▶ 系统管理${NC}"
echo -e "  ${GREEN} 1.${NC} 系统信息总览        ${GREEN} 2.${NC} 系统更新与升级"
echo -e "  ${GREEN} 3.${NC} 系统垃圾清理        ${GREEN} 4.${NC} 修改 root 密码"
echo -e "  ${GREEN} 5.${NC} 修改主机名          ${GREEN} 6.${NC} 修改系统时区"
echo -e "  ${GREEN} 7.${NC} 虚拟内存管理        ${GREEN} 8.${NC} DNS 极速优化"
echo -e "  ${GREEN} 9.${NC} 修改 SSH 端口       ${GREEN}10.${NC} SSH 密钥管理"
echo -e "  ${GREEN}11.${NC} 磁盘分区管理        ${GREEN}12.${NC} 定时任务管理"
echo -e "  ${GREEN}13.${NC} 基础工具箱"

echo -e "\n  ${CYAN}▶ 网络优化${NC}"
echo -e "  ${GREEN}14.${NC} TCP 智能调优引擎    ${GREEN}15.${NC} 调优参数备份/还原"
echo -e "  ${GREEN}16.${NC} BBR 拥塞控制管理"

echo -e "\n  ${CYAN}▶ 节点部署${NC}"
echo -e "  ${GREEN}17.${NC} IP 质量与流媒体检测       ${GREEN}18.${NC} 部署 VLESS-Reality"
echo -e "  ${GREEN}19.${NC} 部署 VLESS-WS-TLS         ${GREEN}20.${NC} 部署 AnyTLS"
echo -e "  ${GREEN}21.${NC} 部署 Hysteria2            ${GREEN}22.${NC} 查看已部署节点"
echo -e "  ${GREEN}23.${NC} 删除指定节点"

echo -e "\n  ${CYAN}▶ 工具与安全${NC}"
echo -e "  ${GREEN}24.${NC} Docker 一键安装     ${GREEN}25.${NC} Fail2Ban 防暴力破解"
echo -e "  ${GREEN}26.${NC} WARP 解锁           ${GREEN}27.${NC} UFW 防火墙管理"
echo -e "  ${GREEN}00.${NC} 脚本管理（更新/卸载）"

echo -e "\n  ${GREEN} 0.${NC} 退出"
print_divider
echo ""
# 版本检测：首次运行时后台异步，不阻塞菜单显示
if [ "$_VER_CHECKED" -eq 0 ]; then
    _VER_CHECKED=1
    { _rmt=$(curl -sL --connect-timeout 2 --max-time 3 "https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh" 2>/dev/null | grep -oP '^VPSBOX_VERSION="\K[^"]+' | head -1)
      _rmt="${_rmt#v}"
      local_ver="${VPSBOX_VERSION#v}"
      if [ -n "$_rmt" ] && [ -n "$local_ver" ] && [ "$_rmt" != "$local_ver" ]; then
          IFS='.' read -ra rmt_parts <<< "$_rmt"
          IFS='.' read -ra loc_parts <<< "$local_ver"
          newer=0
          for i in 0 1 2; do
              r=${rmt_parts[$i]:-0}; l=${loc_parts[$i]:-0}
              if [ "$r" -gt "$l" ] 2>/dev/null; then newer=1; break; fi
              if [ "$r" -lt "$l" ] 2>/dev/null; then break; fi
          done
          if [ "$newer" -eq 1 ]; then
              echo "   ${GREEN}[新版本可用] ${_rmt} (当前: ${local_ver}) → 请选择 00 更新${NC}" > /tmp/vpsbox_version_msg
          fi
      fi
    } &
fi
# 显示缓存版本消息（上次后台检测的结果）
if [ -f /tmp/vpsbox_version_msg ]; then
    cat /tmp/vpsbox_version_msg
    rm -f /tmp/vpsbox_version_msg
else
    echo ""
fi
echo ""
read -r -p "> 请输入选择 [0-27,00]: " OPTION
OPTION="${OPTION// /}"
# 修复：curl|bash 管道关闭或空输入时继续循环而非退出
if [ -z "$OPTION" ]; then
    if [ ! -t 0 ]; then
        echo -e "\n${RED}[提示] 检测到输入流异常，请使用 ${GREEN}bash <(curl -sL ${SCRIPT_URL})${NC} 方式运行。${NC}"
        exit 1
    fi
    continue
fi
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
11) disk_manager ;;
12) crontab_manager ;;
13) tools_manager ;;
14) apply_tuning ;;
15) manage_backup ;;
16) manage_bbr ;;
17) check_media_unlock ;;
18) install_reality_node ;;
19) install_ws_tls_node ;;
20) install_anytls_node ;;
21) install_hy2_node ;;
22) view_deployed_nodes ;;
23) delete_node ;;
24) docker_install ;;
25) fail2ban_install ;;
26) install_warp ;;
27) manage_ufw ;;
00) manage_script ;; 
 0) echo -e "\n${GREEN}[感谢使用] 正在退出...${NC}\n"; exit 0 ;;
 *) echo -e "\n${RED}[提示] 编号不存在！${NC}"; sleep 1 ;;
esac
done
}

# 管道模式下函数调用时重定向 stdin 到终端，bash <() 模式下为无操作
_vpsbox_main </dev/tty