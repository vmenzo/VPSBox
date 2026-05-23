<p align="center">
  <img src="https://img.shields.io/badge/platform-linux-blue" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash" alt="bash">
</p>

## VPS Box

VPS 全功能管理脚本，集系统优化、BBR 内核管理、三协议节点部署、工具箱于一体。一条命令搞定服务器运维。

---

### 快速开始

```bash
bash <(curl -sL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh)
```

> 兼容传统管道方式：`curl -fsSL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh | bash`

首次运行自动注册 `vpsbox` 全局命令，后续直接敲 `vpsbox` 进入主菜单。

---

### 支持系统

| 发行版 | 包管理器 |
|--------|----------|
| Debian 10+ / Ubuntu 18.04+ / Kali / Mint / Deepin / Pop!_OS / Armbian | apt |
| CentOS 7/8 / RHEL / Rocky / Alma / Oracle | yum / dnf |
| Fedora | dnf |
| Alpine | apk |
| Arch / Manjaro | pacman |
| openSUSE | zypper |

---

### 主菜单

```
▶ 系统管理
   1. 系统信息总览          2. 系统更新与升级
   3. 系统垃圾清理          4. 修改 root 密码
   5. 修改主机名            6. 修改系统时区
   7. 虚拟内存 Swap 管理    8. DNS 极速优化
   9. 修改 SSH 端口        10. SSH 密钥管理
  11. 磁盘分区管理         12. 定时任务管理
  13. 基础工具箱

▶ 网络优化
  14. TCP 智能调优引擎     15. 调优参数备份/还原
  16. BBR 拥塞控制管理

▶ 节点部署
  17. IP 质量与流媒体检测  18. 部署 VLESS-Reality
  19. 部署 VLESS-WS-TLS   20. 部署 Hysteria2
  21. 查看已部署节点       22. 删除指定节点

▶ 工具与安全
  23. Docker 一键安装      24. Fail2Ban 防暴力破解
  25. WARP 解锁           26. UFW 防火墙管理
  00. 脚本更新/卸载

   0. 退出
```

---

### 功能详解

#### 系统管理

| 功能 | 说明 |
|------|------|
| 系统信息总览 | CPU 型号/架构/核心数、内存/磁盘/网络吞吐、虚拟化类型、ISP/地理位置、运行时长、xray/sing-box/docker/fail2ban 服务状态 |
| 系统更新与升级 | 自动检测包管理器执行全量更新，apt 系统先修复 dpkg 锁 |
| 系统垃圾清理 | autoremove 废弃依赖 + 包缓存清理 + journal 日志裁剪（保留 500M） |
| 修改 root 密码 | 交互式修改，密码不回显，失败可重试 |
| 修改主机名 | 字母/数字/连字符校验，同步更新 /etc/hosts |
| 修改系统时区 | 一键北京时间（Asia/Shanghai），支持自定义时区 |
| Swap 管理 | 创建/修改/删除，内存自适应推荐大小，fallocate 优先，Alpine 开机自启适配 |
| DNS 优化 | Google / Cloudflare / 阿里 / 腾讯 / 自定义，自动处理 systemd-resolved 冲突 |
| SSH 端口 | 10000-65534 范围校验，修改后提醒控制台放行 |
| SSH 密钥管理 | 生成 ed25519 密钥对、粘贴公钥、GitHub 用户名拉取、URL 导入、查看/清空 authorized_keys、密码登录开关 |
| 磁盘分区管理 | 检测新磁盘、一键格式化 ext4/xfs、自动挂载写入 fstab、UUID 方式 |
| 定时任务 | crontab 可视化管理，添加/查看/删除/清空 |
| 基础工具箱 | 17 个常用工具（见下方），输入序号安装，`d+序号` 卸载，实时 ✅❌ 状态 |

#### 基础工具箱

```
curl  wget  sudo  socat  htop  iftop  unzip  tar  tmux
ffmpeg  btop  ranger  ncdu  fzf  vim  nano  git
```

---

#### 网络优化

**TCP 智能调优引擎**

自动读取 CPU 核心数和内存总量，计算最优 TCP 缓冲区、连接队列、TIME_WAIT 回收等参数。提供多种预设方案：均衡/吞吐优先/低延迟/巨帧，调优参数可一键备份还原。

**BBR 拥塞控制管理**

