//! The pinned Swift Sites.swift browser-side requests. Credentials stay inside these
//! page scripts; Rust receives only a status and bounded numeric usage JSON.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fidelity {
    Official,
    Derived,
}

#[derive(Clone, Debug)]
pub struct Site {
    pub id: &'static str,
    pub name: &'static str,
    pub origin: &'static str,
    pub manage_path: &'static str,
    pub associated_hosts: &'static [&'static str],
    pub polls_during_sign_in: bool,
    pub headline: &'static str,
    pub weekly: Option<&'static str>,
    pub fidelity: Fidelity,
    pub read_script: String,
    pub auth_script: String,
}

const DEEPSEEK_READ: &str = r###"
const readToken = () => {
  const extract = (value) => {
    if (typeof value === 'string' && value.trim()) return value.trim();
    if (!value || typeof value !== 'object') return null;
    for (const key of ['value', 'token', 'access_token', 'accessToken']) {
      const candidate = extract(value[key]); if (candidate) return candidate;
    }
    return null;
  };
  try { const raw = localStorage.getItem('userToken');
    if (!raw) return null; return extract(JSON.parse(raw)) || raw.trim() || null;
  } catch (_) { const raw = localStorage.getItem('userToken');
    return raw && raw.trim() ? raw.trim() : null; }
};
const token = readToken();
const headers = { 'Accept': 'application/json', 'x-client-platform': 'web' };
if (token) headers.Authorization = token.startsWith('Bearer ') ? token : 'Bearer ' + token;
const now = new Date();
const today = new Date(now); today.setHours(0, 0, 0, 0);
const start = new Date(today); start.setDate(start.getDate() - 29);
const end = new Date(today); end.setDate(end.getDate() + 1);
const startSeconds = Math.floor(start.getTime() / 1000);
const endSeconds = Math.floor(end.getTime() / 1000);
const timeZoneSeconds = -now.getTimezoneOffset() * 60;
const query = 'start=' + startSeconds + '&end=' + endSeconds + '&tz=' + timeZoneSeconds;
const get = async (path) => { const response = await fetch(path, { credentials: 'include', headers });
  return { status: response.status, body: await response.text() }; };
const [summary, amount, cost] = await Promise.all([
  get('/api/v0/users/get_user_summary'),
  get('/api/v0/usage/by_api_key/amount?' + query),
  get('/api/v0/usage/by_api_key/cost?' + query)
]);
const failed = [summary, amount, cost].find(item => item.status < 200 || item.status >= 300);
return JSON.stringify({status: failed ? failed.status : 200,
  body: JSON.stringify({summary:summary.body,amount:amount.body,cost:cost.body,
    start:startSeconds,end:endSeconds,time_zone_seconds:timeZoneSeconds})});
"###;

const DEEPSEEK_AUTH: &str = r###"
const extract = (value) => {
  if (typeof value === 'string' && value.trim()) return value.trim();
  if (!value || typeof value !== 'object') return null;
  for (const key of ['value', 'token', 'access_token', 'accessToken']) {
    const candidate = extract(value[key]); if (candidate) return candidate;
  }
  return null;
};
try {
  const raw = localStorage.getItem('userToken'); if (!raw) return JSON.stringify({authenticated:false});
  const token = extract(JSON.parse(raw)) || raw.trim();
  if (!token) return JSON.stringify({authenticated:false});
  const response = await fetch('/api/v0/users/get_user_summary', {credentials:'include',headers:{
    'Accept':'application/json','x-client-platform':'web',
    'Authorization':token.startsWith('Bearer ') ? token : 'Bearer ' + token
  }});
  if (response.status < 200 || response.status >= 300) return JSON.stringify({authenticated:false});
  const bytes = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const fingerprint = Array.from(new Uint8Array(digest))
    .map(byte => byte.toString(16).padStart(2,'0')).join('');
  return JSON.stringify({authenticated:true,fingerprint});
} catch (_) { return JSON.stringify({authenticated:false}); }
"###;

