//! 文件与代码行引用的纯格式化边界。
//!
//! 本模块只把稳定 `workspaceRoot`、目标路径和可选行范围转换为文本，不读取文件正文、
//! 不探测前台进程，也不写入 PTY。CLI 语法变化应被限制在这里，避免污染文件树与终端生命周期。

use std::path::Path;

/// 当前工作区选择的引用文本策略。
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ReferenceFormat {
    /// 产品公共语义，未知或旧会话都安全回退到这里。
    #[default]
    Common,
    /// Codex 官方目前没有稳定 mention 协议，因此显式复用公共语义。
    Codex,
    /// Claude Code 使用官方支持的 `@` 文件 mention 前缀。
    Claude,
    /// 普通 PowerShell 使用单引号绝对路径，不假装存在模型附件协议。
    PowerShell,
}

impl ReferenceFormat {
    /// 返回会话文件使用的稳定小写名称。
    pub(crate) const fn as_persisted(self) -> &'static str {
        match self {
            Self::Common => "common",
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::PowerShell => "powershell",
        }
    }

    /// 从持久化文本恢复策略；未知值不得阻断会话恢复。
    pub(crate) fn from_persisted(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "codex" => Self::Codex,
            "claude" | "claude_code" | "claude-code" => Self::Claude,
            "powershell" | "pwsh" => Self::PowerShell,
            _ => Self::Common,
        }
    }
}

/// 描述一次引用格式化请求。
pub(crate) struct ReferenceRequest<'a> {
    /// 创建工作区时绑定的稳定根目录。
    pub(crate) workspace_root: &'a Path,
    /// 用户从右侧文件树选择的真实路径。
    pub(crate) target_path: &'a Path,
    /// 目标是否为目录；目录引用不携带行号。
    pub(crate) is_directory: bool,
    /// 可选的 1-based 闭区间；反向或零值会被归一化。
    pub(crate) lines: Option<(usize, usize)>,
}

/// 按所选 CLI 策略生成模型或 Shell 可识别的纯文本引用。
pub(crate) fn format_reference(format: ReferenceFormat, request: ReferenceRequest<'_>) -> String {
    let lines = (!request.is_directory)
        .then_some(request.lines)
        .flatten()
        .map(normalized_lines);

    match format {
        ReferenceFormat::PowerShell => {
            let absolute = request.target_path.to_string_lossy().replace('\'', "''");
            append_line_suffix(format!("'{absolute}'"), lines)
        }
        ReferenceFormat::Common | ReferenceFormat::Codex | ReferenceFormat::Claude => {
            let mut display = relative_display_path(request.workspace_root, request.target_path);
            if request.is_directory && display != "." && !display.ends_with('/') {
                display.push('/');
            }
            let prefix = if format == ReferenceFormat::Claude {
                "@"
            } else {
                "f:"
            };
            append_line_suffix(format!("{prefix}{display}"), lines)
        }
    }
}

/// 优先生成 workspaceRoot 相对路径；根外路径保留绝对文本，分隔符统一为 `/`。
fn relative_display_path(workspace_root: &Path, target_path: &Path) -> String {
    let candidate = target_path
        .strip_prefix(workspace_root)
        .unwrap_or(target_path);
    let normalized = candidate.to_string_lossy().replace('\\', "/");
    if normalized.is_empty() {
        ".".to_string()
    } else {
        normalized
    }
}

/// 把任意输入归一化为最小值不小于 1 的升序闭区间。
fn normalized_lines((first, last): (usize, usize)) -> (usize, usize) {
    let first = first.max(1);
    let last = last.max(1);
    (first.min(last), first.max(last))
}

/// 为单行或连续行范围追加统一、可被模型识别的行号语义。
fn append_line_suffix(mut reference: String, lines: Option<(usize, usize)>) -> String {
    if let Some((first, last)) = lines {
        if first == last {
            reference.push_str(&format!("#L{first}"));
        } else {
            reference.push_str(&format!("#L{first}-L{last}"));
        }
    }
    reference
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request<'a>(root: &'a Path, path: &'a Path) -> ReferenceRequest<'a> {
        ReferenceRequest {
            workspace_root: root,
            target_path: path,
            is_directory: false,
            lines: None,
        }
    }

    #[test]
    fn formats_same_path_for_all_cli_strategies() {
        let root = Path::new(r"C:\workspace\repo");
        let path = Path::new(r"C:\workspace\repo\src\main.rs");

        assert_eq!(
            format_reference(ReferenceFormat::Common, request(root, path)),
            "f:src/main.rs"
        );
        assert_eq!(
            format_reference(ReferenceFormat::Codex, request(root, path)),
            "f:src/main.rs"
        );
        assert_eq!(
            format_reference(ReferenceFormat::Claude, request(root, path)),
            "@src/main.rs"
        );
        assert_eq!(
            format_reference(ReferenceFormat::PowerShell, request(root, path)),
            r"'C:\workspace\repo\src\main.rs'"
        );
    }

    #[test]
    fn directories_and_line_ranges_keep_their_semantics() {
        let root = Path::new(r"C:\workspace\repo");
        let directory = Path::new(r"C:\workspace\repo\docs");
        let file = Path::new(r"C:\workspace\repo\src\main.rs");

        assert_eq!(
            format_reference(
                ReferenceFormat::Claude,
                ReferenceRequest {
                    workspace_root: root,
                    target_path: directory,
                    is_directory: true,
                    lines: Some((9, 2)),
                }
            ),
            "@docs/"
        );
        assert_eq!(
            format_reference(
                ReferenceFormat::Common,
                ReferenceRequest {
                    workspace_root: root,
                    target_path: file,
                    is_directory: false,
                    lines: Some((43, 23)),
                }
            ),
            "f:src/main.rs#L23-L43"
        );
    }

    #[test]
    fn powershell_escapes_quotes_and_unknown_values_fall_back() {
        let root = Path::new(r"C:\workspace\repo");
        let path = Path::new(r"C:\workspace\repo\user's file.rs");
        let formatted = format_reference(
            ReferenceFormat::PowerShell,
            ReferenceRequest {
                workspace_root: root,
                target_path: path,
                is_directory: false,
                lines: Some((0, 0)),
            },
        );

        assert_eq!(formatted, r"'C:\workspace\repo\user''s file.rs'#L1");
        assert_eq!(
            ReferenceFormat::from_persisted("future-cli"),
            ReferenceFormat::Common
        );
        assert_eq!(
            ReferenceFormat::from_persisted("CLAUDE-CODE"),
            ReferenceFormat::Claude
        );
    }
}