| 分类 | 选项 | 说明 |
|------|------|------|
| 内核安装 | BBR Cloud | Google BBR 优化版 |
| | BBRplus 新版 | 暴力发包增强 |
| | BBRv3 (推荐) | Google BBRv3 |
| | Debian Cloud | Debian 官方云内核 |
| | 官方稳定 | 官方最新稳定内核 |
| | 官方最新 | 官方主线内核 |
| 加速启用 | BBR+FQ / +FQ_PIE / +CAKE | 三种队列算法切换 |
| | BBRplus+FQ | BBRplus 加速 |
| 系统配置 | ECN 开关 | 显式拥塞通知 |
| | 防CC/DDOS优化 | SYN Cookie + 连接限制 |
| | IPv6 开关 | 完全禁用/启用 |
| | 合并/编辑内核参数 | sysctl 手动调参 |
| 内核管理 | 查看/删除已安装内核 | 多内核共存管理 |
| | 卸载全部加速 | 恢复系统原生配置 |

---

#### 节点部署

三协议一键部署，终端直接展示二维码手机扫码导入。自动检测 Xray / Sing-box 双核心，首次自动安装，配置写入后语法核验并重启服务。

| 协议 | 传输 | 伪装 | 域名 | 适用场景 |
|------|------|------|------|----------|
| VLESS-Reality | TCP + xtls-rprx-vision | 偷大厂 TLS | 不需要 | 防封锁首选，零配置 |
| VLESS-WS-TLS | WebSocket + TLS | 自有域名证书 | 需要 | 套 CDN，兼容性好 |
| Hysteria2 | QUIC / UDP | 自签证书 | 需要 | 暴力发包，低延迟 |

**IP 质量检测**

多运营商并发检测（百度/字节/腾讯/阿里），流媒体解锁（Netflix/Disney+/YouTube），IP 欺诈分/风险等级评估。

---

#### 工具与安全

| 功能 | 说明 |
|------|------|
| Docker | 一键安装，国内镜像加速（linuxmirrors），已有安装智能跳过 |
| Fail2Ban | 防 SSH 暴力破解，自动适配 auth.log / secure / messages，自定义封禁时长和重试次数 |
| WARP | Cloudflare WARP 双栈（IPv4+IPv6），解锁 Netflix/Disney+ 等流媒体，支持切换/卸载 |
| UFW 防火墙 | 安装/启停/端口放行/规则删除，智能清理 Oracle 自带 REJECT 规则，一键仅放行在用端口 |

---

### 跨平台适配

脚本内部所有系统调用均通过封装层，无需手动适配：

- **服务管理** — `_svc_restart/start/stop/enable/is_active` 自动检测 systemd / Alpine rc-service
- **包管理器** — `_pkg_install/_pkg_remove` 统一接口，覆盖 6 种包管理器
- **日志路径** — Fail2Ban 自动适配 `/var/log/auth.log` / `secure` / `messages`
- **DNS/防火墙** — 发行版通用路径，无需手动判断

---

### 卸载

```bash
rm -f /usr/local/bin/vpsbox && rm -rf /etc/vpsbox_backups
```

或脚本内 `00 → 2` 交互式卸载。

---

### 终端截图

```
===========================================
         VPS Box  节点部署与服务器管家
===========================================

  ▶ 系统管理
   1. 系统信息总览         2. 系统更新与升级
   3. 系统垃圾清理         4. 修改 root 密码
   5. 修改主机名           6. 修改系统时区
   7. 虚拟内存 Swap 管理   8. DNS 极速优化
   9. 修改 SSH 端口       10. SSH 密钥管理
  11. 磁盘分区管理        12. 定时任务管理
  13. 基础工具箱

  ▶ 网络优化
  14. TCP 智能调优引擎    15. 调优参数备份/还原
  16. BBR 拥塞控制管理

  ▶ 节点部署
  17. IP 质量与流媒体检测 18. 部署 VLESS-Reality
  19. 部署 VLESS-WS-TLS  20. 部署 Hysteria2
  21. 查看已部署节点      22. 删除指定节点

  ▶ 工具与安全
  23. Docker 一键安装     24. Fail2Ban 防暴力破解
  25. WARP 解锁          26. UFW 防火墙管理
  00. 脚本更新/卸载

   0. 退出
===========================================
> 请输入选择 [0-26,00]:
```

---

### License

MIT — 随意使用、修改、分发。
