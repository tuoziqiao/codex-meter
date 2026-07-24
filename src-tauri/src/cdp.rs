use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use serde_json::Value;

pub const DEFAULT_CDP_PORT: u16 = 9335;
pub const CDP_WAIT_TIMEOUT_SECS: u64 = 45;
const STATE_SCHEMA_VERSION: u32 = 1;

/// Result of ensuring a verified Codex CDP endpoint.
#[derive(Debug, Clone)]
pub struct CdpSession {
    pub port: u16,
    pub browser_id: String,
    pub strategy: String,
    pub package_family_name: Option<String>,
}

/// Validated OpenAI.Codex / OpenAI.CodexBeta Store package identity.
#[derive(Debug, Clone)]
pub struct CodexInstall {
    pub app_user_model_id: String,
    pub package_root: String,
    pub executable: String,
    pub version: String,
    pub package_name: Option<String>,
    pub package_family_name: Option<String>,
}

fn resource_path(file_name: &str) -> Result<PathBuf, String> {
    if let Ok(cwd) = std::env::current_dir() {
        let from_root = cwd.join("src-tauri").join("resources").join(file_name);
        if from_root.exists() {
            return Ok(from_root);
        }
        let from_crate = cwd.join("resources").join(file_name);
        if from_crate.exists() {
            return Ok(from_crate);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join("resources").join(file_name);
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }
    Err(format!("{file_name} 资源文件未找到。"))
}

fn powershell_error_message(stderr: &[u8], fallback: &str) -> String {
    let text = String::from_utf8_lossy(stderr);
    let trimmed = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or(fallback);
    if let Some(idx) = trimmed.rfind(": ") {
        let tail = trimmed[idx + 2..].trim();
        if !tail.is_empty() {
            return tail.to_string();
        }
    }
    trimmed.to_string()
}

fn first_json_object(stdout: &str) -> Option<&str> {
    stdout
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with('{'))
}

fn state_dir() -> Option<PathBuf> {
    dirs::data_dir().map(|dir| dir.join("CodexMeter"))
}

fn state_path() -> Option<PathBuf> {
    state_dir().map(|dir| dir.join("state.json"))
}

#[derive(Debug, Clone, Default)]
struct PersistedState {
    port: Option<u16>,
    #[allow(dead_code)]
    browser_id: Option<String>,
    #[allow(dead_code)]
    package_family_name: Option<String>,
}

fn read_persisted_state() -> PersistedState {
    let Some(path) = state_path() else {
        return PersistedState::default();
    };
    let Ok(raw) = std::fs::read_to_string(path) else {
        return PersistedState::default();
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return PersistedState::default();
    };
    let schema = value
        .get("schemaVersion")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if schema != u64::from(STATE_SCHEMA_VERSION) {
        return PersistedState::default();
    }
    PersistedState {
        port: value
            .get("port")
            .and_then(Value::as_u64)
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| (1024..=65535).contains(port)),
        browser_id: value
            .get("browserId")
            .and_then(Value::as_str)
            .map(str::to_owned),
        package_family_name: value
            .get("packageFamilyName")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

fn write_persisted_state(session: &CdpSession) {
    let Some(dir) = state_dir() else {
        return;
    };
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let Some(path) = state_path() else {
        return;
    };
    let payload = serde_json::json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "port": session.port,
        "browserId": session.browser_id,
        "packageFamilyName": session.package_family_name,
        "updatedAt": chrono::Utc::now().to_rfc3339(),
    });
    let Ok(text) = serde_json::to_string_pretty(&payload) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, text).is_ok() {
        let _ = std::fs::rename(tmp, path);
    }
}

/// Fetch the browser-id from the CDP /json/version endpoint (unverified).
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

/// Wait for CDP /json/version (legacy helper; prefer ensure_codex_cdp).
#[allow(dead_code)]
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
#[allow(dead_code)]
pub fn stop_codex() -> Result<(), String> {
    for image in ["ChatGPT.exe", "ChatGPT (Beta).exe"] {
        let _ = Command::new("taskkill").args(["/IM", image, "/F"]).output();
    }
    std::thread::sleep(Duration::from_secs(2));
    Ok(())
}

/// Resolve the official Store Codex install via Appx manifest.
pub fn resolve_codex_install() -> Result<CodexInstall, String> {
    let script = resource_path("resolve-codex-install.ps1")?;
    let script_path = script
        .to_str()
        .ok_or_else(|| "resolve-codex-install.ps1 路径无效".to_string())?;

    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script_path,
        ])
        .output()
        .map_err(|e| format!("PowerShell 调用失败: {e}"))?;

    if !output.status.success() {
        let detail = powershell_error_message(&output.stderr, "无法解析 Codex 安装身份");
        return Err(format!("无法解析 Codex 安装身份: {detail}"));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let json_line = first_json_object(&stdout)
        .ok_or_else(|| "无法解析 Codex 安装身份: 解析脚本未返回 JSON".to_string())?;

    parse_codex_install_json(json_line)
}

