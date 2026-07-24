use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use serde_json::Value;

pub const DEFAULT_CDP_PORT: u16 = 9335;

/// Fetch the browser-id from the CDP /json/version endpoint.
pub async fn get_browser_id(client: &reqwest::Client, port: u16) -> Result<String, String> {
    let url = format!("http://127.0.0.1:{port}/json/version");
    let response = client
        .get(&url)
        .timeout(Duration::from_secs(3))
        .send()
        .await
        .map_err(|e| format!("CDP version request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "CDP version request returned {}",
            response.status()
        ));
    }
    let body: Value = response
        .json()
        .await
        .map_err(|e| format!("CDP version parse failed: {e}"))?;
    let ws_url = body["webSocketDebuggerUrl"]
        .as_str()
        .ok_or("missing webSocketDebuggerUrl in CDP version response")?;
    // Extract browser-id from ws://127.0.0.1:PORT/devtools/browser/{id}
    let prefix = "/devtools/browser/";
    let id = ws_url
        .find(prefix)
        .map(|pos| &ws_url[pos + prefix.len()..])
        .ok_or("invalid webSocketDebuggerUrl format")?;
    if id.is_empty() {
        return Err("empty browser-id".into());
    }
    Ok(id.to_string())
}

/// Wait for CDP to become available, returning the browser-id.
pub async fn wait_for_cdp(
    client: &reqwest::Client,
    port: u16,
    timeout_secs: u64,
) -> Result<String, String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs);
    let mut last_error = String::new();
    while tokio::time::Instant::now() < deadline {
        match get_browser_id(client, port).await {
            Ok(id) => return Ok(id),
            Err(e) => last_error = e,
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
    Err(format!(
        "CDP did not become available on port {port} within {timeout_secs}s: {last_error}"
    ))
}

/// Find the Codex Desktop executable inside the validated Store package.
#[allow(dead_code)]
pub fn find_codex_exe() -> Result<PathBuf, String> {
    let install = resolve_codex_install()?;
    let candidate = PathBuf::from(&install.executable);
    if candidate.exists() {
        return Ok(candidate);
    }
    Err("Codex Desktop 未找到，请先安装 Codex Desktop。".into())
}

/// Stop all running ChatGPT / ChatGPT (Beta) (Codex) processes.
pub fn stop_codex() -> Result<(), String> {
    for image in ["ChatGPT.exe", "ChatGPT (Beta).exe"] {
        let _ = Command::new("taskkill").args(["/IM", image, "/F"]).output();
    }
    // Give processes time to exit
    std::thread::sleep(Duration::from_secs(2));
    Ok(())
}

/// Validated OpenAI.Codex Store package identity used for package activation.
#[derive(Debug, Clone)]
pub struct CodexInstall {
    pub app_user_model_id: String,
    pub package_root: String,
    pub executable: String,
    pub version: String,
}

/// Resolve the path to resolve-codex-install.ps1 (dev CWD, then exe-relative).
fn resolve_codex_install_ps1() -> Result<PathBuf, String> {
    if let Ok(cwd) = std::env::current_dir() {
        // Project root during `npm run tauri -- dev`
        let from_root = cwd
            .join("src-tauri")
            .join("resources")
            .join("resolve-codex-install.ps1");
        if from_root.exists() {
            return Ok(from_root);
        }
        // `cargo test` / cargo commands run with CWD = src-tauri
        let from_crate = cwd.join("resources").join("resolve-codex-install.ps1");
        if from_crate.exists() {
            return Ok(from_crate);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join("resources").join("resolve-codex-install.ps1");
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }
    Err("resolve-codex-install.ps1 资源文件未找到。".into())
}

fn powershell_error_message(stderr: &[u8], fallback: &str) -> String {
    let text = String::from_utf8_lossy(stderr);
    let trimmed = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or(fallback);
    // PowerShell Write-Error often prefixes with category info; keep the useful tail.
    if let Some(idx) = trimmed.rfind(": ") {
        let tail = trimmed[idx + 2..].trim();
        if !tail.is_empty() {
            return tail.to_string();
        }
    }
    trimmed.to_string()
}

/// Resolve the official Store Codex install via Appx manifest (Dream-Skin compatible).
pub fn resolve_codex_install() -> Result<CodexInstall, String> {
    let script = resolve_codex_install_ps1()?;
    let script_path = script
        .to_str()
        .ok_or_else(|| "resolve-codex-install.ps1 路径无效".to_string())?;

    let output = Command::new("powershell")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path])
        .output()
        .map_err(|e| format!("PowerShell 调用失败: {e}"))?;

    if !output.status.success() {
        let detail = powershell_error_message(&output.stderr, "无法解析 Codex 安装身份");
        return Err(format!("无法解析 Codex 安装身份: {detail}"));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let json_line = stdout
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with('{'))
        .ok_or_else(|| "无法解析 Codex 安装身份: 解析脚本未返回 JSON".to_string())?;

    let value: Value = serde_json::from_str(json_line)
        .map_err(|e| format!("无法解析 Codex 安装身份: JSON 无效 ({e})"))?;

    let app_user_model_id = value
        .get("appUserModelId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "无法解析 Codex 安装身份: 缺少 appUserModelId".to_string())?
        .to_owned();
    let package_root = value
        .get("packageRoot")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let executable = value
        .get("executable")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let version = value
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();

    Ok(CodexInstall {
        app_user_model_id,
        package_root,
        executable,
        version,
    })
}

/// Get the AppUserModelId for the Codex Store package.
/// Returns e.g. "OpenAI.Codex_xxx!App"
#[allow(dead_code)]
pub fn get_codex_app_user_model_id() -> Result<String, String> {
    Ok(resolve_codex_install()?.app_user_model_id)
}

/// Launch Codex with CDP debugging port enabled.
/// Uses COM IApplicationActivationManager to activate the Store app with arguments,
/// matching the approach used by Codex-Dream-Skin.
pub fn launch_codex_with_cdp(port: u16) -> Result<(), String> {
    let install = resolve_codex_install()?;
    let app_id = &install.app_user_model_id;
    let args = format!("--remote-debugging-address=127.0.0.1 --remote-debugging-port={port}");
    eprintln!(
        "[cdp] launching Codex {} ({}) from {} via {}",
        install.version,
        install.app_user_model_id,
        install.package_root,
        install.executable
    );

    // Use PowerShell + Add-Type to call COM IApplicationActivationManager
    // (same approach as Codex-Dream-Skin's Initialize-DreamSkinPackageLauncher)
    let ps_cmd = format!(
        r#"Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IApplicationActivationManager {{
    int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
}}
[Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
[ComImport]
class ApplicationActivationManager {{}}
public static class AppLauncher {{
    public static uint Launch(string id, string args) {{
        var m = (IApplicationActivationManager)new ApplicationActivationManager();
        uint pid; m.ActivateApplication(id, args ?? "", 0, out pid); return pid;
    }}
}}
'@; [AppLauncher]::Launch('{app_id}', '{args}')"#
    );

    let output = Command::new("powershell")
        .args(["-NoProfile", "-Command", &ps_cmd])
        .output()
        .map_err(|e| format!("启动 Codex (CDP) 失败: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("启动 Codex (CDP) 失败: {stderr}"));
    }
    Ok(())
}

/// Find the Node.js executable on PATH.
pub fn find_node_exe() -> Result<PathBuf, String> {
    if let Ok(output) = Command::new("where").args(["node"]).output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout)
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            if !path.is_empty() {
                let candidate = PathBuf::from(&path);
                if candidate.exists() {
                    return Ok(candidate);
                }
            }
        }
    }

    // Try common install locations
    if let Ok(sys_root) = std::env::var("ProgramFiles") {
        let node = PathBuf::from(sys_root).join("nodejs").join("node.exe");
        if node.exists() {
            return Ok(node);
        }
    }

    Err("Node.js 未找到，请安装 Node.js 并确保其在 PATH 中。".into())
}

