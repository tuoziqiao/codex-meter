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

/// Find the Codex Desktop executable (ChatGPT.exe inside the Appx package).
/// Uses Get-AppxPackage to locate the installation directory.
#[allow(dead_code)]
pub fn find_codex_exe() -> Result<PathBuf, String> {
    // Try AppxPackage via PowerShell — Codex is a Store app (OpenAI.Codex)
    if let Ok(output) = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "(Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation",
        ])
        .output()
    {
        if output.status.success() {
            let location = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !location.is_empty() {
                // Store app executable lives at {InstallLocation}\app\ChatGPT.exe
                let candidate = PathBuf::from(&location).join(r"app\ChatGPT.exe");
                if candidate.exists() {
                    return Ok(candidate);
                }
            }
        }
    }

    Err("Codex Desktop 未找到，请先安装 Codex Desktop。".into())
}

/// Stop all running ChatGPT (Codex) processes.
pub fn stop_codex() -> Result<(), String> {
    let _ = Command::new("taskkill")
        .args(["/IM", "ChatGPT.exe", "/F"])
        .output();
    // Give processes time to exit
    std::thread::sleep(Duration::from_secs(2));
    Ok(())
}

/// Get the AppUserModelId for the Codex Store package.
/// Returns e.g. "OpenAI.Codex_0.1.2.0_x64__abc123!App"
pub fn get_codex_app_user_model_id() -> Result<String, String> {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            r"$p = Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1; if ($p) { $m = Get-AppxPackageManifest -Package $p; $appId = ($m.Package.Applications.Application | Where-Object { $_.Executable -replace '/','\' -eq 'app\ChatGPT.exe' } | Select-Object -First 1).Id; if ($appId) { Write-Output ('{0}!{1}' -f $p.PackageFamilyName, $appId) } }",
        ])
        .output()
        .map_err(|e| format!("PowerShell 调用失败: {e}"))?;
    if !output.status.success() {
        return Err("无法获取 Codex AppUserModelId".into());
    }
    let id = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if id.is_empty() {
        return Err("未找到 Codex 的 ApplicationId".into());
    }
    Ok(id)
}

/// Launch Codex with CDP debugging port enabled.
/// Uses COM IApplicationActivationManager to activate the Store app with arguments,
/// matching the approach used by Codex-Dream-Skin.
pub fn launch_codex_with_cdp(port: u16) -> Result<(), String> {
    let app_id = get_codex_app_user_model_id()?;
    let args = format!("--remote-debugging-address=127.0.0.1 --remote-debugging-port={port}");

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
