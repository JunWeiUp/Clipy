use gpui::{div, px, AnyElement, Context, IntoElement, Window};
use gpui_component::{h_flex, v_flex, button::Button, input::Input};
use super::{
    ButtonVariants, FluentBuilder, InteractiveElement, ParentElement, Sizable, ScrollableElement,
    StatefulInteractiveElement, StyleSized, Styled,
};
use gpui_component::ActiveTheme as _;

use crate::clipboard::CopyRequest;
use crate::gui::board::ClipyBoard;
use crate::gui::layout::{
    body_text, detail_column, empty_state, field_label, list_row, mono_badge, sidebar_column,
    toolbar, toolbar_btn,
};
use crate::gui::macos_dialog::pick_files;
use crate::snippet::SnippetStore;

impl ClipyBoard {
    pub(crate) fn render_snippets(&mut self, window: &mut Window, cx: &mut Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let folders = SnippetStore::global().folders();
        let selected_folder = self.selected_folder_id.clone();
        let selected_snippet = self.selected_snippet_id.clone();

        let mut sidebar_rows: Vec<gpui::AnyElement> = Vec::new();
        for (fi, folder) in folders.into_iter().enumerate() {
            let folder_id = folder.id.clone();
            let folder_name = folder.name.clone();
            let folder_selected =
                selected_folder.as_deref() == Some(folder_id.as_str()) && selected_snippet.is_none();
            sidebar_rows.push(
                list_row(
                    folder_selected,
                    &theme,
                    h_flex()
                        .gap_2()
                        .items_center()
                        .child(mono_badge("D", &theme))
                        .child(body_text(folder_name, &theme)),
                )
                .id(("folder", fi as u64))
                .on_click({
                    let fid = folder_id.clone();
                    cx.listener(move |this, _, window, cx| {
                        this.selected_folder_id = Some(fid.clone());
                        this.selected_snippet_id = None;
                        this.load_snippet_draft(window, cx);
                        cx.notify();
                    })
                })
                .into_any_element(),
            );
            for (si, snippet) in folder.snippets.into_iter().enumerate() {
                let sid = snippet.id.clone();
                let title = snippet.title.clone();
                let selected = selected_snippet.as_deref() == Some(sid.as_str());
                sidebar_rows.push(
                    list_row(selected, &theme, body_text(title, &theme))
                        .pl(px(28.0))
                        .id(("snippet", (fi * 1000 + si) as u64))
                        .on_click({
                            let sid = sid.clone();
                            cx.listener(move |this, _, window, cx| {
                                this.selected_snippet_id = Some(sid.clone());
                                this.selected_folder_id = None;
                                this.load_snippet_draft(window, cx);
                                cx.notify();
                            })
                        })
                        .into_any_element(),
                );
            }
        }

        let detail = if selected_snippet.is_some() || selected_folder.is_some() {
            detail_column(
                v_flex()
                    .w_full()
                    .gap_2()
                    .child(field_label(
                        if selected_snippet.is_some() {
                            self.t(cx, "snippet_title")
                        } else {
                            self.t(cx, "folder_name")
                        },
                        &theme,
                    ))
                    .child(Input::new(&self.snippet_title_input).w_full())
                    .when(selected_snippet.is_some(), |v| {
                        v.child(field_label(self.t(cx, "snippet_content"), &theme))
                            .child(Input::new(&self.snippet_content_input).flex_1().w_full())
                    })
                    .child(
                        h_flex()
                            .gap_1()
                            .child(
                                Button::new("snip-save")
                                    .label(self.t(cx, "action_save"))
                                    .primary()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.save_snippet_draft(cx);
                                    })),
                            )
                            .child(
                                toolbar_btn("snip-del", self.t(cx, "delete"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        if let Some(id) = this.selected_snippet_id.take() {
                                            SnippetStore::global().delete_snippet(&id);
                                        } else if let Some(id) = this.selected_folder_id.take() {
                                            SnippetStore::global().delete_folder(&id);
                                        }
                                        crate::gui::tray::TrayState::refresh_menu(cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                toolbar_btn("snip-copy", self.t(cx, "action_copy"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let content =
                                            this.snippet_content_input.read(cx).value().to_string();
                                        let _ = this.copy_tx.try_send(CopyRequest::Text {
                                            text: content,
                                            paste: false,
                                        });
                                        cx.notify();
                                    })),
                            ),
                    ),
                &theme,
            )
            .into_any_element()
        } else {
            detail_column(empty_state(self.t(cx, "select_folder_or_snippet"), &theme), &theme).into_any_element()
        };

        v_flex()
            .size_full()
            .child(toolbar(
                vec![
                    toolbar_btn("snip-add", self.t(cx, "action_add_snippet"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            let folder_id = this.selected_folder_id.clone().or_else(|| {
                                SnippetStore::global().folders().first().map(|f| f.id.clone())
                            });
                            if let Some(fid) = folder_id {
                                if let Some(snippet) =
                                    SnippetStore::global().add_snippet(&fid, "New", "")
                                {
                                    this.selected_snippet_id = Some(snippet.id);
                                    this.selected_folder_id = None;
                                    this.load_snippet_draft(window, cx);
                                }
                            }
                            cx.notify();
                        }))
                        .into_any_element(),
                    toolbar_btn("snip-add-folder", self.t(cx, "action_add_folder"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            let folder = SnippetStore::global().add_folder("New Folder");
                            this.selected_folder_id = Some(folder.id);
                            this.selected_snippet_id = None;
                            this.load_snippet_draft(window, cx);
                            cx.notify();
                        }))
                        .into_any_element(),
                    toolbar_btn("snip-del-toolbar", self.t(cx, "delete"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Some(id) = this.selected_snippet_id.take() {
                                SnippetStore::global().delete_snippet(&id);
                            } else if let Some(id) = this.selected_folder_id.take() {
                                SnippetStore::global().delete_folder(&id);
                            }
                            crate::gui::tray::TrayState::refresh_menu(cx);
                            cx.notify();
                        }))
                        .into_any_element(),
                ],
                vec![
                    toolbar_btn("snip-import", self.t(cx, "action_import"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            for path in pick_files() {
                                if let Ok(json) = std::fs::read_to_string(&path) {
                                    SnippetStore::global().import_json(&json);
                                }
                            }
                            crate::gui::tray::TrayState::refresh_menu(cx);
                            let _ = this;
                            cx.notify();
                        }))
                        .into_any_element(),
                    toolbar_btn("snip-export", self.t(cx, "action_export"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Some(json) = SnippetStore::global().export_json() {
                                let _ = this.copy_tx.try_send(CopyRequest::Text {
                                    text: json,
                                    paste: false,
                                });
                            }
                            cx.notify();
                        }))
                        .into_any_element(),
                ],
                &theme,
            ))
            .child(
                h_flex()
                    .flex_1()
                    .size_full()
                    .child(sidebar_column(div().children(sidebar_rows), &theme))
                    .child(detail),
            )
            .into_any_element()
    }
}