/// Resolve the path to the injector.mjs resource file.
/// Checks CWD first (dev), then exe-relative (production).
pub fn resolve_injector_mjs() -> Result<PathBuf, String> {
    // Development: CWD/resources/injector.mjs
    if let Ok(cwd) = std::env::current_dir() {
        let candidate = cwd.join("src-tauri").join("resources").join("injector.mjs");
        if candidate.exists() {
            return Ok(candidate);
        }
    }
    // Production: exe_dir/resources/injector.mjs
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join("resources").join("injector.mjs");
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }
    Err("injector.mjs 资源文件未找到。".into())
}

/// Spawn the injector process in watch mode.
pub fn spawn_injector(
    node_exe: &std::path::Path,
    injector_mjs: &std::path::Path,
    port: u16,
    browser_id: &str,
) -> Result<Child, String> {
    #[cfg(windows)]
    const HIDDEN: u32 = 0x08000000; // CREATE_NO_WINDOW

    let mut cmd = Command::new(node_exe);
    cmd.args([
        injector_mjs.to_str().ok_or("invalid injector path")?,
        "--watch",
        "--port",
        &port.to_string(),
        "--browser-id",
        browser_id,
    ]);
    cmd.stdin(std::process::Stdio::piped());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    cmd.creation_flags(HIDDEN);

    let child = cmd
        .spawn()
        .map_err(|e| format!("启动 injector 失败: {e}"))?;
    Ok(child)
}

/// Send one JSON-line control message to the injector process.
pub fn send_injector_message(child: &mut Option<Child>, message: &str) -> Result<(), String> {
    let process = child
        .as_mut()
        .ok_or_else(|| "injector is not running".to_string())?;
    if process
        .try_wait()
        .map_err(|error| format!("failed to inspect injector process: {error}"))?
        .is_some()
    {
        return Err("injector has already exited".into());
    }
    let stdin = process
        .stdin
        .as_mut()
        .ok_or_else(|| "injector control channel is unavailable".to_string())?;
    stdin
        .write_all(message.as_bytes())
        .and_then(|_| stdin.write_all(b"\n"))
        .and_then(|_| stdin.flush())
        .map_err(|error| format!("failed to send injector message: {error}"))
}

/// Ask the injector to remove its UI and stop, then force-terminate it on timeout.
pub fn kill_injector(child: &mut Option<Child>) {
    if let Some(mut process) = child.take() {
        if let Some(mut stdin) = process.stdin.take() {
            let _ = stdin.write_all(b"shutdown\n");
            let _ = stdin.flush();
        }

        let graceful_deadline = Instant::now() + Duration::from_secs(4);
        while Instant::now() < graceful_deadline {
            match process.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                Err(_) => break,
            }
        }

        let _ = process.kill();
        let _ = process.wait();
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn resolves_installed_codex_store_identity() {
        let install = resolve_codex_install().expect("Codex Store package should be resolvable");
        assert!(
            install.app_user_model_id.contains('!'),
            "appUserModelId should be family!applicationId, got {}",
            install.app_user_model_id
        );
        assert!(
            PathBuf::from(&install.executable).exists(),
            "executable should exist: {}",
            install.executable
        );
        assert!(!install.version.is_empty());
    }
}
