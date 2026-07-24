# 测试矩阵

| 范围 | 场景 | 预期结果 |
| --- | --- | --- |
| 数据 | Codex 正常登录 | 显示本周剩余百分比、进度条和重置倒计时。 |
| 数据 | 未登录、过期或接口不可用 | 显示中文紧凑错误状态，不暴露 token 或原始响应。 |
| 界面 | 默认启动 | 窗口固定为 350 × 40，显示中文本周额度与重置倒计时。 |
| 界面 | 重置机会存在 | 界面不显示重置机会或到期详情。 |
| 托盘 | 显示 / 隐藏、窗口置顶、立即刷新、开机启动、退出 | 所有菜单项使用中文并正常工作。 |
| 单元测试 | `npm run test` | Vitest 全部通过。 |
| 前端构建 | `npm run build` | TypeScript 与 Vite 构建通过。 |
| Rust 检查 | `cargo check --manifest-path src-tauri\Cargo.toml` | Rust 静态检查通过。 |
| exe 打包 | `npm run package:exe` | 生成 `src-tauri\target\release\codex-meter.exe`。 |
| 安装包打包 | `npm run package:windows` | 生成精简版 MSI/NSIS，以及 `bundle\with-node\` 下的内置 Node 安装包。 |

Windows 打包前必须具备 Rust MSVC 工具链及 Visual Studio Build Tools 的 **Desktop development with C++** 工作负载。
