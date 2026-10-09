import Foundation
import SQLite3

/// 轻量 SQLite 封装（使用 iOS 内置 libsqlite3）
final class Database {
    static let shared = Database()
    private var db: OpaquePointer?

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let path = dir.appendingPathComponent("attendance.db").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            fatalError("无法打开数据库: \(path)")
        }
        migrate()
    }

    private func migrate() {
        // 注意：必须用 sqlite3_exec（可多语句）；sqlite3_prepare_v2 只会执行第一条语句
        let sql = """
        CREATE TABLE IF NOT EXISTS courses(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS students(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            course_id INTEGER NOT NULL,
            student_id TEXT NOT NULL,
            name TEXT NOT NULL,
            class_name TEXT NOT NULL DEFAULT '',
            feature BLOB,
            photo BLOB,
            UNIQUE(course_id, student_id));
        CREATE INDEX IF NOT EXISTS idx_students_course ON students(course_id);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            fatalError("数据库初始化失败: \(String(cString: sqlite3_errmsg(db)))")
        }
        // v6.7.18：旧库补 photo 列（CREATE TABLE IF NOT EXISTS 不会给已有表加列）
        let cols = query("PRAGMA table_info(students)").compactMap { $0["name"] as? String }
        if !cols.contains("photo") {
            _ = exec("ALTER TABLE students ADD COLUMN photo BLOB")
            print("[点名-v6.7.30] 旧库迁移：students 表已补 photo 列")
        }
    }

    @discardableResult
    func exec(_ sql: String, _ bind: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        if let s = stmt { bind?(s) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func query(_ sql: String, _ bind: ((OpaquePointer) -> Void)? = nil) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let s = stmt { bind?(s) }
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let n = sqlite3_column_count(stmt)
            for i in 0..<n {
                let key = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[key] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:   row[key] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:    row[key] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let len = sqlite3_column_bytes(stmt, i)
                    if let ptr = sqlite3_column_blob(stmt, i) {
                        row[key] = Data(bytes: ptr, count: Int(len))
                    }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - 绑定辅助
    static func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ s: String) {
        sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    static func bindBlob(_ stmt: OpaquePointer, _ idx: Int32, _ floats: [Float]) {
        _ = floats.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(ptr.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    // MARK: - 课程
    func createCourse(name: String) -> Int64 {
        exec("INSERT INTO courses(name, created_at) VALUES(?, ?)") { s in
            Database.bindText(s, 1, name)
            sqlite3_bind_double(s, 2, Date().timeIntervalSince1970)
        }
        return sqlite3_last_insert_rowid(db)
    }

    func listCourses() -> [Course] {
        query("""
        SELECT c.id, c.name, c.created_at, COUNT(s.id) AS cnt,
               COUNT(s.feature) AS fcnt
        FROM courses c LEFT JOIN students s ON s.course_id = c.id
        GROUP BY c.id ORDER BY c.id DESC
        """).map { r in
            Course(id: r["id"] as! Int64,
                   name: r["name"] as! String,
                   createdAt: Date(timeIntervalSince1970: r["created_at"] as! Double),
                   studentCount: Int(r["cnt"] as! Int64),
                   // v6.7.30：COUNT(列) 只数非 NULL 行——即已提取特征的人数
                   featureCount: Int(r["fcnt"] as! Int64))
        }
    }

    func deleteCourse(_ id: Int64) {
        exec("DELETE FROM students WHERE course_id=?") { sqlite3_bind_int64($0, 1, id) }
        exec("DELETE FROM courses WHERE id=?") { sqlite3_bind_int64($0, 1, id) }
    }

    // MARK: - 学生
    func upsertStudent(courseId: Int64, studentId: String, name: String,
                       className: String, feature: [Float]?, photo: Data? = nil) {
        exec("""
        INSERT INTO students(course_id, student_id, name, class_name, feature, photo)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(course_id, student_id) DO UPDATE SET
          name=excluded.name, class_name=excluded.class_name,
          feature=excluded.feature, photo=excluded.photo
        """) { s in
            sqlite3_bind_int64(s, 1, courseId)
            Database.bindText(s, 2, studentId)
            Database.bindText(s, 3, name)
            Database.bindText(s, 4, className)
            if let f = feature { Database.bindBlob(s, 5, f) } else { sqlite3_bind_null(s, 5) }
            if let d = photo {
                _ = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(s, 6, ptr.baseAddress, Int32(ptr.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else { sqlite3_bind_null(s, 6) }
        }
    }

    func students(courseId: Int64) -> [Student] {
        query("SELECT * FROM students WHERE course_id=? ORDER BY class_name, student_id") {
            sqlite3_bind_int64($0, 1, courseId)
        }.map { r in
            var feature: [Float]? = nil
            if let data = r["feature"] as? Data {
                feature = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            return Student(id: r["id"] as! Int64,
                           courseId: courseId,
                           studentId: r["student_id"] as! String,
                           name: r["name"] as! String,
                           className: r["class_name"] as? String ?? "",
                           feature: feature,
                           photo: r["photo"] as? Data)
        }
    }

    /// v6.7.30：名册全量替换语义——删除本次名册之外的学生（旧名单残留）。
    /// 旧实现重新导入只 upsert 不删除：从名册里删掉的学生永远留在库中，
    /// 总人数停在旧人数不变。返回被移除者名单（结果提示用）。
    @discardableResult
    func deleteStudentsNotIn(courseId: Int64, keepIds: Set<String>) -> [String] {
        let stale = students(courseId: courseId).filter { !keepIds.contains($0.studentId) }
        for st in stale {
            exec("DELETE FROM students WHERE id=?") { sqlite3_bind_int64($0, 1, st.id) }
        }
        return stale.map { "\($0.studentId) \($0.name)" }
    }

    func studentCount(courseId: Int64) -> Int {
        let r = query("SELECT COUNT(*) c FROM students WHERE course_id=?") {
            sqlite3_bind_int64($0, 1, courseId)
        }
        return Int(r.first?["c"] as? Int64 ?? 0)
    }

    func featureCount(courseId: Int64) -> Int {
        let r = query("SELECT COUNT(*) c FROM students WHERE course_id=? AND feature IS NOT NULL") {
            sqlite3_bind_int64($0, 1, courseId)
        }
        return Int(r.first?["c"] as? Int64 ?? 0)
    }
}
