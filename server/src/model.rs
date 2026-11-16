use crate::{
    error::{ApiError, Result},
    repeat::Rule,
};
use chrono::{
    DateTime, Datelike, Days, Duration, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike,
    Utc, offset::LocalResult,
};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::FromRow;

pub const STATUSES: [&str; 3] = ["todo", "doing", "done"];
pub const STAGES: [&str; 8] = [
    "new",
    "none",
    "gathering",
    "needs_answer",
    "ready",
    "running",
    "review",
    "declined",
];
// Where an item was captured. A human token and an agent token may each only name their own.
pub const HUMAN_SOURCES: [&str; 4] = ["app", "siri", "share", "shortcut"];
pub const AGENT_SOURCES: [&str; 2] = ["telegram", "mcp"];
// Dates outside these years are rejected as mistakes.
const YEARS: std::ops::RangeInclusive<i32> = 1970..=2200;
// Far beyond any sequence number, and small enough that halving a gap keeps its precision.
const POSITION_LIMIT: f64 = 1e15;

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ChecklistLine {
    // Clients may send their own stable ID. The server fills in a missing one.
    #[serde(default)]
    pub id: String,
    pub text: String,
    #[serde(default)]
    pub done: bool,
}

#[derive(Serialize, Clone, FromRow)]
pub struct Item {
    pub id: i64,
    pub title: String,
    pub description: String,
    pub status: String,
    pub project_id: Option<String>,
    pub priority: i64,
    pub position: f64,
    #[sqlx(json)]
    pub tags: Vec<String>,
    #[sqlx(json)]
    pub checklist: Vec<ChecklistLine>,
    pub due_at: Option<String>,
    pub due_tz: Option<String>,
    pub remind_at: Option<String>,
    pub repeat_rule: Option<String>,
    pub agent_stage: String,
    pub hidden_from_agents: bool,
    pub created_via: String,
    pub source_url: Option<String>,
    pub archived: bool,
    pub trashed: bool,
    pub completed_at: Option<String>,
    // Changed only by the file routes. An edit of the item cannot write it.
    #[sqlx(json)]
    #[serde(flatten)]
    pub files: Attachments,
    pub version: i64,
    pub seq: i64,
    pub created_by: String,
    pub updated_by: String,
    pub created_at: String,
    pub updated_at: String,
}

// A file on an item, without its bytes. The ID addresses it under its item, and the hash lets
// a client keep a copy that stays right when a restored server gives the ID to another file.
// `upload_id` is the uploader's own name for the upload, so it can tell its file from another
// with the same bytes when an answer was lost. A picture the server could measure carries its
// `width` and `height`.
#[derive(Serialize, Deserialize, Clone)]
pub struct FileRef {
    pub id: i64,
    pub name: String,
    pub mime: String,
    pub bytes: i64,
    pub sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<i64>,
}

impl FileRef {
    // A JPEG or PNG with its size: what the apps of 0.2.0 know as an image.
    pub fn is_legacy_image(&self) -> bool {
        self.width.is_some()
            && self.height.is_some()
            && LEGACY_IMAGE_TYPES.contains(&self.mime.as_str())
    }
}

const LEGACY_IMAGE_TYPES: [&str; 2] = ["image/jpeg", "image/png"];

// The files on an item. Written out as `files`, and the pictures among them once more as
// `images`, in the shape the apps of 0.2.0 read; they knew images only. Remove `images` and
// the routes in images.rs together, once no 0.2.0 app is left.
#[derive(Clone, Default)]
pub struct Attachments(pub Vec<FileRef>);

impl<'de> Deserialize<'de> for Attachments {
    fn deserialize<D: serde::Deserializer<'de>>(from: D) -> std::result::Result<Self, D::Error> {
        Vec::deserialize(from).map(Self)
    }
}

impl Serialize for Attachments {
    fn serialize<S: serde::Serializer>(&self, to: S) -> std::result::Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let images: Vec<Value> = self
            .0
            .iter()
            .filter(|file| file.is_legacy_image())
            .map(|file| {
                serde_json::json!({
                    "id": file.id,
                    "mime": file.mime,
                    "width": file.width,
                    "height": file.height,
                    "bytes": file.bytes,
                    "sha256": file.sha256,
                })
            })
            .collect();
        let mut map = to.serialize_map(Some(2))?;
        map.serialize_entry("files", &self.0)?;
        map.serialize_entry("images", &images)?;
        map.end()
    }
}

