use gpui::{div, px, AnyElement, Context, IntoElement};
use gpui_component::v_flex;
use super::{
    ButtonVariants, FluentBuilder, InteractiveElement, ParentElement, ScrollableElement,
    StatefulInteractiveElement, StyleSized, Styled,
};
use gpui_component::ActiveTheme as _;

use crate::gui::board::ClipyBoard;
use crate::gui::layout::{
    body_text, caption, empty_state, list_row, list_window, secondary_text, toolbar, toolbar_btn,
};
use crate::notification::NotificationStore;

impl ClipyBoard {
    pub(crate) fn render_notifications(&self, cx: &Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let entries = NotificationStore::global().active_entries();
        let count = entries.len();
        let status = if count == 0 {
            self.t(cx, "no_notifications")
        } else {
            format!("{}: {count}", self.t(cx, "phone_notifications")).into()
        };

        let tb = toolbar(
            vec![toolbar_btn("notif-clear-local", self.t(cx, "action_clear_local"))
                .on_click(cx.listener(|_, _, _, cx| {
                    NotificationStore::global().dismiss_all();
                    cx.notify();
                }))
                .into_any_element()],
            vec![toolbar_btn("notif-copy", self.t(cx, "action_copy"))
                .on_click(cx.listener(|this, _, _, cx| {
                    let text = NotificationStore::global()
                        .active_entries()
                        .iter()
                        .map(|e| format!("{} - {}\n{}", e.title, e.body, e.package_name))
                        .collect::<Vec<_>>()
                        .join("\n\n");
                    let _ = this.copy_tx.try_send(crate::clipboard::CopyRequest::Text {
                        text,
                        paste: false,
                    });
                    cx.notify();
                }))
                .into_any_element()],
            &theme,
        );

        let content = if entries.is_empty() {
            empty_state(self.t(cx, "no_notifications"), &theme).into_any_element()
        } else {
            div().flex_1().overflow_y_scrollbar().child(
                div().children(entries.iter().enumerate().map(|(idx, e)| {
                    list_row(
                        false,
                        &theme,
                        v_flex()
                            .w_full()
                            .gap(px(4.0))
                            .child(body_text(e.title.clone(), &theme))
                            .child(secondary_text(e.body.clone(), &theme))
                            .child(caption(e.package_name.clone(), &theme)),
                    )
                    .id(("notif", idx as u64))
                    .into_any_element()
                })),
            )
            .into_any_element()
        };

        list_window(tb, content, status, &theme).into_any_element()
    }
}
