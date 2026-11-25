// The skills this server serves over MCP (the skills extension, SEP-2640): playbooks that chain
// the tools. Each one is compiled into the binary next to tools.json, so a server always serves
// the text written for its own tools, and its digest changes exactly when the text does.
use rmcp::model::{
    Resource, ResourceContents, Skill, SkillFrontmatter, SkillResource, SkillResources,
};

struct Embedded {
    name: &'static str,
    // The same text as in the frontmatter of the file; a test keeps the two equal.
    description: &'static str,
    text: &'static str,
}

const SKILLS: &[Embedded] = &[Embedded {
    name: "agent-loop",
    description: "Triage the owner's new Pendenz items and carry each one through questions, a brief, the work and closing it, with the exact tool calls. Use when items wait in stage new, when the owner answers a question about an item or says to start one, and when the work on an item is finished.",
    text: include_str!("skills/agent-loop/SKILL.md"),
}];

const MIME: &str = "text/markdown";

impl Embedded {
    fn uri(&self) -> String {
        format!("skill://pendenz/{}/SKILL.md", self.name)
    }

    fn skill(&self) -> Skill {
        let uri = self.uri();
        let file = SkillResource::from_bytes(uri.clone(), self.text.as_bytes());
        Skill::new(
            uri,
            SkillFrontmatter::new(self.name, self.description),
            SkillResources::Files(vec![file]),
        )
    }
}

fn find(uri: &str) -> Option<&'static Embedded> {
    SKILLS.iter().find(|skill| skill.uri() == uri)
}

pub fn list() -> Vec<Skill> {
    SKILLS.iter().map(Embedded::skill).collect()
}

pub fn get(uri: &str) -> Option<Skill> {
    find(uri).map(Embedded::skill)
}

// The files as plain resources, for clients that read resources but do not know skills.
pub fn resources() -> Vec<Resource> {
    SKILLS
        .iter()
        .map(|skill| {
            Resource::new(skill.uri(), format!("{}/SKILL.md", skill.name))
                .with_description(skill.description)
                .with_mime_type(MIME)
                .with_size(skill.text.len() as u64)
        })
        .collect()
}

pub fn read(uri: &str) -> Option<ResourceContents> {
    find(uri).map(|skill| ResourceContents::text(skill.text, skill.uri()).with_mime_type(MIME))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The frontmatter fields of a SKILL.md, as `key: value` lines between the two `---`.
    fn frontmatter(text: &str) -> Vec<(&str, &str)> {
        let body = text.strip_prefix("---\n").expect("starts with frontmatter");
        let end = body.find("\n---\n").expect("frontmatter ends");
        body[..end]
            .lines()
            .map(|line| line.split_once(": ").expect("key: value"))
            .collect()
    }

    #[test]
    fn entries_are_valid() {
        let skills = list();
        rmcp::model::validate_skills(&skills).unwrap();
        for skill in &skills {
            assert_eq!(get(&skill.uri).as_ref(), Some(skill));
        }
    }

    #[test]
    fn frontmatter_matches_the_entry() {
        for skill in SKILLS {
            assert_eq!(
                frontmatter(skill.text),
                [("name", skill.name), ("description", skill.description)],
                "{}",
                skill.name
            );
        }
    }

    #[test]
    fn served_bytes_match_the_manifest() {
        for skill in list() {
            let SkillResources::Files(files) = &skill.resources else {
                panic!("a fixed manifest")
            };
            for file in files {
                let Some(ResourceContents::TextResourceContents { text, .. }) = read(&file.uri)
                else {
                    panic!("{} is served", file.uri)
                };
                file.verify(text.as_bytes()).unwrap();
            }
        }
    }

    // Every span in backticks that starts with a tool's name and a space is an example call,
    // `tool {json}`: it has to parse and pass that tool's input schema, so a change to tools.json
    // that the skill no longer matches fails here.
    #[test]
    fn examples_match_the_tools() {
        let tools = super::super::tools::definitions();
        let tool = |name: &str| tools.iter().find(|tool| tool["name"] == name);
        for skill in SKILLS {
            let mut found = 0;
            for span in skill.text.split('`').skip(1).step_by(2) {
                let Some((name, args)) = span.split_once(' ') else {
                    continue;
                };
                let Some(tool) = tool(name) else {
                    assert!(
                        !args.starts_with('{'),
                        "{}: no tool {name}: {span}",
                        skill.name
                    );
                    continue;
                };
                let mut args: serde_json::Value = serde_json::from_str(args)
                    .unwrap_or_else(|error| panic!("{}: {span}: {error}", skill.name));
                super::super::schema::validate(&tool["inputSchema"], &mut args)
                    .unwrap_or_else(|issues| panic!("{}: {span}: {issues}", skill.name));
                found += 1;
            }
            assert!(found >= 10, "{}: only {found} examples", skill.name);
        }
    }

    #[test]
    fn unknown_uris_are_not_served() {
        assert!(get("skill://pendenz/other/SKILL.md").is_none());
        assert!(read("skill://pendenz/agent-loop/other.md").is_none());
    }
}
