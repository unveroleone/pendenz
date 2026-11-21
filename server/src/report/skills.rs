// The first sentence of the skill a Hermes job runs, so the Agents screen can say what a job does
// before the owner writes a line. Hermes finds a skill by its folder's name, at any depth, in the
// home's `skills` folder and then in the folders of `skills.external_dirs`, and last by a unique
// `name:` in a skill's frontmatter. Only the frontmatter's `description` is read, never the rest
// of the skill and never the job's prompt.
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
};

// How deep below a skills folder a skill may lie, and how many folders one lookup looks at, so a
// large or looping tree cannot hold up the report.
const DEPTH: usize = 4;
const FOLDERS: usize = 5000;
// More than any frontmatter needs; a skill's body is not read.
const HEAD: usize = 16 * 1024;

pub struct Skills {
    // Each skill folder by its name, the first found winning, as Hermes does.
    by_folder: HashMap<String, PathBuf>,
    // Every skill folder in the order found, for the lookup by frontmatter name.
    all: Vec<PathBuf>,
}

impl Skills {
    // The skill folders under `<home>/skills` and the external folders, read once per report.
    pub fn index(home: &Path, external: &[String]) -> Self {
        let mut roots = vec![home.join("skills")];
        roots.extend(external.iter().filter_map(|dir| expand(dir, home)));
        let mut skills = Skills {
            by_folder: HashMap::new(),
            all: Vec::new(),
        };
        let mut seen = 0;
        for root in roots {
            let mut stack = vec![(root, 0)];
            while let Some((dir, depth)) = stack.pop() {
                seen += 1;
                if seen > FOLDERS {
                    return skills;
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
                let Ok(entries) = std::fs::read_dir(&dir) else {
                    continue;
                };
                let mut children: Vec<PathBuf> = entries
                    .filter_map(Result::ok)
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name()
                            .and_then(|n| n.to_str())
                            .is_some_and(|n| !n.starts_with('.') && n != "node_modules")
                            && p.is_dir()
                    })
                    .collect();
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
            Some(dir) => dir.clone(),
            None => {
                let mut named = self.all.iter().filter(|dir| {
                    frontmatter(dir).is_some_and(|f| value(&f, "name") == Some(name.to_owned()))
                });
                let dir = named.next()?;
                // A name two skills claim is not guessed at, as in Hermes.
                if named.next().is_some() {
                    return None;
                }
                dir.clone()
            }
        };
        first_sentence(&value(&frontmatter(&dir)?, "description")?)
    }
}

// A folder from `external_dirs`: `~` and `${VAR}` expanded, relative to the Hermes home.
fn expand(dir: &str, home: &Path) -> Option<PathBuf> {
    let mut text = dir.trim().to_owned();
    if text.is_empty() {
        return None;
    }
    if text == "~" || text.starts_with("~/") {
        let user = std::env::var("HOME").ok()?;
        text = format!("{user}{}", &text[1..]);
    }
    while let Some(start) = text.find("${") {
        let end = start + text[start..].find('}')?;
        let value = std::env::var(&text[start + 2..end]).unwrap_or_default();
        text.replace_range(start..=end, &value);
    }
    let path = PathBuf::from(text);
    Some(if path.is_absolute() {
        path
    } else {
        home.join(path)
    })
}

// The frontmatter of a skill, between the first two `---` lines.
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
    for line in lines {
        if line.trim_end() == "---" {
            return Some(out);
        }
        out.push_str(line);
        out.push('\n');
    }
    None
}

// A top-level value of the frontmatter as one line: plain, quoted, or a `>` or `|` block, with
// its continuation lines folded in. Anything it cannot read gives none.
fn value(frontmatter: &str, key: &str) -> Option<String> {
    let mut lines = frontmatter.lines();
    let first = lines.by_ref().find_map(|line| {
        line.strip_prefix(key)
            .and_then(|rest| rest.strip_prefix(':'))
    })?;
    let mut text = first.trim().to_owned();
    let block = matches!(text.chars().next(), Some('>' | '|'));
    if block {
        text.clear();
    }
    // Continuation lines are indented; the next key is not.
    for line in lines {
        if !line.starts_with([' ', '\t']) && !line.trim().is_empty() {
            break;
        }
        let line = line.trim();
        if !line.is_empty() {
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(line);
        }
    }
    if !block {
        if let Some(inner) = text.strip_prefix('"') {
            text = inner.strip_suffix('"')?.replace("\\\"", "\"");
        } else if let Some(inner) = text.strip_prefix('\'') {
            text = inner.strip_suffix('\'')?.replace("''", "'");
        } else if text.starts_with(['[', '{', '&', '*', '!']) {
            return None;
        }
    }
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    (!text.is_empty()).then_some(text)
}

// Words a period follows without ending the sentence.
const ABBREVIATIONS: [&str; 6] = ["e.g", "i.e", "etc", "vs", "approx", "incl"];

// The first sentence: up to the first ".", "!" or "?" that a space and a capital or the end
// follow. A description written for the model ("Use when ...") says when, not what, so it
// gives none.
fn first_sentence(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    if lower.starts_with("use when")
        || lower.starts_with("use for")
        || lower.starts_with("use this")
        || lower.starts_with("use whenever")
    {
        return None;
    }
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    for (i, &(at, c)) in chars.iter().enumerate() {
        if !matches!(c, '.' | '!' | '?') {
            continue;
        }
        let end = at + c.len_utf8();
        let after = &text[end..];
        let ends = after.is_empty()
            || (after.starts_with(' ')
                && after[1..]
                    .chars()
                    .next()
                    .is_some_and(|n| n.is_uppercase() || n.is_ascii_digit() || n == '"'));
        if !ends {
            continue;
        }
        let word = text[..at]
            .rsplit(|ch: char| ch.is_whitespace() || ch == '(')
            .next()
            .unwrap_or("");
        let word_lower = word.to_lowercase();
        if c == '.'
            && (ABBREVIATIONS.contains(&word_lower.as_str())
                || (word.chars().count() == 1 && word.chars().all(char::is_alphabetic)))
            && i + 1 < chars.len()
        {
            continue;
        }
        return Some(text[..end].trim().to_owned());
    }
    Some(text.trim().to_owned())
}
