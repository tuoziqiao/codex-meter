# CodexMeter

CodexMeter 是一个轻量级 Windows 托盘工具，通过本机 CDP 将额度电量组件注入 Codex Desktop 标题栏。它不会修改官方安装包，也不需要额外登录；额度查询直接复用本机已登录的 Codex 会话。

![效果预览](docs/175329643.png)

## 当前功能

- 在 Codex 标题栏“帮助”菜单后显示剩余额度与重置日期。
- 展示真实额度数据，不包含 Mock 数据或随机刷新逻辑。
- 优先展示周额度；接口未提供周额度时回退到短周期额度。
- 额度低于 50% 显示黄色，低于 20% 显示红色，其余显示绿色。
- 后台定时刷新；托盘菜单支持立即刷新、开机启动和退出。
- 从托盘退出时清理已注入的标题栏组件。

## 工作方式

1. Rust 后端只读获取 Codex Desktop 的本机登录信息，并查询额度接口。
2. 后端将规范化后的额度通过标准输入发送给本机 Node.js CDP 注入器。
3. 注入器连接 Codex Desktop，并把电量组件和最新额度同步到标题栏。
4. 页面重新加载或新建窗口时，注入器会自动恢复组件和最新数据。

额度不可用时显示 `--`，不会猜测或伪造数据。

## 使用要求

- Windows
- 已安装并登录 Codex Desktop
- **精简安装包**需要本机已安装 Node.js；**内置 Node 安装包**不需要
- 从源码开发或构建时需要 Node.js、Rust MSVC 工具链和 Visual Studio Build Tools 的 **Desktop development with C++** 工作负载

## 本地开发

```powershell
npm install
npm test
npm run build
npm run tauri -- dev
```

## 构建

```powershell
# 生成可执行文件（不含内置 Node）
npm run package:exe

# 生成两套 MSI / NSIS：精简版 + 内置 Node 版
npm run package:windows
```

`package:windows` 产物：

- 精简版：`src-tauri/target/release/bundle/msi/`、`nsis/`（需系统 Node）
- 内置 Node 版：`src-tauri/target/release/bundle/with-node/msi/`、`with-node/nsis/`（文件名带 `-with-node`，约多 ~87MB）
## 关键文件

- `src-tauri/src/codex.rs`：读取登录状态并查询真实额度。
- `src-tauri/src/models.rs`：将接口数据映射为注入器消息。
- `src-tauri/src/cdp.rs`：`ensure_codex_cdp`、状态持久化、注入器进程管理。
- `src-tauri/resources/resolve-codex-install.ps1`：解析 Store 包身份（稳定版 / Beta）。
- `src-tauri/resources/launch-codex-cdp.ps1`：COM 启动、owl 回退、端口扫描（9335–9435）、CDP 校验。
- `src-tauri/resources/injector.mjs`：连接 Codex Desktop 并分发额度数据。
- `src-tauri/resources/inject.js`：标题栏电量组件及样式。
- `src/inject.test.ts`：注入位置、真实数据渲染和清理测试。
- `scripts/test-cdp-launch.ps1`：CDP 启动辅助自检（命令行状态 / 端口冲突）。

## 隐私说明

应用只在本机读取 Codex 登录状态并查询额度，不上传 token、账户 ID 或聊天内容。
