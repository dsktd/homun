//! The bus envelope, and the legacy inbox line it replaces.

use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;

/// Longest journal line a reader accepts.
pub const MAX_LINE: usize = 4096;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    User,
    Alarm,
    Request,
    Result,
    Approve,
    Lease,
    Stage,
    State,
    Presence,
    Event,
}

/// One record on the bus: `{id, ts, from, to, topic, kind, body, reply_to?, attn?}`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Envelope {
    pub id: String,
    pub ts: u64,
    pub from: String,
    pub to: String,
    pub topic: String,
    pub kind: Kind,
    pub body: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attn: Option<String>,
}

impl Envelope {
    /// A line of the journal as an envelope, or None when it is not one (a legacy line included).
    pub fn parse(line: &[u8]) -> Option<Envelope> {
        if line.is_empty() || line.len() > MAX_LINE {
            return None;
        }
        serde_json::from_slice(line).ok()
    }
}

/// A line of today's `inbox.jsonl`: `{id,ts,from,to,alarm,msg,via?}` as `homun-msg send` writes it.
#[derive(Clone, Debug, PartialEq)]
pub struct Legacy {
    pub id: String,
    /// The decimal digits of `ts`, kept as text: writers send a number or a string.
    pub ts: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub alarm: String,
    pub msg: String,
    pub via: Option<String>,
}

impl Legacy {
    /// The checks of the channel's reader: valid UTF-8 JSON under 4 KiB with an id, alarm and msg.
    pub fn parse(line: &[u8]) -> Option<Legacy> {
        if line.is_empty() || line.len() > MAX_LINE {
            return None;
        }
        let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(line) else {
            return None;
        };
        let text = |key: &str| match map.get(key) {
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            _ => None,
        };
        let ts = match map.get("ts") {
            Some(Value::Number(n)) if n.is_u64() || n.is_i64() => Some(n.to_string()),
            Some(Value::String(s)) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
                Some(s.clone())
            }
            _ => None,
        };
        Some(Legacy {
            id: text("id")?,
            ts,
            from: text("from"),
            to: text("to"),
            alarm: text("alarm")?,
            msg: text("msg")?,
            via: text("via"),
        })
    }

    /// The line exactly as `jq -c` printed it in the shell homun-msg: same key order and escapes.
    pub fn line(&self) -> String {
        let mut out = String::from("{");
        out.push_str(&format!("\"id\":{}", quote(&self.id)));
        out.push_str(&format!(",\"ts\":{}", self.ts.as_deref().unwrap_or("0")));
        for (key, value) in [("from", &self.from), ("to", &self.to)] {
            out.push_str(&format!(
                ",\"{key}\":{}",
                quote(value.as_deref().unwrap_or(""))
            ));
        }
        out.push_str(&format!(",\"alarm\":{}", quote(&self.alarm)));
        out.push_str(&format!(",\"msg\":{}", quote(&self.msg)));
        if let Some(via) = &self.via {
            out.push_str(&format!(",\"via\":{}", quote(via)));
        }
        out.push('}');
        out
    }
}

impl From<Legacy> for Envelope {
    fn from(legacy: Legacy) -> Envelope {
        let mut body = serde_json::json!({ "msg": legacy.msg });
        if let Some(via) = legacy.via {
            body["via"] = Value::String(via);
        }
        Envelope {
            id: legacy.id,
            ts: legacy.ts.and_then(|ts| ts.parse().ok()).unwrap_or(0),
            from: legacy.from.unwrap_or_default(),
            to: legacy.to.unwrap_or_default(),
            topic: legacy.alarm,
            kind: Kind::Alarm,
            body,
            reply_to: None,
            attn: None,
        }
    }
}

/// A JSON string as jq writes it: control characters and DEL as `\u00xx`, the rest raw.
fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                out.push_str(&format!("\\u{:04x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod test {
    use super::*;

    // bus_test.go TestBusParams
    #[test]
    fn test_legacy_parse() {
        let line =
            br#"{"id":"1","ts":"17","from":"sch","to":"m","alarm":"a","msg":"hi","via":"phone"}"#;
        let legacy = Legacy::parse(line).unwrap();
        assert!(legacy.ts.as_deref() == Some("17"));
        assert!(legacy.via.as_deref() == Some("phone"));
        assert!(legacy.from.as_deref() == Some("sch"));
        assert!(Legacy::parse(br#"{"id":"1","alarm":"a"}"#).is_none());
        let long = format!(r#"{{"id":"1","alarm":"a","msg":"{}"}}"#, "x".repeat(5000));
        assert!(Legacy::parse(long.as_bytes()).is_none());
        assert!(Legacy::parse(b"{\"id\":\"1\",\"alarm\":\"a\",\"msg\":\"\xff\"}").is_none());
    }

    #[test]
    fn test_legacy_line_roundtrip() {
        let line = r#"{"id":"u","ts":17,"from":"host","to":"manager","alarm":"a\u007f\u0001\"","msg":"hi","via":"phone"}"#;
        assert!(Legacy::parse(line.as_bytes()).unwrap().line() == line);
    }

    #[test]
    fn test_envelope_from_legacy() {
        let line = br#"{"id":"1","ts":17,"from":"sch","to":"m","alarm":"a","msg":"hi"}"#;
        let envelope = Envelope::from(Legacy::parse(line).unwrap());
        let text = serde_json::to_string(&envelope).unwrap();
        assert!(Envelope::parse(text.as_bytes()) == Some(envelope));
        assert!(text.contains(r#""kind":"alarm""#));
        assert!(Envelope::parse(line).is_none());
    }
}
