use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::config::SyncSettings;
use crate::constants::SYNC_SERVICE_TYPE;

static DISCOVERED: once_cell::sync::Lazy<Arc<Mutex<Vec<String>>>> =
    once_cell::sync::Lazy::new(|| Arc::new(Mutex::new(Vec::new())));

pub fn start(settings: SyncSettings) {
    std::thread::spawn(move || {
        if let Err(e) = register_service(&settings) {
            tracing::warn!(error = %e, "bonjour register failed");
        }
        if let Err(e) = browse_services() {
            tracing::warn!(error = %e, "bonjour browse failed");
        }
    });
}

fn register_service(settings: &SyncSettings) -> Result<(), String> {
    let service = mdns_sd::ServiceInfo::new(
        SYNC_SERVICE_TYPE,
        &settings.device_name,
        settings.device_name.as_str(),
        "",
        settings.port,
        None,
    )
    .map_err(|e| e.to_string())?;
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
    daemon.register(service).map_err(|e| e.to_string())?;
    std::mem::forget(daemon);
    Ok(())
}

fn browse_services() -> Result<(), String> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
    let receiver = daemon.browse(SYNC_SERVICE_TYPE).map_err(|e| e.to_string())?;
    loop {
        match receiver.recv() {
            Ok(event) => {
                if let mdns_sd::ServiceEvent::ServiceResolved(info) = event {
                    let name = info.get_fullname().to_string();
                    if let Ok(mut list) = DISCOVERED.lock() {
                        if !list.contains(&name) {
                            list.push(name);
                        }
                    }
                }
            }
            Err(_) => break,
        }
    }
    Ok(())
}

pub fn discovered_devices() -> Vec<String> {
    DISCOVERED.lock().map(|l| l.clone()).unwrap_or_default()
}
