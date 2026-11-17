# MacRemote — Windows MSTSC 回归记录（2026-11-16）

## 范围与环境

- MacRemote 源码基线：`2a002c5`；FreeRDP Shadow 3.33.1；安装版为个人签名的 macOS App。
- Windows 家用 PC 的原生 `mstsc.exe`，控制台已解锁，利用 Windows 凭据管理器保存的既有 RDP 认证信息；未读取、保存或打印密码。
- 局域网，Classic 图形模式，1920×1080@32 RDP；之前已单独完成 2304×1296 下 100%↔120% HiDPI、鼠标及断线重连测试。
- Windows 端通过**临时交互式 ScheduledTask** 运行测试程序，Mac 端用临时 Hammerspoon canvas/eventtap、临时 webview 与 AppKit pasteboard 检验真实视觉和输入事件。
- 状态分类：PASS=真实观测通过；FAIL=真实观测不满足；PARTIAL=部分链路通过但未覆盖完整用户交互；NOT RUN=未执行。

## 结果

| 分类 | 用例 | 结果 | 证据与结论 |
| --- | --- | --- | --- |
| 原生构建 | FreeRDP、C/ObjC/Swift、打包 | PASS | 重新构建成功；15/15 CTest，Swift 端口/分辨率/恢复测试通过；个人签名严格校验通过 |
| CLI 与设置 | status、doctor、非法 port/bind/gfx | PASS | 状态字段正确；0、65536、非法端口/绑定/图形配置均拒绝；端口持久化单元测试通过 |
| 认证与连接 | 原生 MSTSC、TLS/PAM | PASS | 真正完成 1920×1080@32 认证与激活，TCP ESTABLISHED，CLIPRDR 通道启动 |
| 视频 | Mac→Windows 实际画面 | PASS | Mac 临时画布四个红/绿/蓝/黄区域；Windows 以 GDI 屏幕采样获取四种对应颜色 |
| 指针输入 | 左键、右键、拖拽、滚轮双向 | PASS | Quartz 事件记录：左/右 mouseDown/Up，13 个连续 drag 移动，正负 scroll，按键成对 |
| 几何与重连 | 分辨率、HiDPI、连接后恢复 | PASS | 已有实际 2304×1296 100%↔120% 和 120% 断线重连；本轮 1920×1080 连入后逻辑分辨率正确 |
| 键盘事件 | 字母、数字、Shift/Ctrl/Alt、退格、Enter | PARTIAL | Quartz 确实收到对应 KeyDown/Up 和 flagsChanged；单独慢速输入“123”在网页文本框完整出现 |
| 快速连续键入 | 组合串 `Abc123[Backspace]4↵XYZ` | FAIL | 两次得到 `Abc24\nXYZ`（第一位数字“1”丢失），事件层有“1”的 down/up；慢速独立数字输入正常。仍需区分 AppKit/WebView 焦点/文本处理与 MacRemote 输入链路 |
| Karabiner | 基础重映射、修饰键、Insert / extended | PARTIAL | 单元测试覆盖；运行时正确加载 75 条规则、unsupported 0；实际 Insert 扩展事件已注入，但其最终行为未在目标应用中独立验证 |
| 文本剪贴板 Windows→Mac | 中文、Ω、Emoji、空行、CRLF | PASS | Unicode 原样，3 组 CRLF 保留，Mac pasteboard 检验通过 |
| 文本剪贴板 Mac→Windows | 中文、Ω、Emoji、空行 | PARTIAL | Win 获取的 UTF-16 码点正确；但 `Clipboard.GetText()` 收到 LF×3、CR×0，与项目约定 Windows CRLF 不一致 |
| 图片剪贴板 Windows→Mac | 32×24 Bitmap | PASS | Windows `Clipboard.SetImage` 后，Mac pasteboard 读取 PNG，32×24 一致 |
| 图片剪贴板 Mac→Windows | PNG→Windows 图像 | FAIL | Mac 设置 PNG 28×20，但 Windows `Clipboard.ContainsImage` 返回 false，见到 FileDrop/文本格式，并观测到 Mac pasteboard 被后续文本更新覆盖。需检查 CLIPRDR 格式通告/响应和其他剪贴板同步软件干扰 |
| 进程异常恢复 | 无客户端时强杀专用 RDP 服务 | PASS | GUI 检测 SIGKILL 并自动重启新进程，3389 恢复监听；原生 MSTSC 再次完成连接，保持输出分辨率 |
| macOS 系统共存 | Hammerspoon、桌面恢复 | PASS | 断开 RDP 后恢复原本地 2560×1072，不改变 RDP 输出默认值 |
| 音频 | 音频捕获/实际播放 | PARTIAL | 服务端日志记录 48kHz/2ch 采集；另有 audin WTSVirtualChannelQuery 警告，未完成 Windows 实际听音验证 |
| 安全与高风险场景 | 错误 Mac 密码、TCC 撤权、睡眠/唤醒、拔显示器 | NOT RUN | 不修改用户密码、安全设置和睡眠/硬件连接；证书由用户已有配置与真实连接处理，未单独验证证书信任提示 |
| UI | 菜单栏状态项/SwiftUI 弹窗、滑块拖动 | PARTIAL | 检查 MacRemote AX 菜单栏项存在，调用点击无错误；未获取稳定弹窗结构/未机械拖动滑块；前次缩放测试通过与滑块共享的 `DisplayOutputSettings.commit` |
| 性能 | 实际帧率、音视频延迟、网络丢包/弱网 | NOT RUN | 尚无可靠 Windows 呈现 FPS、延迟采样，避免猜测 |

## 回归后状态

- Windows 测试 MSTSC 已关闭；临时 ScheduledTask 与其脚本已清理；无残留测试客户端连接。
- Hammerspoon 测试画布、鼠标/键盘 eventtap、webview 已移除。
- macOS 本地显示器回到 2560×1072；MacRemote 默认 RDP 输出仍为 1920×1080，缩放档位 0；3389 IPv4/IPv6 正常监听，签名通过。
- 测试发现剪贴板会受到其他程序/对端更新；结束时保留当时的非测试剪贴板内容，以免覆盖新的真实内容。
- 本次只进行回归测试，**未修改 MacRemote 运行代码或覆盖用户安全配置**。

## 待处理（按优先级）

1. **P1** Mac→Windows 图片剪贴板：隔离第三方剪贴板管理器，检查 CLIPRDR FORMAT_LIST/FORMAT_DATA_REQUEST/RESPONSE，确保单向新图片不会被旧的远端数据回写覆盖。
2. **P1/P2** Mac→Windows 换行：验证 `CF_UNICODETEXT` 原始 UTF-16 响应字节与 .NET Clipboard.GetText 结果的差别，确定 LF 来源；按实际用户体验修复。
3. **P2** 快速连续键入丢字符：用原生 NSTextView 和不同输入速度重测，以区分 WebKit 组件行为和远控链路；然后做键盘/IME/扩展键真实应用层检查。
4. **P2** 实际 GUI 滑块、菜单 popover、音频播放、错误凭据拒绝、长时间 soak；在可控测试窗口补齐。
