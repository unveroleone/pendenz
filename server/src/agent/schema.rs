// Checks tool arguments against the input schemas in tools.json and fills in their defaults.
// It knows the part of JSON Schema those schemas use, and words its errors as the zod checks
// of the first version of these tools did. String lengths count UTF-16 units, as they did.
use serde_json::{Map, Value};

pub fn validate(schema: &Value, value: &mut Value) -> Result<(), String> {
    let mut issues = Vec::new();
    check(schema, value, &mut Vec::new(), &mut issues);
    if issues.is_empty() {
        Ok(())
    } else {
        Err(issues.join("\n"))
    }
}

// Every pattern in tools.json, each with its check. An unknown pattern fails the tool list
// when it loads, so a new one cannot slip through unchecked.
pub fn known_pattern(pattern: &str) -> bool {
    matches(pattern, "").is_some()
}

fn matches(pattern: &str, text: &str) -> Option<bool> {
    let positive = |s: &str| {
        let mut chars = s.chars();
        matches!(chars.next(), Some('1'..='9')) && chars.all(|c| c.is_ascii_digit())
    };
    Some(match pattern {
        r"^([Pp]-)?[1-9]\d*$" => positive(
            text.strip_prefix("P-")
                .or_else(|| text.strip_prefix("p-"))
                .unwrap_or(text),
        ),
        r"^[1-9]\d*$" => positive(text),
        r"^\S+$" => !text.is_empty() && !text.chars().any(js_space),
        _ => return None,
    })
}

// What JavaScript's trim() and \s count as white space.
pub fn js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
    )
}

pub fn js_trim(text: &str) -> &str {
    text.trim_matches(js_space)
}

pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

#[derive(Clone)]
enum Segment {
    Key(String),
    Index(usize),
}

fn at(path: &[Segment]) -> String {
    let mut out = String::new();
    for segment in path {
        match segment {
            Segment::Key(key) => {
                if !out.is_empty() {
                    out.push('.');
                }
                out.push_str(key);
            }
            Segment::Index(i) => out.push_str(&format!("[{i}]")),
        }
    }
    if out.is_empty() {
        out
    } else {
        format!(" at {out}")
    }
}

fn kind(value: Option<&Value>) -> &'static str {
    match value {
        None => "undefined",
        Some(Value::Null) => "null",
        Some(Value::Bool(_)) => "boolean",
        Some(Value::Number(_)) => "number",
        Some(Value::String(_)) => "string",
        Some(Value::Array(_)) => "array",
        Some(Value::Object(_)) => "object",
    }
}

fn is_integer(value: &Value) -> bool {
    value
        .as_f64()
        .is_some_and(|n| n.is_finite() && n.fract() == 0.0)
}

fn fits(type_name: &str, value: &Value) -> bool {
    match type_name {
        "string" => value.is_string(),
        "number" => value.is_number(),
        "integer" => value.is_number(),
        "boolean" => value.is_boolean(),
        "object" => value.is_object(),
        "array" => value.is_array(),
        "null" => value.is_null(),
        _ => false,
    }
}

fn number(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 9.007_199_254_740_992e15 {
        format!("{}", n as i64)
    } else {
        format!("{n}")
    }
}

// A value that is missing is checked as `None`, so the message can say "received undefined".
fn check_missing(schema: &Value, path: &[Segment], issues: &mut Vec<String>) {
    if schema.get("anyOf").is_some() {
        issues.push(format!("Invalid input{}", at(path)));
        return;
    }
    let expected = match schema.get("type") {
        Some(Value::String(t)) => t.as_str(),
        Some(Value::Array(types)) => types.first().and_then(Value::as_str).unwrap_or("value"),
        _ => "value",
    };
    let expected = if expected == "integer" {
        "number"
    } else {
        expected
    };
    issues.push(format!(
        "Invalid input: expected {expected}, received undefined{}",
        at(path)
    ));
}

