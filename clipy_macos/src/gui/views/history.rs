use gpui::{div, px, AnyElement, Context, IntoElement, Window};
use gpui_component::{h_flex, v_flex, button::Button, input::Input};
use super::{
    ButtonVariants, FluentBuilder, InteractiveElement, ParentElement, ScrollableElement,
    StatefulInteractiveElement, StyleSized, Styled,
};
use gpui_component::ActiveTheme as _;

use crate::gui::board::{ClipyBoard, HistoryContentCategory, HistoryDateFilter, HistoryTypeFilter};
use crate::gui::layout::{
    body_text, caption, empty_state, filter_bar, filter_chip, list_row, list_window,
    mono_badge, preview_body, preview_header, secondary_text, split_pane, table_header,
    toolbar_btn, window_header,
};
use crate::gui::panels::{format_record_time, record_location, record_preview, record_title, type_icon};
use crate::repository::ContentType;
use crate::repository::GlobalRepository;

impl ClipyBoard {
    pub(crate) fn render_history(&mut self, window: &mut Window, cx: &mut Context<Self>) -> gpui::AnyElement {
        self.render_history_search(window, cx)
    }

    fn render_history_compact(&mut self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let records = self.filter_records.clone();
        let status = self.history_status.clone();
        let can_load_more = self.can_load_more_history(cx);

        let list = self.build_history_list(&records, can_load_more, cx);
        list_window(
            v_flex()
                .w_full()
                .child(
                    h_flex()
                        .w_full()
                        .gap_2()
                        .px(px(10.0))
                        .py(px(8.0))
                        .child(div().flex_1().child(Input::new(&self.search_input).w_full()))
                        .child(
                            toolbar_btn("hist-copy", self.t(cx, "action_copy"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.confirm_selection(cx, false);
                                })),
                        )
                        .child(
                            toolbar_btn("hist-pin", self.t(cx, "pin"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.toggle_pin_selected(cx);
                                })),
                        ),
                ),
            list,
            status,
            &theme,
        )
        .into_any_element()
    }

    fn render_history_search(&mut self, window: &mut Window, cx: &mut Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let records = self.filter_records.clone();
        let status = self.history_status.clone();
        let use_regex = self.history_use_regex;
        let type_filter = self.history_type_filter;
        let date_filter = self.history_date_filter;
        let source_app = self.history_source_app.clone();
        let category = self.history_category;
        let can_load_more = self.can_load_more_history(cx);

        let header = window_header(
            v_flex()
                .w_full()
                .gap_1()
                .child(
                    h_flex()
                        .w_full()
                        .gap_2()
                        .child(div().flex_1().child(Input::new(&self.search_input).w_full()))
                        .child(
                            filter_chip("hist-regex", self.t(cx, "history_regex"), use_regex)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.history_use_regex = !this.history_use_regex;
                                    this.recompute_filter(cx);
                                    cx.notify();
                                })),
                        ),
                )
                .child(
                    filter_bar(
                        h_flex()
                            .w_full()
                            .gap_1()
                            .flex_wrap()
                            .children(type_filter_buttons(
                                cx,
                                type_filter,
                                self.t(cx, "filter_all"),
                                self.t(cx, "filter_text"),
                                self.t(cx, "filter_image"),
                                self.t(cx, "filter_file"),
                                self.t(cx, "filter_rich"),
                            ))
                            .child(
                                filter_chip(
                                    "hist-src",
                                    if source_app.is_empty() {
                                        self.t(cx, "filter_all_sources")
                                    } else {
                                        source_app.clone().into()
                                    },
                                    !source_app.is_empty(),
                                )
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.cycle_source_app(cx);
                                })),
                            )
                            .children(date_filter_buttons(
                                cx,
                                date_filter,
                                self.t(cx, "filter_all"),
                                self.t(cx, "filter_today"),
                                self.t(cx, "filter_week"),
                                self.t(cx, "filter_month"),
                            )),
                        &theme,
                    ),
                )
                .child(
                    filter_bar(
                        h_flex()
                            .w_full()
                            .gap_1()
                            .overflow_x_scrollbar()
                            .children(category_chips(cx, category, self.t(cx, "filter_all"))),
                        &theme,
                    ),
                )
                .when(can_load_more, |v| {
                    v.child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .px(px(10.0))
                            .py(px(4.0))
                            .child(
                                toolbar_btn("hist-load-more", self.t(cx, "history_load_more"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.load_more_history(cx);
                                        cx.notify();
                                    })),
                            ),
                    )
                }),
            &theme,
        );

        let list = self.build_history_table(&records, can_load_more, cx);
        let preview = self
            .selected_record(cx)
            .map(|r| self.build_history_preview(&r, cx))
            .unwrap_or_else(|| empty_state(self.t(cx, "select_history_item"), &theme).into_any_element());

        let content = split_pane(
            v_flex()
                .size_full()
                .child(table_header(
                    &[
                        (self.t(cx, "col_content").as_ref(), 0.0),
                        (self.t(cx, "col_location").as_ref(), 120.0),
                        (self.t(cx, "col_source").as_ref(), 100.0),
                        (self.t(cx, "col_time").as_ref(), 120.0),
                    ],
                    &theme,
                ))
                .child(div().flex_1().overflow_y_scrollbar().child(list)),
            preview,
            &theme,
            420.0,
        );

        list_window(header, content, status, &theme).into_any_element()
    }

    fn build_history_list(
        &self,
        records: &[crate::repository::ClipboardRecord],
        can_load_more: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme().clone();
        if self.filtered_indices.is_empty() {
            return empty_state(self.t(cx, "no_records"), &theme).into_any_element();
        }
        v_flex()
            .children(self.filtered_indices.iter().enumerate().map(|(vis_idx, &rec_idx)| {
                let record = records.get(rec_idx);
                let title = record.map(record_title).unwrap_or_default();
                let selected = vis_idx == self.selected_index;
                list_row(selected, &theme, body_text(title, &theme))
                    .id(("record", rec_idx as u64))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected_index = vis_idx;
                        cx.notify();
                    }))
                    .into_any_element()
            }))
            .when(can_load_more, |v| {
                v.child(
                    h_flex()
                        .w_full()
                        .justify_end()
                        .px(px(10.0))
                        .py(px(8.0))
                        .child(
                            toolbar_btn("hist-load-more-compact", self.t(cx, "history_load_more"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.load_more_history(cx);
                                    cx.notify();
                                })),
                        ),
                )
            })
            .into_any_element()
    }

    fn build_history_table(
        &self,
        records: &[crate::repository::ClipboardRecord],
        can_load_more: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme().clone();
        if self.filtered_indices.is_empty() {
            return empty_state(self.t(cx, "no_records"), &theme).into_any_element();
        }
        div()
            .children(self.filtered_indices.iter().enumerate().map(|(vis_idx, &rec_idx)| {
                let record = records.get(rec_idx);
                let title = record.map(record_title).unwrap_or_default();
                let location = record.map(record_location).unwrap_or_default();
                let source = record
                    .and_then(|r| r.source_app.clone())
                    .unwrap_or_default();
                let time = record.map(|r| format_record_time(&r.created_at)).unwrap_or_default();
                let icon = record.map(|r| type_icon(r.content_type.clone())).unwrap_or("?");
                let pinned = record.map(|r| r.pinned).unwrap_or(false);
                let selected = vis_idx == self.selected_index;

                list_row(
                    selected,
                    &theme,
                    h_flex()
                        .w_full()
                        .gap_2()
                        .items_center()
                        .child(mono_badge(icon, &theme))
                        .when(pinned, |d| {
                            d.child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(gpui::rgb(0xf97316))
                                    .child("PIN"),
                            )
                        })
                        .child(div().flex_1().text_size(px(13.0)).text_color(theme.foreground).child(title))
                        .child(div().w(px(120.0)).child(secondary_text(location, &theme)))
                        .child(div().w(px(100.0)).child(secondary_text(source, &theme)))
                        .child(div().w(px(120.0)).child(secondary_text(time, &theme))),
                )
                .id(("hist-row", rec_idx as u64))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.selected_index = vis_idx;
                    cx.notify();
                }))
                .into_any_element()
            }))
            .when(can_load_more, |d| {
                d.child(
                    h_flex()
                        .w_full()
                        .justify_end()
                        .px(px(10.0))
                        .py(px(8.0))
                        .child(
                            toolbar_btn("hist-load-more-table", self.t(cx, "history_load_more"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.load_more_history(cx);
                                    cx.notify();
                                })),
                        ),
                )
            })
            .into_any_element()
    }

    fn build_history_preview(
        &self,
        record: &crate::repository::ClipboardRecord,
        cx: &Context<Self>,
    ) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let preview = record_preview(record);
        let source = record.source_app.clone().unwrap_or_default();
        let time = format_record_time(&record.created_at);
        let type_name = match record.content_type {
            ContentType::Text => self.t(cx, "filter_text"),
            ContentType::Image => self.t(cx, "filter_image"),
            ContentType::FilePath => self.t(cx, "filter_file"),
            _ => self.t(cx, "filter_rich"),
        };
        let header_title = format!("{} - {type_name}", self.t(cx, "col_type"));

        v_flex()
            .size_full()
            .child(preview_header(header_title, &theme))
            .child(
                v_flex()
                    .px(px(14.0))
                    .py(px(8.0))
                    .gap_1()
                    .child(caption(format!("{}: {time}", self.t(cx, "col_time")), &theme))
                    .when(!source.is_empty(), |v| {
                        v.child(caption(format!("{}: {source}", self.t(cx, "col_source")), &theme))
                    }),
            )
            .child(
                preview_body(
                    div()
                        .text_size(px(13.0))
                        .line_height(px(20.0))
                        .text_color(theme.foreground)
                        .child(preview),
                    &theme,
                ),
            )
            .into_any_element()
    }

    pub(crate) fn toggle_pin_selected(&mut self, cx: &mut Context<Self>) {
        if let Some(record) = self.selected_record(cx) {
            GlobalRepository::read(cx, |repo| {
                if let Some(r) = repo {
                    let _ = r.toggle_pin(record.id);
                }
            });
            self.refresh_from_repo(cx);
            cx.notify();
        }
    }

    fn available_source_apps(&self, records: &[crate::repository::ClipboardRecord]) -> Vec<String> {
        let mut apps: Vec<String> = records
            .iter()
            .filter_map(|r| r.source_app.clone())
            .collect();
        apps.sort();
        apps.dedup();
        apps
    }

    fn cycle_source_app(&mut self, cx: &mut Context<Self>) {
        let records = GlobalRepository::read(cx, |repo| {
            repo.and_then(|r| r.get_display_records(usize::MAX).ok())
        })
        .unwrap_or_else(|| self.filter_records.clone());
        let apps = self.available_source_apps(&records);
        if apps.is_empty() {
            self.history_source_app.clear();
        } else if self.history_source_app.is_empty() {
            self.history_source_app = apps[0].clone();
        } else if let Some(idx) = apps.iter().position(|a| a == &self.history_source_app) {
            self.history_source_app = apps.get(idx + 1).cloned().unwrap_or_default();
        } else {
            self.history_source_app.clear();
        }
        self.recompute_filter(cx);
        cx.notify();
    }
}

