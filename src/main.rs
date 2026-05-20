mod chromium;
mod compositor;
mod config;
mod display_power;
mod schedule;

use anyhow::{Context, Result};
use clap::Parser;
use config::Config;
use log::{error, info, warn};
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::sleep;

#[derive(Parser, Debug)]
#[command(name = "pico-google-photos", version, about)]
struct Cli {
    #[arg(short, long, env = "PICO_GP_CONFIG", default_value_t = default_config_path())]
    config: String,

    #[arg(long)]
    print_args: bool,
}

fn default_config_path() -> String {
    dirs::config_dir()
        .map(|p| p.join("pico-google-photos").join("config.toml"))
        .unwrap_or_else(|| PathBuf::from("/etc/pico-google-photos/config.toml"))
        .display()
        .to_string()
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();
    let cfg = Config::load(PathBuf::from(&cli.config).as_path())
        .with_context(|| format!("loading config {}", cli.config))?;

    if cli.print_args {
        for a in chromium::build_args(&cfg.browser) {
            println!("{a}");
        }
        return Ok(());
    }

    info!("pico-google-photos starting; url={}", cfg.browser.url);

    let window = if cfg.schedule.enabled {
        Some(schedule::Window::parse(&cfg.schedule)?)
    } else {
        None
    };

    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint  = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;

    'outer: loop {
        if let Some(w) = window {
            if !w.is_on_now() {
                display_power::set_power(false).await;
                info!("outside on-window; sleeping 60s");
                tokio::select! {
                    _ = sleep(Duration::from_secs(schedule::seconds_until_minute_boundary())) => {}
                    _ = sigterm.recv() => break 'outer,
                    _ = sigint.recv()  => break 'outer,
                }
                continue;
            }
            display_power::set_power(true).await;
        }

        let mut session = match compositor::Session::spawn(&cfg.display, &cfg.browser) {
            Ok(s) => s,
            Err(e) => {
                error!("spawn failed: {e:#}");
                sleep(Duration::from_secs(5)).await;
                continue;
            }
        };

        let reload_secs = cfg.browser.reload_every_secs;
        let reload_fut: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
            if reload_secs > 0 {
                Box::pin(sleep(Duration::from_secs(reload_secs)))
            } else {
                Box::pin(std::future::pending::<()>())
            };

        tokio::select! {
            _ = session.wait() => {
                warn!("session ended; restarting in 3s");
                sleep(Duration::from_secs(3)).await;
            }
            _ = reload_fut => {
                info!("reload_every_secs elapsed; restarting session");
                session.kill().await;
                let _ = session.wait().await;
            }
            _ = sigterm.recv() => {
                info!("SIGTERM; shutting down");
                session.kill().await;
                let _ = session.wait().await;
                break 'outer;
            }
            _ = sigint.recv() => {
                info!("SIGINT; shutting down");
                session.kill().await;
                let _ = session.wait().await;
                break 'outer;
            }
        }
    }

    display_power::set_power(true).await;
    Ok(())
}
