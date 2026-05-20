pub async fn set_power(on: bool) {
    #[cfg(target_os = "linux")]
    {
        use log::debug;
        let val = if on { "1" } else { "0" };
        match tokio::process::Command::new("vcgencmd")
            .args(["display_power", val])
            .output()
            .await
        {
            Ok(o) if o.status.success() => debug!("vcgencmd display_power {val}: ok"),
            Ok(o) => debug!(
                "vcgencmd display_power {val}: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            ),
            Err(_) => debug!("vcgencmd not available"),
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = on;
}
