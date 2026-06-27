use gpui::{div, px, AnyElement, Context, IntoElement};
use gpui_component::{h_flex, v_flex, input::Input};
use super::{
    ButtonVariants, FluentBuilder, ParentElement, ScrollableElement,
    StatefulInteractiveElement, StyleSized, Styled,
};
use gpui_component::ActiveTheme as _;

use crate::clipboard::CopyRequest;
use crate::collector::CollectorStore;
use crate::gui::board::{ClipyBoard, CollectorCategoryFilter};
use crate::gui::layout::{
    body_text, caption, empty_state, filter_bar, filter_chip, list_row, list_window,
    secondary_text, toolbar, toolbar_btn, toolbar_danger,
};

impl ClipyBoard {
    pub(crate) fn render_collector(&self, cx: &Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let filter = self.collector_filter.to_lowercase();
        let category = self.collector_category;
        let events: Vec<_> = CollectorStore::global()
            .events()
            .into_iter()
            .filter(|e| category.matches(&e.event_type))
            .filter(|e| {
                filter.is_empty()
                    || e.event_type.to_lowercase().contains(&filter)
                    || e.device_id.to_lowercase().contains(&filter)
                    || e.payload.to_string().to_lowercase().contains(&filter)
            })
            .take(200)
            .collect();

        let status = if events.is_empty() {
            self.t(cx, "no_collector_events")
        } else {
            format!("{}: {}", self.t(cx, "collector_event_count"), events.len()).into()
        };

        let tb = v_flex()
            .w_full()
            .child(toolbar(
                vec![toolbar_danger("col-clear", self.t(cx, "action_clear_all"))
                    .on_click(cx.listener(|_, _, _, cx| {
                        CollectorStore::global().clear_all();
                        cx.notify();
                    }))
                    .into_any_element()],
                vec![],
                &theme,
            ))
            .child(filter_bar(
                h_flex()
                    .w_full()
                    .gap_1()
                    .items_center()
                    .children(category_buttons(cx, category, self.t(cx, "filter_all")))
                    .child(div().w(px(220.0)).child(Input::new(&self.collector_filter_input).w_full())),
                &theme,
            ));

        let content = if events.is_empty() {
            empty_state(self.t(cx, "no_collector_events"), &theme).into_any_element()
        } else {
            div().flex_1().overflow_y_scrollbar().child(
                div().children(events.iter().enumerate().map(|(idx, e)| {
                    let title = collector_title(e);
                    let subtitle = collector_subtitle(e);
                    let copy_text = format!("{title}\n{subtitle}");
                    let time = e.received_at.format("%Y-%m-%d %H:%M:%S").to_string();
                    let category_label = e.event_type.clone();
                    list_row(
                        false,
                        &theme,
                        v_flex()
                            .w_full()
                            .gap(px(4.0))
                            .child(
                                h_flex()
                                    .w_full()
                                    .child(caption(category_label, &theme))
                                    .child(div().flex_1())
                                    .child(caption(time, &theme)),
                            )
                            .child(body_text(title, &theme))
                            .when(!subtitle.is_empty(), |v| {
                                v.child(secondary_text(subtitle, &theme))
                            })
                            .child(
                                h_flex()
                                    .w_full()
                                    .items_center()
                                    .child(caption(e.device_id.clone(), &theme))
                                    .child(div().flex_1())
                                    .child(
                                        toolbar_btn(("col-copy", idx as u64), self.t(cx, "action_copy"))
                                            .on_click(cx.listener(move |this, _, _, cx| {
                                                let _ = this.copy_tx.try_send(CopyRequest::Text {
                                                    text: copy_text.clone(),
                                                    paste: false,
                                                });
                                                cx.notify();
                                            })),
                                    ),
                            ),
                    )
                    .into_any_element()
                })),
            )
            .into_any_element()
        };

        list_window(tb, content, status, &theme).into_any_element()
    }
}

fn category_buttons(
    cx: &Context<ClipyBoard>,
    current: CollectorCategoryFilter,
    all: gpui::SharedString,
) -> Vec<gpui::AnyElement> {
    [
        (CollectorCategoryFilter::All, "col-all", all),
        (CollectorCategoryFilter::Notification, "col-notif", "Notification".into()),
        (CollectorCategoryFilter::Sms, "col-sms", "SMS".into()),
        (CollectorCategoryFilter::Call, "col-call", "Call".into()),
        (CollectorCategoryFilter::Clipboard, "col-clip", "Clipboard".into()),
    ]
    .into_iter()
    .map(|(cat, id, label)| {
        filter_chip(id, label, current == cat)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.collector_category = cat;
                cx.notify();
            }))
            .into_any_element()
    })
    .collect()
}

fn collector_title(e: &crate::collector::CollectorEvent) -> String {
    let p = &e.payload;
    match e.event_type.as_str() {
        "notification" => p
            .get("title")
            .or_else(|| p.get("appName"))
            .and_then(|v| v.as_str())
            .unwrap_or("Notification")
            .to_string(),
        "sms" => p
            .get("address")
            .and_then(|v| v.as_str())
            .unwrap_or("SMS")
            .to_string(),
        "clipboard" => "Clipboard".to_string(),
        _ => e.event_type.clone(),
    }
}

fn collector_subtitle(e: &crate::collector::CollectorEvent) -> String {
    let p = &e.payload;
    match e.event_type.as_str() {
        "notification" => p
            .get("body")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        "sms" => p.get("body").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        "clipboard" => p
            .get("text")
            .and_then(|v| v.as_str())
            .map(|s| s.chars().take(200).collect())
            .unwrap_or_default(),
        _ => p.to_string().chars().take(120).collect(),
    }
}
