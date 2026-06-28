<p align="center">
  <img src="https://img.shields.io/badge/platform-linux-blue" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash" alt="bash">
  <img src="https://img.shields.io/badge/version-v1.3-orange" alt="version">
</p>

<h1 align="center">VPS Box</h1>

<p align="center">
  Linux VPS 综合管理脚本，集成系统维护、网络优化、安全配置、节点部署与常用服务管理。
</p>

---

## 项目定位

VPS Box 是一个面向 Linux VPS 的交互式运维工具。项目以菜单方式整合常见服务器管理流程，适用于新机初始化、代理节点部署、网络调优、安全加固和日常维护。

脚本重点关注以下目标：

- 降低常见 VPS 运维操作的复杂度
- 将系统层、网络层和服务层功能集中到统一入口
- 保留必要确认步骤，减少高风险操作误触
- 提供可重复执行的部署、查看、备份和清理流程

## 系统要求

- 需要 root 用户执行
- 支持主流 Linux 发行版，包括 Debian、Ubuntu、CentOS、Rocky、AlmaLinux、Fedora、Alpine、Arch、openSUSE 等
- 部分功能依赖系统包管理器、systemd/OpenRC、Docker、iptables、acme.sh 或第三方安装脚本
- NodeSeek Bot 当前仅建议在 Debian / Ubuntu 等 apt 系统使用

## 安装与运行

推荐使用以下命令运行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh)
```

首次运行后会自动同步快捷命令：

```bash
vpsbox
```

## 功能概览

### 系统维护

- 系统状态总览
- 系统更新与基础组件安装
- 垃圾清理
- Root 密码修改
- 主机名与时区配置
- Swap 管理
- DNS 优化
- SSH 端口与 SSH 密钥管理

### 网络与安全

- TCP 参数调优
- BBR 内核与拥塞控制管理
- 流媒体与 IP 质量检测
- Docker 与 Docker Compose 安装
- Fail2Ban 防护
- Cloudflare WARP
- UFW 防火墙管理

### 节点管理

- VLESS-Reality
- VLESS-WS-TLS
- AnyTLS
- Hysteria2
- Shadowsocks
- 端口转发管理
- 证书查看、续签和删除
- 已部署节点查看、二维码输出、删除、备份与恢复

节点部署支持 Xray 与 Sing-box。脚本会尽量以独立节点片段方式管理配置，减少新增或删除节点时对已有服务的影响。

### 应用管理

- PicVault 图床部署、更新、状态、日志、重启、停止、备份和卸载
- NodeSeek Bot 部署、更新、手动运行、手动验证 Cookie、日志、配置编辑和卸载

PicVault 首次安装后，第一个注册成功的网页端账号会自动成为管理员。

### AI 工具

- Codex CLI 安装、更新、状态查看和诊断
- Claude Code 安装、更新、状态查看和诊断
- Codex CLI 与 Claude Code 第三方 API 中转地址和 API Key 配置
- 安装后按各自命令提示完成账号登录

### 其他工具

- 磁盘分区、挂载、格式化和检查
- Cron 定时任务管理
- 常用运维工具安装
- VPSBox 脚本更新与卸载

## 目录与数据

常用路径如下：

- VPSBox 快捷命令：`/usr/local/bin/vpsbox`
- VPSBox 备份目录：`/etc/vpsbox_backups`
- 节点记录文件：`/etc/vpsbox_nodes.txt`
- Xray 配置目录：`/usr/local/etc/xray`
- Sing-box 配置目录：`/etc/sing-box`
- VPSBox 证书目录：`/etc/vpsbox-cert`
- PicVault 安装目录：`/opt/picvault`
- NodeSeek Bot 安装目录：`/opt/NodeSeek-Bot`
- Codex CLI 配置目录：`~/.codex`
- Claude Code 配置目录：`~/.claude`

## 注意事项

- 修改 SSH、防火墙、内核、磁盘和证书前，请确认当前 VPS 具备可恢复手段
- 涉及端口开放时，除系统防火墙外，还需要检查云厂商安全组规则
- 使用 Cloudflare 代理域名申请证书时，建议使用 DNS API 模式
- Docker、Xray、Sing-box、acme.sh、WARP 等功能依赖外部网络和上游脚本可用性
- Codex CLI 与 Claude Code 安装后需要按各自命令提示完成账号登录
- 卸载应用前请确认是否需要保留配置、数据库、图片或 Docker 数据卷

## License

MIT
