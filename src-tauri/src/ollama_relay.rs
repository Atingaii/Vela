//! An explicitly enabled Ollama loopback relay. Hyper handles HTTP framing and
//! backpressure; each connection is an owned task that is aborted when the
//! preference or upstream changes. Only bounded stream metadata is observed.
use crate::ollama_stream::{Observer, Performance, Transition};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, combinators::UnsyncBoxBody};
use hyper::{body::{Body, Frame, Incoming}, header, service::service_fn, Request, Response, StatusCode};
use hyper_util::{client::legacy::{connect::HttpConnector, Client}, rt::{TokioExecutor, TokioIo}};
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    convert::Infallible,
    error::Error,
    pin::Pin,
    sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Mutex, OnceLock},
    task::{Context, Poll},
    time::Duration,
};
use tokio::{net::TcpListener, task::JoinSet, time::timeout};

type BoxError = Box<dyn Error + Send + Sync>;
type ReplyBody = UnsyncBoxBody<Bytes, BoxError>;
const ADDRESS: &str = "127.0.0.1:11435";
const PORT: u16 = 11435;
const MAX_BODY: usize = 32 * 1024 * 1024;
#[cfg(not(test))]
const BODY_DEADLINE: Duration = Duration::from_secs(30);
#[cfg(test)]
const BODY_DEADLINE: Duration = Duration::from_millis(250);
static REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static GENERATION: AtomicU64 = AtomicU64::new(1);
static ALLOWED: AtomicBool = AtomicBool::new(false);
static DESIRED: AtomicBool = AtomicBool::new(false);
static CONTROLLER: OnceLock<Mutex<Controller>> = OnceLock::new();
static STATE: OnceLock<Mutex<Activity>> = OnceLock::new();

