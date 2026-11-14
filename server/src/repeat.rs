use chrono::{Datelike, Days, NaiveDate, Weekday};

const WEEKDAYS: [(&str, Weekday); 7] = [
    ("MO", Weekday::Mon),
    ("TU", Weekday::Tue),
    ("WE", Weekday::Wed),
    ("TH", Weekday::Thu),
    ("FR", Weekday::Fri),
    ("SA", Weekday::Sat),
    ("SU", Weekday::Sun),
];

#[derive(Clone, Copy, PartialEq)]
enum Freq {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

// A small subset of RFC 5545: FREQ, INTERVAL, BYDAY for weekly and BYMONTHDAY for monthly rules.
pub struct Rule {
    freq: Freq,
    interval: u32,
    by_day: Vec<Weekday>,
    by_month_day: Option<u32>,
}

fn day_in_month(year: i32, month: u32, day: u32) -> Option<NaiveDate> {
    // Clamp to the last day, so the 31st falls on the 30th or 28th in shorter months.
    (1..=day)
        .rev()
        .find_map(|d| NaiveDate::from_ymd_opt(year, month, d))
}

fn week_start(date: NaiveDate) -> NaiveDate {
    date - Days::new(date.weekday().num_days_from_monday() as u64)
}

impl Rule {
    // `anchor` is the due date. A monthly rule without BYMONTHDAY takes its day from it, so a
    // rule set on the 31st keeps meaning the 31st after a short month moved the due date.
    pub fn parse(input: &str, anchor: NaiveDate) -> Result<Self, String> {
        let text = input.trim().to_ascii_uppercase();
        let text = text.strip_prefix("RRULE:").unwrap_or(&text);
        let (mut freq, mut interval, mut by_day, mut by_month_day) = (None, None, None, None);
        for part in text.split(';').filter(|p| !p.is_empty()) {
            let (key, value) = part
                .split_once('=')
                .ok_or("Write the repeat rule as KEY=VALUE parts separated by semicolons.")?;
            let repeated = match key {
                "FREQ" => freq
                    .replace(match value {
                        "DAILY" => Freq::Daily,
                        "WEEKLY" => Freq::Weekly,
                        "MONTHLY" => Freq::Monthly,
                        "YEARLY" => Freq::Yearly,
                        _ => return Err("FREQ is DAILY, WEEKLY, MONTHLY or YEARLY.".into()),
                    })
                    .is_some(),
                "INTERVAL" => interval
                    .replace(
                        value
                            .parse::<u32>()
                            .ok()
                            .filter(|n| (1..=999).contains(n))
                            .ok_or("INTERVAL is a number from 1 to 999.")?,
                    )
                    .is_some(),
                "BYDAY" => {
                    let mut days = Vec::new();
                    for code in value.split(',') {
                        let day = WEEKDAYS
                            .iter()
                            .find(|(name, _)| *name == code)
                            .ok_or("BYDAY lists weekdays as MO, TU, WE, TH, FR, SA, SU.")?
                            .1;
                        if !days.contains(&day) {
                            days.push(day);
                        }
                    }
                    days.sort_by_key(Weekday::num_days_from_monday);
                    by_day.replace(days).is_some()
                }
                "BYMONTHDAY" => by_month_day
                    .replace(
                        value
                            .parse::<u32>()
                            .ok()
                            .filter(|n| (1..=31).contains(n))
                            .ok_or("BYMONTHDAY is a day from 1 to 31.")?,
                    )
                    .is_some(),
                _ => {
                    return Err(
                        "A repeat rule supports FREQ, INTERVAL, BYDAY and BYMONTHDAY.".into(),
                    );
                }
            };
            if repeated {
                return Err(format!("{key} appears twice in the repeat rule."));
            }
        }
        let freq = freq.ok_or("A repeat rule needs FREQ.")?;
        if by_day.is_some() && freq != Freq::Weekly {
            return Err("BYDAY only works with FREQ=WEEKLY.".into());
        }
        if by_month_day.is_some() && freq != Freq::Monthly {
            return Err("BYMONTHDAY only works with FREQ=MONTHLY.".into());
        }
        Ok(Self {
            freq,
            interval: interval.unwrap_or(1),
            by_day: by_day.unwrap_or_default(),
            by_month_day: (freq == Freq::Monthly).then(|| by_month_day.unwrap_or(anchor.day())),
        })
    }

    pub fn canonical(&self) -> String {
        let mut text = format!(
            "FREQ={}",
            match self.freq {
                Freq::Daily => "DAILY",
                Freq::Weekly => "WEEKLY",
                Freq::Monthly => "MONTHLY",
                Freq::Yearly => "YEARLY",
            }
        );
        if self.interval != 1 {
            text.push_str(&format!(";INTERVAL={}", self.interval));
        }
        if !self.by_day.is_empty() {
            let codes: Vec<&str> = self
                .by_day
                .iter()
                .filter_map(|day| {
                    WEEKDAYS
                        .iter()
                        .find(|(_, d)| d == day)
                        .map(|(name, _)| *name)
                })
                .collect();
            text.push_str(&format!(";BYDAY={}", codes.join(",")));
        }
        if let Some(day) = self.by_month_day {
            text.push_str(&format!(";BYMONTHDAY={day}"));
        }
        text
    }

    // The first occurrence after `anchor` that is not before `earliest`.
    pub fn next(&self, anchor: NaiveDate, earliest: NaiveDate) -> Option<NaiveDate> {
        let interval = i64::from(self.interval);
        let gap = (earliest - anchor).num_days();
        match self.freq {
            Freq::Daily | Freq::Weekly if self.by_day.is_empty() => {
                let step = if self.freq == Freq::Daily {
                    interval
                } else {
                    7 * interval
                };
                let count = gap.div_euclid(step) + i64::from(gap.rem_euclid(step) != 0);
                anchor.checked_add_days(Days::new((count.max(1) * step) as u64))
            }
            Freq::Daily | Freq::Weekly => {
                let first = earliest.max(anchor.checked_add_days(Days::new(1))?);
                let origin = week_start(anchor);
                // One aligned week lies within any span of `interval` weeks.
                (0..=7 * (interval as u64 + 1)).find_map(|offset| {
                    let day = first.checked_add_days(Days::new(offset))?;
                    let weeks = (week_start(day) - origin).num_days() / 7;
                    (weeks % interval == 0 && self.by_day.contains(&day.weekday())).then_some(day)
                })
            }
            Freq::Monthly => {
                let day = self.by_month_day.unwrap_or(anchor.day());
                let origin = i64::from(anchor.year()) * 12 + i64::from(anchor.month0());
                let target = i64::from(earliest.year()) * 12 + i64::from(earliest.month0());
                let start = ((target - origin).div_euclid(interval)).max(0);
                (start..start + 3).find_map(|count| {
                    let index = origin + count * interval;
                    let date = day_in_month(
                        i32::try_from(index.div_euclid(12)).ok()?,
                        index.rem_euclid(12) as u32 + 1,
                        day,
                    )?;
                    (date > anchor && date >= earliest).then_some(date)
                })
            }
            Freq::Yearly => {
                let years = i64::from(earliest.year() - anchor.year());
                let start = years.div_euclid(interval).max(1);
                (start..start + 3).find_map(|count| {
                    let year = i32::try_from(i64::from(anchor.year()) + count * interval).ok()?;
                    let date = day_in_month(year, anchor.month(), anchor.day())?;
                    (date >= earliest).then_some(date)
                })
            }
        }
    }
}
