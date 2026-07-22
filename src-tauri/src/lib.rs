mod cdp;
mod codex;
mod models;

use std::{process::Child, sync::Mutex, time::Duration};

use models::InjectorQuotaUpdate;
use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, IDYES, MB_ICONQUESTION, MB_YESNO};

const REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);
const ERROR_RETRY_BASE: Duration = Duration::from_secs(30);
const ERROR_RETRY_MAX: Duration = Duration::from_secs(30 * 60);

struct AppState {
    client: reqwest::Client,
    fetch_lock: tokio::sync::Mutex<()>,
    injector_child: Mutex<Option<Child>>,
}

async fn fetch_and_publish_quota(app: &AppHandle) -> bool {
    let Some(state) = app.try_state::<AppState>() else {
        return false;
    };
    let _guard = state.fetch_lock.lock().await;
    let snapshot = codex::fetch_snapshot(&state.client).await;
    let update = InjectorQuotaUpdate::from(&snapshot);
    let has_quota = snapshot.status == "ok" && update.percent.is_some();
    let message = match serde_json::to_string(&update) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[quota] failed to serialize update: {error}");
            return false;
        }
    };

    let sent = state
        .injector_child
        .lock()
        .map_err(|_| "injector state is unavailable".to_string())
        .and_then(|mut child| cdp::send_injector_message(&mut child, &message));
    if let Err(error) = sent {
        eprintln!("[quota] failed to publish update: {error}");
        return false;
    }

    has_quota
}

fn request_quota_refresh(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let _ = fetch_and_publish_quota(&app).await;
    });
}

fn start_quota_refresh_loop(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut failures = 0u32;
        loop {
            let succeeded = fetch_and_publish_quota(&app).await;
            failures = if succeeded {
                0
            } else {
                failures.saturating_add(1)
            };
            let delay = if failures == 0 {
                REFRESH_INTERVAL
            } else {
                let multiplier = 1u64 << failures.saturating_sub(1).min(5);
                ERROR_RETRY_BASE
                    .saturating_mul(multiplier as u32)
                    .min(ERROR_RETRY_MAX)
            };
            tokio::time::sleep(delay).await;
        }
    });
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let refresh = MenuItem::with_id(app, "refresh", "立即刷新", true, None::<&str>)?;
    let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);
    let autostart = CheckMenuItem::with_id(
        app,
        "autostart",
        "开机启动",
        true,
        autostart_enabled,
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&refresh, &autostart, &quit])?;
    let mut builder = TrayIconBuilder::with_id("main")
        .menu(&menu)
        .tooltip("CodexMeter");
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    let autostart_menu = autostart.clone();
    builder
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "refresh" => request_quota_refresh(app),
            "autostart" => {
                let manager = app.autolaunch();
                let enabled = manager.is_enabled().unwrap_or(false);
                let result = if enabled {
                    manager.disable()
                } else {
                    manager.enable()
                };
                match result {
                    Ok(()) => {
                        let _ = autostart_menu.set_checked(!enabled);
                    }
                    Err(error) => eprintln!("autostart update failed: {error}"),
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

/// Initialize the verified local CDP connection and injector process.
fn init_cdp(app: &AppHandle) -> bool {
    let port = cdp::DEFAULT_CDP_PORT;
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            eprintln!("[cdp] failed to create HTTP client: {error}");
            return false;
        }
    };

    let browser_id = match tauri::async_runtime::block_on(cdp::get_browser_id(&client, port)) {
        Ok(id) => id,
        Err(_) => {
            #[cfg(windows)]
            {
                let text: Vec<u16> = "Codex 未启用调试端口，是否重启 Codex 以启用额度显示？"
                    .encode_utf16()
                    .chain(std::iter::once(0))
                    .collect();
                let caption: Vec<u16> = "CodexMeter"
                    .encode_utf16()
                    .chain(std::iter::once(0))
                    .collect();
                let result = unsafe {
                    MessageBoxW(
                        None,
                        windows::core::PCWSTR(text.as_ptr()),
                        windows::core::PCWSTR(caption.as_ptr()),
                        MB_YESNO | MB_ICONQUESTION,
                    )
                };
                if result != IDYES {
                    app.exit(0);
                    return false;
                }
            }
            #[cfg(not(windows))]
            {
                eprintln!("[cdp] automatic Codex restart is only supported on Windows");
                app.exit(0);
                return false;
            }

            if let Err(error) = cdp::stop_codex() {
                eprintln!("[cdp] failed to stop Codex: {error}");
            }
            if let Err(error) = cdp::launch_codex_with_cdp(port) {
                eprintln!("[cdp] {error}");
                app.exit(0);
                return false;
            }
            match tauri::async_runtime::block_on(cdp::wait_for_cdp(&client, port, 30)) {
                Ok(id) => id,
                Err(error) => {
                    eprintln!("[cdp] {error}");
                    app.exit(0);
                    return false;
                }
            }
        }
    };

    let node_exe = match cdp::find_node_exe() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("[cdp] {error}");
            return false;
        }
    };
    let injector_mjs = match cdp::resolve_injector_mjs() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("[cdp] {error}");
            return false;
        }
    };

    match cdp::spawn_injector(&node_exe, &injector_mjs, port, &browser_id) {
        Ok(child) => {
            if let Some(state) = app.try_state::<AppState>() {
                if let Ok(mut injector) = state.injector_child.lock() {
                    *injector = Some(child);
                }
            }
            eprintln!("[cdp] injector started (port={port}, browser-id={browser_id})");
            true
        }
        Err(error) => {
            eprintln!("[cdp] {error}");
            false
        }
    }
}

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            request_quota_refresh(app);
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .setup(|app| {
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(12))
                .redirect(reqwest::redirect::Policy::none())
                .user_agent("CodexMeter/0.2")
                .build()
                .expect("static HTTP client configuration must be valid");
            app.manage(AppState {
                client,
                fetch_lock: tokio::sync::Mutex::new(()),
                injector_child: Mutex::new(None),
            });
            setup_tray(app)?;
            if init_cdp(app.handle()) {
                start_quota_refresh_loop(app.handle().clone());
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build CodexMeter");

    app.run(|app_handle, event| {
        if matches!(event, tauri::RunEvent::Exit) {
            if let Some(state) = app_handle.try_state::<AppState>() {
                if let Ok(mut child) = state.injector_child.lock() {
                    cdp::kill_injector(&mut child);
                }
            }
        }
    });
}