#[derive(Default)]
struct Controller {
    endpoint: String,
    worker: Option<tauri::async_runtime::JoinHandle<()>>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RelayStatus {
    pub ready: bool,
    pub status: String,
    pub address: String,
    pub thinking_models: BTreeMap<String, u64>,
    pub performances: BTreeMap<String, Performance>,
}

struct Activity {
    public: RelayStatus,
    requests: BTreeMap<u64, (String, u64)>,
}
impl Default for Activity {
    fn default() -> Self {
        Self {
            public: RelayStatus {
                ready: false, status: "Off".into(), address: format!("http://{ADDRESS}"),
                thinking_models: BTreeMap::new(), performances: BTreeMap::new(),
            },
            requests: BTreeMap::new(),
        }
    }
}
fn controller() -> &'static Mutex<Controller> { CONTROLLER.get_or_init(|| Mutex::new(Controller::default())) }
fn state() -> &'static Mutex<Activity> { STATE.get_or_init(|| Mutex::new(Activity::default())) }
pub fn status() -> RelayStatus { state().lock().unwrap().public.clone() }
pub fn desired_enabled() -> bool { DESIRED.load(Ordering::Acquire) }

/// Disables new forwarding immediately, before an asynchronous reconfiguration
/// can run. Any task already serving a connection is aborted with its parent.
pub fn disallow() { ALLOWED.store(false, Ordering::Release); }

/// Called after a checked settings write or on launch. It never touches user
/// credentials or changes the persisted toggle on bind failure.
pub fn configure(enabled: bool, endpoint: &str) {
    let mut control = controller().lock().unwrap();
    DESIRED.store(enabled, Ordering::Release);
    if enabled && control.endpoint == endpoint && control.worker.as_ref().is_some_and(|h| !h.inner().is_finished()) {
        return;
    }
    disallow();
    let previous = control.worker.take();
    if let Some(worker) = previous.as_ref() { worker.abort(); }
    control.endpoint.clear();
    // Keep generation and the state reset under the same lock. An old stream
    // cannot pass a check just before this reset then write into the new map.
    let generation = {
        let mut activity = state().lock().unwrap();
        let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        *activity = Activity::default();
        activity.public.status = if enabled { "Starting…".into() } else { "Off".into() };
        generation
    };
    if !enabled {
        // Keep the aborted handle so a rapid off→on waits for the old listener
        // to release the fixed port before the new generation binds it.
        control.worker = previous;
        return;
    }
    let parsed = match crate::local_runtime::endpoint(endpoint) {
        Ok(url) if url.port_or_known_default() != Some(PORT) => url,
        _ => {
            state().lock().unwrap().public.status = "Invalid upstream address or relay loop".into();
            control.worker = previous;
            return;
        }
    };
    let upstream = parsed.to_string();
    control.endpoint = endpoint.into();
    control.worker = Some(tauri::async_runtime::spawn(async move {
        if let Some(previous) = previous { let _ = previous.await; }
        let listener = match TcpListener::bind(ADDRESS).await {
            Ok(listener) => listener,
            Err(_) => {
                let mut activity = state().lock().unwrap();
                if GENERATION.load(Ordering::Acquire) == generation {
                    activity.public.status = "Cannot start relay. Check that port 11435 is free.".into();
                }
                return;
            }
        };
        {
            let mut activity = state().lock().unwrap();
            if GENERATION.load(Ordering::Acquire) != generation { return; }
            ALLOWED.store(true, Ordering::Release);
            activity.public.ready = true;
            activity.public.status = format!("Ready · http://{ADDRESS}");
        }
        serve(listener, upstream, generation).await;
    }));
}

fn with_current(generation: u64, f: impl FnOnce(&mut Activity)) {
    let mut activity = state().lock().unwrap();
    if GENERATION.load(Ordering::Acquire) == generation && ALLOWED.load(Ordering::Acquire) {
        f(&mut activity);
    }
}

async fn serve(listener: TcpListener, upstream: String, generation: u64) {
    let mut children = JoinSet::new();
    loop {
        tokio::select! {
            result = listener.accept() => {
                let Ok((socket, peer)) = result else { break; };
                if !peer.ip().is_loopback() || children.len() >= 16 {
                    drop(socket);
                    continue;
                }
                let upstream = upstream.clone();
                children.spawn(async move {
                    let io = TokioIo::new(socket);
                    let service = service_fn(move |request| forward(request, upstream.clone(), generation));
                    // A non-reading downstream may hold a write pending forever.
                    // This bound also covers idle keep-alive connections.
                    let _ = timeout(Duration::from_secs(600),
                        hyper::server::conn::http1::Builder::new()
                            .keep_alive(false).serve_connection(io, service)).await;
                });
            }
            Some(_) = children.join_next(), if !children.is_empty() => {}
        }
    }
    // JoinSet's Drop aborts every accepted connection, including a blocked
    // request body, slow downstream writer, or upstream generation stream.
}

fn header_values<'a>(headers: &'a [(String, String)], key: &str) -> Vec<&'a str> {
    headers.iter().filter(|(name, _)| name.eq_ignore_ascii_case(key))
        .map(|(_, value)| value.as_str()).collect()
}

fn loopback_origin(origin: &str) -> bool {
    let origin = origin.trim();
    if origin.is_empty() || origin.eq_ignore_ascii_case("null") { return false; }
    let Ok(url) = tauri::Url::parse(origin) else { return false; };
    matches!(url.scheme(), "http" | "https")
        && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        && url.username().is_empty() && url.password().is_none()
        && url.path() == "/" && url.query().is_none() && url.fragment().is_none()
        && url.port() != Some(0)
}

