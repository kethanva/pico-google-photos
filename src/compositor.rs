use crate::chromium;
use crate::config::{BrowserConfig, DisplayConfig};
use anyhow::{Context, Result};
use log::{info, warn};
use std::process::Stdio;
use tokio::process::{Child, Command};

pub struct Session {
    child: Child,
}

impl Session {
    pub fn spawn(display: &DisplayConfig, browser: &BrowserConfig) -> Result<Self> {
        std::fs::create_dir_all(&browser.profile_dir)
            .with_context(|| format!("create profile dir {}", browser.profile_dir.display()))?;

        let chromium_args = chromium::build_args(browser);

        let mut cmd = Command::new(&display.compositor);
        cmd.args(&display.cage_flags)
           .arg("--")
           .arg(&browser.chromium_binary)
           .args(&chromium_args)
           .stdin(Stdio::null())
           .stdout(Stdio::inherit())
           .stderr(Stdio::inherit())
           .kill_on_drop(true);

        info!(
            "spawning: {} {} -- {} <{} args>",
            display.compositor,
            display.cage_flags.join(" "),
            browser.chromium_binary,
            chromium_args.len()
        );

        let child = cmd.spawn().with_context(|| {
            format!(
                "spawn compositor `{}` (is it installed? `sudo apt-get install -y cage chromium-browser`)",
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
