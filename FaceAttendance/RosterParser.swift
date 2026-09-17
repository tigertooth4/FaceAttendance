import Foundation
import ZIPFoundation

/// 花名册 xlsx 解析器。
/// 布局约定（与服务器版一致）：照片锚点下方第 4/5/6 行（0 基）依次为 学号/姓名/班级。
/// 仅支持 .xlsx；老 .xls 请先在 Excel/WPS「另存为 .xlsx」。
final class RosterParser {

    struct RosterEntry {
        let studentId: String
        let name: String
        let className: String
        let photoData: Data
    }

    enum ParseError: LocalizedError {
        case notXLSX, noImages, noStudents
        var errorDescription: String? {
            switch self {
            case .notXLSX: return "无法读取该文件：仅支持 .xlsx 格式。如果是老版 .xls，请先在 Excel/WPS/Numbers 中「另存为 .xlsx」再导入"
            case .noImages: return "未在花名册中找到嵌入的证件照（请确认照片是直接嵌入单元格区域的图片，而不是链接或拍照后粘贴的浮动对象）"
            case .noStudents: return "解析到照片但未找到对应的学号/姓名（照片下方应依次为学号、姓名、班级三行）"
            }
        }
    }

    func parse(url: URL) throws -> [RosterEntry] {
        // 先严格校验格式：老 .xls 是 OLE2 二进制，可能被 ZIPFoundation 误判成 zip，
        // 导致后续查不到任何内容而报出误导性的错误
        let ext = url.pathExtension.lowercased()
        guard ext == "xlsx" || ext == "xlsm" else { throw ParseError.notXLSX }
        // zip 魔数 "PK" 校验（try? 会把嵌套 Optional 拍平成 Data）
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4),
              head.count >= 2, head[0] == 0x50, head[1] == 0x4B else {
            throw ParseError.notXLSX
        }
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              readEntry(archive, "xl/workbook.xml") != nil else { throw ParseError.notXLSX }

        // 1. 共享字符串表
        let sharedStrings = parseSharedStrings(archive)

        // 2. 所有工作表
        let sheetPaths = try sheetXMLPaths(archive)

        var entries: [RosterEntry] = []
        var totalAnchors = 0
        for sheetPath in sheetPaths {
            guard let sheetData = readEntry(archive, sheetPath) else { continue }
            let cells = parseCells(sheetData, sharedStrings: sharedStrings)

            // 3. 该工作表的图片锚点
            guard let drawingPath = drawingPath(for: sheetPath, archive: archive),
                  let drawingData = readEntry(archive, drawingPath) else { continue }
            let anchors = parseDrawing(drawingData)          // [(row0, col0, embedId)]
            totalAnchors += anchors.count
            let rels = drawingRels(archive, drawingPath: drawingPath)  // embedId -> media path

            for a in anchors {
                guard let mediaPath = rels[a.embed],
                      let photo = readEntry(archive, mediaPath) else { continue }
                // 1 基坐标：学号行 = 锚点 0 基行 + 5，列 = 锚点 0 基列 + 1
                let sid  = cells[a.row + 5]?[a.col + 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = cells[a.row + 6]?[a.col + 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let cls  = cells[a.row + 7]?[a.col + 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !sid.isEmpty, !name.isEmpty {
                    entries.append(RosterEntry(studentId: sid, name: name,
                                               className: cls, photoData: photo))
                }
            }
        }
        if entries.isEmpty {
            throw totalAnchors == 0 ? ParseError.noImages : ParseError.noStudents
        }
        return entries
    }

    // MARK: - ZIP 读取

    private func readEntry(_ archive: Archive, _ path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data
    }

    // MARK: - XML 解析（通用收集器）

    /// 收集 (元素路径, 属性, 文本) 三元组
    private class XMLCollector: NSObject, XMLParserDelegate {
        var events: [(path: [String], attrs: [String: String], text: String)] = []
        private var stack: [String] = []
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            stack.append(e); text = ""
            events.append((stack, attributes, ""))
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append((stack, [:], text))
            }
            _ = stack.popLast()
        }
    }

    private func collect(_ data: Data) -> [(path: [String], attrs: [String: String], text: String)] {
        let c = XMLCollector()
        let p = XMLParser(data: data)
        p.delegate = c
        p.parse()
        return c.events
    }

    // MARK: - 各部分解析

    private func parseSharedStrings(_ archive: Archive) -> [String] {
        guard let data = readEntry(archive, "xl/sharedStrings.xml") else { return [] }
        // <si> 起始事件（无属性无文本）作为分隔，内部多个 <t> 文本聚合
        var result: [String] = []
        var inSi = false
        var buf = ""
        for ev in collect(data) {
            let last = ev.path.last ?? ""
            if last == "si" && ev.attrs.isEmpty && ev.text.isEmpty {
                if inSi { result.append(buf); buf = "" }
                inSi = true
            } else if last == "t" && inSi {
                buf += ev.text
            }
        }
        if inSi { result.append(buf) }
        return result
    }