const QIANWEN_READ: &str = r###"
const infoResponse = await fetch('https://platform-home.qianwenai.com/tool/user/info.json', {
  credentials:'include',headers:{'Accept':'application/json'}
});
let secToken = null;
try { const info = JSON.parse(await infoResponse.text());
  const payload = info && info.payload ? info.payload : info;
  if (payload && String(payload.code)==='200' && payload.data && payload.data.secToken)
    secToken = payload.data.secToken;
} catch (_) {}
if (!secToken) return JSON.stringify({status:401,body:'{"code":"ConsoleNeedLogin"}'});
const cornerstoneParam = {
  domain:window.location.hostname,consoleSite:'QIANWENAI',console:'ONE_CONSOLE',
  xsp_lang:(window.ALIYUN_CONSOLE_CONFIG || {}).LOCALE || 'zh-CN',
  protocol:'V2',productCode:'p_efm'
};
const params = JSON.stringify({Api:'zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage',
  Data:{cornerstoneParam:cornerstoneParam},V:'1.0'});
const form = new URLSearchParams();
form.set('product','sfm_bailian');form.set('action','BroadScopeAspnGateway');
form.set('sec_token',secToken);form.set('region','cn-beijing');form.set('params',params);
const response = await fetch('https://cs-data.qianwenai.com/data/api.json', {
  method:'POST',credentials:'include',headers:{'Content-Type':'application/x-www-form-urlencoded'},
  body:form.toString()
});
const body = await response.text(); let status = response.status;
try { const envelope=JSON.parse(body),data=(envelope&&envelope.data)||{};
  const named=[envelope.code,data.errorCode,data.code];
  const signedOut=['ConsoleNeedLogin','BailianGateway.Login.NotLogined','NO_LOGIN'];
  if (named.some(value=>signedOut.some(marker=>String(value||'').trim().toLowerCase()===marker.toLowerCase())))
    status=401;
} catch (_) {}
return JSON.stringify({status:status,body:body});
"###;

const QIANWEN_AUTH: &str = r###"
try {
  const response=await fetch('https://platform-home.qianwenai.com/tool/user/info.json', {
    credentials:'include',headers:{'Accept':'application/json'}
  });
  if (response.status < 200 || response.status >= 300) return JSON.stringify({authenticated:false});
  const info=JSON.parse(await response.text());
  const payload=info&&info.payload?info.payload:info;
  if (!payload || String(payload.code)!=='200' || !payload.data || !payload.data.secToken)
    return JSON.stringify({authenticated:false});
  const bytes=new TextEncoder().encode(payload.data.secToken);
  const digest=await crypto.subtle.digest('SHA-256',bytes);
  const fingerprint=Array.from(new Uint8Array(digest)).map(byte=>byte.toString(16).padStart(2,'0')).join('');
  return JSON.stringify({authenticated:true,fingerprint});
} catch (_) { return JSON.stringify({authenticated:false}); }
"###;

fn minimax_read(remains: &str) -> String {
    format!(
        r###"
const response=await fetch('{remains}',{{credentials:'include',headers:{{'Accept':'application/json'}}}});
let status=response.status; const body=await response.text();
try {{ const parsed=JSON.parse(body);
  const resp=(parsed&&parsed.base_resp)||(parsed&&parsed.data&&parsed.data.base_resp);
  const code=resp&&resp.status_code;
  if (status===1004 || Number(code)===1004) status=401;
}} catch (_) {{}}
return JSON.stringify({{status:status,body:body}});
"###
    )
}

fn minimax_auth(remains: &str) -> String {
    format!(
        r###"
try {{
  const response=await fetch('{remains}',{{credentials:'include',headers:{{'Accept':'application/json'}}}});
  let status=response.status;const body=await response.text();
  try {{ const parsed=JSON.parse(body);
    const resp=(parsed&&parsed.base_resp)||(parsed&&parsed.data&&parsed.data.base_resp);
    const code=resp&&resp.status_code;
    if (status===1004 || Number(code)===1004) status=401;
  }} catch (_) {{}}
  if (status<200 || status>=300) return JSON.stringify({{authenticated:false}});
  let fingerprint=null;
  try {{const session=localStorage.getItem('access_token');if(session){{
    const bytes=new TextEncoder().encode(session);
    const digest=await crypto.subtle.digest('SHA-256',bytes);
    fingerprint=Array.from(new Uint8Array(digest)).map(byte=>byte.toString(16).padStart(2,'0')).join('');
  }}}} catch (_) {{}}
  return JSON.stringify({{authenticated:true,fingerprint}});
}} catch (_) {{return JSON.stringify({{authenticated:false}});}}
"###
    )
}