fn parse_codex_install_json(json_line: &str) -> Result<CodexInstall, String> {
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
    let package_name = value
        .get("packageName")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let package_family_name = value
        .get("packageFamilyName")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            app_user_model_id
                .split_once('!')
                .map(|(family, _)| family.to_owned())
        });

    Ok(CodexInstall {
        app_user_model_id,
        package_root,
        executable,
        version,
        package_name,
        package_family_name,
    })
}

fn map_launch_failure_code(code: &str) -> &'static str {
    match code {
        "protocol-redirect-access-denied" => {
            "Codex 将 CDP 参数转入了 codex://，且直接启动 Store 可执行文件被 ACL 拒绝"
        }
        "protocol-redirect-start-failed" => {
            "Codex 将 CDP 参数转入了 codex://，且直接启动 Store 可执行文件失败"
        }
        "protocol-redirect-failed" => "Codex 未保留 CDP 调试参数（可能被 owl runtime 转换）",
        "cdp-timeout" => "已启动 Codex，但在超时内未出现可信的本机 CDP 监听",
        "cdp-unavailable" => "当前没有可用的 Codex CDP 端点",
        "port-unavailable" => "找不到可用的本机调试端口",
        "invalid-identity" => "Codex Store 包身份无效",
        "launch-failed" => "启动 Codex CDP 失败",
        _ => "启动 Codex CDP 失败",
    }
}

fn parse_launch_result_json(json_line: &str) -> Result<CdpSession, String> {
    let value: Value = serde_json::from_str(json_line)
        .map_err(|e| format!("launch-codex-cdp.ps1 JSON 无效: {e}"))?;

    let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(false);
    if !ok {
        let code = value
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or("launch-failed");
        let message = value
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return Err(format!("{} ({code}): {message}", map_launch_failure_code(code)));
    }

    let port = value
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|port| u16::try_from(port).ok())
        .filter(|port| (1024..=65535).contains(port))
        .ok_or_else(|| "launch-codex-cdp.ps1 缺少有效 port".to_string())?;
    let browser_id = value
        .get("browserId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| "launch-codex-cdp.ps1 缺少 browserId".to_string())?
        .to_owned();
    let strategy = value
        .get("strategy")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned();
    let package_family_name = value
        .get("packageFamilyName")
        .and_then(Value::as_str)
        .map(str::to_owned);

    Ok(CdpSession {
        port,
        browser_id,
        strategy,
        package_family_name,
    })
}

fn run_launch_codex_cdp(
    install: &CodexInstall,
    preferred_port: u16,
    skip_launch: bool,
    allow_port_scan: bool,
) -> Result<CdpSession, String> {
    let script = resource_path("launch-codex-cdp.ps1")?;
    let script_path = script
        .to_str()
        .ok_or_else(|| "launch-codex-cdp.ps1 路径无效".to_string())?;

    let mut args = vec![
        "-NoProfile".to_string(),
        "-ExecutionPolicy".to_string(),
        "Bypass".to_string(),
        "-File".to_string(),
        script_path.to_string(),
        "-PreferredPort".to_string(),
        preferred_port.to_string(),
        "-AppUserModelId".to_string(),
        install.app_user_model_id.clone(),
        "-Executable".to_string(),
        install.executable.clone(),
        "-PackageRoot".to_string(),
        install.package_root.clone(),
        "-Version".to_string(),
        install.version.clone(),
        "-CdpTimeoutSeconds".to_string(),
        CDP_WAIT_TIMEOUT_SECS.to_string(),
    ];
    if let Some(name) = &install.package_name {
        args.push("-PackageName".to_string());
        args.push(name.clone());
    }
    if let Some(family) = &install.package_family_name {
        args.push("-PackageFamilyName".to_string());
        args.push(family.clone());
    }
    if allow_port_scan {
        args.push("-AllowPortScan".to_string());
    }
    if skip_launch {
        args.push("-SkipLaunch".to_string());
    }

    eprintln!(
        "[cdp] launching Codex {} ({}) via {} (preferred port {preferred_port}, skip_launch={skip_launch})",
        install.version, install.app_user_model_id, install.executable
    );

    let output = Command::new("powershell")
        .args(&args)
        .output()
        .map_err(|e| format!("PowerShell 调用失败: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    for line in stdout.lines().chain(stderr.lines()) {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('{') {
            continue;
        }
        eprintln!("[cdp:ps] {trimmed}");
    }

    if let Some(json_line) = first_json_object(&stdout) {
        return parse_launch_result_json(json_line);
    }

    if !output.status.success() {
        let detail = powershell_error_message(&output.stderr, "启动 Codex CDP 失败");
        return Err(format!("启动 Codex CDP 失败: {detail}"));
    }
    Err("launch-codex-cdp.ps1 未返回 JSON".into())
}

