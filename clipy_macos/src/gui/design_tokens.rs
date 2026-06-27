use gpui::{Pixels, Size, px, size};

/// 与 Swift `DesignTokens.swift` / `AppWindowSize` 对齐
pub mod spacing {
    use gpui::Pixels;
    use gpui::px;

    pub fn xs() -> Pixels {
        px(8.0)
    }
    pub fn sm() -> Pixels {
        px(12.0)
    }
    pub fn md() -> Pixels {
        px(16.0)
    }
    pub fn lg() -> Pixels {
        px(20.0)
    }
    pub fn xl() -> Pixels {
        px(28.0)
    }
}

pub mod font {
    pub const CAPTION: f32 = 11.0;
    pub const BODY: f32 = 13.0;
    pub const SECONDARY: f32 = 12.0;
    pub const TITLE: f32 = 14.0;
    pub const EMPTY_STATE: f32 = 16.0;
}

pub mod row {
    use gpui::Pixels;
    use gpui::px;

    pub fn compact() -> Pixels {
        px(28.0)
    }
    pub fn standard() -> Pixels {
        px(36.0)
    }
    pub fn group() -> Pixels {
        px(40.0)
    }
}

pub mod radius {
    use gpui::Pixels;
    use gpui::px;

    pub fn sm() -> Pixels {
        px(4.0)
    }
    pub fn md() -> Pixels {
        px(8.0)
    }
    pub fn badge() -> Pixels {
        px(10.0)
    }
}

pub mod chrome {
    use gpui::Pixels;
    use gpui::px;

    pub fn toolbar() -> Pixels {
        px(40.0)
    }
    pub fn tab_bar() -> Pixels {
        px(36.0)
    }
    pub fn status() -> Pixels {
        px(28.0)
    }
    pub fn sidebar() -> Pixels {
        px(240.0)
    }
}

pub mod window_size {
    use super::*;

    pub fn settings() -> Size<Pixels> {
        size(px(420.0), px(640.0))
    }
    pub fn list() -> Size<Pixels> {
        size(px(720.0), px(500.0))
    }
    pub fn search() -> Size<Pixels> {
        size(px(1200.0), px(800.0))
    }
    pub fn editor() -> Size<Pixels> {
        size(px(800.0), px(600.0))
    }
    pub fn log() -> Size<Pixels> {
        size(px(800.0), px(500.0))
    }
    pub fn search_min() -> Size<Pixels> {
        size(px(800.0), px(680.0))
    }
    pub fn editor_min() -> Size<Pixels> {
        size(px(640.0), px(480.0))
    }
    pub fn list_min() -> Size<Pixels> {
        size(px(480.0), px(320.0))
    }
    pub fn notification_min() -> Size<Pixels> {
        size(px(560.0), px(360.0))
    }
    pub fn preview_min_width() -> Pixels {
        px(280.0)
    }
    pub fn table_min_width() -> Pixels {
        px(420.0)
    }
}
