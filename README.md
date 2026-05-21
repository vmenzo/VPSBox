# VPS Box — 轻量级节点管理与服务器管家

一键部署 VLESS-Reality / WS-TLS / Hysteria2 节点，集系统优化、BBR 内核管理、工具箱于一体。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh | bash
```

首次运行后自动注册全局命令 `vpsbox`，后续直接终端输入即可。

## 支持系统

Debian / Ubuntu / CentOS / Rocky / Alma / Fedora / Alpine / Arch / openSUSE 等主流 Linux 发行版。

## 功能

| 分类 | 功能 |
|------|------|
| 系统管理 | 信息总览、更新升级、垃圾清理、root密码、主机名、时区、Swap、DNS、SSH端口/密钥、磁盘管理、定时任务、基础工具箱(17工具) |
| 网络优化 | TCP智能调优、BBR内核管理(6种内核+4种加速+ECN+防CC) |
| 节点部署 | VLESS-Reality、VLESS-WS-TLS、Hysteria2 (Xray/Sing-box双核自适应) |
| 工具安全 | Docker、Fail2Ban、WARP解锁、UFW防火墙 |

## 卸载

```bash
rm -f /usr/local/bin/vpsbox && rm -rf /etc/vpsbox_backups
```

## License

MIT
