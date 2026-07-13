# 已知限制

- 额度数据来自非公开的只读服务响应；字段或认证方式变化时，应用会显示不可用状态而不会猜测额度。
- 当前仅启用 Codex provider，类型层中的其他 provider 为后续扩展预留。
- 官方当前暂停 5 小时额度时，接口可能只返回本周窗口；应用会自动识别并只显示「本周」。
- 重置机会数据仍会读取，但已从 350 × 40 紧凑界面中隐藏。
- Windows 本地打包依赖 Rust MSVC 工具链和 Visual Studio Build Tools 的 **Desktop development with C++** 工作负载；缺少 `link.exe` 时无法生成 exe 或安装包。
- 未签名的 Windows 安装包可能触发 SmartScreen 提示。
- 应用读取本机 Codex 登录态，不会上传 token、账户 ID、原始响应或聊天内容。
