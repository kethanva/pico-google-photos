use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const DEFAULT_URL: &str = "https://photos.google.com/";

const DEFAULT_MOBILE_UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 5) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub browser:  BrowserConfig,
    pub display:  DisplayConfig,
    pub schedule: ScheduleConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct BrowserConfig {
    pub url:               String,
    pub user_agent:        String,
    pub profile_dir:       PathBuf,
    pub chromium_binary:   String,
    pub extra_flags:       Vec<String>,
    pub reload_every_secs: u64,
    pub low_ram:           bool,
    pub app_mode:          bool,
    pub disable_gpu:       bool,
    pub ephemeral_cache:   bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DisplayConfig {
    pub compositor: String,
    pub cage_flags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ScheduleConfig {
    pub enabled:  bool,
    pub on_time:  String,
    pub off_time: String,
}

impl Default for BrowserConfig {
    fn default() -> Self {
        let profile_dir = dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("/var/lib/pico-google-photos"))
            .join("pico-google-photos")
            .join("profile");

        Self {
            url:               DEFAULT_URL.to_string(),
            user_agent:        DEFAULT_MOBILE_UA.to_string(),
            profile_dir,
            chromium_binary:   "chromium".to_string(),
            extra_flags:       Vec::new(),
            reload_every_secs: 0,
            low_ram:           true,
            app_mode:          true,
            disable_gpu:       true,
            ephemeral_cache:   true,
        }
    }
}

impl Default for DisplayConfig {
    fn default() -> Self {
        Self {
            compositor: "cage".to_string(),
            cage_flags: vec!["-s".to_string()],
        }
    }
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self {
            enabled:  false,
            on_time:  "07:00".to_string(),
            off_time: "23:00".to_string(),
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("read config {}", path.display()))?;
        let cfg: Self = toml::from_str(&text)
            .with_context(|| format!("parse config {}", path.display()))?;
        Ok(cfg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Defaults must remain tuned for Pi Zero 2 W (the lowest supported target).
    // Bumping these requires an explicit decision — change the test in the same diff.
    #[test]
    fn defaults_target_pi_zero_2_w() {
        let b = BrowserConfig::default();
        assert!(b.app_mode,        "app_mode must default true (chromeless --app=URL)");
        assert!(b.disable_gpu,     "disable_gpu must default true (software render — safest on Pi Zero)");
        assert!(b.ephemeral_cache, "ephemeral_cache must default true (no SD-card writes)");
        assert!(b.low_ram,         "low_ram must default true (process limits + small JS heap)");
        assert_eq!(b.url, "https://photos.google.com/");
        assert!(b.user_agent.contains("Pixel 5"),    "UA must spoof a mobile device");
        assert!(b.user_agent.contains("Mobile Safari"));
        assert_eq!(b.chromium_binary, "chromium");
        assert_eq!(b.reload_every_secs, 0);
        assert!(b.extra_flags.is_empty());
    }

    #[test]
    fn schedule_default_disabled() {
        let s = ScheduleConfig::default();
        assert!(!s.enabled);
        assert_eq!(s.on_time,  "07:00");
        assert_eq!(s.off_time, "23:00");
    }

    #[test]
    fn display_default_is_cage() {
        let d = DisplayConfig::default();
        assert_eq!(d.compositor, "cage");
        assert_eq!(d.cage_flags, vec!["-s"]);
    }
}
