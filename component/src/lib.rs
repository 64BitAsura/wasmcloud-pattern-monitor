// ── WIT bindings (excluded from test builds to allow native compilation) ──────
#[cfg(not(test))]
wit_bindgen::generate!({ generate_all });

use embeddenator_io::to_bincode;
use embeddenator_retrieval::TernaryInvertedIndex;
use embeddenator_vsa::{ReversibleVSAConfig, SparseVec};
use serde_json::Value;
use std::collections::HashMap;

// ─── Pure encoding logic (testable on native target) ─────────────────────────

/// Holds VSA-encoded fields produced from a single JSON message.
pub(crate) struct EncodedFields {
    pub id_to_vec: HashMap<usize, SparseVec>,
    pub id_to_field: HashMap<usize, String>,
    pub index: TernaryInvertedIndex,
}

/// Parse a JSON object and encode each key/value field as a bound VSA
/// hypervector. Returns `Err` if the payload is not a valid JSON object.
pub(crate) fn encode_json_fields(body: &[u8]) -> Result<EncodedFields, String> {
    let json: Value =
        serde_json::from_slice(body).map_err(|e| format!("JSON parse error: {e}"))?;

    let obj = json
        .as_object()
        .ok_or_else(|| "message body is not a JSON object".to_string())?;

    // ReversibleVSAConfig::default() is fully deterministic (no random state).
    let config = ReversibleVSAConfig::default();
    let mut id_to_vec: HashMap<usize, SparseVec> = HashMap::new();
    let mut id_to_field: HashMap<usize, String> = HashMap::new();
    let mut index = TernaryInvertedIndex::new();

    for (idx, (key, value)) in obj.iter().enumerate() {
        let key_vec = SparseVec::encode_data(key.as_bytes(), &config, None);
        let val_vec = SparseVec::encode_data(value.to_string().as_bytes(), &config, None);
        let bound = key_vec.bind(&val_vec);
        index.add(idx, &bound);
        id_to_field.insert(idx, key.clone());
        id_to_vec.insert(idx, bound);
    }

    index.finalize();
    Ok(EncodedFields {
        id_to_vec,
        id_to_field,
        index,
    })
}

/// Bundle all per-field hypervectors into a single master bundle vector via
/// VSA superposition. Returns `None` if `id_to_vec` is empty.
pub(crate) fn build_master_bundle(id_to_vec: &HashMap<usize, SparseVec>) -> Option<SparseVec> {
    let mut iter = id_to_vec.values();
    iter.next()
        .map(|first| iter.fold(first.clone(), |acc, v| acc.bundle(v)))
}

/// Serialise a `SparseVec` to bincode bytes.
pub(crate) fn serialise_vector(vec: &SparseVec) -> Result<Vec<u8>, String> {
    to_bincode(vec).map_err(|e| format!("bincode encode error: {e}"))
}

// ─── wasmCloud component implementation (excluded from test builds) ───────────

#[cfg(not(test))]
const BUCKET_ID: &str = "pattern-monitor-vectors";
#[cfg(not(test))]
const PREFIX_SEMANTIC: &str = "semantic:v1";
#[cfg(not(test))]
const PREFIX_BUNDLE: &str = "bundle:v1";

#[cfg(not(test))]
fn kv_err(e: crate::wasi::keyvalue::store::Error) -> String {
    use crate::wasi::keyvalue::store::Error;
    match e {
        Error::NoSuchStore => "keyvalue error: no such store".to_string(),
        Error::AccessDenied => "keyvalue error: access denied".to_string(),
        Error::Other(msg) => format!("keyvalue error: {msg}"),
    }
}

#[cfg(not(test))]
struct PatternMonitor;

