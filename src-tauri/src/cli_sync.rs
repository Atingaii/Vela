//! Portable library and reviewed, optimistic, backed-up writes. Never executes an MCP or skill.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant},
};
use toml_edit::{value, DocumentMut, Item, Table};
static LOCK: Mutex<()> = Mutex::new(());
static PENDING: Mutex<Option<Plan>> = Mutex::new(None);
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Library {
    pub providers: Vec<Provider>,
    pub mcp: Vec<Mcp>,
    pub skills: Vec<Skill>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Provider {
    pub id: String,
    pub cli: String,
    pub name: String,
    pub base_url: String,
    pub model: String,
    pub key_env: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Mcp {
    pub id: String,
    pub transport: String,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub env_vars: Vec<String>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Skill {
    pub id: String,
    pub description: String,
    pub instructions: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub kind: String,
    pub id: String,
    pub targets: Vec<String>,
}
struct Change {
    path: PathBuf,
    before: Option<Vec<u8>>,
    after: Vec<u8>,
    summary: String,
}
struct Plan {
    token: String,
    created: Instant,
    changes: Vec<Change>,
}
fn id_ok(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !id.starts_with('-')
        && !id.ends_with('-')
}
fn cli_ok(cli: &str) -> bool {
    matches!(cli, "claude" | "codex" | "gemini")
}
fn env_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() < 128
        && !s.as_bytes()[0].is_ascii_digit()
        && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
}
fn endpoint(s: &str) -> Result<(), String> {
    let u = tauri::Url::parse(s).map_err(|_| "无效 URL")?;
    if !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || !(u.scheme() == "https"
            || u.scheme() == "http"
                && matches!(u.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")))
    {
        return Err("地址须使用 HTTPS（本机可 HTTP），不得包含凭据、查询或片段".into());
    }
    Ok(())
}
fn validate(lib: &Library) -> Result<(), String> {
    if lib.providers.len() + lib.mcp.len() + lib.skills.len() > 100 {
        return Err("资料库上限为 100 项".into());
    }
    for ids in [
        lib.providers.iter().map(|p| &p.id).collect::<Vec<_>>(),
        lib.mcp.iter().map(|p| &p.id).collect(),
        lib.skills.iter().map(|p| &p.id).collect(),
    ] {
        let mut seen = HashSet::new();
        for id in ids {
            if !id_ok(id) || !seen.insert(id) {
                return Err("ID 需唯一，仅使用小写字母、数字和连字符".into());
            }
        }
    }
    for p in &lib.providers {
        endpoint(&p.base_url)?;
        if !cli_ok(&p.cli)
            || !env_ok(&p.key_env)
            || p.model.is_empty()
            || p.model.len() > 200
            || p.name.len() > 100
        {
            return Err("供应商字段无效".into());
        }
    }
    for m in &lib.mcp {
        if m.transport == "http" {
            endpoint(&m.url)?;
            if !m.env_vars.is_empty() {
                return Err("HTTP MCP 的 OAuth 请在各 CLI 内登录；本版不转换认证头".into());
            }
        } else if m.transport != "stdio" || m.command.is_empty() || m.command.contains(['\n', '\r'])
        {
            return Err("MCP 需为 stdio 或 http".into());
        }
        if m.env_vars.iter().any(|s| !env_ok(s)) || m.args.len() > 100 {
            return Err("MCP 环境变量或参数无效".into());
        }
    }
    for s in &lib.skills {
        if s.description.trim().is_empty()
            || s.description.len() > 1024
            || s.instructions.trim().is_empty()
            || s.instructions.len() > 256 * 1024
        {
            return Err("Skill 需要描述和正文，正文上限 256 KiB".into());
        }
    }
    Ok(())
}
fn lib_path() -> PathBuf {
    crate::workbench::root().join("library.json")
}
#[tauri::command]
pub fn get_library() -> Result<Library, String> {
    match fs::read(lib_path()) {
        Ok(b) => serde_json::from_slice(&b).map_err(|e| format!("资料库解析失败: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Library::default()),
        Err(e) => Err(e.to_string()),
    }
}
#[tauri::command]
pub fn save_library(library: Library) -> Result<(), String> {
    validate(&library)?;
    let bytes = serde_json::to_vec_pretty(&library).map_err(|e| e.to_string())?;
    if bytes.len() > 1024 * 1024 {
        return Err("资料库超过 1 MiB".into());
    }
    crate::workbench::atomic(&lib_path(), &bytes)
}
// Reject symlinks anywhere below the user root. Reading invalid config never silently resets it.
fn safe_path(path: &Path) -> Result<(), String> {
    for p in path.ancestors() {
        match fs::symlink_metadata(p) {
            Ok(m) if m.file_type().is_symlink() => {
                return Err(format!("不覆盖符号链接: {}", p.display()))
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}
fn read(path: &Path) -> Result<Option<Vec<u8>>, String> {
    safe_path(path)?;
    match fs::metadata(path) {
        Ok(m) if !m.is_file() || m.len() > 2 * 1024 * 1024 => {
            return Err("配置须为不超过 2 MiB 的普通文件".into())
        }
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.to_string()),
        _ => {}
    }
    match fs::read(path) {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}
fn object(bytes: &Option<Vec<u8>>) -> Result<Value, String> {
    let v: Value = if let Some(b) = bytes {
        serde_json::from_slice(b).map_err(|e| format!("现有 JSON 无效，未修改: {e}"))?
    } else {
        json!({})
    };
    if !v.is_object() {
        return Err("现有配置须为 JSON 对象".into());
    }
    Ok(v)
}
fn put(v: &mut Value, keys: &[&str], val: Value) -> Result<(), String> {
    let mut curr = v;
    for key in &keys[..keys.len() - 1] {
        if !curr.is_object() {
            return Err("现有字段类型冲突，未修改".into());
        }
        if curr.get(*key).is_none() {
            curr[*key] = json!({});
        }
        curr = &mut curr[*key];
    }
    curr.as_object_mut()
        .ok_or("现有字段类型冲突，未修改")?
        .insert(keys[keys.len() - 1].into(), val);
    Ok(())
}
fn table<'a>(d: &'a mut DocumentMut, key: &str) -> Result<&'a mut Table, String> {
    if !d.contains_key(key) {
        d[key] = Item::Table(Table::new());
    }
    d[key]
        .as_table_mut()
        .ok_or_else(|| format!("TOML 字段 {key} 不是表，未修改"))
}
fn document(bytes: &Option<Vec<u8>>) -> Result<DocumentMut, String> {
    String::from_utf8(bytes.clone().unwrap_or_default())
        .map_err(|e| e.to_string())?
        .parse::<DocumentMut>()
        .map_err(|e| format!("现有 TOML 无效，未修改: {e}"))
}
fn json_bytes(v: &Value) -> Result<Vec<u8>, String> {
    serde_json::to_vec_pretty(v).map_err(|e| e.to_string())
}
fn build(
    home: &Path,
    lib: &Library,
    request: &Request,
    resolve: impl Fn(&str) -> Result<String, String>,
) -> Result<Vec<Change>, String> {
    validate(lib)?;
    if request.targets.is_empty()
        || request.targets.len() > 3
        || request.targets.iter().any(|s| !cli_ok(s))
    {
        return Err("请选择有效 CLI".into());
    }
    let mut out = Vec::new();
    let targets: HashSet<_> = request.targets.iter().collect();
    for cli in targets {
        let config = home.join(match cli.as_str() {
            "claude" => ".claude/settings.json",
            "codex" => ".codex/config.toml",
            _ => ".gemini/settings.json",
        });
        if request.kind == "provider" {
            let p = lib
                .providers
                .iter()
                .find(|p| p.id == request.id)
                .ok_or("供应商不存在")?;
            if &p.cli != cli {
                return Err("供应商协议仅适用于所选 CLI，不能跨协议切换".into());
            }
            let before = read(&config)?;
            let after;
            if cli == "codex" {
                let mut d = document(&before)?;
                d["model"] = value(&p.model);
                let id = format!("vela-{}", p.id);
                d["model_provider"] = value(&id);
                let mut t = Table::new();
                t["name"] = value(&p.name);
                t["base_url"] = value(&p.base_url);
                t["env_key"] = value(&p.key_env);
                t["wire_api"] = value("responses");
                table(&mut d, "model_providers")?.insert(&id, Item::Table(t));
                after = d.to_string().into_bytes();
            } else {
                let secret = resolve(&p.key_env)?;
                if secret.is_empty() || secret.len() > 8192 || secret.contains(['\n', '\r', '\0']) {
                    return Err("密钥环境变量为空或格式无效".into());
                }
                let mut v = object(&before)?;
                if cli == "claude" {
                    put(&mut v, &["env", "ANTHROPIC_BASE_URL"], json!(p.base_url))?;
                    put(&mut v, &["env", "ANTHROPIC_API_KEY"], json!(secret))?;
                    put(&mut v, &["env", "ANTHROPIC_MODEL"], json!(p.model))?;
                    // A pre-existing auth token takes precedence over API key in some gateways.
                    if let Some(env) = v["env"].as_object_mut() {
                        env.remove("ANTHROPIC_AUTH_TOKEN");
                    }
                } else {
                    put(&mut v, &["model", "name"], json!(p.model))?;
                    put(
                        &mut v,
                        &["security", "auth", "selectedType"],
                        json!("gemini-api-key"),
                    )?;
                    let path = home.join(".gemini/.env");
                    let old = read(&path)?;
                    let text = String::from_utf8(old.clone().unwrap_or_default())
                        .map_err(|e| e.to_string())?;
                    let mut lines: Vec<_> = text
                        .lines()
                        .filter(|l| {
                            !matches!(
                                l.trim_start()
                                    .strip_prefix("export ")
                                    .unwrap_or(l.trim_start())
                                    .split('=')
                                    .next()
                                    .unwrap_or("")
                                    .trim(),
                                "GEMINI_API_KEY" | "GOOGLE_GEMINI_BASE_URL"
                            )
                        })
                        .map(str::to_owned)
                        .collect();
                    // dotenv double quotes retain $, unlike shell expansion. Escape backslashes and quotes.
                    let quote =
                        |s: &str| format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""));
                    lines.push(format!("GEMINI_API_KEY={}", quote(&secret)));
                    lines.push(format!("GOOGLE_GEMINI_BASE_URL={}", quote(&p.base_url)));
                    out.push(Change {
                        path,
                        before: old,
                        after: (lines.join("\n") + "\n").into_bytes(),
                        summary: format!(
                            "设置 Gemini API 地址；从 {} 写入密钥（预览隐藏）",
                            p.key_env
                        ),
                    });
                }
                after = json_bytes(&v)?;
            }
            out.push(Change{path:config,before,after,summary:format!("切换至 {} · {} · {}；认证变量 {}。Claude/Gemini 将密钥写入其本地配置；Codex 仅引用变量。",p.name,p.base_url,p.model,p.key_env)});
        } else if request.kind == "mcp" {
            let m = lib
                .mcp
                .iter()
                .find(|m| m.id == request.id)
                .ok_or("MCP 不存在")?;
            let path = if cli == "claude" {
                home.join(".claude.json")
            } else {
                config
            };
            let before = read(&path)?;
            let after;
            if cli == "codex" {
                let mut d = document(&before)?;
                let mut t = Table::new();
                if m.transport == "stdio" {
                    t["command"] = value(&m.command);
                    let a: toml_edit::Array = m.args.iter().map(|s| s.as_str()).collect();
                    t["args"] = value(a);
                    let e: toml_edit::Array = m.env_vars.iter().map(|s| s.as_str()).collect();
                    t["env_vars"] = value(e);
                } else {
                    t["url"] = value(&m.url);
                }
                table(&mut d, "mcp_servers")?.insert(&m.id, Item::Table(t));
                after = d.to_string().into_bytes();
            } else {
                let mut v = object(&before)?;
                let entry = if m.transport == "stdio" {
                    let env: BTreeMap<_, _> = m
                        .env_vars
                        .iter()
                        .map(|k| (k, format!("${{{k}}}")))
                        .collect();
                    json!({"command":m.command,"args":m.args,"env":env})
                } else if cli == "claude" {
                    json!({"type":"http","url":m.url})
                } else {
                    json!({"httpUrl":m.url})
                };
                put(&mut v, &["mcpServers", &m.id], entry)?;
                after = json_bytes(&v)?;
            }
            out.push(Change {
                path,
                before,
                after,
                summary: format!(
                    "新增或替换 MCP {}（{}）；其他服务器保留；不会启动服务器",
                    m.id, m.transport
                ),
            });
        } else if request.kind == "skill" {
            let s = lib
                .skills
                .iter()
                .find(|s| s.id == request.id)
                .ok_or("Skill 不存在")?;
            let root = home.join(match cli.as_str() {
                "claude" => ".claude/skills",
                "codex" => ".agents/skills",
                _ => ".gemini/skills",
            });
            let path = root.join(&s.id).join("SKILL.md");
            let before = read(&path)?;
            // JSON string quoting is valid YAML and prevents frontmatter injection.
            let desc = serde_json::to_string(&s.description).map_err(|e| e.to_string())?;
            let after = format!(
                "---\nname: {}\ndescription: {desc}\n---\n\n{}\n",
                s.id, s.instructions
            )
            .into_bytes();
            out.push(Change {
                path,
                before,
                after,
                summary: format!(
                    "写入可移植指令型 Skill {}；不执行正文；现有附属文件保留",
                    s.id
                ),
            });
        } else {
            return Err("未知同步类型".into());
        }
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out.retain(|c| c.before.as_deref() != Some(c.after.as_slice()));
    Ok(out)
}
fn hash(b: &[u8]) -> String {
    format!("{:x}", Sha256::digest(b))
}
#[tauri::command]
pub fn preview_sync(request: Request) -> Result<Value, String> {
    let _lock = LOCK.lock().map_err(|_| "同步锁不可用")?;
    let changes = build(
        &dirs::home_dir().ok_or("用户目录不可用")?,
        &get_library()?,
        &request,
        |key| {
            std::env::var(key).map_err(|_| {
                format!("Vela 进程未继承环境变量 {key}，请设置变量后从同一终端启动 Vela")
            })
        },
    )?;
    let token = hash(
        format!(
            "{:?}-{:?}",
            Instant::now(),
            changes.iter().map(|c| hash(&c.after)).collect::<Vec<_>>()
        )
        .as_bytes(),
    );
    let items:Vec<_>=changes.iter().map(|c|json!({"path":c.path.to_string_lossy(),"exists":c.before.is_some(),"summary":c.summary,"before_hash":c.before.as_ref().map(|b|hash(b)),"after_hash":hash(&c.after)})).collect();
    *PENDING.lock().map_err(|_| "预览锁不可用")? = Some(Plan {
        token: token.clone(),
        created: Instant::now(),
        changes,
    });
    Ok(json!({"token":token,"changes":items}))
}
fn apply(changes: &[Change]) -> Result<Vec<String>, String> {
    for c in changes {
        if read(&c.path)? != c.before {
            return Err(format!("{} 在预览后已变更，请重新预览", c.path.display()));
        }
    }
    let mut backups = vec![];
    // Persist every backup before the first mutation. Backups are private even for permissive originals.
    for c in changes {
        if let Some(bytes) = &c.before {
            use std::io::Write;
            let parent = c.path.parent().ok_or("目录无效")?;
            let mut f = tempfile::Builder::new()
                .prefix(&format!(
                    "{}.vela-backup-",
                    c.path.file_name().unwrap().to_string_lossy()
                ))
                .tempfile_in(parent)
                .map_err(|e| e.to_string())?;
            f.write_all(bytes)
                .and_then(|_| f.as_file().sync_all())
                .map_err(|e| e.to_string())?;
            let (_, path) = f.keep().map_err(|e| e.to_string())?;
            backups.push(path.to_string_lossy().to_string());
        }
    }
    for (i, c) in changes.iter().enumerate() {
        let result = read(&c.path).and_then(|now| {
            if now != c.before {
                Err("配置发生并发修改".into())
            } else {
                crate::workbench::atomic(&c.path, &c.after)
            }
        });
        if let Err(e) = result {
            let mut issues = vec![];
            for done in changes[..i].iter().rev() {
                if read(&done.path).ok().flatten().as_deref() != Some(done.after.as_slice()) {
                    issues.push(format!("{} 又被修改，保留现场", done.path.display()));
                    continue;
                }
                let rollback = if let Some(b) = &done.before {
                    crate::workbench::atomic(&done.path, b)
                } else {
                    fs::remove_file(&done.path).map_err(|e| e.to_string())
                };
                if let Err(e) = rollback {
                    issues.push(e);
                }
            }
            return Err(format!(
                "应用失败: {e}；已尝试回滚。{}；备份: {}",
                issues.join("；"),
                backups.join("，")
            ));
        }
    }
    Ok(backups)
}
#[tauri::command]
pub fn apply_sync(token: String) -> Result<Value, String> {
    let _lock = LOCK.lock().map_err(|_| "同步锁不可用")?;
    let mut pending = PENDING.lock().map_err(|_| "预览锁不可用")?;
    let p = pending.as_ref().ok_or("请先预览")?;
    if p.token != token || p.created.elapsed() > Duration::from_secs(300) {
        return Err("预览已失效，请重新预览".into());
    }
    let p = pending.take().unwrap();
    let backups = apply(&p.changes)?;
    Ok(json!({"files":p.changes.len(),"backups":backups}))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn library() -> Library {
        Library {
            mcp: vec![Mcp {
                id: "demo".into(),
                transport: "stdio".into(),
                command: "node".into(),
                args: vec!["server.js".into()],
                url: String::new(),
                env_vars: vec!["DEMO_TOKEN".into()],
            }],
            skills: vec![Skill {
                id: "review".into(),
                description: "Review code".into(),
                instructions: "Read the diff.".into(),
            }],
            ..Default::default()
        }
    }
    #[test]
    fn sync_preserves_unrelated_data_and_makes_exact_backups() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir(t.path().join(".codex")).unwrap();
        let path = t.path().join(".codex/config.toml");
        let old = b"# keep me\nmodel = 'existing'\n[mcp_servers.other]\ncommand = 'other'\n";
        fs::write(&path, old).unwrap();
        let c = build(
            t.path(),
            &library(),
            &Request {
                kind: "mcp".into(),
                id: "demo".into(),
                targets: vec!["codex".into(), "claude".into(), "gemini".into()],
            },
            |_| panic!(),
        )
        .unwrap();
        let backups = apply(&c).unwrap();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(&backups[0]).unwrap(), old);
        let new = fs::read_to_string(path).unwrap();
        assert!(new.contains("# keep me"));
        assert!(new.contains("mcp_servers.other"));
        assert!(new.contains("env_vars"));
    }
    #[test]
    fn stale_preview_does_not_write_any_file() {
        let t = tempfile::tempdir().unwrap();
        let c = build(
            t.path(),
            &library(),
            &Request {
                kind: "mcp".into(),
                id: "demo".into(),
                targets: vec!["claude".into()],
            },
            |_| panic!(),
        )
        .unwrap();
        fs::write(t.path().join(".claude.json"), "{}").unwrap();
        assert!(apply(&c).is_err());
        assert_eq!(
            fs::read_to_string(t.path().join(".claude.json")).unwrap(),
            "{}"
        );
    }
    #[test]
    fn corrupt_config_is_not_overwritten() {
        let t = tempfile::tempdir().unwrap();
        fs::write(t.path().join(".claude.json"), "bad").unwrap();
        assert!(build(
            t.path(),
            &library(),
            &Request {
                kind: "mcp".into(),
                id: "demo".into(),
                targets: vec!["claude".into()]
            },
            |_| panic!()
        )
        .is_err());
    }
    #[test]
    fn skill_frontmatter_is_portable_and_path_safe() {
        let t = tempfile::tempdir().unwrap();
        let c = build(
            t.path(),
            &library(),
            &Request {
                kind: "skill".into(),
                id: "review".into(),
                targets: vec!["codex".into(), "claude".into(), "gemini".into()],
            },
            |_| panic!(),
        )
        .unwrap();
        assert_eq!(c.len(), 3);
        assert!(String::from_utf8_lossy(&c[0].after).contains("name: review"));
        assert!(!id_ok("../escape"));
    }
    #[test]
    fn codex_provider_uses_environment_reference() {
        let t = tempfile::tempdir().unwrap();
        let mut l = library();
        l.providers.push(Provider {
            id: "proxy".into(),
            cli: "codex".into(),
            name: "Proxy".into(),
            base_url: "https://example.com/v1".into(),
            model: "example".into(),
            key_env: "PROXY_KEY".into(),
        });
        let c = build(
            t.path(),
            &l,
            &Request {
                kind: "provider".into(),
                id: "proxy".into(),
                targets: vec!["codex".into()],
            },
            |_| panic!(),
        )
        .unwrap();
        let text = String::from_utf8_lossy(&c[0].after);
        assert!(text.contains("env_key = \"PROXY_KEY\""));
        assert!(text.contains("wire_api = \"responses\""));
    }
}
