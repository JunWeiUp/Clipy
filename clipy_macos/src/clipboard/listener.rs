use std::sync::{Arc, Mutex};
use std::thread;

use async_channel::Sender;
use clipboard_rs::{
    Clipboard, ClipboardContext, ClipboardHandler, ClipboardWatcher, ClipboardWatcherContext,
    ContentFormat, common::RustImage,
};
use image::DynamicImage;

use super::{ClipboardEvent, LastCopyState};
use crate::utils::{hash_file_paths, normalize_file_paths};

struct Monitor {
    tx: Sender<ClipboardEvent>,
    image_tx: Sender<(DynamicImage, u64)>,
    last_copy: Arc<Mutex<LastCopyState>>,
}

impl ClipboardHandler for Monitor {
    fn on_clipboard_change(&mut self) {
        let ctx = match ClipboardContext::new() {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!(error = %e, "clipboard context failed");
                return;
            }
        };
        let (source_app, source_bundle_id) = frontmost_app_info();
        if let Some(paths) = ctx.get_files().ok().map(|p| normalize_file_paths(p)) {
            if !paths.is_empty() {
                let hash = hash_file_paths(&paths);
                if should_forward_files(&self.last_copy, hash) {
                    let event = ClipboardEvent::Files {
                        paths,
                        source_app,
                        source_bundle_id,
                    };
                    if self.tx.try_send(event).is_ok() {
                        if let Ok(mut lc) = self.last_copy.lock() {
                            *lc = LastCopyState::Files(hash);
                        }
                    }
                }
                return;
            }
        }
        if let Ok(text) = ctx.get_text() {
            if !text.is_empty() {
                let has_html = ctx.has(ContentFormat::Html);
                let has_rtf = ctx.has(ContentFormat::Rtf);
                if has_html || has_rtf {
                    let html = has_html.then(|| ctx.get_html().ok()).flatten();
                    let rtf = has_rtf.then(|| ctx.get_rich_text().ok()).flatten();
                    if should_forward_text(&self.last_copy, &text) {
                        let event = ClipboardEvent::RichText {
                            plain_text: text.clone(),
                            html,
                            rtf,
                            source_app,
                            source_bundle_id,
                        };
                        if self.tx.try_send(event).is_ok() {
                            if let Ok(mut lc) = self.last_copy.lock() {
                                *lc = LastCopyState::RichText(text);
                            }
                        }
                    }
                    return;
                }
                if should_forward_text(&self.last_copy, &text) {
                    let event = ClipboardEvent::Text {
                        text: text.clone(),
                        source_app,
                        source_bundle_id,
                    };
                    if self.tx.try_send(event).is_ok() {
                        if let Ok(mut lc) = self.last_copy.lock() {
                            *lc = LastCopyState::Text(text);
                        }
                    }
                }
                return;
            }
        }
        if let Ok(img) = ctx.get_image() {
            if let Ok(dynamic) = img.get_dynamic_image() {
                let hash = hash_image(&dynamic);
                if should_forward_image(&self.last_copy, hash) {
                    let _ = self.image_tx.try_send((dynamic, hash));
                }
            }
        }
    }
}

pub fn start(tx: Sender<ClipboardEvent>, last_copy: Arc<Mutex<LastCopyState>>) {
    let (image_tx, image_rx) = async_channel::bounded::<(DynamicImage, u64)>(1);
    let tx_image = tx.clone();
    let last_copy_image = last_copy.clone();
    thread::spawn(move || {
        while let Ok((img, hash)) = image_rx.recv_blocking() {
            if let Some(path) = save_image(&img, hash) {
                let (source_app, source_bundle_id) = frontmost_app_info();
                let event = ClipboardEvent::Image {
                    path,
                    hash,
                    source_app,
                    source_bundle_id,
                };
                if tx_image.try_send(event).is_ok() {
                    if let Ok(mut lc) = last_copy_image.lock() {
                        *lc = LastCopyState::Image(hash);
                    }
                }
            }
        }
    });
    thread::spawn(move || {
        let monitor = Monitor {
            tx,
            image_tx,
            last_copy,
        };
        match ClipboardWatcherContext::new() {
            Ok(mut watcher) => {
                watcher.add_handler(monitor);
                let _ = watcher.start_watch();
            }
            Err(e) => tracing::error!(error = %e, "failed to create clipboard watcher"),
        }
        loop {
            thread::sleep(std::time::Duration::from_secs(3600));
        }
    });
}

fn should_forward_text(last_copy: &Arc<Mutex<LastCopyState>>, text: &str) -> bool {
    last_copy
        .lock()
        .map(|lc| !matches!(&*lc, LastCopyState::Text(s) if s == text))
        .unwrap_or(true)
}

fn should_forward_image(last_copy: &Arc<Mutex<LastCopyState>>, hash: u64) -> bool {
    last_copy
        .lock()
        .map(|lc| !matches!(&*lc, LastCopyState::Image(h) if *h == hash))
        .unwrap_or(true)
}

fn should_forward_files(last_copy: &Arc<Mutex<LastCopyState>>, hash: u64) -> bool {
    last_copy
        .lock()
        .map(|lc| !matches!(&*lc, LastCopyState::Files(h) if *h == hash))
        .unwrap_or(true)
}

fn hash_image(img: &DynamicImage) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = seahash::SeaHasher::new();
    img.width().hash(&mut hasher);
    img.height().hash(&mut hasher);
    hasher.finish()
}

fn save_image(img: &DynamicImage, hash: u64) -> Option<String> {
    let dir = crate::utils::images_dir()?;
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("{hash}.png"));
    img.save(&path).ok()?;
    Some(path.to_string_lossy().into_owned())
}

#[cfg(target_os = "macos")]
fn frontmost_app_info() -> (Option<String>, Option<String>) {
    use objc2_app_kit::NSWorkspace;
    unsafe {
        let workspace = NSWorkspace::sharedWorkspace();
        let Some(app) = workspace.frontmostApplication() else {
            return (None, None);
        };
        let name = app.localizedName().map(|s| s.to_string());
        let bundle = app.bundleIdentifier().map(|s| s.to_string());
        (name, bundle)
    }
}

#[cfg(not(target_os = "macos"))]
fn frontmost_app_info() -> (Option<String>, Option<String>) {
    (None, None)
}
