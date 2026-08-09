use std::collections::{BTreeMap, HashSet};

use serde_json::{Map, Value};

use crate::error::{BackendError, BackendResult};

const ID_PREFIX_FLOOR: usize = 8;

const SCALAR_ID_KEYS: &[&str] = &[
    "clipId",
    "sourceClipId",
    "referenceClipId",
    "targetClipId",
    "mediaRef",
    "startFrameMediaRef",
    "endFrameMediaRef",
    "sourceVideoMediaRef",
    "videoSourceMediaRef",
    "sourceMediaRef",
    "captionGroupId",
    "timelineId",
    "trackId",
    "item",
    "from",
    "reference",
    "groupId",
    "memberId",
    "jobId",
    "id",
];

const ARRAY_ID_KEYS: &[&str] = &[
    "clipIds",
    "targetClipIds",
    "items",
    "ids",
    "deletes",
    "referenceMediaRefs",
    "referenceImageMediaRefs",
    "referenceVideoMediaRefs",
    "referenceAudioMediaRefs",
];

pub fn short_id_map(ids: &HashSet<String>) -> BTreeMap<String, String> {
    let sorted: Vec<&String> = {
        let mut values: Vec<&String> = ids.iter().collect();
        values.sort();
        values
    };
    let mut out = BTreeMap::new();
    for (index, id) in sorted.iter().enumerate() {
        let mut shared_len = 0;
        if index > 0 {
            shared_len = shared_len.max(common_prefix_length(id, sorted[index - 1]));
        }
        if index + 1 < sorted.len() {
            shared_len = shared_len.max(common_prefix_length(id, sorted[index + 1]));
        }
        let len = id.len().min(ID_PREFIX_FLOOR.max(shared_len + 1));
        out.insert((*id).clone(), id.chars().take(len).collect());
    }
    out
}

pub fn shorten_value(value: &mut Value, universe: &HashSet<String>) {
    let map = short_id_map(universe);
    if map.is_empty() {
        return;
    }
    shorten_recursive(value, &map);
}

pub fn expand_args(args: &Value, universe: &HashSet<String>) -> BackendResult<Value> {
    expand_value(args, universe)
}

fn expand_value(value: &Value, universe: &HashSet<String>) -> BackendResult<Value> {
    match value {
        Value::Object(map) => {
            let mut out = Map::new();
            for (key, nested) in map {
                if SCALAR_ID_KEYS.contains(&key.as_str()) {
                    if let Some(text) = nested.as_str() {
                        out.insert(key.clone(), Value::String(expand_one(text, universe)?));
                        continue;
                    }
                }
                if ARRAY_ID_KEYS.contains(&key.as_str()) {
                    if let Some(items) = nested.as_array() {
                        let mut expanded = Vec::with_capacity(items.len());
                        for item in items {
                            if let Some(text) = item.as_str() {
                                expanded.push(Value::String(expand_one(text, universe)?));
                            } else {
                                expanded.push(expand_value(item, universe)?);
                            }
                        }
                        out.insert(key.clone(), Value::Array(expanded));
                        continue;
                    }
                }
                out.insert(key.clone(), expand_value(nested, universe)?);
            }
            Ok(Value::Object(out))
        }
        Value::Array(items) => {
            let mut expanded = Vec::with_capacity(items.len());
            for item in items {
                expanded.push(expand_value(item, universe)?);
            }
            Ok(Value::Array(expanded))
        }
        other => Ok(other.clone()),
    }
}

fn expand_one(reference: &str, universe: &HashSet<String>) -> BackendResult<String> {
    if universe.contains(reference) {
        return Ok(reference.to_owned());
    }
    if reference.chars().count() < ID_PREFIX_FLOOR {
        return Ok(reference.to_owned());
    }
    let matches: Vec<&String> = universe
        .iter()
        .filter(|id| id.starts_with(reference))
        .collect();
    match matches.as_slice() {
        [] => Ok(reference.to_owned()),
        [only] => Ok((*only).clone()),
        many => Err(BackendError::AmbiguousId {
            ref_id: reference.to_owned(),
            count: many.len(),
        }),
    }
}

fn shorten_recursive(value: &mut Value, map: &BTreeMap<String, String>) {
    match value {
        Value::String(text) => {
            if let Some(short) = map.get(text.as_str()) {
                *text = short.clone();
            } else {
                *text = replace_uuids(text, map);
            }
        }
        Value::Array(items) => {
            for item in items {
                shorten_recursive(item, map);
            }
        }
        Value::Object(map_value) => {
            for nested in map_value.values_mut() {
                shorten_recursive(nested, map);
            }
        }
        _ => {}
    }
}

fn replace_uuids(text: &str, map: &BTreeMap<String, String>) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < bytes.len() {
        if let Some(uuid) = match_uuid_at(text, index) {
            out.push_str(map.get(uuid).map(String::as_str).unwrap_or(uuid));
            index += uuid.len();
        } else {
            out.push(bytes[index] as char);
            index += 1;
        }
    }
    out
}

fn match_uuid_at(text: &str, start: usize) -> Option<&str> {
    const LEN: usize = 36;
    if start + LEN > text.len() {
        return None;
    }
    let candidate = &text[start..start + LEN];
    let bytes = candidate.as_bytes();
    let hex = |b: u8| b.is_ascii_hexdigit();
    let groups = [8, 4, 4, 4, 12];
    let mut offset = 0;
    for (group_index, group_len) in groups.iter().enumerate() {
        for _ in 0..*group_len {
            if !hex(bytes[offset]) {
                return None;
            }
            offset += 1;
        }
        if group_index + 1 != groups.len() {
            if bytes[offset] != b'-' {
                return None;
            }
            offset += 1;
        }
    }
    Some(candidate)
}

fn common_prefix_length(left: &str, right: &str) -> usize {
    left.chars()
        .zip(right.chars())
        .take_while(|(a, b)| a == b)
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_unique_prefix() {
        let universe = HashSet::from([
            "AAAAAAAA-1111-1111-1111-111111111111".to_owned(),
            "BBBBBBBB-2222-2222-2222-222222222222".to_owned(),
        ]);
        let expanded = expand_one("AAAAAAAA", &universe).unwrap();
        assert_eq!(expanded, "AAAAAAAA-1111-1111-1111-111111111111");
    }

    #[test]
    fn short_map_uses_floor() {
        let universe = HashSet::from([
            "AAAAAAAA-1111-1111-1111-111111111111".to_owned(),
            "BBBBBBBB-2222-2222-2222-222222222222".to_owned(),
        ]);
        let map = short_id_map(&universe);
        assert_eq!(
            map.get("AAAAAAAA-1111-1111-1111-111111111111")
                .map(String::as_str),
            Some("AAAAAAAA")
        );
    }
}
