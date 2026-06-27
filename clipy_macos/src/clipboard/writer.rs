use clipboard_rs::{Clipboard, ClipboardContent, ClipboardContext};
use gpui::{App, AppContext as _};
use image::ImageReader;

use super::CopyRequest;
use crate::config::{ConfirmMode, Settings};

pub fn start(cx: &App) -> async_channel::Sender<CopyRequest> {
    let (tx, rx) = async_channel::unbounded();
    cx.background_spawn(async move {
        let ctx = match ClipboardContext::new() {
            Ok(c) => c,
            Err(e) => {
                tracing::error!(error = %e, "clipboard writer init failed");
                return;
            }
        };
        while let Ok(req) = rx.recv().await {
            match req {
                CopyRequest::Text { text, paste } => {
                    let _ = ctx.set_text(text);
                    if paste {
                        simulate_paste();
                    }
                }
                CopyRequest::Image { path, paste } => {
                    set_image(&ctx, &path);
                    if paste {
                        simulate_paste();
                    }
                }
                CopyRequest::Files { paths, paste } => {
                    set_files(&ctx, &paths);
                    if paste {
                        simulate_paste();
                    }
                }
                CopyRequest::RichText {
                    plain_text,
                    html,
                    rtf,
                    paste,
                } => {
                    set_rich_text(&ctx, plain_text, html, rtf);
                    if paste {
                        simulate_paste();
                    }
                }
            }
        }
    })
    .detach();
    tx
}

pub fn should_paste_immediately(cx: &App) -> bool {
    Settings::read(cx, |s| s.confirm.mode == ConfirmMode::PasteImmediately)
}

fn set_image(ctx: &ClipboardContext, path: &str) {
    if let Ok(img) = ImageReader::open(path).map_err(image::ImageError::from).and_then(|r| r.decode()) {
        let mut bytes = Vec::new();
        if img
            .write_to(
                &mut std::io::Cursor::new(&mut bytes),
                image::ImageFormat::Png,
            )
            .is_ok()
        {
            let _ = ctx.set_buffer("public.png", bytes);
        }
    }
}

fn set_files(ctx: &ClipboardContext, paths: &[String]) {
    if paths.is_empty() {
        return;
    }
    let contents = vec![
        ClipboardContent::Text(paths.join("\n")),
        ClipboardContent::Files(paths.to_vec()),
    ];
    if ctx.set(contents).is_err() {
        let _ = ctx.set_files(paths.to_vec());
    }
}

fn set_rich_text(
    ctx: &ClipboardContext,
    plain_text: String,
    html: Option<String>,
    rtf: Option<String>,
) {
    let mut contents = vec![ClipboardContent::Text(plain_text.clone())];
    if let Some(h) = html {
        contents.push(ClipboardContent::Html(h));
    }
    if let Some(r) = rtf {
        contents.push(ClipboardContent::Rtf(r));
    }
    if ctx.set(contents).is_err() {
        let _ = ctx.set_text(plain_text);
    }
}

fn simulate_paste() {
    use enigo::{Direction, Enigo, Key, Keyboard, Settings};
    if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
        #[cfg(target_os = "macos")]
        {
            let _ = enigo.key(Key::Meta, Direction::Press);
            let _ = enigo.key(Key::Unicode('v'), Direction::Click);
            let _ = enigo.key(Key::Meta, Direction::Release);
        }
    }
}
