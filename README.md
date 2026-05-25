<p align="center">
  <img src="https://img.shields.io/badge/platform-linux-blue" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash" alt="bash">
  <img src="https://img.shields.io/badge/version-v1.7.2-orange" alt="version">
</p>

## VPS Box

VPS 全功能管理脚本，集系统优化、BBR 内核管理、节点部署、证书申请、常用工具箱于一体。一条命令搞定服务器运维。

当前最新版：`v1.7.2`

本次版本重点补强：**节点热重载安全、删除节点回滚、证书复用校验、80 端口独立申请保护**。

---

### 快速开始

```bash
bash <(curl -sL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh)
```

> 兼容传统管道方式：`curl -fsSL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh | bash`

首次运行自动注册 `vpsbox` 全局命令，后续直接敲 `vpsbox` 进入主菜单。

---

### 支持系统

- Debian 10+
- Ubuntu 18.04+
- Kali / Mint / Deepin / Pop!_OS / Armbian
- CentOS 7/8 / RHEL / Rocky / Alma / Oracle
- Fedora
- Alpine
- Arch / Manjaro
- openSUSE

支持的包管理器：`apt` / `yum` / `dnf` / `apk` / `pacman` / `zypper`

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

### v1.7.2 更新亮点

- **节点改为单端口单文件片段管理**
  - Xray 与 Sing-box 均采用 `nodes.d` 目录保存独立节点片段
  - 新增/删除节点时先重建总配置，再校验后生效
  - 不再直接把所有节点硬写进一个大配置文件里

- **优先热重载，不强制重启核心**
  - Xray / Sing-box 服务自动补齐 `ExecReload=/bin/kill -HUP $MAINPID`
  - 新增或删除节点优先使用 `systemctl reload` / `HUP`
  - 热重载失败时直接报错并保留旧连接，不为了上线新配置而强制重启

- **删除节点支持自动回滚**
  - 删除时先临时挪走节点片段，不会先永久删文件
  - 只有在主配置重建成功、核心热重载成功后才真正删除
  - 若失败会自动恢复片段与旧配置，避免误删后服务异常

- **证书申请和复用逻辑更安全**
  - 证书目录按域名独立：`/etc/vpsbox-cert/<domain>`
  - 复用旧证书前会校验实际证书文件与 SAN 域名是否匹配
  - 申请失败或安装失败时自动清理残留，避免后续反复复用坏记录

- **80 端口独立模式更稳妥**
  - 若 80 端口被占用，只提示占用情况并中止 standalone 申请
  - 不再盲目停服务或强杀占用 80 的进程
  - 引导用户手动释放端口，或切换到 Cloudflare API 模式

- **Cloudflare 交互更干净**
  - API 申请仅要求 `CF_Token`
  - Token 输入隐藏显示
  - README 与脚本交互已对齐，不再暗示必须填写 Cloudflare Account ID

- **链接与配置结构更规范**
  - WS 链接中的 `alpn` 已做 URL 编码
  - Xray Hysteria2 入站结构已切换到新版 `hysteria2` 形态
  - 节点元数据统一写入 `/etc/vpsbox_node_runtime/`

---

### 功能详解

#### 系统管理

- **系统信息总览**：CPU 型号/架构/核心数、内存/磁盘/网络吞吐、虚拟化类型、ISP/地理位置、运行时长、xray/sing-box/docker/fail2ban 服务状态
- **系统更新与升级**：自动检测包管理器执行全量更新，apt 系统先修复 dpkg 锁
- **系统垃圾清理**：autoremove 废弃依赖 + 包缓存清理 + journal 日志裁剪（保留 500M）
- **修改 root 密码**：交互式修改，密码不回显，失败可重试
- **修改主机名**：字母/数字/连字符校验，同步更新 `/etc/hosts`
- **修改系统时区**：一键北京时间（`Asia/Shanghai`），支持自定义时区
- **Swap 管理**：创建/修改/删除，内存自适应推荐大小，`fallocate` 优先，Alpine 开机自启适配
- **DNS 优化**：Google / Cloudflare / 阿里 / 腾讯 / 自定义，自动处理 `systemd-resolved` 冲突
- **SSH 端口**：10000-65534 范围校验，修改后提醒控制台放行
- **SSH 密钥管理**：生成 ed25519 密钥对、粘贴公钥、GitHub 用户名拉取、URL 导入、查看/清空 `authorized_keys`、密码登录开关
- **磁盘分区管理**：检测新磁盘、一键格式化 ext4/xfs、自动挂载写入 fstab、UUID 方式
- **定时任务**：crontab 可视化管理，添加/查看/删除/清空
- **基础工具箱**：17 个常用工具，输入序号安装，`d+序号` 卸载，实时显示安装状态

#### 基础工具箱

```text
curl  wget  sudo  socat  htop  iftop  unzip  tar  tmux
ffmpeg  btop  ranger  ncdu  fzf  vim  nano  git
```

---

#### 网络优化

**TCP 智能调优引擎**

自动读取 CPU 核心数和内存总量，计算最优 TCP 缓冲区、连接队列、TIME_WAIT 回收等参数。提供多种预设方案：均衡 / 吞吐优先 / 低延迟 / 巨帧，调优参数可一键备份还原。

**BBR 拥塞控制管理**

- **内核安装**
  - BBR Cloud：Google BBR 优化版
  - BBRplus 新版：暴力发包增强
  - BBRv3（推荐）：Google BBRv3
  - Debian Cloud：Debian 官方云内核
  - 官方稳定：官方最新稳定内核
  - 官方最新：官方主线内核