fn check(schema: &Value, value: &mut Value, path: &mut Vec<Segment>, issues: &mut Vec<String>) {
    if let Some(Value::Array(branches)) = schema.get("anyOf") {
        for branch in branches {
            let mut candidate = value.clone();
            let mut found = Vec::new();
            check(branch, &mut candidate, path, &mut found);
            if found.is_empty() {
                *value = candidate;
                return;
            }
        }
        issues.push(format!("Invalid input{}", at(path)));
        return;
    }
    let types: Vec<&str> = match schema.get("type") {
        Some(Value::String(t)) => vec![t.as_str()],
        Some(Value::Array(types)) => types.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    };
    if !types.is_empty() && !types.iter().any(|t| fits(t, value)) {
        let expected = types
            .iter()
            .find(|t| **t != "null")
            .copied()
            .unwrap_or("null");
        let expected = if expected == "integer" {
            "number"
        } else {
            expected
        };
        issues.push(format!(
            "Invalid input: expected {expected}, received {}{}",
            kind(Some(value)),
            at(path)
        ));
        return;
    }
    if value.is_null() {
        return;
    }
    if let Some(expected) = schema.get("const")
        && value != expected
    {
        issues.push(format!("Invalid input: expected {expected}{}", at(path)));
        return;
    }
    if let Some(Value::Array(options)) = schema.get("enum")
        && !options.contains(value)
    {
        let options: Vec<String> = options.iter().map(Value::to_string).collect();
        issues.push(format!(
            "Invalid option: expected one of {}{}",
            options.join("|"),
            at(path)
        ));
        return;
    }
    match value {
        Value::String(text) => check_string(schema, text, path, issues),
        Value::Number(_) => check_number(schema, value, &types, path, issues),
        Value::Array(items) => {
            if let Some(max) = schema.get("maxItems").and_then(Value::as_u64)
                && items.len() as u64 > max
            {
                issues.push(format!(
                    "Too big: expected array to have <={max} items{}",
                    at(path)
                ));
            }
            if let Some(item_schema) = schema.get("items") {
                for (i, item) in items.iter_mut().enumerate() {
                    path.push(Segment::Index(i));
                    check(item_schema, item, path, issues);
                    path.pop();
                }
            }
        }
        Value::Object(map) => check_object(schema, map, path, issues),
        _ => {}
    }
}

fn check_string(schema: &Value, text: &str, path: &[Segment], issues: &mut Vec<String>) {
    let len = utf16_len(text) as u64;
    if let Some(min) = schema.get("minLength").and_then(Value::as_u64)
        && len < min
    {
        issues.push(format!(
            "Too small: expected string to have >={min} characters{}",
            at(path)
        ));
    }
    if let Some(max) = schema.get("maxLength").and_then(Value::as_u64)
        && len > max
    {
        issues.push(format!(
            "Too big: expected string to have <={max} characters{}",
            at(path)
        ));
    }
    if let Some(pattern) = schema.get("pattern").and_then(Value::as_str)
        && matches(pattern, text) != Some(true)
    {
        issues.push(format!(
            "Invalid string: must match pattern /{pattern}/{}",
            at(path)
        ));
    }
    if schema.get("format").and_then(Value::as_str) == Some("uri") && url::Url::parse(text).is_err()
    {
        issues.push(format!("Invalid URL{}", at(path)));
    }
}

fn check_number(
    schema: &Value,
    value: &Value,
    types: &[&str],
    path: &[Segment],
    issues: &mut Vec<String>,
) {
    let n = value.as_f64().unwrap_or(f64::NAN);
    if types.contains(&"integer") && !types.contains(&"number") && !is_integer(value) {
        issues.push(format!(
            "Invalid input: expected int, received number{}",
            at(path)
        ));
        return;
    }
    if let Some(min) = schema.get("minimum").and_then(Value::as_f64)
        && n < min
    {
        issues.push(format!(
            "Too small: expected number to be >={}{}",
            number(min),
            at(path)
        ));
    }
    if let Some(min) = schema.get("exclusiveMinimum").and_then(Value::as_f64)
        && n <= min
    {
        issues.push(format!(
            "Too small: expected number to be >{}{}",
            number(min),
            at(path)
        ));
    }
    if let Some(max) = schema.get("maximum").and_then(Value::as_f64)
        && n > max
    {
        issues.push(format!(
            "Too big: expected number to be <={}{}",
            number(max),
            at(path)
        ));
    }
}

fn check_object(
    schema: &Value,
    map: &mut Map<String, Value>,
    path: &mut Vec<Segment>,
    issues: &mut Vec<String>,
) {
    let empty = Map::new();
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|r| r.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    for (name, property) in properties {
        path.push(Segment::Key(name.clone()));
        match map.get_mut(name) {
            Some(value) => check(property, value, path, issues),
            None => {
                if let Some(default) = property.get("default") {
                    map.insert(name.clone(), default.clone());
                } else if required.contains(&name.as_str()) {
                    check_missing(property, path, issues);
                }
            }
        }
        path.pop();
    }
    if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
        let unknown: Vec<String> = map
            .keys()
            .filter(|key| !properties.contains_key(*key))
            .map(|key| format!("\"{key}\""))
            .collect();
        match unknown.len() {
            0 => {}
            1 => issues.push(format!("Unrecognized key: {}{}", unknown[0], at(path))),
            _ => issues.push(format!(
                "Unrecognized keys: {}{}",
                unknown.join(", "),
                at(path)
            )),
        }
    }
}