#[cfg(not(test))]
impl crate::exports::wasmcloud::messaging::handler::Guest for PatternMonitor {
    fn handle_message(
        msg: crate::exports::wasmcloud::messaging::handler::BrokerMessage,
    ) -> Result<(), String> {
        use crate::wasi::keyvalue::store;
        use crate::wasi::logging::logging::{log, Level};
        use embeddenator_retrieval::search::{two_stage_search, SearchConfig};

        let subject = msg.subject.clone();

        log(
            Level::Info,
            "pattern-monitor",
            &format!(
                "received message on subject '{}' ({} bytes)",
                subject,
                msg.body.len()
            ),
        );

        // ── 1. Encode fields ──────────────────────────────────────────────────
        let encoded = match encode_json_fields(&msg.body) {
            Ok(e) if e.id_to_vec.is_empty() => {
                log(Level::Warn, "pattern-monitor", "empty JSON object; skipping");
                return Ok(());
            }
            Ok(e) => e,
            Err(err) => {
                log(
                    Level::Warn,
                    "pattern-monitor",
                    &format!("skipping message: {err}"),
                );
                return Ok(());
            }
        };

        let EncodedFields {
            id_to_vec,
            id_to_field,
            index,
        } = encoded;

        // ── 2. Persist semantic vectors ───────────────────────────────────────
        let bucket = store::open(BUCKET_ID).map_err(kv_err)?;

        for (id, vec) in &id_to_vec {
            let field_name = id_to_field.get(id).map(String::as_str).unwrap_or("unknown");
            let bytes = serialise_vector(vec)?;
            let kv_key = format!("{PREFIX_SEMANTIC}:{field_name}");
            bucket.set(&kv_key, &bytes).map_err(kv_err)?;
            log(
                Level::Debug,
                "pattern-monitor",
                &format!(
                    "stored semantic vector for field '{}' ({} bytes)",
                    field_name,
                    bytes.len()
                ),
            );
        }

        // ── 3. Build and persist master bundle ────────────────────────────────
        if let Some(master) = build_master_bundle(&id_to_vec) {
            let bundle_bytes = serialise_vector(&master)?;
            let bundle_key = format!("{PREFIX_BUNDLE}:{subject}");
            bucket.set(&bundle_key, &bundle_bytes).map_err(kv_err)?;
            log(
                Level::Info,
                "pattern-monitor",
                &format!(
                    "stored master bundle for subject '{}' ({} fields, {} bytes)",
                    subject,
                    id_to_vec.len(),
                    bundle_bytes.len(),
                ),
            );
        }

        // ── 4. Demonstrate retrieval ──────────────────────────────────────────
        if id_to_vec.len() > 1 {
            if let Some(query_vec) = id_to_vec.get(&0) {
                let query_field = id_to_field
                    .get(&0)
                    .map(String::as_str)
                    .unwrap_or("field_0");
                let search_cfg = SearchConfig::default();
                let results = two_stage_search(query_vec, &index, &id_to_vec, &search_cfg, 5);
                log(
                    Level::Debug,
                    "pattern-monitor",
                    &format!(
                        "retrieval query for field '{}' returned {} result(s)",
                        query_field,
                        results.len(),
                    ),
                );
            }
        }

        Ok(())
    }
}

#[cfg(not(test))]
export!(PatternMonitor);

// ─── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use embeddenator_io::from_bincode;

    #[test]
    fn test_encode_fields_parses_json_object() {
        let body = br#"{"event":"quake","magnitude":"6.2"}"#;
        let result = encode_json_fields(body);
        assert!(result.is_ok(), "expected Ok, got: {:?}", result.err());
        let encoded = result.unwrap();
        assert_eq!(encoded.id_to_vec.len(), 2, "expected 2 field vectors");
        assert_eq!(encoded.id_to_field.len(), 2, "expected 2 field names");
    }

    #[test]
    fn test_encode_fields_rejects_json_array() {
        let result = encode_json_fields(b"[1, 2, 3]");
        assert!(result.is_err());
        assert!(
            result.err().unwrap().contains("not a JSON object"),
            "error should mention 'not a JSON object'"
        );
    }

    #[test]
    fn test_encode_fields_rejects_invalid_json() {
        let result = encode_json_fields(b"not json");
        assert!(result.is_err());
        assert!(
            result.err().unwrap().contains("JSON parse error"),
            "error should mention 'JSON parse error'"
        );
    }

    #[test]
    fn test_encode_fields_rejects_json_string() {
        let result = encode_json_fields(br#""just a string""#);
        assert!(result.is_err());
    }

    #[test]
    fn test_build_master_bundle_single_field() {
        let encoded = encode_json_fields(br#"{"only":"field"}"#).unwrap();
        let bundle = build_master_bundle(&encoded.id_to_vec);
        assert!(bundle.is_some(), "bundle should exist for a single-field object");
    }

    #[test]
    fn test_build_master_bundle_multiple_fields() {
        let encoded = encode_json_fields(br#"{"a":"1","b":"2","c":"3"}"#).unwrap();
        let bundle = build_master_bundle(&encoded.id_to_vec);
        assert!(bundle.is_some(), "bundle should exist for a multi-field object");
    }

    #[test]
    fn test_build_master_bundle_empty_map() {
        let empty: HashMap<usize, SparseVec> = HashMap::new();
        let bundle = build_master_bundle(&empty);
        assert!(bundle.is_none(), "empty map should yield no bundle");
    }

    #[test]
    fn test_serialise_vector_roundtrip() {
        let encoded =
            encode_json_fields(br#"{"sensor":"temperature","value":"42.5"}"#).unwrap();
        let original = encoded.id_to_vec.values().next().unwrap();
        let bytes = serialise_vector(original).unwrap();
        assert!(!bytes.is_empty(), "serialised bytes must not be empty");
        // Deserialise then re-serialise: bytes must be identical (bincode is deterministic)
        let restored: SparseVec =
            from_bincode(&bytes).expect("from_bincode should succeed on a serialised SparseVec");
        let bytes2 = serialise_vector(&restored).expect("re-serialisation should succeed");
        assert_eq!(
            bytes, bytes2,
            "re-serialising a deserialised SparseVec must produce identical bytes"
        );
    }

    #[test]
    fn test_same_input_produces_same_vector() {
        // from_data is deterministic: same bytes -> same serialised vector
        let body = br#"{"key":"value"}"#;
        let enc1 = encode_json_fields(body).unwrap();
        let enc2 = encode_json_fields(body).unwrap();
        let bytes1 = serialise_vector(enc1.id_to_vec.values().next().unwrap()).unwrap();
        let bytes2 = serialise_vector(enc2.id_to_vec.values().next().unwrap()).unwrap();
        assert_eq!(bytes1, bytes2, "same JSON input must produce identical vector bytes");
    }
}