/// Probe whether a verified CDP session already exists without restarting Codex.
#[allow(dead_code)]
pub fn probe_codex_cdp(preferred_port: u16) -> Result<CdpSession, String> {
    let install = resolve_codex_install()?;
    let persisted = read_persisted_state();
    let port = persisted.port.unwrap_or(preferred_port);
    run_launch_codex_cdp(&install, port, true, true)
}

/// Ensure Codex exposes a verified loopback CDP endpoint (reuse, launch, or port-scan).
///
/// When `allow_restart` is true, the launch script may stop/restart Codex with CDP flags.
/// Port conflicts scan PreferredPort .. PreferredPort+100 for a free loopback port.
pub fn ensure_codex_cdp(preferred_port: u16, allow_restart: bool) -> Result<CdpSession, String> {
    let install = resolve_codex_install()?;
    let persisted = read_persisted_state();
    // Prefer persisted port when probing, but always allow +100 scan so an
    // alternate CDP from a previous conflict can still be reused.
    let probe_port = persisted.port.unwrap_or(preferred_port);

    match run_launch_codex_cdp(&install, probe_port, true, true) {
        Ok(session) => {
            eprintln!(
                "[cdp] reused existing CDP (port={}, browser-id={}, strategy={})",
                session.port, session.browser_id, session.strategy
            );
            write_persisted_state(&session);
            return Ok(session);
        }
        Err(error) => {
            if !allow_restart {
                return Err(error);
            }
            eprintln!("[cdp] no reusable CDP: {error}");
        }
    }

    // Launch always starts from the default preferred port and scans +100 on conflict.
    let session = run_launch_codex_cdp(&install, preferred_port, false, true)?;
    if session.port != preferred_port {
        eprintln!(
            "[cdp] preferred port {preferred_port} was busy; selected {}",
            session.port
        );
    }
    eprintln!(
        "[cdp] CDP ready (port={}, browser-id={}, strategy={})",
        session.port, session.browser_id, session.strategy
    );
    write_persisted_state(&session);
    Ok(session)
}

/// Legacy wrapper kept for call sites; prefer ensure_codex_cdp.
#[allow(dead_code)]
pub fn launch_codex_with_cdp(port: u16) -> Result<(), String> {
    let _ = ensure_codex_cdp(port, true)?;
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

    if let Ok(sys_root) = std::env::var("ProgramFiles") {
        let node = PathBuf::from(sys_root).join("nodejs").join("node.exe");
        if node.exists() {
            return Ok(node);
        }
    }

    Err("Node.js 未找到，请安装 Node.js 并确保其在 PATH 中。".into())
}

/// Resolve the path to the injector.mjs resource file.
pub fn resolve_injector_mjs() -> Result<PathBuf, String> {
    resource_path("injector.mjs")
}

/// Spawn the injector process in watch mode.
pub fn spawn_injector(
    node_exe: &Path,
    injector_mjs: &Path,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_launch_success_json() {
        let session = parse_launch_result_json(
            r#"{"ok":true,"port":9335,"browserId":"abc-123","strategy":"reused-existing","packageFamilyName":"OpenAI.Codex_test"}"#,
        )
        .unwrap();
        assert_eq!(session.port, 9335);
        assert_eq!(session.browser_id, "abc-123");
        assert_eq!(session.strategy, "reused-existing");
        assert_eq!(
            session.package_family_name.as_deref(),
            Some("OpenAI.Codex_test")
        );
    }

    #[test]
    fn parses_launch_failure_json() {
        let err = parse_launch_result_json(
            r#"{"ok":false,"code":"cdp-timeout","message":"No verified loopback CDP endpoint"}"#,
        )
        .unwrap_err();
        assert!(err.contains("cdp-timeout"));
        assert!(err.contains("No verified loopback CDP endpoint"));
    }

    #[test]
    fn maps_protocol_redirect_access_denied() {
        let err = parse_launch_result_json(
            r#"{"ok":false,"code":"protocol-redirect-access-denied","message":"ACL denied"}"#,
        )
        .unwrap_err();
        assert!(err.contains("protocol-redirect-access-denied"));
        assert!(err.contains("ACL"));
    }

    #[test]
    fn maps_port_unavailable() {
        let err = parse_launch_result_json(
            r#"{"ok":false,"code":"port-unavailable","message":"No free loopback port"}"#,
        )
        .unwrap_err();
        assert!(err.contains("port-unavailable"));
        assert!(err.contains("调试端口"));
    }

    #[test]
    fn parses_codex_install_json_with_family_fallback() {
        let install = parse_codex_install_json(
            r#"{"appUserModelId":"OpenAI.CodexBeta_x!App","packageRoot":"C:\\pkg","executable":"C:\\pkg\\app\\ChatGPT (Beta).exe","version":"1.0.0","packageName":"OpenAI.CodexBeta"}"#,
        )
        .unwrap();
        assert_eq!(install.app_user_model_id, "OpenAI.CodexBeta_x!App");
        assert_eq!(
            install.package_family_name.as_deref(),
            Some("OpenAI.CodexBeta_x")
        );
    }

    #[cfg(windows)]
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