#[derive(Serialize, FromRow)]
pub struct Comment {
    pub id: i64,
    pub item_id: i64,
    pub author_id: String,
    pub body: String,
    pub seq: i64,
    pub created_at: String,
}

#[derive(Serialize, FromRow)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub icon: Option<String>,
    pub deleted: bool,
    pub seq: i64,
    pub created_at: String,
}

#[derive(Serialize, FromRow)]
pub struct Activity {
    pub id: i64,
    pub actor_id: String,
    pub action: String,
    #[sqlx(json)]
    pub detail: Value,
    pub created_at: String,
}

// A local time that falls into a daylight saving gap moves one hour forward.
pub fn localize(naive: NaiveDateTime, tz: Tz) -> Option<DateTime<Tz>> {
    match tz.from_local_datetime(&naive) {
        LocalResult::Single(at) | LocalResult::Ambiguous(at, _) => Some(at),
        LocalResult::None => tz
            .from_local_datetime(&(naive + Duration::hours(1)))
            .earliest(),
    }
}

// Accepts a time with an offset, or a local time that is read in `tz`. Keeps any fraction.
fn parse_time(value: &str, tz: Tz) -> Option<DateTime<Tz>> {
    let at = match DateTime::parse_from_rfc3339(value) {
        Ok(at) => at.with_timezone(&tz),
        Err(_) => ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M"]
            .iter()
            .find_map(|format| NaiveDateTime::parse_from_str(value, format).ok())
            .and_then(|naive| localize(naive, tz))?,
    };
    YEARS.contains(&at.year()).then_some(at)
}

// Drops the fraction of a second. Done on the instant: setting a field of the local time
// fails for a time that happens twice when clocks go back.
fn whole_second(at: DateTime<Tz>) -> DateTime<Tz> {
    at - Duration::nanoseconds(i64::from(at.nanosecond()))
}

// A stored time has whole seconds.
pub fn parse_instant(value: &str, tz: Tz) -> Option<DateTime<Tz>> {
    parse_time(value, tz).map(whole_second)
}