fn validate(method: &str, path: &str, headers: &[(String, String)]) -> Result<(), StatusCode> {
    let hosts = header_values(headers, "host");
    if hosts.len() != 1 || !matches!(hosts[0].to_ascii_lowercase().as_str(),
        "127.0.0.1:11435" | "localhost:11435")
        || !path.starts_with('/') || path.starts_with("//") || path.contains('\\')
        || method.eq_ignore_ascii_case("CONNECT") || !header_values(headers, "upgrade").is_empty()
    { return Err(StatusCode::BAD_REQUEST); }
    let lengths = header_values(headers, "content-length");
    if lengths.len() > 1 || (!lengths.is_empty() && !header_values(headers, "transfer-encoding").is_empty()) {
        return Err(StatusCode::BAD_REQUEST);
    }
    if header_values(headers, "sec-fetch-site").iter().any(|s| s.eq_ignore_ascii_case("cross-site")) {
        return Err(StatusCode::FORBIDDEN);
    }
    let origins = header_values(headers, "origin");
    if origins.len() > 1 || origins.iter().any(|origin| !loopback_origin(origin)) {
        return Err(StatusCode::FORBIDDEN);
    }
    Ok(())
}

fn filtered_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    let mut hop: BTreeSet<String> = ["connection", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]
        .into_iter().map(str::to_owned).collect();
    for value in header_values(headers, "connection") {
        hop.extend(value.split(',').map(|part| part.trim().to_ascii_lowercase()));
    }
    headers.iter().filter(|(name, _)| !hop.contains(&name.to_ascii_lowercase()))
        .cloned().collect()
}

fn headers_of(map: &hyper::HeaderMap) -> Result<Vec<(String, String)>, StatusCode> {
    map.iter().map(|(name, value)| value.to_str()
        .map(|v| (name.as_str().to_owned(), v.to_owned()))
        .map_err(|_| StatusCode::BAD_REQUEST)).collect()
}

fn empty(code: StatusCode) -> Response<ReplyBody> {
    let body = Full::new(Bytes::new())
        .map_err(|never| -> BoxError { match never {} }).boxed_unsync();
    Response::builder().status(code).body(body).unwrap()
}

async fn forward(request: Request<Incoming>, upstream: String, generation: u64)
    -> Result<Response<ReplyBody>, Infallible> {
    if !ALLOWED.load(Ordering::Acquire) || GENERATION.load(Ordering::Acquire) != generation {
        return Ok(empty(StatusCode::SERVICE_UNAVAILABLE));
    }
    let headers = match headers_of(request.headers()) { Ok(h) => h, Err(code) => return Ok(empty(code)) };
    let path = request.uri().to_string();
    if let Err(code) = validate(request.method().as_str(), &path, &headers) { return Ok(empty(code)); }
    if request.body().size_hint().upper().is_some_and(|size| size > MAX_BODY as u64) {
        return Ok(empty(StatusCode::PAYLOAD_TOO_LARGE));
    }
    let method = request.method().clone();
    let mut incoming = request.into_body();
    let body = match timeout(BODY_DEADLINE, async {
        let mut bytes = Vec::new();
        while let Some(frame) = incoming.frame().await {
            let frame = frame.map_err(|_| StatusCode::BAD_REQUEST)?;
            if let Ok(data) = frame.into_data() {
                if bytes.len().saturating_add(data.len()) > MAX_BODY { return Err(StatusCode::PAYLOAD_TOO_LARGE); }
                bytes.extend_from_slice(&data);
            }
        }
        Ok::<_, StatusCode>(bytes)
    }).await {
        Ok(Ok(body)) => body,
        Ok(Err(code)) => return Ok(empty(code)),
        Err(_) => return Ok(empty(StatusCode::REQUEST_TIMEOUT)),
    };
    if !ALLOWED.load(Ordering::Acquire) || GENERATION.load(Ordering::Acquire) != generation {
        return Ok(empty(StatusCode::SERVICE_UNAVAILABLE));
    }
    let route = path.split('?').next().unwrap_or_default();
    let observer = Observer::new(route, &body);
    let uri = format!("{}{}", upstream.trim_end_matches('/'), path);
    let Ok(uri) = uri.parse::<hyper::Uri>() else { return Ok(empty(StatusCode::BAD_REQUEST)); };
    let mut outbound = Request::builder().method(method).uri(uri).body(Full::new(Bytes::from(body))).unwrap();
    for (name, value) in filtered_headers(&headers) {
        if matches!(name.as_str(), "host" | "expect" | "content-length" | "accept-encoding") { continue; }
        if let (Ok(name), Ok(value)) = (name.parse::<hyper::header::HeaderName>(), value.parse::<hyper::header::HeaderValue>()) {
            outbound.headers_mut().append(name, value);
        }
    }
    outbound.headers_mut().insert(header::ACCEPT_ENCODING, header::HeaderValue::from_static("identity"));
    // HttpConnector is direct HTTP to the already validated literal loopback
    // endpoint. It has no proxy and never follows redirects.
    let connector = HttpConnector::new();
    let client: Client<_, Full<Bytes>> = Client::builder(TokioExecutor::new()).build(connector);
    let response = match timeout(Duration::from_secs(10), client.request(outbound)).await {
        Ok(Ok(response)) => response,
        _ => return Ok(empty(StatusCode::BAD_GATEWAY)),
    };
    let code = response.status();
    let response_headers = match headers_of(response.headers()) { Ok(h) => h, Err(_) => return Ok(empty(StatusCode::BAD_GATEWAY)) };
    let can_observe = code.is_success() && header_values(&response_headers, "content-encoding").is_empty();
    let id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
    let observed = ObservedBody { inner: Box::pin(response.into_body()),
        observer: can_observe.then_some(observer), id, generation };
    let mut answer = Response::builder().status(code).body(observed
        .map_err(|error| -> BoxError { Box::new(error) }).boxed_unsync()).unwrap();
    for (name, value) in filtered_headers(&response_headers) {
        if name.eq_ignore_ascii_case("content-length") { continue; }
        if let (Ok(name), Ok(value)) = (name.parse::<hyper::header::HeaderName>(), value.parse::<hyper::header::HeaderValue>()) {
            answer.headers_mut().append(name, value);
        }
    }
    Ok(answer)
}

