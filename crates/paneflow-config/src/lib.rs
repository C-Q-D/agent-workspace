#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::unwrap_in_result,
        clippy::panic
    )
)]

/// AgentWorkspace 用户数据目录的统一布局契约。
pub mod data_layout;
pub mod loader;
pub mod schema;
pub mod watcher;
