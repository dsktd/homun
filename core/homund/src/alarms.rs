//! The scheduler's forecast alarms (`ResetAlarms` in container/services/scheduler/serve.py): the
//! burn-5h, burn-7d and window-open alarms of every reset the forecast shows, each decided once,
//! when its reset is first seen, and kept in the state file as `{"<reset epoch>": {"<alarm>": at|null}}`.

use std::collections::BTreeMap;

use serde_json::Map;
use serde_json::Value;

const BURN_BEFORE: i64 = 3000; // 50 minutes
const BURN_MIN_AWAY: i64 = 3300; // 55 minutes
const OPEN_AFTER: i64 = 300; // 5 minutes
const BURN7_BEFORE: i64 = 4500; // 75 minutes
const BURN7_MIN_AWAY: i64 = 4800; // 80 minutes
const SAME_RESET: i64 = 600; // resets this close are one reset
/// A forecast alarm found this late (the service was down) is dropped, not fired.
pub const LATE: i64 = 600;
/// burn-7d only while the week is projected under this at its reset.
pub const BURN7_UNDER: f64 = 97.0;
pub const NAMES: [&str; 3] = ["burn-5h", "burn-7d", "window-open"];

#[derive(Clone, Copy, PartialEq)]
pub enum Window {
    FiveHour,
    SevenDay,
}

impl Window {
    fn names(self) -> &'static [&'static str] {
        match self {
            Self::FiveHour => &["burn-5h", "window-open"],
            Self::SevenDay => &["burn-7d"],
        }
    }
}

#[derive(Default)]
pub struct ResetAlarms {
    resets: BTreeMap<i64, BTreeMap<String, Option<i64>>>,
}

impl ResetAlarms {
    pub fn from_json(saved: Option<&Value>) -> Self {
        let mut resets = BTreeMap::new();
        for (key, plan) in saved.and_then(Value::as_object).into_iter().flatten() {
            let Ok(reset) = key.parse::<i64>() else {
                continue;
            };
            let plan = plan.as_object().into_iter().flatten().map(|(name, at)| {
                let name = if name == "leftover-burn" {
                    "burn-5h"
                } else {
                    name
                };
                (name.to_owned(), at.as_i64())
            });
            resets.insert(reset, plan.collect());
        }
        Self { resets }
    }

    pub fn to_json(&self) -> Value {
        let map: Map<String, Value> = self
            .resets
            .iter()
            .map(|(reset, plan)| (reset.to_string(), serde_json::json!(plan)))
            .collect();
        Value::Object(map)
    }

    /// Learn a reset of `window` from the forecast; a burn alarm is planned only if there is time.
    pub fn observe(
        &mut self,
        resets_at: i64,
        now: i64,
        window: Window,
    ) {
        if resets_at <= now {
            return;
        }
        let key = self
            .resets
            .keys()
            .copied()
            .find(|k| (resets_at - k).abs() < SAME_RESET)
            .unwrap_or(resets_at);
        let plan = self.resets.entry(key).or_default();
        if window.names().iter().any(|n| plan.contains_key(*n)) {
            return;
        }
        let far = |away: i64| key - now > away;
        match window {
            Window::SevenDay => {
                plan.insert(
                    "burn-7d".into(),
                    far(BURN7_MIN_AWAY).then(|| key - BURN7_BEFORE),
                );
            }
            Window::FiveHour => {
                plan.insert(
                    "burn-5h".into(),
                    far(BURN_MIN_AWAY).then(|| key - BURN_BEFORE),
                );
                plan.insert("window-open".into(), Some(key + OPEN_AFTER));
            }
        }
        self.resets.retain(|k, _| *k >= now - 86400);
    }

    /// `(name, at, reset)` not yet fired, soonest first.
    pub fn pending(&self) -> Vec<(String, i64, i64)> {
        let mut found: Vec<_> = self
            .resets
            .iter()
            .flat_map(|(reset, plan)| {
                plan.iter()
                    .filter_map(|(name, at)| Some((name.clone(), (*at)?, *reset)))
            })
            .collect();
        found.sort_by_key(|(_, at, _)| *at);
        found
    }

    pub fn finish(
        &mut self,
        name: &str,
        reset: i64,
    ) {
        if let Some(plan) = self.resets.get_mut(&reset) {
            plan.insert(name.to_owned(), None);
        }
    }
}

/// A forecast number as Python's f-string shows it ("?" when it is missing).
fn show(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(v) if !v.is_null() => v.to_string(),
        _ => "?".into(),
    }
}

/// The message of a forecast alarm; None when the forecast has no slots for window-open.
pub fn message(
    name: &str,
    fc: &Value,
) -> Option<String> {
    if name == "burn-5h" || name == "burn-7d" {
        let (window, minutes) = if name == "burn-7d" {
            ("7d", 75)
        } else {
            ("5h", 50)
        };
        let burn = &fc["burn"];
        return Some(format!(
            "{name}: about {minutes} minutes to the {window} reset: pick items from \
             `tracker list tag burn` by their properties, within {} points and {} slots",
            show(burn.get("points")),
            show(burn.get("slots"))
        ));
    }
    let slots = fc.get("slots").filter(|s| !s.is_null())?;
    let left = match fc
        .pointer("/seven_day/projected_at_reset")
        .and_then(Value::as_f64)
    {
        Some(p) => format!("{}", (100.0 - p).max(0.0).round_ties_even()),
        None => "?".into(),
    };
    Some(format!(
        "window-open: {} agent slots available, {left}% of the 7d budget projected unused; \
         start queued issue work per your usual rules",
        show(Some(slots))
    ))
}

/// Whether a due alarm may be sent: window-open needs a free slot, a burn alarm a burn budget of
/// at least one point, burn-7d a week projected under BURN7_UNDER.
pub fn allowed(
    name: &str,
    fc: &Value,
) -> bool {
    let num = |p: &str| fc.pointer(p).and_then(Value::as_f64);
    if name == "window-open" && num("/slots").unwrap_or(0.0) < 1.0 {
        return false;
    }
    if name.starts_with("burn-") && num("/burn/points").unwrap_or(0.0) < 1.0 {
        return false;
    }
    !(name == "burn-7d" && num("/seven_day/projected_at_reset").is_none_or(|p| p >= BURN7_UNDER))
}
