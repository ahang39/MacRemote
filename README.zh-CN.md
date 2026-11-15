# MacRemote

**用 Windows 自带远程桌面控制 Mac，保留熟悉的快捷键、剪贴板与操作习惯。**

MacRemote 为 macOS 提供原生 RDP 服务端。直接在 Windows 打开 **远程桌面连接（`mstsc`）**，即可连接 Mac 当前登录的桌面。无需安装专用 Windows 客户端、打开浏览器或依赖云中继。

[English](README.md) · [构建与运行](#构建与运行) · [技术架构](docs/ARCHITECTURE.md) · [参与贡献](CONTRIBUTING.md)

[![CI](https://github.com/ahang39/MacRemote/actions/workflows/source-checks.yml/badge.svg)](https://github.com/ahang39/MacRemote/actions/workflows/source-checks.yml)
![macOS](https://img.shields.io/badge/macOS-14%2B-222222?logo=apple)
![CPU](https://img.shields.io/badge/CPU-Apple%20Silicon%20%7C%20Intel-222222)

## 下载安装

**[MacRemote v0.1.0 首个 Ad-hoc 预览版](https://github.com/ahang39/MacRemote/releases/tag/v0.1.0-adhoc.1)** — 支持 macOS 14+。

| Mac 类型 | 下载 |
| --- | --- |
| Apple Silicon（M1/M2/M3/M4 等） | [ARM64 DMG](https://github.com/ahang39/MacRemote/releases/download/v0.1.0-adhoc.1/MacRemote-v0.1.0-macos-arm64.dmg) |
| Intel（x86_64） | [Intel DMG](https://github.com/ahang39/MacRemote/releases/download/v0.1.0-adhoc.1/MacRemote-v0.1.0-macos-x86_64.dmg) |

下载后将 App 拖入「应用程序」。由于 Ad-hoc 签名未经过苹果公证，首次启动若被阻止，可在「系统设置 → 隐私与安全性 → 仍要打开」中允许。启动 RDP 前请授予屏幕录制权限。

## 为什么选择 MacRemote？

### Windows 原生远程桌面体验

直接使用 Windows 自带的 `mstsc`，输入 Mac 地址即可按熟悉的 RDP 方式远程操作。MacRemote 基于 FreeRDP Shadow 与 ScreenCaptureKit，连接的是 **Mac 当前已登录的真实桌面**，支持键鼠控制、自定义端口和原生 SwiftUI 菜单栏管理。

### 远程操作也兼容 Karabiner 快捷键

常规远程注入的按键容易绕过 macOS 键盘映射。MacRemote **自动读取现有 Karabiner-Elements 配置**，在 RDP 输入链路内直接兼容支持的 **basic manipulator** 规则：

- 键位重映射、组合修饰键、按前台应用生效的规则、鼠标按键映射
- 支持的窗口快捷操作在 MacRemote 内直接执行
- 配置变化自动重新加载，无需额外常驻键盘映射服务
- 未安装或未配置 Karabiner 时，直接使用原生 Quartz 输入

兼容的是 Karabiner 基础规则子集，不涵盖全部复杂规则语义。[查看实现原理](docs/adr/0008-inprocess-karabiner-compat.md)。

### 兼容 Windows 的剪贴板与换行习惯

通过标准 RDP 剪贴板通道在 Windows 与 Mac 之间双向复制**文本和图片**，处理 PNG/DIB 格式和复制回环。文字换行在 **Windows 和 Mac 两端统一为 CRLF（`\r\n`）**，减少跨平台编辑、粘贴和输入法的换行差异。

## 功能一览

| 能力 | 实现 |
| --- | --- |
| **标准 RDP** | Windows `mstsc` 与其他 RDP 客户端；FreeRDP 3.33.1 Shadow |
| **Mac 账号登录** | TLS + macOS PAM，使用已有 Mac 账户 |
| **真实桌面** | ScreenCaptureKit 捕获已登录的显示器 |
| **键鼠控制** | Quartz 原生输入 + 内置 Karabiner 基础规则兼容 |
| **双向剪贴板** | 文本、图片、PNG/DIB、Windows CRLF 换行 |
| **原生管理界面** | SwiftUI 菜单栏、服务启停、权限引导、端口持久化 |
| **独立 App** | 打包所需运行时依赖，目标 Mac 运行时不依赖 Homebrew |

Windows `mstsc` 已通过 **Classic 图形模式**连接验证；H.264/AVC444 图形协商持续优化中，详见[技术记录](docs/m2/AVC444.md)。

## 构建与运行

**环境要求：** macOS 14+ 的 64 位 Mac、Xcode Command Line Tools，以及 Homebrew 构建依赖 CMake、Ninja、pkg-config、Opus、OpenSSL 4、json-c。构建脚本会按需拉取固定版本 FreeRDP 3.33.1。

```bash
git clone https://github.com/ahang39/MacRemote.git
cd MacRemote
./tools/build-dev-app.sh
```

构建完成后，在 `~/Library/Caches/MacRemote/product/` 下得到 `MacRemote-*.app`。打开应用、授予 macOS「屏幕与系统音频录制」权限，然后在菜单栏启动 RDP 服务。

Windows 端运行 `mstsc`，连接 Mac IP 地址（默认 TCP **3389**），使用已有 Mac 账户登录。端口可修改，并在后续启动时保持设置。

构建选项、签名与测试方法参见[构建指南](docs/m2/README.md)。

**网络安全：** 建议通过可信局域网或 VPN 使用，输入 Mac 密码前检查 RDP 证书。当前认证为 TLS + PAM（不使用 NLA），不要将监听端口直接暴露到公网。[安全说明](SECURITY.md)。

## 技术架构

```text
Windows mstsc / 标准 RDP 客户端
                 |
         FreeRDP Shadow
          /     |     \
 ScreenCaptureKit  输入  CLIPRDR
                      |
              Karabiner 基础规则
                原生兼容处理
                      |
                  macOS 桌面
```

服务端使用 C/Objective-C，管理界面基于 AppKit/SwiftUI；在固定版本 FreeRDP 上实现 macOS 系统集成，不依赖自定义远程桌面协议或额外的远控客户端。

项目提供[架构文档](docs/ARCHITECTURE.md)、[技术决策](docs/adr/)、[测试说明](docs/TESTING.md)与[性能实验](benchmarks/)。本地构建包含 11 项 CTest 和 Swift 端口偏好设置测试。

## 开发计划

- [ ] 完成 Windows `mstsc` 对 Karabiner、剪贴板、输入法、断线重连、睡眠唤醒的全面回归
- [ ] 完善证书信任与桌面会话恢复
- [ ] 优化 H.264/AVC444 图形通道并发布可复现性能数据
- [ ] 完成第三方依赖许可审查后提供正式签名、公证安装包

详细进展见[发布验收清单](docs/RELEASE_CHECKLIST.md)。

## 参与贡献

欢迎提交 Issue、可复现的兼容性报告和 Pull Request。参见[贡献指南](CONTRIBUTING.md)与[安全政策](SECURITY.md)。

## 使用许可

项目使用条款见 [LICENSE](LICENSE)，第三方组件许可证见[第三方声明](THIRD_PARTY_NOTICES.md)。
