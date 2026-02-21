wit_bindgen::generate!({ generate_all });

use crate::exports::wasmcloud::messaging::handler::{Guest, BrokerMessage};
use crate::wasi::keyvalue::store;
use crate::wasi::logging::logging::{log, Level};

use embeddenator_vsa::{ReversibleVSAConfig, SparseVec};
use embeddenator_io::to_bincode;
use embeddenator_retrieval::{
    TernaryInvertedIndex,
    search::{two_stage_search, SearchConfig},
};

use serde_json::Value;
use std::collections::HashMap;

/// Name of the wasi:keyvalue bucket used by this component.
const BUCKET_ID: &str = "pattern-monitor-vectors";

/// Key-space prefixes used when persisting hypervectors.
const PREFIX_SEMANTIC: &str = "semantic:v1";
const PREFIX_BUNDLE: &str = "bundle:v1";

// ─── Helper: convert a wasi:keyvalue store::Error to a String ────────────────

fn kv_err(e: store::Error) -> String {
    match e {
        store::Error::NoSuchStore => "keyvalue error: no such store".to_string(),
        store::Error::AccessDenied => "keyvalue error: access denied".to_string(),
        store::Error::Other(msg) => format!("keyvalue error: {msg}"),
    }
}

// ─── Component struct ────────────────────────────────────────────────────────

struct PatternMonitor;

// ─── Messaging handler implementation ────────────────────────────────────────

impl Guest for PatternMonitor {
    /// Invoked for every message arriving on a subscribed NATS subject.
    ///
    /// Workflow
    /// 1. Parse the body as a JSON object.
    /// 2. For every key/value pair encode both key and value bytes into a
    ///    `SparseVec` (VSA hypervector), then *bind* them together.
    /// 3. Persist each bound semantic vector into Redis (wasi:keyvalue) under
    ///    the key `semantic:v1:{field_name}`.
    /// 4. *Bundle* (superpose) all per-field vectors into a master vector and
    ///    persist it under `bundle:v1:{subject}`.
    fn handle_message(msg: BrokerMessage) -> Result<(), String> {
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

        // ── 1. Parse JSON ────────────────────────────────────────────────────
        let json: Value = serde_json::from_slice(&msg.body)
            .map_err(|e| format!("JSON parse error: {e}"))?;

        let obj = match json.as_object() {
            Some(o) => o,
            None => {
                log(
                    Level::Warn,
                    "pattern-monitor",
                    "message body is not a JSON object; skipping",
                );
                return Ok(());
            }
        };

        if obj.is_empty() {
            log(
                Level::Warn,
                "pattern-monitor",
                "empty JSON object; skipping",
            );
            return Ok(());
        }

        // ── 2. Encode fields and build local retrieval index ─────────────────
        let config = ReversibleVSAConfig::default();

        // id_to_vec: id -> SparseVec  (needed for two_stage_search)
        // id_to_field: id -> field name (for logging)
        let mut id_to_vec: HashMap<u64, SparseVec> = HashMap::new();
        let mut id_to_field: HashMap<u64, String> = HashMap::new();
        let mut index = TernaryInvertedIndex::new();

        for (idx, (key, value)) in obj.iter().enumerate() {
            let key_bytes = key.as_bytes();
            let val_str = value.to_string();
            let val_bytes = val_str.as_bytes();

            // Encode key and value independently, then bind the pair together
            let key_vec = SparseVec::encode_data(key_bytes, &config, None);
            let val_vec = SparseVec::encode_data(val_bytes, &config, None);
            let bound = key_vec.bind(&val_vec);

            let id = idx as u64;
            index.add(id, &bound);
            id_to_field.insert(id, key.clone());
            id_to_vec.insert(id, bound);
        }

        index.finalize();

        // ── 3. Persist semantic vectors to Redis ─────────────────────────────
        let bucket = store::open(BUCKET_ID).map_err(kv_err)?;

        for (id, vec) in &id_to_vec {
            let field_name = id_to_field.get(id).map(String::as_str).unwrap_or("unknown");
            let bytes: Vec<u8> = to_bincode(vec)
                .map_err(|e| format!("bincode encode error for field '{field_name}': {e}"))?;
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

        // ── 4. Build and persist master bundle ───────────────────────────────
        let mut values_iter = id_to_vec.values();
        if let Some(first) = values_iter.next() {
            let master = values_iter.fold(first.clone(), |acc, v| acc.bundle(v));

            let bundle_bytes: Vec<u8> = to_bincode(&master)
                .map_err(|e| format!("bincode encode error for bundle: {e}"))?;
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

        // ── 5. Demonstrate retrieval: query the first field against the index ──
        if id_to_vec.len() > 1 {
            if let Some(query_vec) = id_to_vec.get(&0) {
                let query_field = id_to_field
                    .get(&0)
                    .map(String::as_str)
                    .unwrap_or("field_0");
                let search_cfg = SearchConfig::default();
                let results =
                    two_stage_search(query_vec, &index, &id_to_vec, &search_cfg, 5);

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

export!(PatternMonitor);
