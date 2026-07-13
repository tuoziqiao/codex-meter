# CodexMeter

CodexMeter 是一个轻量级 Windows 桌面悬浮窗，用于**只读**查看本机 Codex Desktop 的额度使用情况。无需额外登录，直接复用你已在本机登录的 Codex 会话。

![窗口尺寸](https://img.shields.io/badge/窗口-350×40-blue)
![平台](https://img.shields.io/badge/平台-Windows-lightgrey)
![技术栈](https://img.shields.io/badge/技术栈-Tauri%202%20%2B%20React-orange)

## 功能概览

- **紧凑悬浮窗**：固定 350 × 40 像素，可拖动到屏幕任意位置
- **额度展示**：显示「本周」剩余百分比、进度条与重置倒计时（如 `6天19小时`）
- **自动刷新**：后台定时拉取额度，接近重置时加快刷新频率
- **系统托盘**：右键菜单支持显示/隐藏、立即刷新、窗口置顶、开机启动、退出
- **隐私优先**：仅在本机读取 Codex 登录态，不上传 token、账户 ID 或聊天内容

> 若 Codex 官方恢复独立的 5 小时额度窗口，应用会自动识别并额外显示一行「5h」额度。

## 使用前准备

1. 已在 Windows 上安装并登录 **Codex Desktop**
2. 若从源码构建，还需安装下方「开发环境」中的工具

## 安装与使用

### 方式一：安装包（推荐）

从 Release 页面下载 `MSI` 或 `NSIS` 安装包，按向导完成安装后启动 **CodexMeter**。

安装包产物路径（本地构建时）：

```
src-tauri\target\release\bundle\msi\
src-tauri\target\release\bundle\nsis\
```

### 方式二：直接运行 exe

```
src-tauri\target\release\codex-meter.exe
```

### 日常使用

| 操作 | 说明 |
|------|------|
| 拖动窗口 | 在悬浮窗上按住鼠标左键拖动 |
| 显示 / 隐藏 | 托盘图标右键 → **显示 / 隐藏** |
| 立即刷新 | 托盘右键 → **立即刷新** |
| 窗口置顶 | 托盘右键 → **窗口置顶**（默认开启） |
| 开机启动 | 托盘右键 → **开机启动** |
| 退出 | 托盘右键 → **退出** |
| 关闭按钮 | 点击关闭会隐藏到托盘，不会退出程序 |

启动后若显示「Codex 登录已失效」，请先在 Codex Desktop 中重新登录。

## 开发环境

| 依赖 | 用途 |
|------|------|
| [Node.js](https://nodejs.org/) | 前端构建与脚本 |
| [Rust](https://www.rust-lang.org/)（MSVC 工具链） | Tauri 后端 |
| [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) | 安装 **Desktop development with C++** 工作负载（提供 `link.exe`） |

## 本地开发

```powershell
# 安装依赖
npm install

# 运行测试
npm run test

# 启动开发模式（真实额度读取仅在 Tauri 环境中生效）
npm run tauri -- dev
```

浏览器中单独执行 `npm run dev` 时使用的是 mock 数据，无法读取真实 Codex 额度。

## 构建与打包

```powershell
# 构建前端
npm run build

# 生成可直接运行的 exe
npm run package:exe

# 生成 MSI 与 NSIS 安装包
npm run package:windows
```

打包命令会自动定位 Visual Studio Build Tools 并加载 MSVC x64 环境。

**产物位置：**

| 产物 | 路径 |
|------|------|
| 可执行文件 | `src-tauri\target\release\codex-meter.exe` |
| MSI 安装包 | `src-tauri\target\release\bundle\msi\` |
| NSIS 安装包 | `src-tauri\target\release\bundle\nsis\` |

首次打包 MSI 时，Tauri 会自动下载 WiX 工具链并缓存到 `%LOCALAPPDATA%\tauri\WixTools314`。若网络受限，可手动将 `wix314-binaries.zip` 解压到该目录。

## 技术栈

- **前端**：React、TypeScript、Vite
- **桌面壳**：Tauri 2、Rust
- **网络**：Rust `reqwest` 只读查询 Codex 额度接口

## 已知限制

- 额度数据来自非公开只读接口；若官方变更字段或认证方式，应用会显示不可用状态，不会猜测额度数值
- 当前仅支持 Codex provider
- 未签名的 Windows 安装包可能触发 SmartScreen 安全提示
- Windows 本地打包依赖 MSVC 工具链与 C++ Build Tools

更多细节见 [`docs/KNOWN-LIMITATIONS.md`](docs/KNOWN-LIMITATIONS.md)。

## 项目结构

```
codex-meter-remote/
├── src/                    # React 前端
│   ├── components/         # 额度卡片等 UI 组件
│   └── lib/                # 格式化、桥接逻辑
├── src-tauri/              # Tauri / Rust 后端
│   ├── src/codex.rs        # Codex 登录态与额度解析
│   └── icons/              # 应用图标
├── scripts/                # Windows 打包脚本
└── docs/                   # 发布说明与项目文档
```

## 许可证

Copyright CodexMeter contributors
