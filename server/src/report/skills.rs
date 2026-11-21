// The first sentence of the skill a Hermes job runs, so the Agents screen can say what a job does
// before the owner writes a line. Hermes finds a skill by its folder's name, at any depth, in the
// home's `skills` folder and then in the folders of `skills.external_dirs`, and last by a unique
// `name:` in a skill's frontmatter. Only the frontmatter's `description` is read, never the rest
// of the skill and never the job's prompt.
use std::{
    cell::OnceCell,
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

// How deep below a skills folder a skill may lie, how many folder entries one index looks at and
// how long it may take, so a large, looping or slow tree cannot hold up the report.
const DEPTH: usize = 4;
const ENTRIES: usize = 20_000;
const TIME: Duration = Duration::from_secs(3);
// More than any frontmatter needs; a skill's body is not read.
const HEAD: usize = 16 * 1024;
const FRONTMATTER_LINES: usize = 80;

pub struct Skills {
    // Each skill folder by its name, the first found winning, as Hermes does.
    by_folder: HashMap<String, PathBuf>,
    // Every skill folder in the order found, for the lookup by frontmatter name.
    all: Vec<PathBuf>,
    // The frontmatter names, read once and only when a name is not a folder's.
    by_name: OnceCell<HashMap<String, Option<PathBuf>>>,
}

impl Skills {
    // The skill folders under `<home>/skills` and the external folders, read once per report.
    pub fn index(home: &Path, external: &[String]) -> Self {
        let mut roots = vec![home.join("skills")];
        roots.extend(external.iter().filter_map(|dir| expand(dir, home)));
        let mut skills = Skills {
            by_folder: HashMap::new(),
            all: Vec::new(),
            by_name: OnceCell::new(),
        };
        let started = Instant::now();
        let mut entries = 0;
        // A folder reached twice, through a link or a second root, is read once.
        let mut visited = HashSet::new();
        for root in roots {
            let mut stack = vec![(root, 0)];
            while let Some((dir, depth)) = stack.pop() {
                if started.elapsed() > TIME {
                    return skills;
                }
                let Ok(real) = std::fs::canonicalize(&dir) else {
                    continue;
                };
                if !visited.insert(real) {
                    continue;
                }
                if dir.join("SKILL.md").is_file() {
                    if let Some(name) = dir.file_name().and_then(|n| n.to_str()) {
                        skills
                            .by_folder
                            .entry(name.to_owned())
                            .or_insert_with(|| dir.clone());
                    }
                    skills.all.push(dir);
                    continue;
                }
                if depth >= DEPTH {
                    continue;
                }
                let Ok(list) = std::fs::read_dir(&dir) else {
                    continue;
                };
                let mut children = Vec::new();
                for entry in list.filter_map(Result::ok) {
                    entries += 1;
                    if entries > ENTRIES {
                        return skills;
                    }
                    let path = entry.path();
                    let shown = path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| !n.starts_with('.') && n != "node_modules");
                    if shown && path.is_dir() {
                        children.push(path);
                    }
                }
                // Read in name order, so "the first found" is the same on every run.
                children.sort();
                stack.extend(children.into_iter().rev().map(|p| (p, depth + 1)));
            }
        }
        skills
    }

    // The first sentence of the named skill's description, when the skill is found and its
    // description reads cleanly.
    pub fn summary(&self, name: &str) -> Option<String> {
        let dir = match self.by_folder.get(name) {
            Some(dir) => dir,
            // A name two skills claim is not guessed at, as in Hermes.
            None => self.by_name().get(name)?.as_ref()?,
        };
        first_sentence(&value(&frontmatter(dir)?, "description")?)
    }

    fn by_name(&self) -> &HashMap<String, Option<PathBuf>> {
        self.by_name.get_or_init(|| {
            let mut names: HashMap<String, Option<PathBuf>> = HashMap::new();
            for dir in &self.all {
                if let Some(name) = frontmatter(dir).and_then(|f| value(&f, "name")) {
                    names
                        .entry(name)
                        .and_modify(|found| *found = None)
                        .or_insert_with(|| Some(dir.clone()));
                }
            }
            names
        })
    }
}

