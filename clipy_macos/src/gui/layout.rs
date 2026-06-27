use gpui::{
    div, px, AnyElement, Div, ElementId, Hsla, IntoElement, ParentElement, SharedString, Styled,
};
use gpui_component::{
    h_flex, v_flex,
    button::{Button, ButtonVariants},
    scroll::ScrollableElement,
    Sizable, StyleSized, StyledExt as _,
};
use gpui::prelude::FluentBuilder;

use super::design_tokens::{chrome, font, radius, row, spacing};

/// 主文字色（深色主题下为浅色）
pub fn text_primary(theme: &gpui_component::Theme) -> Hsla {
    theme.foreground
}

/// 次级说明文字
pub fn text_secondary(theme: &gpui_component::Theme) -> Hsla {
    theme.foreground.opacity(0.72)
}

/// 弱化说明文字（仍保证在 muted 背景上可读）
pub fn text_tertiary(theme: &gpui_component::Theme) -> Hsla {
    theme.foreground.opacity(0.55)
}

/// 顶栏 / 工具栏背景
pub fn window_chrome(theme: &gpui_component::Theme) -> Hsla {
    theme.tab_bar
}

/// 内容区背景
pub fn window_background(theme: &gpui_component::Theme) -> Hsla {
    theme.background
}

/// 预览 / 侧栏等次级面板背景
pub fn pane_surface(theme: &gpui_component::Theme) -> Hsla {
    theme.list_head
}

pub fn divider(theme: &gpui_component::Theme) -> Div {
    div().h(px(1.0)).w_full().bg(theme.border)
}

pub fn vertical_divider(theme: &gpui_component::Theme) -> Div {
    div().w(px(1.0)).h_full().bg(theme.border)
}

pub fn window_header(content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    v_flex()
        .w_full()
        .gap(spacing::xs())
        .px(spacing::sm())
        .py(spacing::xs())
        .bg(window_chrome(theme))
        .border_b_1()
        .border_color(theme.border)
        .text_color(text_primary(theme))
        .child(content)
}

pub fn filter_bar(content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    h_flex()
        .w_full()
        .gap(spacing::xs())
        .px(spacing::md())
        .py(spacing::xs())
        .flex_wrap()
        .bg(window_chrome(theme))
        .text_color(text_primary(theme))
        .child(content)
}

