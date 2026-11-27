// SPDX-License-Identifier: MPL-2.0
//! What Lobby Server says to this program: one JSON object a line, on stdin.

use crate::juice::{Stun, TurnServer};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;

/// More than any line that means something.
pub const MAX_LINE: usize = 64 << 10;
const MAX_SDP: usize = 8 << 10;

pub struct Start {
    /// Where every stream goes.
    pub socket: String,
    /// Shown on that socket, so that Lobby Server knows it is this program.
    pub secret: String,
    pub box_id: String,
    pub certificate: Certificate,
    /// Zero for no limit.
    pub max_upload_bits: u64,
}

pub struct Certificate {
    pub chain: Vec<Vec<u8>>,
    /// PKCS #8, DER.
    pub key: Vec<u8>,
}

pub struct Open {
    pub id: String,
    /// The Ed25519 key of the one device this connection is for.
    pub device: [u8; 32],
    pub offer: String,
    pub bind: Option<String>,
    pub stun: Option<Stun>,
    pub turn: Option<TurnServer>,
}

pub enum Command {
    Start(Start),
    Certificate(Certificate),
    Open(Open),
    Close(String),
}

pub fn read(line: &str) -> Option<Command> {
    if line.len() > MAX_LINE {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    match value["op"].as_str()? {
        "start" => Some(Command::Start(Start {
            socket: text(&value, "socket", 200)?,
            secret: text(&value, "secret", 128)?,
            box_id: text(&value, "boxId", 64)?,
            certificate: certificate(&value)?,
            max_upload_bits: value["maxUploadBits"].as_u64().unwrap_or(0),
        })),
        "certificate" => Some(Command::Certificate(certificate(&value)?)),
        "open" => Some(Command::Open(Open {
            id: text(&value, "id", 64)?,
            device: bytes(&value["device"])?.try_into().ok()?,
            offer: text(&value, "offer", MAX_SDP)?,
            bind: text(&value, "bind", 64),
            stun: server(&value["stun"]).map(|(host, port)| Stun { host, port }),
            turn: match server(&value["turn"]) {
                Some((host, port)) => Some(TurnServer {
                    host,
                    port,
                    user: text(&value["turn"], "user", 256)?,
                    pass: text(&value["turn"], "pass", 256)?,
                }),
                None => None,
            },
        })),
        "close" => Some(Command::Close(text(&value, "id", 64)?)),
        _ => None,
    }
}

fn text(value: &Value, key: &str, most: usize) -> Option<String> {
    let found = value[key].as_str()?;
    // Nothing in here may end a line that is written from it.
    let plain = key == "offer" || !found.chars().any(char::is_control);
    (found.len() <= most && plain).then(|| found.to_string())
}

fn bytes(value: &Value) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(value.as_str()?).ok()
}

fn server(value: &Value) -> Option<(String, u16)> {
    Some((
        text(value, "host", 253)?,
        u16::try_from(value["port"].as_u64()?).ok()?,
    ))
}

fn certificate(value: &Value) -> Option<Certificate> {
    let chain = value["chain"]
        .as_array()?
        .iter()
        .map(bytes)
        .collect::<Option<Vec<_>>>()?;
    (!chain.is_empty()).then_some(())?;
    Some(Certificate {
        chain,
        key: bytes(&value["key"])?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_is_whole_and_nothing_else() {
        let device = URL_SAFE_NO_PAD.encode([1u8; 32]);
        let open = format!(r#"{{"op":"open","id":"a","device":"{device}","offer":"v"}}"#);
        assert!(matches!(read(&open), Some(Command::Open(_))));
        assert!(matches!(
            read(r#"{"op":"close","id":"a"}"#),
            Some(Command::Close(_))
        ));
        for wrong in [
            "",
            "x",
            "[]",
            r#"{"op":"close"}"#,
            r#"{"op":"close","id":"a\nb"}"#,
            r#"{"op":"open","id":"a","device":"AAAA","offer":"v"}"#,
            r#"{"op":"start","socket":"/x","secret":"s","boxId":"b","chain":[],"key":""}"#,
            r#"{"op":"else"}"#,
        ] {
            assert!(read(wrong).is_none(), "{wrong}");
        }
        assert!(read(&format!("{}{}", open, " ".repeat(MAX_LINE))).is_none());
    }
}
