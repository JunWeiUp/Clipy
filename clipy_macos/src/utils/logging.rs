use tracing_subscriber::{EnvFilter, fmt, prelude::*};

use super::log_buffer;

pub struct LoggingGuard;

impl Drop for LoggingGuard {
    fn drop(&mut self) {
        tracing::info!("Clipy shutting down");
    }
}

struct LogBufferLayer;

impl<S> tracing_subscriber::Layer<S> for LogBufferLayer
where
    S: tracing::Subscriber,
{
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let level = event.metadata().level().to_string().to_lowercase();
        log_buffer::push(&level, visitor.message.unwrap_or_default());
    }
}

#[derive(Default)]
struct MessageVisitor {
    message: Option<String>,
}

impl tracing::field::Visit for MessageVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{value:?}").trim_matches('"').to_string());
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_string());
        }
    }
}

pub fn init_logging() -> LoggingGuard {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::registry()
        .with(fmt::layer().with_target(false))
        .with(LogBufferLayer)
        .with(filter)
        .init();
    tracing::info!("Clipy logging initialized");
    LoggingGuard
}
