//! 真实文本文件的受控读取与保真保存模型。
//!
//! 本模块负责把磁盘字节分类为可编辑的 UTF-8 文档快照，并集中记录原始字节、编码、
//! 换行摘要和指纹。正文在编辑器内统一使用 LF；保存时再按照原文件的换行风格和 BOM
//! 重新编码，避免跨平台编辑造成不可见的格式抖动。这里不创建 GPUI 节点，也不对非
//! UTF-8 内容做 lossy 转换。

use std::collections::hash_map::DefaultHasher;
use std::fs::File;
use std::hash::{Hash, Hasher};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// 只读文本 Context 允许加载的最大文件字节数。
pub(crate) const MAX_TEXT_DOCUMENT_BYTES: u64 = 1024 * 1024;

/// 文档解码方式；BOM 不会进入展示正文，但会保留在原始字节中。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TextEncoding {
    /// 没有 BOM 的 UTF-8。
    Utf8,
    /// 以 UTF-8 BOM 开头的文件。
    Utf8Bom,
}

/// 文档中检测到的换行风格摘要。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LineEnding {
    /// 没有换行符（包括空文件和单行文件）。
    None,
    /// 全部换行符为 LF。
    Lf,
    /// 全部换行符为 CRLF。
    CrLf,
    /// 全部换行符为单独 CR。
    Cr,
    /// 同一文件混用了多种换行符。
    Mixed,
}

/// 足以判断文档是否仍可安全审查/后续保存的文件指纹。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TextDocumentFingerprint {
    /// 文件字节长度。
    pub(crate) byte_len: u64,
    /// 文件系统提供的最后修改时间。
    pub(crate) modified: Option<std::time::SystemTime>,
    /// 本次真实读取字节的进程内稳定哈希。
    pub(crate) content_hash: u64,
}

/// 读取失败的可判别类型；调用方可以据此选择降级页面，而不是解析错误文本。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TextDocumentLoadError {
    /// 路径不存在，或读取期间文件被删除。
    Missing,
    /// 当前用户没有读取权限。
    PermissionDenied,
    /// 目标不是普通文件（例如目录）。
    NotRegularFile,
    /// 文件超过 1 MiB 上限；边界等于 1 MiB 仍允许读取。
    TooLarge { actual: u64, limit: u64 },
    /// 字节包含 NUL 或其他明确的二进制信号，不进入文本编辑器。
    Binary,
    /// 字节不是合法 UTF-8。
    InvalidUtf8,
    /// 文件在读取前后发生替换、增长或删除。
    ChangedDuringRead,
    /// 其他不可归类的操作系统读取失败。
    Io { kind: io::ErrorKind },
}

impl TextDocumentLoadError {
    /// 生成供右侧降级页面直接显示的中文原因；不暴露原始文件正文。
    pub(crate) fn user_message(&self) -> String {
        match self {
            Self::Missing => "文件不存在或已被删除".to_string(),
            Self::PermissionDenied => "没有权限读取该文件".to_string(),
            Self::NotRegularFile => "目标不是普通文件".to_string(),
            Self::TooLarge { actual, limit } => {
                format!(
                    "文件过大（超过 1 MiB：{} 字节，限制 {} 字节）",
                    actual, limit
                )
            }
            Self::Binary => "二进制文件不支持只读文本预览".to_string(),
            Self::InvalidUtf8 => "文件不是有效 UTF-8 文本".to_string(),
            Self::ChangedDuringRead => "文件在读取过程中被替换或修改，请重新打开".to_string(),
            Self::Io { kind } => format!("读取文件失败（{kind:?}）"),
        }
    }
}

