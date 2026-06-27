use gpui::{div, px, AnyElement, Context, IntoElement, Window};
use gpui_component::{h_flex, v_flex, button::Button, input::Input};
use super::{
    ButtonVariants, FluentBuilder, ParentElement, ScrollableElement,
    StatefulInteractiveElement, StyleSized, Styled,
};
use gpui_component::ActiveTheme as _;

use crate::config::Settings;
use crate::gui::board::ClipyBoard;
use crate::gui::layout::{
    caption, filter_chip, form_card, form_window, label_sm, section_label, toolbar_btn,
};
use crate::i18n::Language;

impl ClipyBoard {
    pub(crate) fn render_settings(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> gpui::AnyElement {
        let theme = cx.theme().clone();
        let settings = Settings::read(cx, |s| s.clone());
        let limit = self.settings_history_limit;
        let history_count = self.records.read().map(|r| r.len()).unwrap_or(0);

        form_window(
            v_flex()
                .w_full()
                .gap_2()
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_general"), &theme))
                        .child(lang_buttons(cx, settings.language))
                        .child(toggle_row(
                            cx,
                            "set-autostart",
                            settings.autostart.enabled,
                            self.t(cx, "launch_at_login"),
                            |checked, cx| {
                                let mut s = Settings::read(cx, |s| s.clone());
                                s.autostart.enabled = checked;
                                let _ = s.save();
                                cx.set_global(s);
                            },
                        )),
                    &theme,
                ))
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_device"), &theme))
                        .child(
                            h_flex()
                                .gap_1()
                                .child(div().flex_1().child(Input::new(&self.settings_device_input).w_full()))
                                .child(
                                    Button::new("set-device-save")
                                        .label(self.t(cx, "action_save"))
                                        .text_xs()
                                        .primary()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.save_device_name(cx);
                                        })),
                                ),
                        )
                        .child(caption(self.t(cx, "device_name_hint"), &theme)),
                    &theme,
                ))
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_history"), &theme))
                        .child(
                            h_flex()
                                .gap_1()
                                .items_center()
                                .child(label_sm(self.t(cx, "settings_history_limit"), &theme))
                                .child(
                                    toolbar_btn("set-limit-dec", "-")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.settings_history_limit =
                                                this.settings_history_limit.saturating_sub(1).max(1);
                                            cx.notify();
                                        })),
                                )
                                .child(label_sm(format!("{limit}"), &theme))
                                .child(
                                    toolbar_btn("set-limit-inc", "+")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.settings_history_limit =
                                                (this.settings_history_limit + 1).min(1000);
                                            cx.notify();
                                        })),
                                ),
                        )
                        .child(caption(
                            format!("{}: {history_count}", self.t(cx, "history_current_count")),
                            &theme,
                        ))
                        .child(
                            v_flex()
                                .gap_1()
                                .child(label_sm(self.t(cx, "excluded_apps"), &theme))
                                .child(Input::new(&self.settings_excluded_input).w_full()),
                        )
                        .child(toggle_row(
                            cx,
                            "set-encrypt",
                            settings.history_encryption.enabled,
                            self.t(cx, "encrypt_history"),
                            |checked, cx| {
                                let mut s = Settings::read(cx, |s| s.clone());
                                s.history_encryption.enabled = checked;
                                let _ = s.save();
                                cx.set_global(s);
                                crate::repository::GlobalRepository::read(cx, |repo| {
                                    if let Some(r) = repo {
                                        r.set_encryption_enabled(checked);
                                        let _ = r.persist_current();
                                    }
                                });
                            },
                        ))
                        .child(caption(self.t(cx, "encrypt_history_hint"), &theme)),
                    &theme,
                ))
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_sync"), &theme))
                        .child(toggle_row(
                            cx,
                            "set-sync",
                            settings.sync.enabled,
                            self.t(cx, "enable_lan_sync"),
                            |checked, cx| {
                                let mut s = Settings::read(cx, |s| s.clone());
                                s.sync.enabled = checked;
                                let _ = s.save();
                                cx.set_global(s);
                            },
                        ))
                        .child(
                            h_flex()
                                .gap_1()
                                .child(label_sm(self.t(cx, "settings_port"), &theme))
                                .child(Input::new(&self.settings_port_input).w(px(80.0))),
                        )
                        .child(
                            v_flex()
                                .gap_1()
                                .child(label_sm(self.t(cx, "authorized_devices"), &theme))
                                .child(Input::new(&self.settings_auth_devices_input).w_full()),
                        ),
                    &theme,
                ))
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_collector"), &theme))
                        .child(toggle_row(cx, "col-sync", settings.collector.enabled, self.t(cx, "enable_collector_sync"), |v, cx| {
                            update_collector(cx, |c| c.enabled = v);
                        }))
                        .child(toggle_row(cx, "col-notif", settings.collector.notifications, self.t(cx, "collector_category_notification"), |v, cx| {
                            update_collector(cx, |c| c.notifications = v);
                        }))
                        .child(toggle_row(cx, "col-sms", settings.collector.sms, self.t(cx, "collector_category_sms"), |v, cx| {
                            update_collector(cx, |c| c.sms = v);
                        }))
                        .child(toggle_row(cx, "col-call", settings.collector.calls, self.t(cx, "collector_category_call"), |v, cx| {
                            update_collector(cx, |c| c.calls = v);
                        }))
                        .child(toggle_row(cx, "col-clip", settings.collector.clipboard, self.t(cx, "collector_category_clipboard"), |v, cx| {
                            update_collector(cx, |c| c.clipboard = v);
                        }))
                        .child(toggle_row(cx, "col-loc", settings.collector.location, self.t(cx, "collector_category_location"), |v, cx| {
                            update_collector(cx, |c| c.location = v);
                        }))
                        .child(toggle_row(cx, "col-sys", settings.collector.system, self.t(cx, "collector_category_system"), |v, cx| {
                            update_collector(cx, |c| c.system = v);
                        })),
                    &theme,
                ))
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_notification"), &theme))
                        .child(toggle_row(cx, "set-notif-sync", settings.notification.enabled, self.t(cx, "enable_notification_sync"), |v, cx| {
                            let mut s = Settings::read(cx, |s| s.clone());
                            s.notification.enabled = v;
                            let _ = s.save();
                            cx.set_global(s);
                        }))
                        .child(toggle_row(cx, "set-notif-sound", settings.notification.sound, self.t(cx, "notification_sound"), |v, cx| {
                            let mut s = Settings::read(cx, |s| s.clone());
                            s.notification.sound = v;
                            let _ = s.save();
                            cx.set_global(s);
                        })),
                    &theme,
                ))
                .child(form_card(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(section_label(self.t(cx, "settings_hotkey"), &theme))
                        .child(label_sm(
                            format!(
                                "{}: {}",
                                self.t(cx, "settings_hotkey"),
                                settings.hotkey.activation_key
                            ),
                            &theme,
                        ))
                        .child(
                            Button::new("set-save-all")
                                .label(self.t(cx, "action_save"))
                                .primary()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.save_settings(cx);
                                    crate::gui::tray::TrayState::refresh_menu(cx);
                                })),
                        ),
                    &theme,
                )),
            &theme,
        )
        .into_any_element()
    }

    pub(crate) fn save_device_name(&mut self, cx: &mut Context<Self>) {
        let name = self.settings_device_input.read(cx).value().to_string();
        let mut settings = Settings::read(cx, |s| s.clone());
        settings.sync.device_name = name;
        let _ = settings.save();
        cx.set_global(settings);
        cx.notify();
    }
}

