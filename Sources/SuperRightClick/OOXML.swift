import Foundation

/// 生成最小可用的 OOXML 文件（.docx / .xlsx）。
/// 通过临时目录 + `ditto -c -k`（不带 --keepParent，使内容位于压缩包根目录）打包。
enum OOXML {

    static func docx() -> Data {
        makeZip(root: [
            "[Content_Types].xml": xmlDecl + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """,
            "_rels/.rels": xmlDecl + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """,
            "word/document.xml": xmlDecl + """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body><w:p/></w:body>
            </w:document>
            """
        ])
    }

    static func xlsx() -> Data {
        makeZip(root: [
            "[Content_Types].xml": xmlDecl + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
              <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            </Types>
            """,
            "_rels/.rels": xmlDecl + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """,
            "xl/workbook.xml": xmlDecl + """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """,
            "xl/_rels/workbook.xml.rels": xmlDecl + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """,
            "xl/worksheets/sheet1.xml": xmlDecl + """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>
            """
        ])
    }

    private static let xmlDecl = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    /// 将内存中的「相对路径 -> 内容」映射打包成 zip（内容位于压缩包根目录）。
    private static func makeZip(root: [String: String]) -> Data {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("srx-ooxml-\(UUID().uuidString)", isDirectory: true)
        let srcDir = workDir.appendingPathComponent("src", isDirectory: true)
        let zipPath = workDir.appendingPathComponent("out.zip") // 放在 src 之外，避免被打进压缩包

        do {
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
            for (relativePath, content) in root {
                let fileURL = srcDir.appendingPathComponent(relativePath)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.data(using: .utf8)!.write(to: fileURL)
            }
            // ditto 不带 --keepParent：压缩源目录的内容本身，文件位于 zip 根目录。
            let result = Shell.run("/usr/bin/ditto", ["-c", "-k", srcDir.path, zipPath.path])
            if result.status != 0 {
                NSLog("[SuperRightClick] OOXML 打包失败: %@", result.stderr)
                return Data()
            }
            let data = (try? Data(contentsOf: zipPath)) ?? Data()
            try? fm.removeItem(at: workDir)
            return data
        } catch {
            NSLog("[SuperRightClick] OOXML 生成失败: %@", "\(error)")
            return Data()
        }
    }
}
