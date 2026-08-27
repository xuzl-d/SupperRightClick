import Foundation

/// 新建文件模板。
struct Template {
    let displayName: String   // 菜单显示名，如「文本文档 (.txt)」
    let baseName: String      // 基础文件名，如「未命名」
    let fileExtension: String // 扩展名（不含点）
    let symbol: String        // SF Symbol 名
    let makeData: () -> Data  // 文件内容
}

enum Templates {
    static func all() -> [Template] {
        [
            Template(displayName: "文本文档 (.txt)", baseName: "未命名", fileExtension: "txt", symbol: "doc.text") { Data() },
            Template(displayName: "Markdown (.md)", baseName: "未命名", fileExtension: "md", symbol: "doc.richtext") { Data("# 未命名\n".utf8) },
            Template(displayName: "JSON (.json)", baseName: "未命名", fileExtension: "json", symbol: "curlybraces") { Data("{}\n".utf8) },
            Template(displayName: "CSV (.csv)", baseName: "未命名", fileExtension: "csv", symbol: "tablecells") { Data() },
            Template(displayName: "富文本 (.rtf)", baseName: "未命名", fileExtension: "rtf", symbol: "doc.richtext") { Data(rtf.utf8) },
            Template(displayName: "Word 文档 (.docx)", baseName: "未命名", fileExtension: "docx", symbol: "doc") { OOXML.docx() },
            Template(displayName: "Excel 表格 (.xlsx)", baseName: "未命名", fileExtension: "xlsx", symbol: "tablecells") { OOXML.xlsx() },
        ]
    }

    private static let rtf = #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 }"#
}
