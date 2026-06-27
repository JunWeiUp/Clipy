use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncMessage {
    pub device_id: String,
    pub timestamp: f64,
    #[serde(rename = "type")]
    pub message_type: String,
    pub content: String,
    pub hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileHeader {
    pub file_id: String,
    pub file_name: String,
    pub file_size: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileChunk {
    pub file_id: String,
    pub chunk_index: i32,
    pub data: String,
    pub is_last: bool,
    #[serde(default)]
    pub is_compressed: bool,
    pub original_size: Option<i64>,
}

pub fn encode_frame(message: &SyncMessage) -> Result<Vec<u8>, serde_json::Error> {
    let json = serde_json::to_vec(message)?;
    let len = (json.len() as u32).to_be_bytes();
    let mut frame = Vec::with_capacity(4 + json.len());
    frame.extend_from_slice(&len);
    frame.extend_from_slice(&json);
    Ok(frame)
}

pub fn decode_frames(buffer: &mut Vec<u8>) -> Vec<SyncMessage> {
    let mut messages = Vec::new();
    loop {
        if buffer.len() < 4 {
            break;
        }
        let len = u32::from_be_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
        if buffer.len() < 4 + len {
            break;
        }
        let json = buffer[4..4 + len].to_vec();
        buffer.drain(0..4 + len);
        if let Ok(msg) = serde_json::from_slice::<SyncMessage>(&json) {
            messages.push(msg);
        }
    }
    messages
}
