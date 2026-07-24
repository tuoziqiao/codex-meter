# Windows 发布说明

## 发布前检查

```powershell
npm run test
npm run build
cargo check --manifest-path src-tauri\Cargo.toml
```

确认悬浮窗固定为 350 × 40，并显示中文本周额度百分比、进度条和重置倒计时。

## 生成本地 Windows 产物

```powershell
# 裸 exe（不含内置 Node）
npm run package:exe

# MSI 和 NSIS：精简版 + 内置 Node 版
npm run package:windows
```

`package:exe` 输出 `src-tauri\target\release\codex-meter.exe`。

`package:windows` 一次打出两套：

| 变体 | 路径 | 说明 |
| --- | --- | --- |
| 精简版 | `src-tauri\target\release\bundle\msi\`、`nsis\` | 依赖本机 Node.js |
| 内置 Node 版 | `src-tauri\target\release\bundle\with-node\msi\`、`with-node\nsis\` | 捆绑 `node.exe`（约 +87MB），文件名带 `-with-node` |

打包脚本会下载并校验固定 LTS 的 `win-x64/node.exe`（缓存于 `src-tauri\.node-runtime-cache\`）。

两个命令会自动初始化 MSVC x64 环境。若提示缺少 Visual Studio Build Tools，请安装 **Desktop development with C++** 工作负载后重试。

## 发布后检查

- 启动产物，确认可读取本机 Codex Desktop 登录态。
- 确认窗口为中文紧凑额度条，无语言切换项和重置机会显示。
- 托盘菜单可切换窗口置顶、开机启动，并可立即刷新额度。
- 对外分发前确认是否需要 Windows 代码签名；未签名程序可能显示 SmartScreen 警告。