fn type_filter_buttons(
    cx: &mut Context<ClipyBoard>,
    current: HistoryTypeFilter,
    all: gpui::SharedString,
    text: gpui::SharedString,
    image: gpui::SharedString,
    file: gpui::SharedString,
    rich: gpui::SharedString,
) -> Vec<gpui::AnyElement> {
    [
        (HistoryTypeFilter::All, "type-all", all),
        (HistoryTypeFilter::Text, "type-text", text),
        (HistoryTypeFilter::Image, "type-image", image),
        (HistoryTypeFilter::File, "type-file", file),
        (HistoryTypeFilter::RichText, "type-rich", rich),
    ]
    .into_iter()
    .map(|(filter, id, label)| {
        filter_chip(id, label, current == filter)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.history_type_filter = filter;
                this.recompute_filter(cx);
                cx.notify();
            }))
            .into_any_element()
    })
    .collect()
}

fn date_filter_buttons(
    cx: &mut Context<ClipyBoard>,
    current: HistoryDateFilter,
    all: gpui::SharedString,
    today: gpui::SharedString,
    week: gpui::SharedString,
    month: gpui::SharedString,
) -> Vec<gpui::AnyElement> {
    [
        (HistoryDateFilter::All, "date-all", all),
        (HistoryDateFilter::Today, "date-today", today),
        (HistoryDateFilter::Week, "date-week", week),
        (HistoryDateFilter::Month, "date-month", month),
    ]
    .into_iter()
    .map(|(filter, id, label)| {
        filter_chip(id, label, current == filter)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.history_date_filter = filter;
                this.recompute_filter(cx);
                cx.notify();
            }))
            .into_any_element()
    })
    .collect()
}

fn category_chips(
    cx: &mut Context<ClipyBoard>,
    current: Option<HistoryContentCategory>,
    all_label: gpui::SharedString,
) -> Vec<gpui::AnyElement> {
    let categories: [(Option<HistoryContentCategory>, &str, gpui::SharedString); 4] = [
        (None, "cat-all", all_label),
        (Some(HistoryContentCategory::Url), "cat-url", "URL".into()),
        (Some(HistoryContentCategory::Code), "cat-code", "Code".into()),
        (Some(HistoryContentCategory::Email), "cat-email", "Email".into()),
    ];
    categories
        .into_iter()
        .map(|(cat, id, label)| {
            filter_chip(id, label, current == cat)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.history_category = cat;
                    this.recompute_filter(cx);
                    cx.notify();
                }))
                .into_any_element()
        })
        .collect()
}
