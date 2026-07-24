# 开发与构建

## 本地开发

```powershell
npm install
npm run test
npm run build
npm run tauri -- dev
```

浏览器模式下执行 `npm run dev` 时使用 mock 数据；真实额度读取仅在 Tauri 桌面环境中生效。

## Windows 打包

打包前请安装：

- Rust MSVC 工具链；
- Visual Studio Build Tools 的 **Desktop development with C++** 工作负载（提供 `link.exe`）。

以下命令会自动定位 Build Tools 并加载 MSVC x64 环境：

```powershell
# 生成可直接运行的 exe
npm run package:exe

# 生成 MSI 与 NSIS（精简版 + 内置 Node 版）
npm run package:windows
```

产物位置：

- `src-tauri\target\release\codex-meter.exe`
- `src-tauri\target\release\bundle\msi\`、`nsis\`（精简版，需系统 Node）
- `src-tauri\target\release\bundle\with-node\msi\`、`with-node\nsis\`（内置 Node）

如果命令提示未找到 Build Tools，请在 Visual Studio Installer 中安装上述 C++ 工作负载后重新执行。
