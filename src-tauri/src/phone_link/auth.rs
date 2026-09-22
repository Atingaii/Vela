//! Phone Link v3, translated from the pinned Swift implementation and official vectors.
use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, Mac};
use rand::{rngs::OsRng, RngCore};
use ring::{aead, hkdf};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    net::IpAddr,
};

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn unhex(text: &str) -> Result<Vec<u8>, &'static str> {
    if !text.len().is_multiple_of(2) {
        return Err("invalid-hex");
    }
    text.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let hi = (pair[0] as char).to_digit(16).ok_or("invalid-hex")?;
            let lo = (pair[1] as char).to_digit(16).ok_or("invalid-hex")?;
            Ok((hi * 16 + lo) as u8)
        })
        .collect()
}
pub fn random_code() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(|_| "无法生成配对码")?;
    Ok(hex(&bytes))
}
fn derive(material: &[u8], info: &str) -> [u8; 32] {
    struct Len;
    impl hkdf::KeyType for Len {
        fn len(&self) -> usize {
            32
        }
    }
    let salt = hkdf::Salt::new(hkdf::HKDF_SHA256, &[]);
    let prk = salt.extract(material);
    let info = [info.as_bytes()];
    let mut result = [0u8; 32];
    prk.expand(&info, Len)
        .expect("valid HKDF length")
        .fill(&mut result)
        .expect("valid output length");
    result
}
pub struct Keys {
    pub signature: [u8; 32],
    pub encryption: [u8; 32],
}
pub fn pairing_keys(code: &str) -> Result<Keys, &'static str> {
    let bytes = unhex(code)?;
    if bytes.len() != 16 {
        return Err("invalid-code");
    }
    Ok(Keys {
        signature: derive(&bytes, "codenotch/v3/pair-sig"),
        encryption: derive(&bytes, "codenotch/v3/pair-enc"),
    })
}
pub fn device_keys(secret: &[u8]) -> Keys {
    Keys {
        signature: derive(secret, "codenotch/v3/sig"),
        encryption: derive(secret, "codenotch/v3/enc"),
    }
}
pub fn device_secret(code: &str, device: &str) -> Result<String, &'static str> {
    let code = unhex(code)?;
    if code.len() != 16 {
        return Err("invalid-code");
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(&code).expect("HMAC accepts any key");
    mac.update(format!("codenotch-device-v3:{device}").as_bytes());
    Ok(hex(&mac.finalize().into_bytes()))
}
fn signing_mac(key: &[u8], r: &Signed<'_>) -> Hmac<Sha256> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key");
    mac.update(
        format!(
            "{}.{}.{}.{}.{}",
            r.ts,
            r.nonce,
            r.method,
            r.uri,
            hex(&Sha256::digest(r.body))
        )
        .as_bytes(),
    );
    mac
}
pub fn verify(key: &[u8], r: &Signed<'_>) -> bool {
    unhex(r.signature)
        .is_ok_and(|bytes| bytes.len() == 32 && signing_mac(key, r).verify_slice(&bytes).is_ok())
}
pub fn aad(r: &Signed<'_>, pairing: bool, response: bool) -> String {
    let kind = match (pairing, response) {
        (true, true) => "pair-res",
        (true, false) => "pair-req",
        (false, true) => "res",
        _ => "req",
    };
    format!(
        "v3|{kind}|{}|{}|{}|{}|{}{}",
        r.ts,
        r.nonce,
        r.method,
        r.uri.split('?').next().unwrap_or(r.uri),
        r.device,
        if response { "|200" } else { "" }
    )
}
fn key(bytes: &[u8; 32]) -> aead::LessSafeKey {
    aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_256_GCM, bytes).expect("32-byte AES key"),
    )
}
pub fn open(envelope: &[u8], bytes: &[u8; 32], aad: &str) -> Result<Vec<u8>, &'static str> {
    let combined = STANDARD.decode(envelope).map_err(|_| "bad-envelope")?;
    if combined.len() < 28 {
        return Err("bad-envelope");
    }
    let nonce: aead::Nonce =
        aead::Nonce::try_assume_unique_for_key(&combined[..12]).map_err(|_| "bad-envelope")?;
    let mut data = combined[12..].to_vec();
    let plain = key(bytes)
        .open_in_place(nonce, aead::Aad::from(aad), &mut data)
        .map_err(|_| "bad-envelope")?;
    Ok(plain.to_vec())
}
fn seal_with_nonce(
    plaintext: &[u8],
    bytes: &[u8; 32],
    aad: &str,
    nonce: [u8; 12],
) -> Result<String, &'static str> {
    let mut data = plaintext.to_vec();
    key(bytes)
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(aad),
            &mut data,
        )
        .map_err(|_| "unavailable")?;
    let mut combined = nonce.to_vec();
    combined.extend(data);
    Ok(STANDARD.encode(combined))
}
pub fn seal(plaintext: &[u8], bytes: &[u8; 32], aad: &str) -> Result<String, &'static str> {
    let mut nonce = [0u8; 12];
    OsRng
        .try_fill_bytes(&mut nonce)
        .map_err(|_| "unavailable")?;
    seal_with_nonce(plaintext, bytes, aad, nonce)
}
// The vault account includes the six-character `phone-` prefix (100-byte maximum).
pub fn valid_device(id: &str) -> bool {
    !id.is_empty() && id.len() <= 94 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
pub fn private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => v.is_private() || v.is_link_local() || v.is_loopback(),
        IpAddr::V6(v) => {
            v.is_loopback()
                || (v.segments()[0] & 0xfe00) == 0xfc00
                || (v.segments()[0] & 0xffc0) == 0xfe80
                || v.to_ipv4_mapped().is_some_and(|v| private_ip(v.into()))
        }
    }
}
pub struct Signed<'a> {
    pub ts: &'a str,
    pub nonce: &'a str,
    pub signature: &'a str,
    pub method: &'a str,
    pub uri: &'a str,
    pub device: &'a str,
    pub body: &'a [u8],
}
pub struct Pairing {
    pub code: Option<String>,
    pub expires: u64,
    pub state: &'static str,
    retired: VecDeque<(String, u64)>,
}
impl Pairing {
    pub fn new() -> Self {
        Self {
            code: None,
            expires: 0,
            state: "closed",
            retired: VecDeque::new(),
        }
    }
    pub fn close(&mut self, now: u64) {
        if let Some(code) = self.code.take() {
            self.retired.push_back((code, now + 600));
        }
        self.retired.retain(|(_, until)| *until > now);
        while self.retired.len() > 8 {
            self.retired.pop_front();
        }
        self.expires = 0;
        self.state = "closed";
    }
    pub fn open(&mut self, now: u64) -> Result<(), String> {
        let code = random_code()?;
        self.close(now);
        self.code = Some(code);
        self.expires = now + 300;
        self.state = "open";
        Ok(())
    }
    pub fn refresh(&mut self, now: u64) {
        if self.code.is_some() && now >= self.expires {
            self.close(now);
            self.state = "expired";
        }
    }
    pub fn authenticate(&mut self, r: &Signed<'_>, now: u64) -> Result<Keys, &'static str> {
        self.refresh(now);
        let code = self.code.as_ref().ok_or("pairing-closed")?;
        let keys = pairing_keys(code)?;
        if verify(&keys.signature, r) {
            return Ok(keys);
        }
        if self.retired.iter().any(|(code, until)| {
            *until > now && pairing_keys(code).is_ok_and(|k| verify(&k.signature, r))
        }) {
            Err("code-expired")
        } else {
            Err("bad-code")
        }
    }
}
#[derive(Default)]
pub struct Gate {
    rates: HashMap<(IpAddr, bool), (u64, u32)>,
    nonces: HashMap<(String, String), u64>,
}
impl Gate {
    pub fn rate(&mut self, ip: IpAddr, pairing: bool, now: u64) -> Result<(), &'static str> {
        if !private_ip(ip) {
            return Err("local-network-only");
        }
        self.rates
            .retain(|_, (start, _)| now.saturating_sub(*start) < 60);
        if self.rates.len() >= 1024 && !self.rates.contains_key(&(ip, pairing)) {
            return Err("rate-limited");
        }
        let (_, count) = self.rates.entry((ip, pairing)).or_insert((now, 0));
        *count += 1;
        if *count > if pairing { 10 } else { 120 } {
            Err("rate-limited")
        } else {
            Ok(())
        }
    }
    pub fn headers(
        &mut self,
        ip: IpAddr,
        pairing: bool,
        r: &Signed<'_>,
        now: u64,
    ) -> Result<(), &'static str> {
        if !valid_device(r.device)
            || r.signature.len() != 64
            || unhex(r.nonce).is_err()
            || r.nonce.len() != 32
        {
            return Err("bad-headers");
        }
        let ts = r.ts.parse::<u64>().map_err(|_| "bad-headers")?;
        if now.abs_diff(ts) > 120 {
            return Err("clock-skew");
        }
        self.nonces.retain(|_, until| *until > now);
        let scope = if pairing {
            format!("pair:{ip}")
        } else {
            format!("device:{}", r.device)
        };
        let key = (scope, r.nonce.to_owned());
        if self.nonces.contains_key(&key) {
            return Err("replayed-nonce");
        }
        if self.nonces.len() >= 16_384 {
            return Err("rate-limited");
        }
        self.nonces.insert(key, now + 300);
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upstream_v3_vector_and_tampering() {
        let v: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/phone-link-v3-vectors.json"
        ))
        .unwrap();
        let s = |key: &str| v[key].as_str().unwrap();
        let secret = device_secret(s("code"), s("deviceId")).unwrap();
        assert_eq!(secret, s("S"));
        let keys = device_keys(&unhex(&secret).unwrap());
        assert_eq!(hex(&keys.signature), s("K_sig"));
        assert_eq!(hex(&keys.encryption), s("K_enc"));
        let pair = pairing_keys(s("code")).unwrap();
        assert_eq!(hex(&pair.signature), s("K_pair_sig"));
        assert_eq!(hex(&pair.encryption), s("K_pair_enc"));
        let x = &v["sample"];
        let x = |k: &str| x[k].as_str().unwrap();
        let r = Signed {
            ts: x("ts"),
            nonce: x("nonce"),
            signature: x("signature"),
            method: x("method"),
            uri: x("uri"),
            device: s("deviceId"),
            body: x("envelopeBase64").as_bytes(),
        };
        assert_eq!(aad(&r, false, false), x("aad"));
        assert!(verify(&keys.signature, &r));
        assert_eq!(
            open(r.body, &keys.encryption, x("aad")).unwrap(),
            x("plaintext").as_bytes()
        );
        assert_eq!(
            seal_with_nonce(
                x("plaintext").as_bytes(),
                &keys.encryption,
                x("aad"),
                unhex(x("gcmNonce")).unwrap().try_into().unwrap()
            )
            .unwrap(),
            x("envelopeBase64")
        );
        assert!(open(r.body, &keys.encryption, "wrong aad").is_err());
        assert!(!verify(
            &keys.signature,
            &Signed {
                uri: "/api/v3/refresh",
                ..r
            }
        ));
    }
    #[test]
    fn pairing_only_while_window_is_open_and_single_use() {
        let mut p = Pairing::new();
        assert!(p.code.is_none());
        p.open(100).unwrap();
        let code = p.code.clone();
        p.refresh(399);
        assert_eq!(p.code, code);
        p.refresh(400);
        assert!(p.code.is_none());
        p.open(401).unwrap();
        assert_ne!(p.code, code);
        p.close(402);
        assert!(p.code.is_none());
    }
    #[test]
    fn admission_rejects_replay_across_ips_and_bounds_rate() {
        let mut g = Gate::default();
        let ip = "192.168.1.5".parse().unwrap();
        assert_eq!(
            g.rate("8.8.8.8".parse().unwrap(), true, 1000),
            Err("local-network-only")
        );
        for _ in 0..10 {
            assert!(g.rate(ip, true, 1000).is_ok());
        }
        assert_eq!(g.rate(ip, true, 1000), Err("rate-limited"));
        assert!(g.rate(ip, true, 1060).is_ok());
        let r = Signed {
            ts: "1000",
            nonce: "00112233445566778899aabbccddeeff",
            signature: "0000000000000000000000000000000000000000000000000000000000000000",
            method: "GET",
            uri: "/api/v3/snapshot",
            device: "device-a",
            body: b"",
        };
        assert!(g.headers(ip, false, &r, 1000).is_ok());
        assert_eq!(
            g.headers("192.168.1.6".parse().unwrap(), false, &r, 1001),
            Err("replayed-nonce")
        );
        assert_eq!(g.headers(ip, false, &r, 1201), Err("clock-skew"));
        assert!(!private_ip("::ffff:8.8.8.8".parse().unwrap()));
    }
}