/// 成功读取的真实文本文档快照；原始字节保留在内存中，保存必须经过保真编码方法。
#[derive(Clone, Debug)]
pub(crate) struct TextDocumentLoad {
    /// 文件绝对路径。
    #[allow(dead_code)]
    path: PathBuf,
    /// 去除 BOM 且统一为 LF 换行的 UTF-8 编辑正文。
    text: Arc<str>,
    /// 读取时的原始字节，供后续保真保存和冲突检测使用。
    #[allow(dead_code)]
    raw_bytes: Arc<[u8]>,
    /// 解码方式摘要。
    #[allow(dead_code)]
    encoding: TextEncoding,
    /// 换行风格摘要。
    #[allow(dead_code)]
    line_ending: LineEnding,
    /// 是否以 LF、CRLF 或单独 CR 结束。
    #[allow(dead_code)]
    has_final_newline: bool,
    /// 读取完成时的文件指纹。
    fingerprint: TextDocumentFingerprint,
}

impl TextDocumentLoad {
    /// 从真实磁盘路径加载文档；所有阻塞 I/O 都在调用线程执行，UI 调用方必须放到
    /// `smol::unblock` 或其他后台执行器中，避免阻塞 GPUI 帧。
    pub(crate) fn load(path: PathBuf) -> Result<Self, TextDocumentLoadError> {
        let initial_metadata = std::fs::metadata(&path).map_err(classify_io_error)?;
        if !initial_metadata.is_file() {
            return Err(TextDocumentLoadError::NotRegularFile);
        }
        if initial_metadata.len() > MAX_TEXT_DOCUMENT_BYTES {
            return Err(TextDocumentLoadError::TooLarge {
                actual: initial_metadata.len(),
                limit: MAX_TEXT_DOCUMENT_BYTES,
            });
        }
        let initial_stamp = metadata_stamp(&initial_metadata);

        let file = File::open(&path).map_err(classify_io_error)?;
        let mut bytes = Vec::with_capacity(initial_metadata.len().min(64 * 1024) as usize);
        file.take(MAX_TEXT_DOCUMENT_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(classify_io_error)?;
        if bytes.len() as u64 > MAX_TEXT_DOCUMENT_BYTES {
            return Err(TextDocumentLoadError::TooLarge {
                actual: bytes.len() as u64,
                limit: MAX_TEXT_DOCUMENT_BYTES,
            });
        }

        let final_metadata = std::fs::metadata(&path).map_err(classify_io_error)?;
        if !final_metadata.is_file() || metadata_stamp(&final_metadata) != initial_stamp {
            return Err(TextDocumentLoadError::ChangedDuringRead);
        }

        Self::from_bytes(path, bytes, initial_stamp)
    }

    /// 用已确认的磁盘快照构造文档；真实路径入口统一经过 [`Self::load`]。
    fn from_bytes(
        path: PathBuf,
        raw_bytes: Vec<u8>,
        stamp: MetadataStamp,
    ) -> Result<Self, TextDocumentLoadError> {
        if raw_bytes.contains(&0) {
            return Err(TextDocumentLoadError::Binary);
        }
        let (encoding, text_bytes) = raw_bytes
            .strip_prefix(&[0xEF, 0xBB, 0xBF])
            .map_or((TextEncoding::Utf8, raw_bytes.as_slice()), |body| {
                (TextEncoding::Utf8Bom, body)
            });
        let text = std::str::from_utf8(text_bytes)
            .map_err(|_| TextDocumentLoadError::InvalidUtf8)?
            .to_owned();
        let text = normalize_line_endings(&text);
        let line_ending = summarize_line_endings(text_bytes);
        let has_final_newline = text_bytes.ends_with(b"\n") || text_bytes.ends_with(b"\r");
        let fingerprint = TextDocumentFingerprint {
            byte_len: stamp.len,
            modified: stamp.modified,
            content_hash: hash_bytes(&raw_bytes),
        };
        Ok(Self {
            path,
            text: Arc::from(text),
            raw_bytes: Arc::from(raw_bytes),
            encoding,
            line_ending,
            has_final_newline,
            fingerprint,
        })
    }

    /// 返回文件路径。
    #[allow(dead_code)]
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// 返回去除 BOM 且统一为 LF 换行的编辑正文。
    pub(crate) fn text(&self) -> &str {
        &self.text
    }

    /// 将编辑器中的 LF 正文编码回原文件风格，并保留 UTF-8 BOM。
    ///
    /// 未修改的混合换行文件直接返回原始字节；一旦修改混合换行文件则拒绝保存，
    /// 避免在无法推断用户意图时静默统一整份文件。其他风格只转换换行符，不强行
    /// 补齐或删除末尾换行，末尾状态完全由当前编辑正文决定。
    pub(crate) fn encode_text_for_save(&self, text: &str) -> Result<Vec<u8>, String> {
        if text.contains('\0') {
            return Err("保存文件失败：正文包含 NUL 字节".to_string());
        }

        let normalized = normalize_line_endings(text);
        if normalized.as_str() == self.text.as_ref() {
            return Ok(self.raw_bytes.to_vec());
        }
        if self.line_ending == LineEnding::Mixed {
            return Err("混合换行文件暂不支持编辑保存，请使用外部编辑器".to_string());
        }

        let newline = match self.line_ending {
            LineEnding::CrLf => "\r\n",
            LineEnding::Cr => "\r",
            // None 文件在用户新增换行后采用通用 LF；没有新增换行时正文仍不会凭空产生换行。
            LineEnding::None | LineEnding::Lf => "\n",
            LineEnding::Mixed => unreachable!("混合换行已在上方返回错误"),
        };
        let body = if newline == "\n" {
            normalized
        } else {
            normalized.replace('\n', newline)
        };
        let mut encoded = Vec::with_capacity(
            body.len() + usize::from(self.encoding == TextEncoding::Utf8Bom) * 3,
        );
        if self.encoding == TextEncoding::Utf8Bom {
            encoded.extend_from_slice(&[0xEF, 0xBB, 0xBF]);
        }
        encoded.extend_from_slice(body.as_bytes());
        Ok(encoded)
    }

    /// 返回原始字节；调用方不得把解码失败或 lossy 文本写回磁盘。
    #[allow(dead_code)]
    pub(crate) fn raw_bytes(&self) -> &[u8] {
        &self.raw_bytes
    }

    /// 返回编码摘要。
    #[allow(dead_code)]
    pub(crate) fn encoding(&self) -> TextEncoding {
        self.encoding
    }

    /// 返回换行摘要。
    #[allow(dead_code)]
    pub(crate) fn line_ending(&self) -> LineEnding {
        self.line_ending
    }

    /// 返回是否存在最终换行。
    #[allow(dead_code)]
    pub(crate) fn has_final_newline(&self) -> bool {
        self.has_final_newline
    }

    /// 返回读取时的指纹。
    pub(crate) fn fingerprint(&self) -> TextDocumentFingerprint {
        self.fingerprint
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct MetadataStamp {
    len: u64,
    modified: Option<std::time::SystemTime>,
}

fn metadata_stamp(metadata: &std::fs::Metadata) -> MetadataStamp {
    MetadataStamp {
        len: metadata.len(),
        modified: metadata.modified().ok(),
    }
}

fn hash_bytes(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

/// 把 CRLF 和单独 CR 统一为编辑器使用的 LF；先处理 CRLF 可避免重复生成换行。
fn normalize_line_endings(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

fn classify_io_error(error: io::Error) -> TextDocumentLoadError {
    match error.kind() {
        io::ErrorKind::NotFound => TextDocumentLoadError::Missing,
        io::ErrorKind::PermissionDenied => TextDocumentLoadError::PermissionDenied,
        kind => TextDocumentLoadError::Io { kind },
    }
}

fn summarize_line_endings(bytes: &[u8]) -> LineEnding {
    let mut saw_lf = false;
    let mut saw_crlf = false;
    let mut saw_cr = false;
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\r' if bytes.get(index + 1) == Some(&b'\n') => {
                saw_crlf = true;
                index += 2;
            }
            b'\r' => {
                saw_cr = true;
                index += 1;
            }
            b'\n' => {
                saw_lf = true;
                index += 1;
            }
            _ => index += 1,
        }
    }
    match (saw_lf, saw_crlf, saw_cr) {
        (false, false, false) => LineEnding::None,
        (true, false, false) => LineEnding::Lf,
        (false, true, false) => LineEnding::CrLf,
        (false, false, true) => LineEnding::Cr,
        _ => LineEnding::Mixed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_real_zero_byte_and_line_ending_variants_without_lossy_conversion() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");

        let empty = directory.path().join("empty.txt");
        std::fs::write(&empty, []).expect("应能写入空文件");
        let empty_doc = TextDocumentLoad::load(empty).expect("空文件应可读取");
        assert_eq!(empty_doc.text(), "");
        assert_eq!(empty_doc.line_ending(), LineEnding::None);
        assert!(!empty_doc.has_final_newline());

        let lf = directory.path().join("lf.txt");
        std::fs::write(&lf, b"one\ntwo").expect("应能写入 LF 文件");
        let lf_doc = TextDocumentLoad::load(lf).expect("LF 文件应可读取");
        assert_eq!(lf_doc.line_ending(), LineEnding::Lf);
        assert!(!lf_doc.has_final_newline());

        let crlf = directory.path().join("crlf.txt");
        std::fs::write(&crlf, b"one\r\ntwo\r\n").expect("应能写入 CRLF 文件");
        let crlf_doc = TextDocumentLoad::load(crlf).expect("CRLF 文件应可读取");
        assert_eq!(crlf_doc.line_ending(), LineEnding::CrLf);
        assert!(crlf_doc.has_final_newline());
        assert_eq!(crlf_doc.text(), "one\ntwo\n");
        assert_eq!(crlf_doc.raw_bytes(), b"one\r\ntwo\r\n");
    }

    #[test]
    fn encodes_lf_crlf_and_cr_styles_without_changing_final_newline_state() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");

        let lf = directory.path().join("lf-edit.txt");
        std::fs::write(&lf, b"one\ntwo\n").expect("应能写入 LF 文件");
        let lf_doc = TextDocumentLoad::load(lf).expect("LF 文件应可读取");
        assert_eq!(
            lf_doc.encode_text_for_save("one\nchanged\n").unwrap(),
            b"one\nchanged\n"
        );

        let crlf = directory.path().join("crlf-edit.txt");
        std::fs::write(&crlf, b"one\r\ntwo\r\n").expect("应能写入 CRLF 文件");
        let crlf_doc = TextDocumentLoad::load(crlf).expect("CRLF 文件应可读取");
        assert_eq!(
            crlf_doc.encode_text_for_save("one\nchanged").unwrap(),
            b"one\r\nchanged"
        );

        let cr = directory.path().join("cr-edit.txt");
        std::fs::write(&cr, b"one\rtwo").expect("应能写入 CR 文件");
        let cr_doc = TextDocumentLoad::load(cr).expect("CR 文件应可读取");
        assert_eq!(cr_doc.text(), "one\ntwo");
        assert_eq!(
            cr_doc.encode_text_for_save("one\nchanged").unwrap(),
            b"one\rchanged"
        );
    }

    #[test]
    fn preserves_mixed_line_endings_only_when_content_is_unchanged() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("mixed.txt");
        let raw = b"one\r\ntwo\nthree\r";
        std::fs::write(&path, raw).expect("应能写入混合换行文件");

        let document = TextDocumentLoad::load(path).expect("混合换行文件应可读取");
        assert_eq!(document.line_ending(), LineEnding::Mixed);
        assert_eq!(document.encode_text_for_save(document.text()).unwrap(), raw);
        let error = document
            .encode_text_for_save("one\ntwo\nchanged\n")
            .expect_err("修改混合换行文件必须明确拒绝");
        assert!(error.contains("混合换行"));
    }

