use std::path::{Path, PathBuf};
#[derive(Clone)]
pub(super) struct Profile {
    pub id: String,
    pub name: String,
    pub kind: &'static str,
    pub home: PathBuf,
    pub headline: &'static str,
}
pub(super) fn discover(home: &Path) -> Vec<Profile> {
    let mut out = Vec::new();
    for (root, prefix, kind, title, marker, headline) in [
        (
            home.to_owned(),
            ".claude-",
            "claude",
            "Claude",
            ".credentials.json",
            "session",
        ),
        (
            home.to_owned(),
            ".codex-",
            "codex",
            "Codex",
            "auth.json",
            "primary",
        ),
        (
            home.join(".gemini"),
            "antigravity-",
            "antigravity",
            "Antigravity",
            "oauth_creds.json",
            "",
        ),
    ] {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten().take(4096) {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(slug) = name.strip_prefix(prefix).filter(|s| !s.is_empty()) else {
                continue;
            };
            if kind == "antigravity" && ["ide", "cli", "backup", "api"].contains(&slug) {
                continue;
            }
            if !entry.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            if !entry.path().join(marker).is_file()
                && !(kind == "claude" && entry.path().join("credentials.json").is_file())
            {
                continue;
            }
            if !slug
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
            {
                continue;
            }
            out.push(Profile {
                id: format!("{kind}-{slug}"),
                name: format!("{title} ({slug})"),
                kind,
                home: entry.path(),
                headline,
            });
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out.truncate(64);
    out
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovers_accounts_not_internal_flavours() {
        let d = tempfile::tempdir().unwrap();
        for (dir, file) in [
            (".claude-work", ".credentials.json"),
            (".codex-work", "auth.json"),
            (".gemini/antigravity-work", "oauth_creds.json"),
            (".gemini/antigravity-backup", "oauth_creds.json"),
        ] {
            std::fs::create_dir_all(d.path().join(dir)).unwrap();
            std::fs::write(d.path().join(dir).join(file), "{}").unwrap();
        }
        let profiles = discover(d.path());
        assert_eq!(profiles.len(), 3);
        assert!(profiles.iter().any(|p| p.id == "codex-work"));
    }
}
