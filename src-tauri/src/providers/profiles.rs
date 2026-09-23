use std::{
    path::{Path, PathBuf},
    sync::OnceLock,
};

#[derive(Clone)]
pub(crate) struct Profile {
    pub id: String,
    pub name: String,
    pub kind: &'static str,
    pub home: PathBuf,
    pub headline: &'static str,
}

fn any_marker(directory: &Path, names: &[&str]) -> bool {
    names.iter().any(|name| directory.join(name).exists())
}

fn omp_credential(directory: &Path) -> bool {
    use rusqlite::{Connection, OpenFlags};
    let path = directory.join("agent.db");
    if !path.is_file() {
        return false;
    }
    let Ok(db) = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return false;
    };
    let result: rusqlite::Result<String> = db.query_row(
        "SELECT data FROM auth_credentials WHERE provider = 'google-antigravity' ORDER BY updated_at DESC LIMIT 1",
        [],
        |row| row.get(0),
    );
    result
        .ok()
        .filter(|text| text.len() <= 64 * 1024)
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|value| value.get("access")?.as_str().map(str::to_owned))
        .is_some()
}

fn antigravity_has_credential(directory: &Path) -> bool {
    directory.join("oauth_creds.json").is_file() || omp_credential(directory)
}

fn named_dirs(root: &Path, prefix: &str) -> Vec<(String, PathBuf)> {
    let mut dirs: Vec<_> = std::fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            let slug = name.strip_prefix(prefix)?.to_string();
            (!slug.is_empty() && entry.file_type().ok()?.is_dir()).then_some((slug, entry.path()))
        })
        .collect();
    dirs.sort_by(|a, b| a.0.cmp(&b.0));
    dirs
}

pub(crate) fn discover(home: &Path) -> Vec<Profile> {
    discover_with(home, crate::usage::discover_named_profiles(home))
}

/// AppDelegate captures the three CLI profile lists once at launch. Account
/// choices for a newly created profile are reconciled on the next launch.
static LAUNCH_PROFILES: OnceLock<Vec<Profile>> = OnceLock::new();

pub(crate) fn at_launch(home: &Path) -> Vec<Profile> {
    LAUNCH_PROFILES.get_or_init(|| discover(home)).clone()
}

/// Claude profiles are injected so fixtures never enumerate a real keychain.
fn discover_with(home: &Path, claude_named: Vec<(String, PathBuf)>) -> Vec<Profile> {
    let mut out: Vec<Profile> = claude_named
        .into_iter()
        .map(|(slug, dir)| Profile {
            id: format!("claude-{slug}"),
            name: format!("Claude ({slug})"),
            kind: "claude",
            home: dir,
            headline: "session",
        })
        .collect();
    out.extend(
        named_dirs(home, ".codex-")
            .into_iter()
            .filter(|(_, dir)| {
                any_marker(
                    dir,
                    &[
                        "auth.json",
                        "config.toml",
                        "sessions",
                        "history.jsonl",
                        "state_5.sqlite",
                        "sqlite/codex-dev.db",
                    ],
                )
            })
            .map(|(slug, dir)| Profile {
                id: format!("codex-{slug}"),
                name: format!("Codex ({slug})"),
                kind: "codex",
                home: dir,
                headline: "primary",
            }),
    );
    out.extend(
        named_dirs(&home.join(".gemini"), "antigravity-")
            .into_iter()
            .filter(|(slug, dir)| {
                !["ide", "cli", "backup", "api"].contains(&slug.as_str())
                    && any_marker(
                        dir,
                        &["oauth_creds.json", "credentials.json", "brain", "agent.db"],
                    )
                    && antigravity_has_credential(dir)
            })
            .map(|(slug, dir)| Profile {
                id: format!("antigravity-{slug}"),
                name: format!("Antigravity ({slug})"),
                kind: "antigravity",
                home: dir,
                headline: "",
            }),
    );
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_contract_keeps_signed_out_codex_and_requires_antigravity_credential() {
        let root = tempfile::tempdir().unwrap();
        for (dir, marker) in [
            (".codex-work", "sessions"),
            (".codex-日本語", "config.toml"),
            (".gemini/antigravity-work", "brain"),
            (".gemini/antigravity-client", "oauth_creds.json"),
            (".gemini/antigravity-backup", "oauth_creds.json"),
        ] {
            let path = root.path().join(dir);
            std::fs::create_dir_all(&path).unwrap();
            if marker == "sessions" || marker == "brain" {
                std::fs::create_dir_all(path.join(marker)).unwrap();
            } else {
                std::fs::write(path.join(marker), "{}").unwrap();
            }
        }
        let rows = discover_with(root.path(), Vec::new());
        let ids: Vec<_> = rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(ids, ["antigravity-client", "codex-work", "codex-日本語"]);
    }

    #[test]
    fn omp_profile_requires_a_parseable_owned_row() {
        use rusqlite::Connection;
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join(".gemini/antigravity-omp");
        std::fs::create_dir_all(&dir).unwrap();
        let db = Connection::open(dir.join("agent.db")).unwrap();
        db.execute_batch(
            "CREATE TABLE auth_credentials(provider TEXT,data TEXT,updated_at INTEGER);",
        )
        .unwrap();
        assert!(!omp_credential(&dir));
        db.execute(
            "INSERT INTO auth_credentials VALUES('google-antigravity',?1,1)",
            [r#"{"access":"fixture","expires":0}"#],
        )
        .unwrap();
        assert!(omp_credential(&dir));
    }
}
