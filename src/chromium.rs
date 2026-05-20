use crate::config::BrowserConfig;

pub fn build_args(cfg: &BrowserConfig) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "--kiosk".into(),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        "--noerrdialogs".into(),
        "--disable-infobars".into(),
        "--disable-session-crashed-bubble".into(),
        "--disable-features=Translate,TranslateUI,InfiniteSessionRestore".into(),
        "--overscroll-history-navigation=0".into(),
        "--password-store=basic".into(),
        "--autoplay-policy=no-user-gesture-required".into(),
        "--ozone-platform=wayland".into(),
        "--enable-features=UseOzonePlatform".into(),
        format!("--user-data-dir={}", cfg.profile_dir.display()),
        format!("--user-agent={}", cfg.user_agent),
    ];

    if cfg.disable_gpu {
        args.extend([
            "--disable-gpu".into(),
            "--disable-software-rasterizer".into(),
        ]);
    } else {
        args.extend([
            "--enable-gpu-rasterization".into(),
            "--ignore-gpu-blocklist".into(),
            "--disable-gpu-driver-bug-workarounds".into(),
        ]);
    }

    if cfg.low_ram {
        args.extend([
            "--disable-dev-shm-usage".into(),
            "--process-per-site".into(),
            "--renderer-process-limit=2".into(),
            "--memory-pressure-off".into(),
            "--js-flags=--max-old-space-size=128".into(),
        ]);
    }

    if cfg.ephemeral_cache {
        args.push("--disk-cache-dir=/dev/null".into());
        args.push("--disk-cache-size=1".into());
        args.push("--media-cache-size=1".into());
    } else if cfg.low_ram {
        args.push("--disk-cache-size=33554432".into());
        args.push("--media-cache-size=16777216".into());
    }

    args.extend(cfg.extra_flags.iter().cloned());

    if cfg.app_mode {
        args.push(format!("--app={}", cfg.url));
    } else {
        args.push(cfg.url.clone());
    }
    args
}