- **加速启用**
  - BBR + FQ / FQ_PIE / CAKE
  - BBRplus + FQ
- **系统配置**
  - ECN 开关
  - 防 CC / DDoS 优化
  - IPv6 开关
  - 合并 / 编辑内核参数
- **内核管理**
  - 查看 / 删除已安装内核
  - 卸载全部加速，恢复系统原生配置

---

#### 节点部署

支持四种节点能力：**VLESS-Reality、VLESS-WS-TLS、AnyTLS、Hysteria2**。

终端可直接展示分享链接和二维码，手机扫码即可导入。脚本自动检测 Xray / Sing-box 双核心，首次部署时自动下载安装。

> 注意：当前主菜单展示的是 3 个一键入口（Reality / WS-TLS / Hysteria2）。AnyTLS 已在脚本中实现，属于 Sing-box 专属节点能力。

**节点管理架构**

节点管理采用“**单端口单文件片段 + 共用核心**”架构：每个节点独立写入 `nodes.d` 目录，再合并生成主配置并优先执行热重载，避免新增/删除节点时整体重启影响旧连接。

- Xray 主配置：`/usr/local/etc/xray/config.json`
- Sing-box 主配置：`/etc/sing-box/config.json`
- Xray 节点片段目录：`/usr/local/etc/xray/nodes.d/`
- Sing-box 节点片段目录：`/etc/sing-box/nodes.d/`
- 节点元数据目录：`/etc/vpsbox_node_runtime/`
- 元数据文件：`xray_nodes.json` / `singbox_nodes.json`

每创建一个节点，都会生成类似 `443-vless-ws-tls.json`、`8443-hysteria2.json` 这样的独立片段文件；脚本会将全部片段合并成主配置，校验通过后再执行热重载。

**协议说明**

- **VLESS-Reality**
  - 传输：TCP + `xtls-rprx-vision`
  - 域名：不需要
  - 特点：伪装大厂 TLS，防封锁首选

- **VLESS-WS-TLS**
  - 传输：WebSocket + TLS
  - 域名：需要
  - 特点：适合接入 Cloudflare CDN，兼容性高
  - Cloudflare 提示：需开启橙色云朵，并在 SSL/TLS 中使用“完全（严格）”

- **AnyTLS**
  - 核心：Sing-box 专属
  - 传输：TLS
  - 域名：需要
  - 特点：密码认证，结构简洁
  - 证书：支持 Cloudflare API 或 80 端口 standalone 申请

- **Hysteria2**
  - 传输：QUIC / UDP
  - 域名：需要
  - 特点：弱线路下速度优势明显
  - Cloudflare 提示：**不能**走 CDN 代理，必须灰云直连真实 IP

**热重载策略**

- Xray：自动补齐 `ExecReload=/bin/kill -HUP $MAINPID`
- Sing-box：自动补齐 `ExecReload=/bin/kill -HUP $MAINPID`
- 优先顺序：`systemctl reload` → `kill -HUP` → 服务未运行时尝试启动
- 若热重载失败：直接报错并保留旧连接，不自动重启

**删除节点安全策略**

- 根据元数据定位片段文件，而不是硬解析总配置
- 删除时先临时备份片段，再重建主配置并尝试热重载
- 只有成功后才真正移除片段与元数据
- 失败则自动回滚，尽量恢复到原先可用状态

**证书申请策略**

- Cloudflare API 模式：仅需 `CF_Token`
- Standalone 模式：需要 80 端口空闲
- 若 80 端口已占用：直接展示占用情况并退出，不强杀、不猜服务名、不自动停服务
- 复用证书前会校验 SAN 是否包含目标域名
- 安装后会再次校验证书可读性和域名匹配

**查看与备份恢复**

- 已部署节点列表支持查看分享链接与二维码
- 支持为节点配置创建快照备份
- 支持从历史快照恢复 `nodes.d`、主配置、元数据与分享记录

**IP 质量检测**

多运营商并发检测（百度 / 字节 / 腾讯 / 阿里），并集成 Netflix / Disney+ / YouTube 解锁检测与 IP 风险评估。

---

#### 工具与安全

- **Docker 一键安装**：支持国内镜像加速（linuxmirrors），已有安装自动跳过
- **Fail2Ban 防暴力破解**：自动适配 `auth.log` / `secure` / `messages`，可自定义封禁时长和重试次数
- **WARP 解锁**：Cloudflare WARP 双栈（IPv4 + IPv6），支持流媒体解锁、切换与卸载
- **UFW 防火墙管理**：安装 / 启停 / 端口放行 / 删除规则，并支持“一键仅放行在用端口”

---

### 跨平台适配

脚本内部所有系统调用都通过统一封装层处理，无需手动适配：

- **服务管理**：`_svc_restart / start / stop / enable / is_active` 自动适配 `systemd` / Alpine `rc-service`
- **包管理器**：`_pkg_install / _pkg_remove` 统一接口，覆盖 6 种包管理器
- **日志路径**：Fail2Ban 自动适配 `/var/log/auth.log` / `secure` / `messages`
- **DNS / 防火墙**：发行版通用路径，无需手动判断

---

### 卸载

```bash
rm -f /usr/local/bin/vpsbox && rm -rf /etc/vpsbox_backups
```

或脚本内 `00 → 2` 交互式卸载。

---

### 终端截图

```text
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
