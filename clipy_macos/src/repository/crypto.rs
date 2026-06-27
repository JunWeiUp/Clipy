use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use security_framework::passwords::{get_generic_password, set_generic_password};

const KEYCHAIN_SERVICE: &str = "com.yourdomain.ClipyClone.history-key";
const KEYCHAIN_ACCOUNT: &str = "default";

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("keychain error: {0}")]
    Keychain(String),
    #[error("encrypt error")]
    Encrypt,
    #[error("decrypt error")]
    Decrypt,
    #[error("invalid payload")]
    InvalidPayload,
}

pub fn load_or_create_key() -> Result<[u8; 32], CryptoError> {
    if let Ok(data) = get_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT) {
        if data.len() == 32 {
            let mut key = [0u8; 32];
            key.copy_from_slice(&data);
            return Ok(key);
        }
    }
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).map_err(|e| CryptoError::Keychain(e.to_string()))?;
    set_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, &key)
        .map_err(|e| CryptoError::Keychain(e.to_string()))?;
    Ok(key)
}

pub fn encrypt(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, CryptoError> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| CryptoError::Encrypt)?;
    let mut nonce_bytes = [0u8; 12];
    getrandom::fill(&mut nonce_bytes).map_err(|_| CryptoError::Encrypt)?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, data)
        .map_err(|_| CryptoError::Encrypt)?;
    let mut out = Vec::with_capacity(12 + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

pub fn decrypt(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, CryptoError> {
    if data.len() <= 28 {
        return Err(CryptoError::InvalidPayload);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| CryptoError::Decrypt)?;
    let nonce = Nonce::from_slice(&data[..12]);
    let ciphertext = &data[12..];
    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| CryptoError::Decrypt)
}

