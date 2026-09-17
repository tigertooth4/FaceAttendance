import Foundation
import ZIPFoundation

/// 最小化 xlsx 写入器（内联字符串，无需共享字符串表）。
final class AttendanceExporter {

    enum Style: Int32 {
        case normal = 0, header = 1, absent = 2, uncertain = 3
    }

    /// 生成考勤 xlsx。
    /// - records: 全部学生的考勤行（出勤状态、确认方式、命中次数、最高相似度）
    func export(courseName: String, startedAt: Date,
                rows: [(student: Student, present: Bool, method: String,
                        hits: Int, score: Float)]) throws -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = df.string(from: startedAt)
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let timeText = df.string(from: startedAt)

        let total = rows.count
        let present = rows.filter { $0.present }.count

        var lines: [[(String, Style)]] = []
        lines.append([("\(courseName)  考勤表", .header)])
        lines.append([("时间：\(timeText)", .normal)])
        lines.append([("应到：\(total) 人    实到：\(present) 人    缺勤：\(total - present) 人", .normal)])
        lines.append([("注：「待确认」为低置信度识别结果，请核对后再作为最终依据。", .normal)])
        lines.append([])
        lines.append([("序号", .header), ("学号", .header), ("姓名", .header), ("班级", .header),
                      ("出勤", .header), ("确认方式", .header), ("识别次数", .header), ("最高相似度", .header)])
        for (i, r) in rows.enumerated() {
            let style: Style = r.present ? (r.method == "待确认" ? .uncertain : .normal) : .absent
            lines.append([(String(i + 1), style),
                          (r.student.studentId, style),
                          (r.student.name, style),
                          (r.student.className, style),
                          (r.present ? "√" : "缺勤", style),
                          (r.present ? r.method : "", style),
                          (r.present ? String(r.hits) : "", style),
                          (r.present && r.score > 0 ? String(format: "%.3f", r.score) : "", style)])
        }

        let data = try buildXLSX(lines: lines)

        // v6.7.12：保存到本场次文件夹 Documents/exports/<课程名>/<场次>/
        // （如"9月23日周三14点05分的签到"），与当场的标注图/原图/诊断图放一起
        let dir = Self.sessionDir(courseName: courseName, date: startedAt)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fileURL = dir.appendingPathComponent("\(Self.sanitize(courseName))_\(stamp).xlsx")
        var n = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {  // 同一分钟重复签到也不覆盖
            n += 1
            fileURL = dir.appendingPathComponent("\(Self.sanitize(courseName))_\(stamp)_\(n).xlsx")
        }
        try data.write(to: fileURL)
        return fileURL
    }

    /// v6.7.12：场次文件夹——Documents/exports/<课程名>/<M月d日周XH点mm分的签到>。
    /// 相机场次取签到开始时间，照片场次取最早一张照片的拍摄时间（EXIF）。
    /// 同一分钟的两场会合并进同一文件夹（内部文件名带秒级时间戳，不会互相覆盖）
    static func sessionDir(courseName: String, date: Date) -> URL {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日EEEH点mm分的签到"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("exports").appendingPathComponent(sanitize(courseName))
            .appendingPathComponent(df.string(from: date))
    }

    /// v6.7.19：个人签到表整表重建（源数据是签到目录里的 CSV，行数少，
    /// 每次确认后全量重写 xlsx，避免增量改 zip 的复杂度与损坏风险）。
    /// rows 每行固定 5 列：序号/学号/姓名/签到日期/签到时间
    func rebuildPersonal(title: String, rows: [[String]], to url: URL) throws {
        var lines: [[(String, Style)]] = []
        lines.append([(title, .header)])
        lines.append([("共 \(rows.count) 人已签到", .normal)])
        lines.append([])
        lines.append([("序号", .header), ("学号", .header), ("姓名", .header),
                      ("签到日期", .header), ("签到时间", .header)])
        for r in rows { lines.append(r.map { ($0, .normal) }) }
        let data = try buildXLSX(lines: lines)
        try data.write(to: url, options: .atomic)
    }

    static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
    }

    // MARK: - xlsx 组装

    private func colLetter(_ idx: Int) -> String {
        var n = idx + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func buildXLSX(lines: [[(String, Style)]]) throws -> Data {
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <cols>
          <col min="1" max="1" width="6" customWidth="1"/>
          <col min="2" max="2" width="18" customWidth="1"/>
          <col min="3" max="3" width="12" customWidth="1"/>
          <col min="4" max="4" width="12" customWidth="1"/>
          <col min="5" max="5" width="8" customWidth="1"/>
          <col min="6" max="6" width="14" customWidth="1"/>
          <col min="7" max="8" width="10" customWidth="1"/>
        </cols>
        <sheetData>
        """
        for (r, line) in lines.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, cell) in line.enumerated() {
                let ref = "\(colLetter(c))\(r + 1)"
                sheet += "<c r=\"\(ref)\" t=\"inlineStr\" s=\"\(cell.1.rawValue)\"><is><t xml:space=\"preserve\">\(escape(cell.0))</t></is></c>"
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2">
          <font><sz val="11"/><name val="Calibri"/></font>
          <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
        </fonts>
        <fills count="5">
          <fill><patternFill patternType="none"/></fill>
          <fill><patternFill patternType="gray125"/></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/></patternFill></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FFFCE4EC"/></patternFill></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FFFFF4E0"/></patternFill></fill>
        </fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="4">
          <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
          <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
          <xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
          <xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="常规" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """

        let files: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="考勤统计" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheet),
        ]

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        guard let archive = try? Archive(url: tmp, accessMode: .create, pathEncoding: nil) else {
            throw NSError(domain: "XLSX", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建压缩包"])
        }
        for (path, content) in files {
            let data = Data(content.utf8)
            // provider 会被按 bufferSize 分块多次调用，必须按 position/size 返回对应切片，
            // 否则大文件（sheet XML 通常 >16KB）会被重复写入导致 xlsx 损坏
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count)) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        let data = try Data(contentsOf: tmp)
        try? FileManager.default.removeItem(at: tmp)
        return data
    }
}
