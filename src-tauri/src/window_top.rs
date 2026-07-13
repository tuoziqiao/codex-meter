use tauri::WebviewWindow;

pub fn apply_window_top(window: &WebviewWindow, enabled: bool) -> Result<(), String> {
    window
        .set_always_on_top(enabled)
        .map_err(|error| format!("failed to toggle always-on-top: {error}"))?;
    #[cfg(windows)]
    reinforce_win32_topmost(window, enabled)?;
    Ok(())
}

#[cfg(windows)]
fn reinforce_win32_topmost(window: &WebviewWindow, enabled: bool) -> Result<(), String> {
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, HWND_NOTOPMOST, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
    };

    let hwnd = window.hwnd().map_err(|error| error.to_string())?;
    unsafe {
        let insert_after = if enabled { HWND_TOPMOST } else { HWND_NOTOPMOST };
        SetWindowPos(
            hwnd,
            Some(insert_after),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        )
        .map_err(|error| format!("SetWindowPos failed: {error}"))?;
    }
    Ok(())
}
