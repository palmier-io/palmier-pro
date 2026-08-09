use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::error::{BackendError, BackendResult};

pub fn require_object(args: &Value) -> BackendResult<&Map<String, Value>> {
    args.as_object()
        .ok_or_else(|| BackendError::message("arguments must be a JSON object"))
}

pub fn optional_string(map: &Map<String, Value>, key: &str) -> BackendResult<Option<String>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(BackendError::message(format!("{key} must be a string"))),
    }
}

pub fn require_string(map: &Map<String, Value>, key: &str) -> BackendResult<String> {
    optional_string(map, key)?.ok_or_else(|| BackendError::message(format!("{key} is required")))
}

pub fn optional_i64(map: &Map<String, Value>, key: &str) -> BackendResult<Option<i64>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_i64()
            .ok_or_else(|| BackendError::message(format!("{key} must be an integer")))
            .map(Some),
        Some(_) => Err(BackendError::message(format!("{key} must be an integer"))),
    }
}

pub fn require_i64(map: &Map<String, Value>, key: &str) -> BackendResult<i64> {
    optional_i64(map, key)?.ok_or_else(|| BackendError::message(format!("{key} is required")))
}

pub fn optional_bool(map: &Map<String, Value>, key: &str) -> BackendResult<Option<bool>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(BackendError::message(format!("{key} must be a boolean"))),
    }
}

pub fn optional_f64(map: &Map<String, Value>, key: &str) -> BackendResult<Option<f64>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_f64()
            .ok_or_else(|| BackendError::message(format!("{key} must be a number")))
            .map(Some),
        Some(_) => Err(BackendError::message(format!("{key} must be a number"))),
    }
}

pub fn optional_array<'a>(
    map: &'a Map<String, Value>,
    key: &str,
) -> BackendResult<Option<&'a Vec<Value>>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => Ok(Some(items)),
        Some(_) => Err(BackendError::message(format!("{key} must be an array"))),
    }
}

pub fn require_array<'a>(map: &'a Map<String, Value>, key: &str) -> BackendResult<&'a Vec<Value>> {
    optional_array(map, key)?.ok_or_else(|| BackendError::message(format!("{key} is required")))
}

pub fn decode_field<T: DeserializeOwned>(value: &Value, path: &str) -> BackendResult<T> {
    serde_json::from_value(value.clone())
        .map_err(|error| BackendError::message(format!("invalid {path}: {error}")))
}

pub fn reject_unknown_keys(
    map: &Map<String, Value>,
    allowed: &[&str],
    path: &str,
) -> BackendResult<()> {
    let unknown: Vec<&str> = map
        .keys()
        .filter(|key| !allowed.iter().any(|allowed| allowed == key))
        .map(String::as_str)
        .collect();
    if unknown.is_empty() {
        Ok(())
    } else {
        Err(BackendError::message(format!(
            "unknown {path} keys: {}",
            unknown.join(", ")
        )))
    }
}
