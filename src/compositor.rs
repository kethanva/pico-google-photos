use crate::chromium;
use crate::config::{BrowserConfig, DisplayConfig};
use anyhow::{Context, Result};
use log::{info, warn};
use std::path::Path;
use std::process::Stdio;
use tokio::process::{Child, Command};

const CHROMIUM_CANDIDATES: &[&str] = &["chromium", "chromium-browser"];

pub struct Session {
    child: Child,
}

// Bookworm renamed `chromium-browser` to `chromium`. If the configured binary
// is not on PATH (and not an absolute path), try the alternate name before
// failing — keeps a single config working across Bullseye and Bookworm.
fn resolve_chromium(configured: &str) -> String {
    if configured.contains('/') && Path::new(configured).is_file() {
        return configured.to_string();
    }
    if which(configured).is_some() {
        return configured.to_string();
    }
    for cand in CHROMIUM_CANDIDATES {
        if *cand != configured {
            if let Some(p) = which(cand) {
                warn!(
                    "configured chromium_binary `{configured}` not on PATH; \
                     falling back to `{cand}` at {p}"
                );
                return cand.to_string();
            }
        }
    }
    configured.to_string()
}

fn which(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let full = dir.join(name);
        if full.is_file() {
            return Some(full.display().to_string());
        }
    }
    None
}

impl Session {
    pub fn spawn(display: &DisplayConfig, browser: &BrowserConfig) -> Result<Self> {
        std::fs::create_dir_all(&browser.profile_dir)
            .with_context(|| format!("create profile dir {}", browser.profile_dir.display()))?;

        let chromium_args = chromium::build_args(browser);
        let chromium_bin  = resolve_chromium(&browser.chromium_binary);

        let mut cmd = Command::new(&display.compositor);
        cmd.args(&display.cage_flags)
           .arg("--")
           .arg(&chromium_bin)
           .args(&chromium_args)
           .stdin(Stdio::null())
           .stdout(Stdio::inherit())
           .stderr(Stdio::inherit())
           .kill_on_drop(true);

        info!(
            "spawning: {} {} -- {} <{} args>",
            display.compositor,
            display.cage_flags.join(" "),
            chromium_bin,
            chromium_args.len()
        );

        let child = cmd.spawn().with_context(|| {
            format!(
                "spawn compositor `{}` (is it installed? \
                 `sudo apt-get install -y cage chromium` on Bookworm, \
                 or `cage chromium-browser` on Bullseye)",
                display.compositor
            )
        })?;

        Ok(Self { child })
    }

    pub async fn wait(&mut self) -> Result<std::process::ExitStatus> {
        let status = self.child.wait().await.context("waiting on compositor")?;
        if !status.success() {
            warn!("compositor exited with {status}");
        }
        Ok(status)
    }

    pub async fn kill(&mut self) {
        if let Err(e) = self.child.kill().await {
            warn!("kill compositor: {e}");
        }
    }
}