    #[test]
    fn preserves_utf8_bom_and_uses_lf_for_newlines_added_to_single_line_file() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let bom = directory.path().join("bom-edit.txt");
        std::fs::write(&bom, b"\xEF\xBB\xBFone\r\ntwo").expect("应能写入带 BOM 的 CRLF 文件");
        let bom_document = TextDocumentLoad::load(bom).expect("带 BOM 文件应可读取");
        assert_eq!(
            bom_document.encode_text_for_save("one\nchanged").unwrap(),
            b"\xEF\xBB\xBFone\r\nchanged"
        );

        let single = directory.path().join("single-edit.txt");
        std::fs::write(&single, b"one").expect("应能写入无换行文件");
        let single_document = TextDocumentLoad::load(single).expect("无换行文件应可读取");
        assert_eq!(
            single_document.encode_text_for_save("one\nnew").unwrap(),
            b"one\nnew"
        );
    }

    #[test]
    fn rejects_nul_text_before_writing() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("nul.txt");
        std::fs::write(&path, b"one").expect("应能写入初始文件");
        let document = TextDocumentLoad::load(path).expect("初始文件应可读取");
        assert!(document.encode_text_for_save("one\0two").is_err());
    }

    #[test]
    fn recognizes_bom_and_preserves_it_only_in_raw_bytes() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("bom.txt");
        let bytes = [0xEF, 0xBB, 0xBF, b'f', b'i', b'l', b'e'];
        std::fs::write(&path, bytes).expect("应能写入 BOM 文件");

        let document = TextDocumentLoad::load(path).expect("UTF-8 BOM 文件应可读取");
        assert_eq!(document.encoding(), TextEncoding::Utf8Bom);
        assert_eq!(document.text(), "file");
        assert_eq!(document.raw_bytes(), bytes);
    }

    #[test]
    fn rejects_real_binary_invalid_utf8_and_size_overflow() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");

        let binary = directory.path().join("binary.dat");
        std::fs::write(&binary, [b'a', 0, b'b']).expect("应能写入二进制文件");
        assert_eq!(
            TextDocumentLoad::load(binary).unwrap_err(),
            TextDocumentLoadError::Binary
        );

        let invalid = directory.path().join("invalid.txt");
        std::fs::write(&invalid, [0xFF, 0xFE]).expect("应能写入无效 UTF-8 文件");
        assert_eq!(
            TextDocumentLoad::load(invalid).unwrap_err(),
            TextDocumentLoadError::InvalidUtf8
        );

        let exact = directory.path().join("exact.txt");
        std::fs::write(&exact, vec![b'x'; MAX_TEXT_DOCUMENT_BYTES as usize])
            .expect("应能写入 1 MiB 边界文件");
        assert!(TextDocumentLoad::load(exact).is_ok());

        let oversized = directory.path().join("oversized.txt");
        std::fs::write(&oversized, vec![b'x'; MAX_TEXT_DOCUMENT_BYTES as usize + 1])
            .expect("应能写入超限文件");
        assert_eq!(
            TextDocumentLoad::load(oversized).unwrap_err(),
            TextDocumentLoadError::TooLarge {
                actual: MAX_TEXT_DOCUMENT_BYTES + 1,
                limit: MAX_TEXT_DOCUMENT_BYTES,
            }
        );
    }

    #[test]
    fn classifies_missing_directory_and_changed_metadata_without_panicking() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let missing = directory.path().join("missing.txt");
        assert_eq!(
            TextDocumentLoad::load(missing).unwrap_err(),
            TextDocumentLoadError::Missing
        );
        assert_eq!(
            TextDocumentLoad::load(directory.path().to_path_buf()).unwrap_err(),
            TextDocumentLoadError::NotRegularFile
        );

        let path = directory.path().join("changed.txt");
        std::fs::write(&path, b"before").expect("应能写入初始文件");
        let before = metadata_stamp(&std::fs::metadata(&path).expect("应能读取初始元数据"));
        std::fs::write(&path, b"after with a different length").expect("应能替换真实文件内容");
        let after = metadata_stamp(&std::fs::metadata(&path).expect("应能读取新元数据"));
        assert_ne!(before, after);
    }
}
