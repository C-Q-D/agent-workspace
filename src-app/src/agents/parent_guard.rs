//! 为尚未迁移的调用方保留进程守护兼容入口。
//!
//! 通用 PTY 与应用进程守护已经下沉到 [`crate::terminal::process_guard`]。
//! 当前模块只负责保持旧路径可编译，后续清理 Agent 产品层时可以直接删除。

pub use crate::terminal::process_guard::*;
