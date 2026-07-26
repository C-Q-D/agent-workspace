//! App-layer modules extracted from `main.rs`.
//!
//! See `tasks/prd-src-app-refactor.md` for the ongoing decomposition plan.

pub mod about_dialog;
pub mod actions;
// A020 后这些旧产品面不再可达；A027 将依据模块处置清单完成公开路径隔离。
#[allow(dead_code)]
pub mod agents_bottom_panel;
#[allow(dead_code)]
pub mod agents_diff;
#[allow(dead_code)]
pub mod agents_sidebar;
#[allow(dead_code)]
pub mod agents_view_actions;
pub mod attention_queue;
pub mod bootstrap;
pub mod broadcast;
pub mod composer;
pub mod constants;
pub mod custom_buttons_modal;
pub mod diff_sidebar;
pub mod diff_view_actions;
pub mod diff_view_helpers;
pub mod drag;
pub mod event_handlers;
pub mod files_sidebar;
pub mod files_tree;
pub mod fleet_search;
pub mod ipc_handler;
pub mod launch_pad;
pub mod notifications;
pub mod profile_menu;
pub mod project_ops;
pub mod rosetta;
pub mod self_update_flow;
pub mod session;
pub mod sessions_sidebar;
pub mod settings;
pub mod sidebar;
pub mod sidebar_actions_menu;
pub mod telemetry_events;
pub mod theme_picker;
pub mod workspace_close_dialog;
pub mod workspace_focus;
pub mod workspace_grid;
pub mod workspace_lifecycle;
pub mod workspace_ops;

// A021 的会话所有权契约只在测试构建中存在；生产聚合对象由 A022 引入。
#[cfg(test)]
mod window_session_contract;
// E003 的自用效率契约只在测试构建中存在；它固定后续轻量编辑与右侧上下文的所有权边界。
#[cfg(test)]
mod self_use_efficiency_contract;
