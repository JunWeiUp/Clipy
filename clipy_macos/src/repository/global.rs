use std::sync::Arc;

use gpui::{App, AppContext as _, Global, ReadGlobal};

use super::ClipboardRepository;

#[derive(Clone)]
pub struct GlobalRepository(Option<Arc<ClipboardRepository>>);

impl Global for GlobalRepository {}

impl GlobalRepository {
    pub fn new(repository: Option<Arc<ClipboardRepository>>) -> Self {
        Self(repository)
    }

    pub fn get(&self) -> Option<&Arc<ClipboardRepository>> {
        self.0.as_ref()
    }

    pub fn cloned(&self) -> Option<Arc<ClipboardRepository>> {
        self.0.clone()
    }

    pub fn global(cx: &App) -> Self {
        cx.read_global(|s: &Self, _| s.clone())
    }

    pub fn read<R>(cx: &App, reader: impl FnOnce(Option<&Arc<ClipboardRepository>>) -> R) -> R {
        reader(Self::global(cx).get())
    }
}
