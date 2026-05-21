<p align="center">
  <img src="https://img.shields.io/badge/platform-linux-blue" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash" alt="bash">
</p>

## VPS Box

VPS 全功能管理脚本——系统优化、BBR 内核管理、三协议节点部署、工具箱一步到位。

### 安装

```bash
curl -fsSL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh | bash
```

首次运行后自动注册全局命令 `vpsbox`，后续终端直接输入即可。

### 支持系统

| 发行版 | 包管理器 | 测试状态 |
|--------|----------|----------|
| Debian 10+ / Ubuntu 18.04+ | apt | ✅ |
| CentOS 7/8 / RHEL / Rocky / Alma / Oracle | yum/dnf | ✅ |
| Fedora | dnf | ✅ |
| Alpine | apk | ✅ |
| Arch / Manjaro | pacman | ✅ |
| openSUSE | zypper | ✅ |
| Kali / Mint / Deepin / Pop!_OS / Armbian | apt | ✅ |

### 功能菜单

```
▶ 系统管理
  1. 系统信息总览          2. 系统更新与升级
  3. 系统垃圾清理          4. 修改 root 密码
  5. 修改主机名            6. 修改系统时区
  7. 虚拟内存管理          8. DNS 极速优化
  9. 修改 SSH 端口        10. SSH 密钥管理
 11. 磁盘分区管理         12. 定时任务管理
 13. 基础工具箱

▶ 网络优化
 14. TCP 智能调优引擎     15. 调优参数备份/还原
 16. BBR 拥塞控制管理

▶ 节点部署
 17. IP 质量检测          18. 部署 VLESS-Reality
 19. 部署 VLESS-WS-TLS   20. 部署 Hysteria2
 21. 查看已部署节点       22. 删除指定节点

▶ 工具与安全
 23. Docker 一键安装      24. Fail2Ban 防暴力破解
 25. WARP 解锁           26. UFW 防火墙管理
 00. 脚本管理（更新/卸载）

  0. 退出
```

### 节点部署

一键部署代理节点，自动适配 Xray / Sing-box 双核心，首次自动安装，配置核验后重启服务，终端展示二维码手机扫码导入。

| 协议 | 传输 | 伪装方式 | 需要域名 |
|------|------|----------|----------|
| VLESS-Reality | TCP + xtls-rprx-vision | 偷大厂 TLS 证书 | 不需要 |
| VLESS-WS-TLS | WebSocket + TLS | 自有域名证书 | 需要 |
| Hysteria2 | QUIC / UDP | 自签证书 | 需要 |

### BBR 内核管理

| 分类 | 选项 |
|------|------|
| 内核安装 | BBR Cloud、BBRplus 新版、BBRv3(推荐)、Debian Cloud、官方稳定、官方最新 |
| 加速启用 | BBR+FQ、BBR+FQ_PIE、BBR+CAKE、BBRplus+FQ |
| 系统配置 | ECN 开关、防CC/DDOS优化、IPv6 开关、内核参数合并/编辑 |
| 内核管理 | 查看/删除已安装内核、卸载全部加速 |

### 基础工具箱

17 个常用工具，动态检测安装状态（✅已装 / ❌未装），输入序号安装，`d+序号` 卸载。

curl · wget · sudo · socat · htop · iftop · unzip · tar · tmux · ffmpeg · btop · ranger · ncdu · fzf · vim · nano · git

### 跨平台适配

- 服务管理 `_svc_*` 封装，自动检测 systemd / Alpine rc-service
- 包管理器 `_pkg_install/_pkg_remove` 统一接口，覆盖 apt/dnf/yum/apk/pacman/zypper
- Fail2Ban 日志路径自动适配 `/var/log/auth.log` / `secure` / `messages`
- DNS、Swap、防火墙全路径发行版通用

### 卸载

```bash
rm -f /usr/local/bin/vpsbox && rm -rf /etc/vpsbox_backups
```

或在脚本内选择 `00 → 2` 交互式卸载。
