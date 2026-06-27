use gpui::{div, px, AnyElement, Context, IntoElement};
use gpui_component::{h_flex, input::Input};
use super::{
    ButtonVariants, FluentBuilder, InteractiveElement, ParentElement, ScrollableElement,
    StatefulInteractiveElement, StyleSized, Styled,
};
use gpui_component::ActiveTheme as _;

use crate::clipboard::CopyRequest;
use crate::gui::board::ClipyBoard;
use crate::gui::layout::{
    empty_state, level_badge, list_row, list_window, toolbar_btn, window_header,
};
use crate::utils::log_buffer;

impl ClipyBoard {
    pub(crate) fn render_logs(&self, cx: &Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let filter = self.logs_filter.to_lowercase();
        let entries: Vec<_> = log_buffer::entries()
            .into_iter()
            .filter(|e| {
                filter.is_empty()
                    || e.message.to_lowercase().contains(&filter)
                    || e.level.to_lowercase().contains(&filter)
            })
            .collect();

        let status = format!("{}: {}", self.t(cx, "search_result_count"), entries.len());

        let header = window_header(
            h_flex()
                .w_full()
                .gap_2()
                .child(div().flex_1().child(Input::new(&self.logs_filter_input).w_full()))
                .child(
                    toolbar_btn("log-copy", self.t(cx, "action_copy_all"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            let text = log_buffer::entries()
                                .iter()
                                .map(|e| format!("[{}] [{}] {}", e.timestamp, e.level, e.message))
                                .collect::<Vec<_>>()
                                .join("\n");
                            let _ = this.copy_tx.try_send(CopyRequest::Text { text, paste: false });
                            cx.notify();
                        })),
                )
                .child(
                    toolbar_btn("log-clear", self.t(cx, "action_clear_all"))
                        .on_click(cx.listener(|_, _, _, cx| {
                            log_buffer::clear();
                            cx.notify();
                        })),
                ),
            &theme,
        );

        let content = if entries.is_empty() {
            empty_state(self.t(cx, "no_logs"), &theme).into_any_element()
        } else {
            div().flex_1().overflow_y_scrollbar().child(
                div().children(entries.iter().enumerate().map(|(idx, e)| {
                    list_row(
                        false,
                        &theme,
                        h_flex()
                            .w_full()
                            .gap_2()
                            .items_start()
                            .child(
                                div()
                                    .w(px(85.0))
                                    .text_size(px(11.0))
                                    .font_family(theme.mono_font_family.clone())
                                    .text_color(crate::gui::layout::text_tertiary(&theme))
                                    .child(e.timestamp.clone()),
                            )
                            .child(level_badge(&e.level))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px(13.0))
                                    .line_height(px(18.0))
                                    .text_color(theme.foreground)
                                    .child(e.message.clone()),
                            ),
                    )
                    .id(("log", idx as u64))
                    .into_any_element()
                })),
            )
            .into_any_element()
        };

        list_window(header, content, status, &theme).into_any_element()
    }
}
