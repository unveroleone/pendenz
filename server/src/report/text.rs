// Text that leaves the agent's machine: cut to a length, one line, without home paths or
// anything that looks like a key.

pub fn cut(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let mut out: String = text.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

// Prefixes of keys and tokens that are kept out of a report even when short.
const KEY_PREFIXES: [&str; 8] = [
    "sk-",
    "pdz_",
    "ghp_",
    "gho_",
    "github_pat_",
    "xoxb-",
    "xoxp-",
    "Bearer",
];

// A word, or a part of it such as the value in key=value, that looks like a key.
fn looks_like_secret(word: &str) -> bool {
    word.split(['=', ':', '/', ',', '"', '\''])
        .any(looks_like_key)
}

fn looks_like_key(word: &str) -> bool {
    let bare = word.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '-');
    if KEY_PREFIXES.iter().any(|p| bare.starts_with(p)) {
        return true;
    }
    // A long run of letters and digits with both, as keys, hashes and tokens are.
    bare.len() >= 24
        && bare
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        && bare.chars().any(|c| c.is_ascii_digit())
        && bare.chars().any(|c| c.is_ascii_alphabetic())
}

// The first line of a message, with the home folder written as ~ and key-like words removed.
pub fn clean(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    let line = match std::env::var("HOME") {
        Ok(home) if home.len() > 1 => line.replace(&home, "~"),
        _ => line.to_owned(),
    };
    line.split_whitespace()
        .map(|word| {
            if looks_like_secret(word) {
                "[hidden]"
            } else {
                word
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hides_keys_and_keeps_words() {
        assert_eq!(
            clean("401 from api: key sk-ant-abc123 rejected\nmore"),
            "401 from api: key [hidden] rejected"
        );
        assert_eq!(
            clean("token=a1b2c3d4e5f6a1b2c3d4e5f6a1b2 failed"),
            "[hidden] failed"
        );
        assert_eq!(clean("timeout after 30s"), "timeout after 30s");
    }

    #[test]
    fn cuts_on_characters() {
        assert_eq!(cut("äöüäöü", 4), "äöü…");
        assert_eq!(cut(" short ", 10), "short");
    }
}
