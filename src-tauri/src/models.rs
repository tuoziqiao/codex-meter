use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub remaining_percent: f64,
    pub resets_at: Option<String>,
    pub window_seconds: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSnapshot {
    pub provider: String,
    pub display_name: String,
    pub plan: Option<String>,
    pub short_window: Option<UsageWindow>,
    pub weekly_window: Option<UsageWindow>,
    pub reset_credits: Option<u64>,
    pub reset_credit_expires_at: Vec<String>,
    pub updated_at: String,
    pub status: String,
    pub message: Option<String>,
}

impl ProviderSnapshot {
    pub fn failure(status: &str, message: &str) -> Self {
        Self {
            provider: "codex".into(),
            display_name: "CODEX".into(),
            plan: None,
            short_window: None,
            weekly_window: None,
            reset_credits: None,
            reset_credit_expires_at: Vec::new(),
            updated_at: chrono::Utc::now().to_rfc3339(),
            status: status.into(),
            message: Some(message.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InjectorQuotaUpdate {
    #[serde(rename = "type")]
    pub message_type: &'static str,
    pub status: String,
    pub percent: Option<u8>,
    pub resets_at: Option<String>,
}

impl From<&ProviderSnapshot> for InjectorQuotaUpdate {
    fn from(snapshot: &ProviderSnapshot) -> Self {
        let window = snapshot
            .weekly_window
            .as_ref()
            .or(snapshot.short_window.as_ref());
        Self {
            message_type: "quota",
            status: snapshot.status.clone(),
            percent: window.map(|value| value.remaining_percent.clamp(0.0, 100.0).round() as u8),
            resets_at: window.and_then(|value| value.resets_at.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(percent: f64, resets_at: &str, seconds: u64) -> UsageWindow {
        UsageWindow {
            remaining_percent: percent,
            resets_at: Some(resets_at.into()),
            window_seconds: seconds,
        }
    }

    #[test]
    fn injector_update_prefers_weekly_quota() {
        let snapshot = ProviderSnapshot {
            provider: "codex".into(),
            display_name: "CODEX".into(),
            plan: Some("PRO".into()),
            short_window: Some(window(91.0, "2026-08-20T00:00:00Z", 18_000)),
            weekly_window: Some(window(76.4, "2026-08-25T00:00:00Z", 604_800)),
            reset_credits: None,
            reset_credit_expires_at: Vec::new(),
            updated_at: "2026-08-18T00:00:00Z".into(),
            status: "ok".into(),
            message: None,
        };

        let update = InjectorQuotaUpdate::from(&snapshot);
        assert_eq!(update.percent, Some(76));
        assert_eq!(update.resets_at.as_deref(), Some("2026-08-25T00:00:00Z"));
    }

    #[test]
    fn injector_update_falls_back_to_short_window() {
        let mut snapshot = ProviderSnapshot::failure("unavailable", "missing");
        snapshot.status = "ok".into();
        snapshot.short_window = Some(window(42.6, "2026-08-20T00:00:00Z", 18_000));

        let update = InjectorQuotaUpdate::from(&snapshot);
        assert_eq!(update.percent, Some(43));
        assert_eq!(update.resets_at.as_deref(), Some("2026-08-20T00:00:00Z"));
    }
}