struct ObservedBody {
    inner: Pin<Box<Incoming>>,
    observer: Option<Observer>,
    id: u64,
    generation: u64,
}
impl Body for ObservedBody {
    type Data = Bytes;
    type Error = hyper::Error;
    fn poll_frame(mut self: Pin<&mut Self>, cx: &mut Context<'_>)
        -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let result = self.inner.as_mut().poll_frame(cx);
        if let Poll::Ready(frame) = &result {
            let (id, generation) = (self.id, self.generation);
            if let Some(observer) = self.observer.as_mut() {
                match frame {
                    Some(Ok(frame)) => if let Some(data) = frame.data_ref() {
                        let transitions = observer.append(data, crate::now_ms());
                        for transition in transitions { observe(id, transition, generation); }
                    },
                    None => observer.finish(crate::now_ms()),
                    Some(Err(_)) => (),
                }
                if let Some(performance) = observer.take_performance() {
                    record(&observer.model, performance, generation);
                }
            }
            if frame.is_none() { clear_request(id, generation); }
        }
        result
    }
}
impl Drop for ObservedBody {
    fn drop(&mut self) { clear_request(self.id, self.generation); }
}

fn observe(id: u64, transition: Transition, generation: u64) {
    with_current(generation, |activity| {
        if transition.thinking {
            let key = Observer::model_key(&transition.model);
            let since = activity.requests.get(&id).filter(|(name, _)| name == &key)
                .map(|(_, since)| *since).unwrap_or_else(crate::now_ms);
            activity.requests.insert(id, (key, since));
        } else { activity.requests.remove(&id); }
        rebuild_thinking(activity);
    });
}
fn clear_request(id: u64, generation: u64) {
    with_current(generation, |activity| {
        activity.requests.remove(&id);
        rebuild_thinking(activity);
    });
}
fn rebuild_thinking(activity: &mut Activity) {
    let mut models: BTreeMap<String, u64> = BTreeMap::new();
    for (model, since) in activity.requests.values() {
        models.entry(model.clone()).and_modify(|old| *old = (*old).min(*since)).or_insert(*since);
    }
    activity.public.thinking_models = models;
}
fn record(model: &str, measurement: Performance, generation: u64) {
    if model.is_empty() { return; }
    with_current(generation, |activity| {
        let key = Observer::model_key(model);
        if activity.public.performances.get(&key).is_some_and(|old| old.measured_at > measurement.measured_at) {
            return;
        }
        activity.public.performances.insert(key, measurement);
        if activity.public.performances.len() > 128 {
            if let Some(oldest) = activity.public.performances.iter()
                .min_by_key(|(_, value)| value.measured_at).map(|(key, _)| key.clone()) {
                activity.public.performances.remove(&oldest);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::sync::oneshot;
    fn headers(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(k, v)| ((*k).into(), (*v).into())).collect()
    }
    #[test]
    fn rejects_cross_site_and_host_spoof_before_upstream() {
        let valid = headers(&[("Host", "127.0.0.1:11435")]);
        assert!(validate("POST", "/api/chat", &valid).is_ok());
        for bad in [
            headers(&[("Host", "127.0.0.1:11435.evil.test")]),
            headers(&[("Host", "127.0.0.1:11435"), ("Origin", "null")]),
            headers(&[("Host", "127.0.0.1:11435"), ("Origin", "https://example.test")]),
            headers(&[("Host", "127.0.0.1:11435"), ("Sec-Fetch-Site", "cross-site")]),
        ] { assert!(validate("POST", "/api/chat", &bad).is_err()); }
        assert!(validate("CONNECT", "/api/chat", &valid).is_err());
        assert!(validate("POST", "//evil.test", &valid).is_err());
        assert!(validate("POST", "/api\\chat", &valid).is_err());
        assert!(loopback_origin("http://localhost:3000"));
    }
    #[test]
    fn strips_hop_headers_including_connection_nominations() {
        let rows = headers(&[("Connection", "X-Secret, keep-alive"), ("X-Secret", "x"),
            ("Proxy-Authorization", "private"), ("Content-Type", "application/json")]);
        assert_eq!(filtered_headers(&rows), headers(&[("Content-Type", "application/json")]));
    }
    #[test]
    fn previous_generation_cannot_resurrect_metrics_or_thinking() {
        disallow();
        let current = {
            let mut activity = state().lock().unwrap();
            let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
            *activity = Activity::default();
            generation
        };
        ALLOWED.store(true, Ordering::Release);
        record("m", Performance {output_tokens:2, generation_seconds:1., measured_at:1, approximate:false}, current - 1);
        observe(1, Transition {model:"m".into(), thinking:true}, current - 1);
        assert!(status().performances.is_empty());
        assert!(status().thinking_models.is_empty());
        disallow();
    }

    #[test]
    fn loopback_ndjson_preserves_body_and_observes_thinking_then_performance() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let generation = {
                let mut activity = state().lock().unwrap();
                let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
                *activity = Activity::default();
                ALLOWED.store(true, Ordering::Release);
                generation
            };
            let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream_address = upstream.local_addr().unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let relay_address = listener.local_addr().unwrap();
            let relay = tokio::spawn(serve(listener, format!("http://{upstream_address}/"), generation));
            let first = b"{\"model\":\"qwen\",\"message\":{\"thinking\":\"private reasoning\"},\"done\":false}\n";
            let rest = b"{\"model\":\"qwen\",\"message\":{\"content\":\"private answer\"},\"done\":false}\n{\"model\":\"qwen\",\"done\":true,\"eval_count\":20,\"eval_duration\":1000000000}\n";
            let (release_tx, release_rx) = oneshot::channel::<()>();
            let source = tokio::spawn(async move {
                let (mut connection, _) = upstream.accept().await.unwrap();
                let mut request = Vec::new();
                let mut buffer = [0u8; 1024];
                while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                    let read = connection.read(&mut buffer).await.unwrap();
                    assert!(read > 0);
                    request.extend_from_slice(&buffer[..read]);
                }
                assert!(String::from_utf8_lossy(&request).starts_with("POST /api/chat HTTP/1.1"));
                let length = first.len() + rest.len();
                connection.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: {length}\r\n\r\n").as_bytes()).await.unwrap();
                connection.write_all(first).await.unwrap();
                release_rx.await.unwrap();
                connection.write_all(rest).await.unwrap();
            });
            let socket = tokio::net::TcpStream::connect(relay_address).await.unwrap();
            let (mut sender, driver) = hyper::client::conn::http1::handshake(TokioIo::new(socket)).await.unwrap();
            let client = tokio::spawn(async move { let _ = driver.await; });
            let request = Request::builder().method("POST").uri("/api/chat")
                .header(header::HOST, "127.0.0.1:11435")
                .body(Full::new(Bytes::from_static(br#"{"model":"qwen","messages":[]}"#))).unwrap();
            let mut response = timeout(Duration::from_secs(2), sender.send_request(request)).await.unwrap().unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let mut body = Vec::new();
            let first_frame = timeout(Duration::from_secs(2), response.body_mut().frame()).await.unwrap().unwrap().unwrap();
            body.extend_from_slice(&first_frame.into_data().unwrap());
            assert_eq!(body, first);
            assert!(status().thinking_models.contains_key("qwen:latest"));
            release_tx.send(()).unwrap();
            while let Some(frame) = timeout(Duration::from_secs(2), response.body_mut().frame()).await.unwrap() {
                body.extend_from_slice(&frame.unwrap().into_data().unwrap());
            }
            assert_eq!(body, [first.as_slice(), rest.as_slice()].concat());
            let latest = status();
            assert!(latest.thinking_models.is_empty());
            let speed = latest.performances.get("qwen:latest").unwrap();
            assert_eq!(speed.output_tokens, 20);
            assert_eq!(speed.tokens_per_second(), 20.0);
            source.await.unwrap();
            relay.abort();
            let _ = relay.await;
            client.abort();
            disallow();
            *state().lock().unwrap() = Activity::default();
        });
    }

    #[test]
    fn slow_body_times_out_and_stopping_listener_closes_stalled_downstream() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let generation = {
                let mut activity = state().lock().unwrap();
                let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
                *activity = Activity::default();
                ALLOWED.store(true, Ordering::Release);
                generation
            };
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let worker = tokio::spawn(serve(listener, "http://127.0.0.1:9/".into(), generation));
            let mut slow = tokio::net::TcpStream::connect(address).await.unwrap();
            slow.write_all(b"POST /api/chat HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nContent-Length: 100\r\n\r\n{").await.unwrap();
            let mut reply = Vec::new();
            timeout(Duration::from_secs(2), slow.read_to_end(&mut reply)).await.unwrap().unwrap();
            assert!(String::from_utf8_lossy(&reply).contains("408"));

            // The second client never reads the response. Aborting the owner
            // must cancel that connection task, including its upstream body.
            let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream_address = upstream.local_addr().unwrap();
            worker.abort();
            let _ = worker.await;
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let worker = tokio::spawn(serve(listener, format!("http://{upstream_address}/"), generation));
            let source = tokio::spawn(async move {
                let (mut conn, _) = upstream.accept().await.unwrap();
                let mut head = [0u8; 2048];
                let _ = conn.read(&mut head).await;
                let _ = conn.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 67108864\r\n\r\n").await;
                let chunk = vec![b'x'; 65_536];
                for _ in 0..1024 {
                    if conn.write_all(&chunk).await.is_err() { break; }
                }
            });
            let mut stopped = tokio::net::TcpStream::connect(address).await.unwrap();
            stopped.write_all(b"POST /api/chat HTTP/1.1\r\nHost: 127.0.0.1:11435\r\nContent-Length: 13\r\n\r\n{\"model\":\"m\"}").await.unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
            worker.abort();
            let _ = worker.await;
            disallow();
            timeout(Duration::from_secs(2), async {
                let mut buf = [0u8; 65_536];
                loop { if stopped.read(&mut buf).await.unwrap_or(0) == 0 { break; } }
            }).await.expect("stalled downstream must be closed with owner");
            source.abort();
        });
    }
}