    private func sheetXMLPaths(_ archive: Archive) throws -> [String] {
        guard let wbData = readEntry(archive, "xl/workbook.xml") else { return [] }
        var rIds: [String] = []
        for ev in collect(wbData) where ev.path.last == "sheet" {
            let rid = ev.attrs["r:id"] ?? ev.attrs["id"] ?? ""
            if !rid.isEmpty { rIds.append(rid) }
        }
        guard let relsData = readEntry(archive, "xl/_rels/workbook.xml.rels") else { return [] }
        var map: [String: String] = [:]
        for ev in collect(relsData) where ev.path.last == "Relationship" {
            if let rid = ev.attrs["Id"], let target = ev.attrs["Target"] {
                map[rid] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        return rIds.compactMap { map[$0] }
    }

    /// 返回 [1基行: [1基列: 文本]]
    private func parseCells(_ data: Data, sharedStrings: [String]) -> [Int: [Int: String]] {
        var grid: [Int: [Int: String]] = [:]
        var curRow = 0
        var curRef = ""
        var curType = ""
        var curInline = ""
        for ev in collect(data) {
            guard let last = ev.path.last else { continue }
            if last == "row", let r = Int(ev.attrs["r"] ?? "") { curRow = r }
            if last == "c" {
                curRef = ev.attrs["r"] ?? ""
                curType = ev.attrs["t"] ?? ""
                curInline = ""
            }
            if last == "v" || last == "t" {
                let col = columnIndex(from: curRef)
                var value = ev.text
                if curType == "s", let idx = Int(ev.text), idx < sharedStrings.count {
                    value = sharedStrings[idx]
                }
                if curRow > 0 && col > 0 {
                    if curType == "inlineStr" && last == "t" {
                        curInline += ev.text
                        value = curInline
                    }
                    grid[curRow, default: [:]][col] = value
                }
            }
        }
        return grid
    }

    private func columnIndex(from ref: String) -> Int {
        var col = 0
        for scalar in ref.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }   // A...Z
            col = col * 26 + Int(scalar.value) - 64
        }
        return col
    }

    private func drawingPath(for sheetPath: String, archive: Archive) -> String? {
        // sheetPath 如 xl/worksheets/sheet1.xml → rels 在 xl/worksheets/_rels/sheet1.xml.rels
        let dir = (sheetPath as NSString).deletingLastPathComponent
        let base = (sheetPath as NSString).lastPathComponent
        guard let sheetData = readEntry(archive, sheetPath),
              let relsData = readEntry(archive, "\(dir)/_rels/\(base).rels") else { return nil }
        var drawingRid: String?
        for ev in collect(sheetData) where ev.path.last == "drawing" {
            drawingRid = ev.attrs["r:id"] ?? ev.attrs["id"]
        }
        guard let rid = drawingRid else { return nil }
        for ev in collect(relsData) where ev.path.last == "Relationship" {
            if ev.attrs["Id"] == rid, let target = ev.attrs["Target"] {
                // target 如 ../drawings/drawing1.xml，相对 worksheets 目录
                let url = URL(fileURLWithPath: "/" + dir).appendingPathComponent(target)
                return String(url.standardizedFileURL.path.dropFirst())
            }
        }
        return nil
    }

    private struct Anchor { let row: Int; let col: Int; let embed: String }

    private func parseDrawing(_ data: Data) -> [Anchor] {
        var anchors: [Anchor] = []
        var curRow = -1, curCol = -1
        var inFrom = false
        for ev in collect(data) {
            guard let raw = ev.path.last else { continue }
            // XMLParser 不处理命名空间时元素名带前缀（xdr:twoCellAnchor、a:blip 等），取本地名比较
            let last = raw.split(separator: ":").last.map(String.init) ?? raw
            let isAnchor = last == "twoCellAnchor" || last == "oneCellAnchor"
            if isAnchor { curRow = -1; curCol = -1 }
            if last == "from" { inFrom = true }
            if last == "to" { inFrom = false }
            if inFrom {
                if last == "col", let v = Int(ev.text) { curCol = v }
                if last == "row", let v = Int(ev.text) { curRow = v }
            }
            if last == "blip" {
                if let embed = ev.attrs["r:embed"] ?? ev.attrs["embed"],
                   curRow >= 0, curCol >= 0 {
                    anchors.append(Anchor(row: curRow, col: curCol, embed: embed))
                }
            }
        }
        return anchors
    }

    private func drawingRels(_ archive: Archive, drawingPath: String) -> [String: String] {
        let dir = (drawingPath as NSString).deletingLastPathComponent
        let base = (drawingPath as NSString).lastPathComponent
        guard let data = readEntry(archive, "\(dir)/_rels/\(base).rels") else { return [:] }
        var map: [String: String] = [:]
        for ev in collect(data) where ev.path.last == "Relationship" {
            if let rid = ev.attrs["Id"], let target = ev.attrs["Target"] {
                let url = URL(fileURLWithPath: "/" + dir).appendingPathComponent(target)
                map[rid] = String(url.standardizedFileURL.path.dropFirst())
            }
        }
        return map
    }
}
