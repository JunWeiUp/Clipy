pub mod collector;
pub mod history;
pub mod logs;
pub mod notifications;
pub mod settings;
pub mod snippets;

pub(crate) use gpui::{InteractiveElement, IntoElement, ParentElement, Styled};
pub(crate) use gpui::prelude::{FluentBuilder, StatefulInteractiveElement};
pub(crate) use gpui_component::{
    button::ButtonVariants,
    scroll::ScrollableElement,
    ActiveTheme as _, Sizable, StyleSized, StyledExt as _,
};
