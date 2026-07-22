# CodexMeter 项目简介

CodexMeter 是一个 Tauri 2 Windows 托盘工具。它只读复用本机 Codex Desktop 会话查询真实额度，并通过本机 CDP 把电量组件注入 Codex 标题栏“帮助”菜单之后。

## 数据链路

`Codex 本机会话 → Rust 额度查询 → JSON Lines → Node.js CDP 注入器 → 标题栏电量组件`

- 周额度存在时优先展示周额度。
- 周额度缺失时回退到短周期额度。
- 数据不可用时显示 `--`，不使用 Mock 数据。
- 托盘退出时向注入器发送关闭消息并移除组件。

## 关键文件

- `src-tauri/src/codex.rs`：本地登录状态和额度响应解析。
- `src-tauri/src/models.rs`：额度到注入消息的映射。
- `src-tauri/src/lib.rs`：刷新调度和托盘生命周期。
- `src-tauri/src/cdp.rs`：注入器进程管理。
- `src-tauri/resources/injector.mjs`：CDP 会话与消息分发。
- `src-tauri/resources/inject.js`：标题栏 UI。
- `src/inject.test.ts`：注入 UI 自动化测试。

## 开发命令

```powershell
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
cargo check --manifest-path src-tauri/Cargo.toml
```