pub fn site(id: &str, minimax_china: bool) -> Option<Site> {
    match id {
        "deepseek" => Some(Site {
            id: "deepseek",
            name: "DeepSeek",
            origin: "https://platform.deepseek.com/",
            manage_path: "usage",
            associated_hosts: &[],
            polls_during_sign_in: false,
            headline: "spend",
            weekly: None,
            fidelity: Fidelity::Derived,
            read_script: DEEPSEEK_READ.into(),
            auth_script: DEEPSEEK_AUTH.into(),
        }),
        "qianwenai" => Some(Site {
            id: "qianwenai",
            name: "QianwenAI",
            origin: "https://platform.qianwenai.com/",
            manage_path: "home/analytics/token-plan/individual",
            associated_hosts: &[
                "platform-home.qianwenai.com",
                "cs-data.qianwenai.com",
                "account.qianwenai.com",
                "account.aliyun.com",
            ],
            polls_during_sign_in: true,
            headline: "week",
            weekly: Some("week"),
            fidelity: Fidelity::Derived,
            read_script: QIANWEN_READ.into(),
            auth_script: QIANWEN_AUTH.into(),
        }),
        "minimax" => {
            let (origin, remains) = if minimax_china {
                (
                    "https://platform.minimaxi.com/",
                    "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
                )
            } else {
                (
                    "https://platform.minimax.io/",
                    "https://www.minimax.io/v1/api/openplatform/coding_plan/remains",
                )
            };
            Some(Site {
                id: "minimax",
                name: "MiniMax",
                origin,
                manage_path: "user-center/payment/coding-plan",
                associated_hosts: if minimax_china {
                    &["www.minimaxi.com"]
                } else {
                    &["www.minimax.io"]
                },
                polls_during_sign_in: false,
                headline: "session",
                weekly: Some("weekly"),
                fidelity: Fidelity::Derived,
                read_script: minimax_read(remains),
                auth_script: minimax_auth(remains),
            })
        }
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QianwenError {
    NeedsAuth,
    Api(String),
    Invalid,
    NothingMetered,
}

fn qianwen_number(value: &serde_json::Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.trim().parse().ok())
        .filter(|n| n.is_finite())
}

fn qianwen_text(value: &serde_json::Value) -> Option<String> {
    if let Some(s) = value.as_str().map(str::trim).filter(|s| !s.is_empty()) {
        return Some(s.into());
    }
    if let Some(n) = value.as_i64() {
        return Some(n.to_string());
    }
    None
}

fn qianwen_auth_code(name: &str) -> bool {
    [
        "ConsoleNeedLogin",
        "BailianGateway.Login.NotLogined",
        "NO_LOGIN",
    ]
    .iter()
    .any(|code| code.eq_ignore_ascii_case(name.trim()))
}

fn qianwen_reset(value: &serde_json::Value, now_ms: u64) -> Option<u64> {
    let millis = if let Some(n) = qianwen_number(value).filter(|n| *n > 1_000_000_000.0) {
        if n > 1_000_000_000_000.0 {
            n as u64
        } else {
            (n * 1000.0) as u64
        }
    } else if let Some(s) = value.as_str() {
        chrono::DateTime::parse_from_rfc3339(s)
            .ok()
            .and_then(|date| u64::try_from(date.timestamp_millis()).ok())?
    } else {
        return None;
    };
    (millis > now_ms).then_some(millis)
}

/// QianwenUsage.swift's two-level DataV2 unwrap and seven-day Token Plan.
pub fn parse_qianwen(body: &str, now_ms: u64) -> Result<crate::usage::LimitWindow, QianwenError> {
    use serde_json::Value;
    let root: Value = serde_json::from_str(body).map_err(|_| QianwenError::Invalid)?;
    let data = &root["data"];
    if root["successResponse"] == false || data["success"] == false {
        let failure = [&data["errorCode"], &data["code"]]
            .into_iter()
            .find_map(|value| qianwen_text(value))
            .or_else(|| {
                (qianwen_number(&root["code"]) != Some(200.0))
                    .then(|| qianwen_text(&root["code"]))
                    .flatten()
            });
        let message = qianwen_text(&data["errorMsg"]);
        if failure.as_deref().is_some_and(qianwen_auth_code)
            || message.as_deref().is_some_and(qianwen_auth_code)
        {
            return Err(QianwenError::NeedsAuth);
        }
        if let Some(name) = failure {
            return Err(QianwenError::Api(name));
        }
        if message.is_some() {
            return Err(QianwenError::Api("QianwenAI refused the request.".into()));
        }
        return Err(QianwenError::Invalid);
    }
    if qianwen_number(&root["code"]) != Some(200.0) {
        return Err(QianwenError::Invalid);
    }
    let data_v2 = &data["DataV2"]["data"];
    if !data_v2.is_object() {
        return Err(QianwenError::Invalid);
    }
    let payload = if data_v2["data"].is_object() {
        &data_v2["data"]
    } else {
        data_v2
    };
    let mut used = qianwen_number(&payload["per1WeekPercentage"]).map(|n| n.clamp(0.0, 1.0));
    let mut remaining = None;
    let mut used_count = None;
    let total =
        qianwen_number(&payload["totalCredits"]).or_else(|| qianwen_number(&payload["totalQuota"]));
    let left = qianwen_number(&payload["remainingCredits"])
        .or_else(|| qianwen_number(&payload["availableQuota"]));
    if let (Some(total), Some(left)) = (total, left) {
        if total > 0.0 && left >= 0.0 {
            let spent = (total - left).max(0.0);
            remaining = Some(left as i64);
            used_count = Some(spent as i64);
            if used.is_none() {
                used = Some((spent / total).clamp(0.0, 1.0));
            }
        }
    }
    let used = used.ok_or(QianwenError::NothingMetered)?;
    Ok(crate::usage::LimitWindow {
        id: "week".into(),
        label: "Weekly limit".into(),
        used,
        has_fraction: Some(true),
        remaining,
        used_count,
        resets_at: qianwen_reset(&payload["per1WeekResetTime"], now_ms),
        duration: Some(7.0 * 86_400.0),
        derived: true,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn site_routes_match_swift_baseline() {
        let deepseek = site("deepseek", false).unwrap();
        assert_eq!(deepseek.origin, "https://platform.deepseek.com/");
        assert!(!deepseek.polls_during_sign_in);
        let qianwen = site("qianwenai", false).unwrap();
        assert!(qianwen.polls_during_sign_in);
        assert_eq!(qianwen.manage_path, "home/analytics/token-plan/individual");
        assert!(qianwen.associated_hosts.contains(&"account.aliyun.com"));
        for (china, host) in [(false, "www.minimax.io"), (true, "www.minimaxi.com")] {
            let site = site("minimax", china).unwrap();
            assert!(site.read_script.contains(host));
            assert_eq!(site.associated_hosts, [host]);
            assert!(!site.polls_during_sign_in);
        }
    }

    #[test]
    fn qianwen_unwraps_percentage_counts_and_named_failures() {
        let envelope=serde_json::json!({"code":"200","successResponse":true,"data":{"success":true,
            "DataV2":{"data":{"msg":"Success.","data":{"per1WeekPercentage":0.42,"per1WeekResetTime":1700179200000u64}}}}}).to_string();
        let window = parse_qianwen(&envelope, 1_700_000_000_000).unwrap();
        assert_eq!(window.id, "week");
        assert_eq!(window.used, 0.42);
        assert_eq!(window.resets_at, Some(1_700_179_200_000));
        let count = serde_json::json!({"code":"200","data":{"DataV2":{"data":{"data":{
            "totalCredits":"10000.00","remainingCredits":"4000.00"}}}}})
        .to_string();
        let window = parse_qianwen(&count, 0).unwrap();
        assert_eq!(
            (window.used, window.used_count, window.remaining),
            (0.6, Some(6000), Some(4000))
        );
        let denied = serde_json::json!({"code":"200","successResponse":true,
            "data":{"success":false,"errorCode":"BailianGateway.Login.NotLogined"}})
        .to_string();
        assert!(matches!(
            parse_qianwen(&denied, 0),
            Err(QianwenError::NeedsAuth)
        ));
        let refused = serde_json::json!({"code":"200","successResponse":true,
            "data":{"success":false,"errorCode":"Bad Request"}})
        .to_string();
        assert!(
            matches!(parse_qianwen(&refused, 0), Err(QianwenError::Api(message)) if message == "Bad Request")
        );
    }
}
