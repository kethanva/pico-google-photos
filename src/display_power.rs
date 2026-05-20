pub async fn set_power(on: bool) {
    #[cfg(target_os = "linux")]
    {
        use log::{info, warn};
        let val = if on { "1" } else { "0" };
        match tokio::process::Command::new("vcgencmd")
            .args(["display_power", val])
            .output()
            .await
        {
            Ok(o) if o.status.success() => info!("vcgencmd display_power {val}: ok"),
            Ok(o) => warn!(
                "vcgencmd display_power {val} failed: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            ),
            Err(_) => warn!("vcgencmd not available (cannot set display power)"),
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = on;
}
