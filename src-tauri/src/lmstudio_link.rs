//! LM Studio's loopback SDK WebSocket RPC. One bounded connection, serial calls and no inference
//! traffic. The protocol follows the fixed Swift LMStudioLink; user token bytes never enter logs.
use futures_util::{SinkExt, StreamExt};
use rand::{distributions::Alphanumeric, Rng};
use serde_json::{json, Value};
use std::time::Duration;
use tokio_tungstenite::{connect_async_with_config, tungstenite::{protocol::{Message, WebSocketConfig}, Error as WsError}, MaybeTlsStream, WebSocketStream};
use tokio::net::TcpStream;

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
const DEADLINE: Duration = Duration::from_secs(3);

#[derive(Clone, Debug, PartialEq)]
pub struct Instance { pub identifier: String, pub reference: String }
#[derive(Clone, Debug, PartialEq)]
pub struct Processing { pub phase: Option<&'static str>, pub queued: u32, pub generating: bool }

pub fn parse_instances(result: &Value) -> Vec<Instance> {
    result.as_array().into_iter().flatten().filter_map(|item| {
        (item["type"] == "llm").then(|| {
            let identifier = item["identifier"].as_str()?.trim();
            let reference = item["instanceReference"].as_str()?.trim();
            (!identifier.is_empty() && !reference.is_empty()).then(|| Instance {
                identifier: identifier.into(), reference: reference.into(),
            })
        }).flatten()
    }).collect()
}
pub fn parse_processing(result: &Value) -> Option<Processing> {
    let status = result["status"].as_str()?;
    let phase = match status { "processingPrompt" => Some("processingPrompt"),
        "generating" => Some("generating"), _ => None };
    let queued = result["queued"].as_u64().unwrap_or(0).min(u32::MAX as u64) as u32;
    Some(Processing { phase, queued, generating: status == "generating" })
}

fn auth_frame(token: Option<&str>) -> Value {
    let random = || rand::thread_rng().sample_iter(&Alphanumeric).take(20).map(char::from).collect::<String>();
    let (identifier, passkey) = match token {
        Some(value) => {
            let trimmed = value.trim();
            let parts = trimmed.strip_prefix("sk-lm-").and_then(|body| body.split_once(':'));
            if let Some((id, pass)) = parts.filter(|(id, pass)| id.len() == 8 && pass.len() == 20
                && id.bytes().chain(pass.bytes()).all(|byte| byte.is_ascii_alphanumeric())) {
                (id.into(), pass.into())
            } else { ("velo".into(), trimmed.into()) }
        }
        None => { let id = random(); (format!("velo-{}", &id[..8]), random()) },
    };
    json!({"authVersion":1,"clientIdentifier":identifier,"clientPasskey":passkey})
}

pub struct Link { endpoint: String, socket: Option<Socket>, next_call: u64 }
impl Link {
    pub fn new(endpoint: &str) -> Result<Self, String> {
        let parsed = crate::local_runtime::endpoint(endpoint)?;
        let port = parsed.port_or_known_default().ok_or("LM Studio 端口缺失")?;
        let host = parsed.host_str().ok_or("LM Studio 主机缺失")?;
        Ok(Self { endpoint: format!("ws://{host}:{port}/llm"), socket: None, next_call: 0 })
    }

    async fn connect(&mut self) -> Result<(), String> {
        if self.socket.is_some() { return Ok(()); }
        let config = WebSocketConfig::default().max_message_size(Some(2 * 1024 * 1024))
            .max_frame_size(Some(2 * 1024 * 1024));
        let (mut socket, _) = tokio::time::timeout(DEADLINE,
            connect_async_with_config(self.endpoint.as_str(), Some(config), false))
            .await.map_err(|_| "LM Studio 连接超时")?.map_err(|_| "LM Studio WebSocket 不可用")?;
        let token = tokio::task::spawn_blocking(crate::secrets::lmstudio_token).await.ok().flatten();
        socket.send(Message::text(auth_frame(token.as_deref()).to_string())).await
            .map_err(|_| "LM Studio 认证帧发送失败")?;
        let reply = receive(&mut socket).await?;
        if reply["success"] != true { return Err("LM Studio API token 无效或服务器拒绝连接".into()); }
        self.socket = Some(socket);
        Ok(())
    }

    pub async fn call(&mut self, endpoint: &str, parameter: Option<Value>) -> Result<Value, String> {
        self.connect().await?;
        self.next_call = self.next_call.saturating_add(1);
        let id = self.next_call;
        let mut frame = json!({"type":"rpcCall","endpoint":endpoint,"callId":id});
        if let Some(parameter) = parameter { frame["parameter"] = parameter; }
        let socket = self.socket.as_mut().unwrap();
        let result = async {
            socket.send(Message::text(frame.to_string())).await.map_err(|_| "LM Studio RPC 发送失败")?;
            loop {
                let reply = receive(socket).await?;
                if reply["type"] == "communicationWarning" { return Err("LM Studio RPC 帧无效"); }
                if reply["callId"].as_u64() != Some(id) { continue; }
                if reply["type"] == "rpcResult" { return Ok(reply["result"].clone()); }
                if reply["type"] == "rpcError" { return Err("LM Studio RPC 请求失败"); }
            }
        }.await;
        if result.is_err() { self.socket = None; }
        result.map_err(str::to_owned)
    }

    pub fn close(&mut self) { self.socket = None; }
}

async fn receive(socket: &mut Socket) -> Result<Value, &'static str> {
    loop {
        let message = tokio::time::timeout(DEADLINE, socket.next()).await
            .map_err(|_| "LM Studio 响应超时")?.ok_or("LM Studio 已断开")?
            .map_err(|_: WsError| "LM Studio WebSocket 错误")?;
        match message {
            Message::Text(text) => return serde_json::from_str(text.as_str()).map_err(|_| "LM Studio 响应格式无效"),
            Message::Close(_) => return Err("LM Studio 已断开"),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frames_and_state_match_sdk_contract_without_token_logging() {
        assert_eq!(auth_frame(Some("sk-lm-ABCDEFGH:12345678901234567890"))["clientIdentifier"], "ABCDEFGH");
        assert_eq!(auth_frame(Some("sk-lm-ABCDEFGH:12345678901234567890"))["clientPasskey"], "12345678901234567890");
        let instances = parse_instances(&json!([{"type":"embedding","identifier":"skip","instanceReference":"x"},
            {"type":"llm","identifier":"qwen","instanceReference":"ref"}]));
        assert_eq!(instances, vec![Instance { identifier:"qwen".into(), reference:"ref".into() }]);
        assert_eq!(parse_processing(&json!({"status":"generating","queued":2})).unwrap(),
            Processing { phase:Some("generating"), queued:2, generating:true });
        assert!(Link::new("https://example.com").is_err());
        assert_eq!(Link::new("http://[::1]:1234").unwrap().endpoint, "ws://[::1]:1234/llm");
    }
}
