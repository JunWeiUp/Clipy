pub mod app;
pub mod clipboard;
pub mod collector;
pub mod config;
pub mod constants;
pub mod gui;
pub mod i18n;
pub mod notification;
pub mod repository;
pub mod snippet;
pub mod sync;
pub mod utils;

fn main() {
    let _guard = utils::logging::init_logging();
    app::launch();
}
