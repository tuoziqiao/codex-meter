
## Development

```bash
npm install
npm run test
cargo test --manifest-path src-tauri/Cargo.toml
npm run build
```

## Windows Packaging

Packaging requires Rust's Windows MSVC toolchain and Visual Studio Build Tools with the **Desktop development with C++** workload (which provides `link.exe`).

```bash
# Generate MSI and NSIS installers under src-tauri/target/release/bundle/
npm run package:windows

# Generate a standalone executable at src-tauri/target/release/codex-meter.exe
npm run package:exe
```
