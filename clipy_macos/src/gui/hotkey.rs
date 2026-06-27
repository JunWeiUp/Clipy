use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState, hotkey::HotKey};
use gpui::{App, AsyncApp};

use super::spawn_event_forwarder;

#[derive(Clone)]
enum ListenerMessage {
    UpdateHotkey(String),
    HotkeyEvent(global_hotkey::GlobalHotKeyEvent),
}

struct HotkeyListenerState {
    current_hotkey: String,
    manager: Option<GlobalHotKeyManager>,
}

pub fn start_hotkey_listener<F>(
    initial_hotkey: String,
    cx: &App,
    on_hotkey: F,
) -> async_channel::Sender<String>
where
    F: Fn(&AsyncApp) + Send + Sync + 'static,
{
    let (tx, rx) = async_channel::unbounded::<String>();
    let (message_tx, message_rx) = async_channel::unbounded::<ListenerMessage>();

    spawn_hotkey_event_forwarder(message_tx.clone());
    spawn_hotkey_update_forwarder(rx, message_tx);

    cx.spawn(async move |async_app| {
        let mut state = HotkeyListenerState {
            manager: register_hotkey(&initial_hotkey),
            current_hotkey: initial_hotkey,
        };

        while let Ok(message) = message_rx.recv().await {
            process_listener_message(&mut state, message, &mut || on_hotkey(&async_app));
        }
    })
    .detach();

    tx
}

fn process_listener_message(
    state: &mut HotkeyListenerState,
    message: ListenerMessage,
    on_hotkey: &mut dyn FnMut(),
) {
    match message {
        ListenerMessage::UpdateHotkey(new_hotkey) => {
            if new_hotkey == state.current_hotkey {
                return;
            }
            state.current_hotkey = new_hotkey;
            state.manager = register_hotkey(&state.current_hotkey);
        }
        ListenerMessage::HotkeyEvent(event) => {
            if event.state() == HotKeyState::Pressed {
                on_hotkey();
            }
        }
    }
}

fn spawn_hotkey_event_forwarder(message_tx: async_channel::Sender<ListenerMessage>) {
    let receiver = GlobalHotKeyEvent::receiver().clone();
    spawn_event_forwarder("hotkey-event-forwarder", message_tx, move |forward| {
        while let Ok(event) = receiver.recv() {
            if !forward(Some(ListenerMessage::HotkeyEvent(event))) {
                break;
            }
        }
    });
}

fn spawn_hotkey_update_forwarder(
    update_rx: async_channel::Receiver<String>,
    message_tx: async_channel::Sender<ListenerMessage>,
) {
    spawn_event_forwarder("hotkey-update-forwarder", message_tx, move |forward| {
        while let Ok(hotkey) = update_rx.recv_blocking() {
            if !forward(Some(ListenerMessage::UpdateHotkey(hotkey))) {
                break;
            }
        }
    });
}

fn register_hotkey(hotkey_str: &str) -> Option<GlobalHotKeyManager> {
    if hotkey_str.is_empty() {
        return None;
    }
    let manager = GlobalHotKeyManager::new().ok()?;
    let hotkey: HotKey = hotkey_str.parse().ok()?;
    if manager.register(hotkey).is_err() {
        tracing::warn!(hotkey = hotkey_str, "failed to register global hotkey");
        return None;
    }
    tracing::info!(hotkey = hotkey_str, "global hotkey registered");
    Some(manager)
}
