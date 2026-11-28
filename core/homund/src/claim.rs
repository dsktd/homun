//! Claims as journal records (`kind=event, topic=claim`): no marker files. A claim is taken
//! under the journal's lock, so of two readers racing for one entry exactly one wins.

use anyhow::Result;
use serde_json::Value;

use crate::envelope::Envelope;
use crate::envelope::Kind;
use crate::journal::Journal;

/// An entry left unclaimed this long raises `alarm.stalled`.
pub const STALL_AFTER_SECS: u64 = 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// Delivered to its reader.
    Claimed,
    /// Could not be delivered; never pending again.
    Failed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Claimed => "claimed",
            State::Failed => "failed",
        }
    }
}

/// The claim record of entry by reader.
pub fn record(
    entry: &str,
    by: &str,
    state: State,
    ts: u64,
) -> Envelope {
    Envelope {
        id: format!("claim-{entry}"),
        ts,
        from: by.into(),
        to: by.into(),
        topic: "claim".into(),
        kind: Kind::Event,
        body: serde_json::json!({ "id": entry, "state": state.name() }),
        reply_to: Some(entry.into()),
        attn: None,
    }
}

fn claimed_id(envelope: &Envelope) -> Option<&str> {
    if envelope.kind != Kind::Event || envelope.topic != "claim" {
        return None;
    }
    envelope.body.get("id").and_then(Value::as_str)
}

/// The ids of every claim record in the journal.
fn claims(journal: &Journal) -> Result<Vec<String>> {
    Ok(journal
        .lines()?
        .iter()
        .filter_map(|line| Envelope::parse(line))
        .filter_map(|envelope| claimed_id(&envelope).map(String::from))
        .collect())
}

/// Claim entry for by: Ok(true) when this call took it, Ok(false) when it was already claimed
/// or failed, Err when the journal cannot be written (never mistaken for "taken by another").
pub fn claim(
    journal: &Journal,
    entry: &str,
    by: &str,
    state: State,
    ts: u64,
) -> Result<bool> {
    journal.locked(|| {
        if claims(journal)?.iter().any(|id| id == entry) {
            return Ok(false);
        }
        journal.append_unlocked(&serde_json::to_string(&record(entry, by, state, ts))?)?;

        Ok(true)
    })
}

/// The entries that no claim record covers yet, in journal order, as (id, ts).
pub fn pending(journal: &Journal) -> Result<Vec<(String, u64)>> {
    let claimed = claims(journal)?;
    Ok(journal
        .lines()?
        .iter()
        .filter_map(|line| Envelope::parse(line))
        .filter(|envelope| claimed_id(envelope).is_none())
        .filter(|envelope| !claimed.contains(&envelope.id))
        .map(|envelope| (envelope.id, envelope.ts))
        .collect())
}

/// The pending entries older than STALL_AFTER_SECS at now.
pub fn stalled(
    journal: &Journal,
    now: u64,
) -> Result<Vec<String>> {
    Ok(pending(journal)?
        .into_iter()
        .filter(|(_id, ts)| now.saturating_sub(*ts) >= STALL_AFTER_SECS)
        .map(|(id, _ts)| id)
        .collect())
}

#[cfg(test)]
mod test {
    use std::path::PathBuf;

    use super::*;

    fn journal(name: &str) -> (PathBuf, Journal) {
        let dir = std::env::temp_dir().join(format!("homund-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let journal = Journal {
            dir: dir.clone(),
            stem: "bus".into(),
            rotate_at: 20 << 20,
        };
        (dir, journal)
    }

    fn entry(
        journal: &Journal,
        id: &str,
        ts: u64,
    ) {
        let envelope = Envelope {
            id: id.into(),
            ts,
            from: "cockpit".into(),
            to: "manager".into(),
            topic: "user.host".into(),
            kind: Kind::User,
            body: Value::String("hi".into()),
            reply_to: None,
            attn: None,
        };
        journal
            .append(&serde_json::to_string(&envelope).unwrap())
            .unwrap();
    }

    // bus_test.go TestUserClaimedOnce: two readers race for 50 entries, each is taken once
    #[test]
    fn test_claimed_once() {
        let (dir, journal) = journal("once");
        for i in 0..50 {
            entry(&journal, &format!("m{i}"), 1);
        }
        let ids: Vec<String> = pending(&journal)
            .unwrap()
            .into_iter()
            .map(|(id, _ts)| id)
            .collect();
        let won: Vec<usize> = std::thread::scope(|scope| {
            let readers: Vec<_> = ["channel", "hook"]
                .into_iter()
                .map(|by| {
                    let (journal, ids) = (&journal, &ids);
                    scope.spawn(move || {
                        ids.iter()
                            .filter(|id| claim(journal, id, by, State::Claimed, 2).unwrap())
                            .count()
                    })
                })
                .collect();
            readers
                .into_iter()
                .map(|reader| reader.join().unwrap())
                .collect()
        });
        assert!(won.iter().sum::<usize>() == 50, "{won:?}");
        assert!(pending(&journal).unwrap().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    // bus_test.go TestUserDedupeByMarker and TestUserFailedMarksAndPauses
    #[test]
    fn test_dedupe() {
        let (dir, journal) = journal("dedupe");
        for id in ["a", "b", "c"] {
            entry(&journal, id, 1);
        }
        assert!(claim(&journal, "a", "x", State::Claimed, 2).unwrap());
        assert!(claim(&journal, "b", "x", State::Failed, 2).unwrap());
        assert!(pending(&journal).unwrap() == vec![("c".to_string(), 1)]);
        assert!(!claim(&journal, "a", "y", State::Claimed, 3).unwrap());
        assert!(!claim(&journal, "b", "y", State::Claimed, 3).unwrap());
        std::fs::remove_dir_all(dir).unwrap();
    }

    // bus_test.go TestUserClaimErrorIsLoud
    #[test]
    fn test_claim_error_is_loud() {
        let (dir, mut journal) = journal("loud");
        journal.dir = dir.join("missing/dir");
        assert!(claim(&journal, "a", "x", State::Claimed, 2).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    // bus_test.go TestUserStallAlarmsOnce (the stall half; alarming once is the channel's)
    #[test]
    fn test_stalled() {
        let (dir, journal) = journal("stall");
        entry(&journal, "a", 100);
        assert!(stalled(&journal, 100).unwrap().is_empty());
        assert!(stalled(&journal, 100 + 2 * STALL_AFTER_SECS).unwrap() == vec!["a".to_string()]);
        claim(&journal, "a", "x", State::Claimed, 101).unwrap();
        assert!(
            stalled(&journal, 100 + 2 * STALL_AFTER_SECS)
                .unwrap()
                .is_empty()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
