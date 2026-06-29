# XrayDeploy

Xray VLESS-Reality 批量部署工具，通过 SSH 一键在多台服务器上安装 Xray-core。

## 项目组成

```
XrayDeploy/
├── source/                  # C# WinForms 桌面程序
│   ├── Form1.cs             # 主窗体：服务器解析、预览、批量部署
│   ├── Program.cs           # 程序入口
│   └── XrayDeploy.csproj    # .NET 10.0 项目文件
├── scripts/
│   ├── xray-reality.sh      # Xray VLESS-Reality 一键安装脚本
│   └── xray-uninstall.sh    # Xray 卸载脚本
└── dist2/                   # 构建输出
```

## 功能

- **智能解析** — 支持多种格式粘贴服务器信息，自动识别 IP、端口、用户名、密码
- **批量部署** — 多台服务器并发执行，SSH 连接 + 上传脚本 + 远程安装一气呵成
- **预览确认** — 部署前可预览解析结果，避免误操作
- **实时日志** — 界面中实时显示每台服务器的安装进度

## 使用方式

### 桌面程序

1. 构建 `source/XrayDeploy.csproj`（需要 .NET 10.0 SDK）
2. 将 `scripts/xray-reality.sh` 放到程序同目录下
3. 运行程序，在文本框中粘贴服务器信息，格式支持：

**内联格式：**
```
192.168.1.100  22  root  mypassword
10.0.0.50      443 admin p@ssw0rd
```

**分块格式：**
```
IP：192.168.1.100
端口：22
用户名：root
密码：mypassword

IP：10.0.0.50
端口：443
用户名：admin
密码：p@ssw0rd
```

4. 点击「预览」检查识别结果
5. 点击「部署」开始批量安装

### 手动使用脚本

```bash
# 安装（默认 443 端口）
bash xray-reality.sh

# 指定端口和 SNI
bash xray-reality.sh -p 8443 -s www.google.com

# 重装时保留密钥
bash xray-reality.sh -v v25.1.1

# 卸载
bash xray-uninstall.sh
bash xray-uninstall.sh --all    # 同时卸载 Caddy
```

## 技术栈

| 组件 | 技术 |
|------|------|
| GUI | C# WinForms, .NET 10.0 |
| SSH | [SSH.NET](https://github.com/sshnet/SSH.NET) |
| 代理核心 | [Xray-core](https://github.com/XTLS/Xray-core) |
| 协议 | VLESS + XTLS-Reality (TCP) |

## 安装脚本特性

- 自动检测系统发行版（Debian/Ubuntu、RHEL/CentOS、Alpine）
- 自动识别 CPU 架构（amd64/arm64/armv7）
- 自动配置 BBR 拥塞控制
- 重装时保留现有密钥与配置
- 支持 OpenRC（Alpine）和 systemd
- 安装后输出 VLESS 链接和 Base64 订阅
