pub mod crypto;
pub mod global;
pub mod models;
pub mod repo;
pub mod search;
pub mod swift_models;

pub use global::GlobalRepository;
pub use models::*;
pub use repo::ClipboardRepository;

use std::sync::{Arc, RwLock};

pub type SharedRecords = Arc<RwLock<Vec<ClipboardRecord>>>;