pub fn toolbar_btn(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Button {
    Button::new(id).label(label).text_xs().ghost()
}

pub fn toolbar_danger(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Button {
    Button::new(id).label(label).text_xs().ghost()
}

pub fn filter_chip(id: impl Into<ElementId>, label: impl Into<SharedString>, selected: bool) -> Button {
    let mut btn = Button::new(id).label(label).text_xs().rounded(radius::sm());
    if selected {
        btn = btn.primary();
    } else {
        btn = btn.ghost();
    }
    btn
}

pub fn toolbar(
    leading: Vec<AnyElement>,
    trailing: Vec<AnyElement>,
    theme: &gpui_component::Theme,
) -> Div {
    h_flex()
        .w_full()
        .min_h(chrome::toolbar())
        .gap(spacing::xs())
        .px(spacing::md())
        .items_center()
        .bg(window_chrome(theme))
        .text_color(text_primary(theme))
        .children(leading)
        .child(div().flex_1())
        .children(trailing)
}

pub fn tab_bar(children: Vec<AnyElement>, theme: &gpui_component::Theme) -> Div {
    h_flex()
        .w_full()
        .h(chrome::tab_bar())
        .gap(spacing::xs())
        .px(spacing::md())
        .items_center()
        .bg(window_chrome(theme))
        .border_b_1()
        .border_color(theme.border)
        .text_color(text_primary(theme))
        .children(children)
}

pub fn status_bar(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    h_flex()
        .w_full()
        .px(spacing::sm())
        .py(px(4.0))
        .items_center()
        .justify_end()
        .bg(window_chrome(theme))
        .child(
            div()
                .text_size(px(font::CAPTION))
                .text_color(text_secondary(theme))
                .child(text.into()),
        )
}

pub fn bordered_chip(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    selected: bool,
    theme: &gpui_component::Theme,
) -> Button {
    let mut btn = Button::new(id)
        .label(label)
        .text_xs()
        .rounded(radius::sm())
        .border_1()
        .border_color(theme.border);
    if selected {
        btn = btn.primary();
    } else {
        btn = btn.ghost();
    }
    btn
}

pub fn checkbox_row(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    checked: bool,
    theme: &gpui_component::Theme,
) -> Button {
    let prefix = if checked { "☑ " } else { "☐ " };
    let text = format!("{prefix}{}", label.into());
    Button::new(id)
        .label(text)
        .text_xs()
        .ghost()
        .text_color(text_primary(theme))
}

pub fn segmented_control(
    segments: Vec<(impl Into<ElementId>, SharedString, bool)>,
    theme: &gpui_component::Theme,
) -> Div {
    h_flex()
        .gap_0()
        .rounded(radius::sm())
        .border_1()
        .border_color(theme.border)
        .overflow_hidden()
        .children(segments.into_iter().map(|(id, label, selected)| {
            let mut btn = Button::new(id)
                .label(label)
                .text_xs()
                .rounded(px(0.0));
            if selected {
                btn = btn.primary();
            } else {
                btn = btn.ghost().bg(window_chrome(theme));
            }
            btn.into_any_element()
        }))
}

pub fn form_section(title: impl Into<SharedString>, content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    v_flex()
        .w_full()
        .gap(spacing::xs())
        .child(section_label(title, theme))
        .child(
            div()
                .w_full()
                .p(spacing::sm())
                .rounded(radius::md())
                .bg(window_chrome(theme))
                .border_1()
                .border_color(theme.border)
                .child(content),
        )
}

pub fn empty_state(message: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    v_flex()
        .flex_1()
        .size_full()
        .items_center()
        .justify_center()
        .p(spacing::xl())
        .gap(spacing::sm())
        .child(
            div()
                .max_w(px(320.0))
                .text_center()
                .text_size(px(font::EMPTY_STATE))
                .text_color(text_secondary(theme))
                .child(message.into()),
        )
}

/// 列表类窗口：顶栏 → 内容 → 状态栏
pub fn list_window(
    toolbar_el: impl IntoElement,
    content: impl IntoElement,
    status: impl Into<SharedString>,
    theme: &gpui_component::Theme,
) -> Div {
    v_flex()
        .size_full()
        .bg(window_background(theme))
        .text_color(text_primary(theme))
        .child(toolbar_el)
        .child(div().flex_1().size_full().overflow_hidden().child(content))
        .child(divider(theme))
        .child(status_bar(status, theme))
}

/// 双栏布局：列表 + 预览
pub fn split_pane(
    list: impl IntoElement,
    preview: impl IntoElement,
    theme: &gpui_component::Theme,
    list_width: f32,
) -> Div {
    h_flex()
        .size_full()
        .text_color(text_primary(theme))
        .child(
            v_flex()
                .flex()
                .flex_basis(px(list_width))
                .min_w(px(list_width))
                .size_full()
                .child(list),
        )
        .child(vertical_divider(theme))
        .child(
            v_flex()
                .flex_1()
                .min_w(px(260.0))
                .size_full()
                .bg(pane_surface(theme))
                .text_color(text_primary(theme))
                .child(preview),
        )
}

/// 表单类窗口 — 对齐 Swift AppFormWindowLayout
pub fn form_window(content: impl IntoElement, theme: &gpui_component::Theme) -> impl IntoElement {
    div()
        .size_full()
        .p(spacing::sm())
        .bg(window_background(theme))
        .text_color(text_primary(theme))
        .overflow_y_scrollbar()
        .child(content)
}

pub fn form_card(content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    div()
        .w_full()
        .p(spacing::md())
        .rounded(radius::md())
        .border_1()
        .border_color(theme.border)
        .bg(window_chrome(theme))
        .text_color(text_primary(theme))
        .child(content)
}

pub fn table_header(cols: &[(&str, f32)], theme: &gpui_component::Theme) -> Div {
    h_flex()
        .w_full()
        .px(spacing::md())
        .min_h(row::compact())
        .items_center()
        .bg(window_chrome(theme))
        .border_b_1()
        .border_color(theme.border)
        .children(cols.iter().map(|(label, flex_w)| {
            div()
                .when(*flex_w > 0.0, |d| d.flex().flex_basis(px(*flex_w)))
                .when(*flex_w <= 0.0, |d| d.flex_1())
                .text_size(px(font::CAPTION))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(theme.table_head_foreground)
                .child(label.to_string())
        }))
}

pub fn list_row(
    selected: bool,
    theme: &gpui_component::Theme,
    content: impl IntoElement,
) -> Div {
    div()
        .w_full()
        .px(spacing::md())
        .py(spacing::xs())
        .min_h(row::compact())
        .text_color(text_primary(theme))
        .border_b_1()
        .border_color(theme.border.opacity(0.35))
        .when(selected, |d| {
            d.bg(theme.list_active)
                .border_l_2()
                .border_color(theme.list_active_border)
                .pl(spacing::sm())
        })
        .child(content)
}

pub fn mono_badge(label: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .w(px(22.0))
        .h(px(22.0))
        .flex()
        .items_center()
        .justify_center()
        .rounded(radius::sm())
        .bg(theme.muted)
        .text_size(px(10.0))
        .font_family(theme.mono_font_family.clone())
        .text_color(text_secondary(theme))
        .child(label.into())
}

pub fn caption(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .text_size(px(font::CAPTION))
        .text_color(text_tertiary(theme))
        .child(text.into())
}

pub fn body_text(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .text_size(px(font::BODY))
        .line_height(px(18.0))
        .text_color(text_primary(theme))
        .child(text.into())
}

pub fn secondary_text(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .text_size(px(font::SECONDARY))
        .text_color(text_secondary(theme))
        .child(text.into())
}

pub fn label_sm(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .text_sm()
        .text_color(text_primary(theme))
        .child(text.into())
}

pub fn field_label(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .pb(spacing::xs())
        .text_size(px(font::CAPTION))
        .font_weight(gpui::FontWeight::MEDIUM)
        .text_color(text_secondary(theme))
        .child(text.into())
}

pub fn section_label(text: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .w_full()
        .pt(spacing::md())
        .pb(spacing::xs())
        .text_size(px(font::CAPTION))
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .text_color(text_secondary(theme))
        .child(text.into())
}

pub fn preview_header(title: impl Into<SharedString>, theme: &gpui_component::Theme) -> Div {
    div()
        .w_full()
        .px(spacing::md())
        .py(spacing::sm())
        .border_b_1()
        .border_color(theme.border)
        .text_size(px(font::TITLE))
        .font_weight(gpui::FontWeight::MEDIUM)
        .text_color(text_primary(theme))
        .child(title.into())
}

pub fn preview_body(content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    div().flex_1().size_full().child(
        div()
            .size_full()
            .p(spacing::md())
            .text_color(text_primary(theme))
            .overflow_y_scrollbar()
            .child(content),
    )
}

pub fn level_badge(level: &str) -> Div {
    let color = match level.to_lowercase().as_str() {
        "error" => gpui::rgb(0xef4444),
        "warn" | "warning" => gpui::rgb(0xf97316),
        "debug" => gpui::rgb(0xa1a1aa),
        _ => gpui::rgb(0x60a5fa),
    };
    div()
        .w(px(52.0))
        .text_size(px(font::CAPTION))
        .font_family(gpui::SharedString::from("Menlo"))
        .text_color(color)
        .child(level.to_uppercase())
}

pub fn sidebar_column(content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    v_flex()
        .w(chrome::sidebar())
        .min_w(px(200.0))
        .h_full()
        .bg(window_chrome(theme))
        .border_r_1()
        .border_color(theme.border)
        .text_color(text_primary(theme))
        .child(div().flex_1().overflow_y_scrollbar().child(content))
}

pub fn detail_column(content: impl IntoElement, theme: &gpui_component::Theme) -> Div {
    v_flex()
        .flex_1()
        .h_full()
        .p(spacing::md())
        .gap(spacing::md())
        .bg(window_background(theme))
        .text_color(text_primary(theme))
        .child(content)
}