// A folder from `external_dirs`: `~` and `${VAR}` expanded, relative to the Hermes home. One
// that names a variable that is not set is left out.
fn expand(dir: &str, home: &Path) -> Option<PathBuf> {
    let text = dir.trim();
    if text.is_empty() {
        return None;
    }
    let text = if text == "~" || text.starts_with("~/") {
        format!("{}{}", std::env::var("HOME").ok()?, &text[1..])
    } else {
        text.to_owned()
    };
    // Left to right, without reading a variable's value again.
    let mut out = String::new();
    let mut rest = text.as_str();
    while let Some(start) = rest.find("${") {
        let end = start + rest[start..].find('}')?;
        out.push_str(&rest[..start]);
        let value = std::env::var(&rest[start + 2..end])
            .ok()
            .filter(|v| !v.is_empty())?;
        out.push_str(&value);
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    let path = PathBuf::from(out);
    Some(if path.is_absolute() {
        path
    } else {
        home.join(path)
    })
}

// The frontmatter of a skill, between the first two `---` lines, when it looks like YAML: every
// line that is not indented is a key or a comment. Anything else, such as a missing closing line
// that would take in the skill's text, gives none.
fn frontmatter(dir: &Path) -> Option<String> {
    use std::io::Read;
    let mut head = Vec::new();
    std::fs::File::open(dir.join("SKILL.md"))
        .ok()?
        .take(HEAD as u64)
        .read_to_end(&mut head)
        .ok()?;
    let text = String::from_utf8_lossy(&head);
    let mut lines = text.lines();
    if lines.next()?.trim_end() != "---" {
        return None;
    }
    let mut out = String::new();
    for line in lines.take(FRONTMATTER_LINES) {
        if line.trim_end() == "---" {
            return Some(out);
        }
        let top = !line.starts_with([' ', '\t']) && !line.trim().is_empty();
        if top && !line.starts_with('#') && !is_key(line) {
            return None;
        }
        out.push_str(line);
        out.push('\n');
    }
    None
}

fn is_key(line: &str) -> bool {
    let Some((key, _)) = line.split_once(':') else {
        return false;
    };
    !key.is_empty()
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

// A top-level value of the frontmatter as one line: plain, quoted, or a `>` or `|` block, with
// its continuation lines folded in and a trailing comment left out. Anything it cannot read
// gives none.
fn value(frontmatter: &str, key: &str) -> Option<String> {
    let mut lines = frontmatter.lines();
    let first = lines.by_ref().find_map(|line| {
        line.strip_prefix(key)
            .and_then(|rest| rest.strip_prefix(':'))
    })?;
    let mut text = first.trim().to_owned();
    let block = text.starts_with(['>', '|']);
    if block {
        text.clear();
    } else {
        text = uncommented(&text).to_owned();
    }
    // Continuation lines are indented; the next key is not.
    for line in lines {
        if !line.starts_with([' ', '\t']) && !line.trim().is_empty() {
            break;
        }
        let line = line.trim();
        let line = if block { line } else { uncommented(line) };
        if !line.is_empty() {
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(line);
        }
    }
    if !block {
        if let Some(inner) = text.strip_prefix('"') {
            let end = closing(inner, '"')?;
            text = inner[..end].replace("\\\"", "\"");
        } else if let Some(inner) = text.strip_prefix('\'') {
            let end = closing(inner, '\'')?;
            text = inner[..end].replace("''", "'");
        } else if text.starts_with(['[', '{', '&', '*', '!', '#']) {
            return None;
        }
    }
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    (!text.is_empty()).then_some(text)
}

// A plain value without the comment after it: YAML starts one with " #".
fn uncommented(text: &str) -> &str {
    if text.starts_with(['"', '\'']) {
        return text;
    }
    text.split(" #").next().unwrap_or("").trim_end()
}

// Where a quoted value ends: its closing quote, with nothing but a comment after it.
fn closing(inner: &str, quote: char) -> Option<usize> {
    let mut chars = inner.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        if quote == '"' && c == '\\' {
            chars.next();
            continue;
        }
        if c == quote {
            if quote == '\'' && chars.peek().is_some_and(|&(_, n)| n == '\'') {
                chars.next();
                continue;
            }
            let after = inner[at + 1..].trim();
            return (after.is_empty() || after.starts_with('#')).then_some(at);
        }
    }
    None
}

// Words a period follows without ending the sentence.
const ABBREVIATIONS: [&str; 6] = ["e.g", "i.e", "etc", "vs", "approx", "incl"];

// The first sentence: up to the first ".", "!" or "?" (and a closing quote or bracket) that a
// space or the end follows, unless the period ends an abbreviation such as "e.g." or "U.S.". A
// description written for the model ("Use when ...") says when, not what, so it gives none.
fn first_sentence(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    if ["use when", "use for", "use this", "use whenever"]
        .iter()
        .any(|p| lower.starts_with(p))
    {
        return None;
    }
    for (at, c) in text.char_indices() {
        if !matches!(c, '.' | '!' | '?') {
            continue;
        }
        let mut end = at + c.len_utf8();
        end += text[end..]
            .chars()
            .take_while(|ch| matches!(ch, '"' | '\'' | ')' | '\u{201d}' | '\u{2019}'))
            .map(char::len_utf8)
            .sum::<usize>();
        let after = &text[end..];
        if !(after.is_empty() || after.starts_with(' ')) {
            continue;
        }
        if c == '.' && !after.is_empty() {
            let word = text[..at]
                .rsplit(|ch: char| ch.is_whitespace() || ch == '(')
                .next()
                .unwrap_or("");
            let single = word.chars().count() == 1 && word.chars().all(char::is_alphabetic);
            if single || word.contains('.') || ABBREVIATIONS.contains(&word.to_lowercase().as_str())
            {
                continue;
            }
        }
        return Some(text[..end].trim().to_owned());
    }
    Some(text.trim().to_owned())
}