pub fn local_text(at: &DateTime<Tz>) -> String {
    at.format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

pub fn utc_key<Z: TimeZone>(at: &DateTime<Z>) -> String {
    at.with_timezone(&Utc)
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string()
}

// A range bound for due_utc: a date is the start of that day, and a time with a fraction moves
// up to the next second, because stored times have none.
pub fn bound_key(value: &str, tz: Tz) -> Option<String> {
    if value.len() == 10 {
        return Due::parse(value, tz)?.utc_key(tz);
    }
    let at = parse_time(value, tz)?;
    let whole = whole_second(at);
    Some(utc_key(&if at.nanosecond() > 0 {
        whole + Duration::seconds(1)
    } else {
        whole
    }))
}

pub enum Due {
    Day(NaiveDate),
    At(DateTime<Tz>),
}
impl Due {
    pub fn parse(value: &str, tz: Tz) -> Option<Self> {
        if value.len() == 10 {
            return NaiveDate::parse_from_str(value, "%Y-%m-%d")
                .ok()
                .filter(|date| YEARS.contains(&date.year()))
                .map(Self::Day);
        }
        parse_instant(value, tz).map(Self::At)
    }
    pub fn date(&self) -> NaiveDate {
        match self {
            Self::Day(date) => *date,
            Self::At(at) => at.date_naive(),
        }
    }
    pub fn text(&self) -> String {
        match self {
            Self::Day(date) => date.format("%Y-%m-%d").to_string(),
            Self::At(at) => local_text(at),
        }
    }
    // An all-day date sorts at the start of its local day.
    pub fn utc_key(&self, tz: Tz) -> Option<String> {
        match self {
            Self::Day(date) => localize(date.and_time(NaiveTime::MIN), tz).map(|at| utc_key(&at)),
            Self::At(at) => Some(utc_key(at)),
        }
    }
}

pub struct Derived {
    pub due_utc: Option<String>,
    pub remind_utc: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct ItemInput {
    pub title: String,
    pub description: String,
    pub status: String,
    pub project_id: Option<String>,
    pub priority: i64,
    // None means "not sent": a new item then gets its sequence number, an edit keeps the value.
    pub position: Option<f64>,
    pub tags: Vec<String>,
    pub checklist: Vec<ChecklistLine>,
    pub due_at: Option<String>,
    pub due_tz: Option<String>,
    pub remind_at: Option<String>,
    pub repeat_rule: Option<String>,
    pub hidden_from_agents: bool,
    pub source_url: Option<String>,
    pub archived: bool,
    pub trashed: bool,
}
impl Default for ItemInput {
    fn default() -> Self {
        Self {
            title: String::new(),
            description: String::new(),
            status: "todo".into(),
            project_id: None,
            priority: 0,
            position: None,
            tags: vec![],
            checklist: vec![],
            due_at: None,
            due_tz: None,
            remind_at: None,
            repeat_rule: None,
            hidden_from_agents: false,
            source_url: None,
            archived: false,
            trashed: false,
        }
    }
}
impl From<&Item> for ItemInput {
    fn from(item: &Item) -> Self {
        Self {
            title: item.title.clone(),
            description: item.description.clone(),
            status: item.status.clone(),
            project_id: item.project_id.clone(),
            priority: item.priority,
            position: Some(item.position),
            tags: item.tags.clone(),
            checklist: item.checklist.clone(),
            due_at: item.due_at.clone(),
            due_tz: item.due_tz.clone(),
            remind_at: item.remind_at.clone(),
            repeat_rule: item.repeat_rule.clone(),
            hidden_from_agents: item.hidden_from_agents,
            source_url: item.source_url.clone(),
            archived: item.archived,
            trashed: item.trashed,
        }
    }
}

fn blank_to_none(value: &mut Option<String>) {
    if let Some(text) = value {
        *text = text.trim().to_string();
        if text.is_empty() {
            *value = None;
        }
    }
}

impl ItemInput {
    // Checks the fields and rewrites them into the one form that is stored. Running it again on
    // stored values changes nothing, which lets an edit be compared with the current row.
    pub fn validate(&mut self, default_tz: Tz) -> Result<Derived> {
        self.title = self.title.split_whitespace().collect::<Vec<_>>().join(" ");
        if self.title.is_empty() || self.title.chars().count() > 240 {
            return Err(ApiError::bad("Use a title between 1 and 240 characters."));
        }
        self.description = self.description.replace("\r\n", "\n").trim().to_string();
        if self.description.chars().count() > 20_000 {
            return Err(ApiError::bad(
                "Keep the description within 20,000 characters.",
            ));
        }
        if !STATUSES.contains(&self.status.as_str()) {
            return Err(ApiError::bad("Status is todo, doing or done."));
        }
        if !(0..=4).contains(&self.priority) {
            return Err(ApiError::bad("Priority is a number from 0 to 4."));
        }
        if self
            .position
            .is_some_and(|position| !position.is_finite() || position.abs() > POSITION_LIMIT)
        {
            return Err(ApiError::bad(
                "Position is a number between -1e15 and 1e15.",
            ));
        }
        self.tags = self
            .tags
            .iter()
            .map(|tag| tag.trim().trim_start_matches('#').to_lowercase())
            .filter(|tag| !tag.is_empty())
            .collect();
        self.tags.sort();
        self.tags.dedup();
        if self.tags.len() > 12
            || self
                .tags
                .iter()
                .any(|tag| tag.chars().count() > 40 || tag.chars().any(char::is_whitespace))
        {
            return Err(ApiError::bad(
                "Use up to 12 tags of at most 40 characters without spaces.",
            ));
        }
        if self.checklist.len() > 100 {
            return Err(ApiError::bad("A checklist holds up to 100 lines."));
        }
        let mut seen: Vec<String> = Vec::with_capacity(self.checklist.len());
        for line in &mut self.checklist {
            line.text = line.text.split_whitespace().collect::<Vec<_>>().join(" ");
            if line.text.is_empty() || line.text.chars().count() > 500 {
                return Err(ApiError::bad(
                    "Each checklist line needs 1 to 500 characters.",
                ));
            }
            if line.id.is_empty() {
                line.id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
            }
            if line.id.len() > 36
                || !line
                    .id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
                || seen.contains(&line.id)
            {
                return Err(ApiError::bad(
                    "Checklist line IDs are unique and use up to 36 letters, digits, - or _.",
                ));
            }
            seen.push(line.id.clone());
        }
        for field in [
            &mut self.project_id,
            &mut self.due_at,
            &mut self.due_tz,
            &mut self.remind_at,
            &mut self.repeat_rule,
            &mut self.source_url,
        ] {
            blank_to_none(field);
        }
        // The zone belongs to the due date. Without one, a reminder is shown in the server's zone.
        let zone = match (&self.due_at, &self.due_tz) {
            (Some(_), Some(name)) => name.parse::<Tz>().map_err(|_| {
                ApiError::bad("Use an IANA time zone like Europe/Zurich for due_tz.")
            })?,
            _ => default_tz,
        };
        let due = match &self.due_at {
            Some(text) => Some(Due::parse(text, zone).ok_or_else(|| {
                ApiError::bad(
                    "Write due_at as a date (2026-11-13) or a time (2026-11-13T09:00, with or without an offset).",
                )
            })?),
            None => None,
        };
        self.due_at = due.as_ref().map(Due::text);
        self.due_tz = due.as_ref().map(|_| zone.name().to_string());
        let remind = match &self.remind_at {
            Some(text) => Some(parse_instant(text, zone).ok_or_else(|| {
                ApiError::bad(
                    "Write remind_at as a time (2026-11-13T09:00, with or without an offset).",
                )
            })?),
            None => None,
        };
        self.remind_at = remind.as_ref().map(local_text);
        if let Some(text) = &self.repeat_rule {
            let due = due
                .as_ref()
                .ok_or_else(|| ApiError::bad("A repeating item needs a due date."))?;
            let rule = Rule::parse(text, due.date()).map_err(ApiError::bad)?;
            // A rule that cannot produce another date would leave the item impossible to complete.
            let next = due
                .date()
                .succ_opt()
                .and_then(|day| rule.next(due.date(), day));
            if !next.is_some_and(|date| YEARS.contains(&date.year())) {
                return Err(ApiError::bad(
                    "This repeat rule has no next occurrence before the year 2200.",
                ));
            }
            self.repeat_rule = Some(rule.canonical());
        }
        if let Some(link) = &self.source_url {
            let valid = link.len() <= 2000
                && url::Url::parse(link).is_ok_and(|url| {
                    matches!(url.scheme(), "http" | "https") && url.host_str().is_some()
                });
            if !valid {
                return Err(ApiError::bad(
                    "Use an http or https link of at most 2,000 characters for source_url.",
                ));
            }
        }
        let due_utc =
            match &due {
                Some(due) => Some(due.utc_key(zone).ok_or_else(|| {
                    ApiError::bad("This due date does not exist in its time zone.")
                })?),
                None => None,
            };
        let remind_utc = remind.as_ref().map(utc_key).or_else(|| match &due {
            Some(Due::At(at)) => Some(utc_key(at)),
            _ => None,
        });
        Ok(Derived {
            due_utc,
            remind_utc,
        })
    }

    // Completing a repeating item: move the due date to the next occurrence after now, shift the
    // reminder by the same number of days, untick the checklist and leave the item open.
    // Call this on validated fields with a due date and a repeat rule, then validate again.
    pub fn advance(&mut self, now: DateTime<Utc>) -> Result<()> {
        let stuck = || ApiError::bad("This repeat rule has no next occurrence.");
        let zone: Tz = self
            .due_tz
            .as_deref()
            .and_then(|name| name.parse().ok())
            .ok_or_else(stuck)?;
        let due = self
            .due_at
            .as_deref()
            .and_then(|text| Due::parse(text, zone))
            .ok_or_else(stuck)?;
        let rule = self
            .repeat_rule
            .as_deref()
            .and_then(|text| Rule::parse(text, due.date()).ok())
            .ok_or_else(stuck)?;
        let today = now.with_timezone(&zone).naive_local();
        let tomorrow = today
            .date()
            .checked_add_days(Days::new(1))
            .ok_or_else(stuck)?;
        let earliest = match &due {
            Due::At(at) if at.time() > today.time() => today.date(),
            _ => tomorrow,
        };
        let next = rule.next(due.date(), earliest).ok_or_else(stuck)?;
        let shift = next - due.date();
        if let Some(remind) = self
            .remind_at
            .as_deref()
            .and_then(|text| parse_instant(text, zone))
        {
            let moved = localize(remind.naive_local() + shift, zone).ok_or_else(stuck)?;
            self.remind_at = Some(local_text(&moved));
        }
        self.due_at = Some(match &due {
            Due::Day(_) => Due::Day(next).text(),
            Due::At(at) => local_text(&localize(next.and_time(at.time()), zone).ok_or_else(stuck)?),
        });
        for line in &mut self.checklist {
            line.done = false;
        }
        self.status = "todo".into();
        Ok(())
    }
}
