use seahash::SeaHasher;
use sha2::{Digest, Sha256};
use std::hash::{Hash, Hasher};

use crate::repository::models::ContentType;

pub fn content_hash(content: &str, content_type: &ContentType) -> u64 {
    let mut hasher = SeaHasher::new();
    content.hash(&mut hasher);
    format!("{content_type:?}").hash(&mut hasher);
    hasher.finish()
}

pub fn hash_file_paths(paths: &[String]) -> u64 {
    let mut hasher = SeaHasher::new();
    for path in paths {
        path.hash(&mut hasher);
    }
    hasher.finish()
}

pub fn sha256_hex(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn sha256_bytes(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

pub fn normalize_file_paths(paths: Vec<String>) -> Vec<String> {
    paths.into_iter().map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect()
}
