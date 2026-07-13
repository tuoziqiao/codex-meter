# CodexMeter 项目简介

CodexMeter 是一个 Tauri 2 桌面悬浮窗，只读使用本机 Codex Desktop 登录态查询额度。

## 当前界面

- 固定窗口尺寸：350 × 40。
- 紧凑布局显示「本周」额度：剩余百分比、进度条、重置倒计时（如 `6天19小时`）。
- 官方暂停 5 小时额度时，界面只显示本周；若接口恢复独立 5 小时窗口，会自动再显示一行。
- 默认且唯一语言为中文；托盘菜单同样使用中文。
- 重置机会仍由后端读取，但当前界面不显示。

## 技术栈

- 前端：React、TypeScript、Vite。
- 桌面壳：Tauri 2、Rust。
- 网络：Rust `reqwest` 只读查询 Codex 额度响应。

## 关键文件

- `src/components/QuotaCard.tsx`：350 × 40 中文紧凑额度条。
- `src/lib/format.ts`：额度百分比和刷新策略。
- `src-tauri/src/codex.rs`：本地登录态与额度响应解析。
- `scripts/package-windows.ps1`：加载 MSVC 环境并构建 Windows 产物。

## 开发命令

```powershell
npm run test
npm run build
npm run package:exe
npm run package:windows
```

Windows 打包需要 Rust MSVC 工具链和 Visual Studio Build Tools 的 **Desktop development with C++** 工作负载。
