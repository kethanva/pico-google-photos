use crate::config::ScheduleConfig;
use anyhow::{anyhow, Result};
use chrono::{Local, NaiveTime, Timelike};

#[derive(Debug, Clone, Copy)]
pub struct Window {
    pub on:  NaiveTime,
    pub off: NaiveTime,
}

impl Window {
    pub fn parse(cfg: &ScheduleConfig) -> Result<Self> {
        let on  = parse_hhmm(&cfg.on_time)?;
        let off = parse_hhmm(&cfg.off_time)?;
        Ok(Self { on, off })
    }

    pub fn is_on_now(&self) -> bool {
        let now = Local::now().time();
        if self.on == self.off {
            return true;
        }
        if self.on < self.off {
            now >= self.on && now < self.off
        } else {
            now >= self.on || now < self.off
        }
    }
}

fn parse_hhmm(s: &str) -> Result<NaiveTime> {
    let (h, m) = s
        .split_once(':')
        .ok_or_else(|| anyhow!("expected HH:MM, got `{s}`"))?;
    let h: u32 = h.parse()?;
    let m: u32 = m.parse()?;
    NaiveTime::from_hms_opt(h, m, 0).ok_or_else(|| anyhow!("invalid time `{s}`"))
}

pub fn seconds_until_minute_boundary() -> u64 {
    let now = Local::now();
    let secs = 60u32.saturating_sub(now.second());
    secs.max(1) as u64
}