fn lang_buttons(cx: &Context<ClipyBoard>, current: Language) -> gpui::AnyElement {
    h_flex()
        .gap_1()
        .child(lang_btn(cx, "set-lang-sys", Language::System, "System", current))
        .child(lang_btn(cx, "set-lang-en", Language::En, "English", current))
        .child(lang_btn(cx, "set-lang-zh", Language::Zh, "中文", current))
        .into_any_element()
}

fn lang_btn(
    cx: &Context<ClipyBoard>,
    id: &'static str,
    lang: Language,
    label: &'static str,
    current: Language,
) -> Button {
    filter_chip(id, label, current == lang).on_click(cx.listener(move |_, _, _, cx| {
        let mut s = Settings::read(cx, |s| s.clone());
        s.language = lang;
        let _ = s.save();
        cx.set_global(s);
        cx.set_global(crate::i18n::I18n::new(lang));
        crate::gui::tray::TrayState::refresh_menu(cx);
        cx.notify();
    }))
}

fn toggle_row(
    cx: &Context<ClipyBoard>,
    id: &'static str,
    checked: bool,
    label: gpui::SharedString,
    apply: fn(bool, &mut gpui::Context<ClipyBoard>),
) -> gpui::AnyElement {
    let theme = cx.theme().clone();
    h_flex()
        .w_full()
        .items_center()
        .justify_between()
        .gap_2()
        .child(label_sm(label, &theme))
        .child(
            filter_chip(id, if checked { "On" } else { "Off" }, checked)
                .on_click(cx.listener(move |_, _, _, cx| {
                    apply(!checked, cx);
                    cx.notify();
                })),
        )
        .into_any_element()
}

fn update_collector(cx: &mut gpui::Context<ClipyBoard>, f: impl FnOnce(&mut crate::config::CollectorSettings)) {
    let mut s = Settings::read(cx, |s| s.clone());
    f(&mut s.collector);
    let _ = s.save();
    cx.set_global(s);
}
