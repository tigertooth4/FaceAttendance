import Foundation

struct Course: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var createdAt: Date
    var studentCount: Int = 0
}

struct Student: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var courseId: Int64
    var studentId: String      // 学号
    var name: String
    var className: String
    var feature: [Float]?      // 512 维归一化特征
    var photo: Data? = nil     // v6.7.18：证件照缩略图（随机点名头像；旧数据为 nil）
}

/// 一次签到中某学生的合并结果
struct AttendanceRecord {
    var student: Student
    var bestScore: Float
    var hitCount: Int          // 被几个跟踪目标/角度匹配到
    var manual: Bool           // 人工修正确认
}

enum MatchLevel {
    case confirmed    // 绿
    case uncertain    // 橙
    case unknown      // 红

    var thresholdText: String {
        switch self {
        case .confirmed: return "已识别"
        case .uncertain: return "待确认"
        case .unknown: return "未识别"
        }
    }
}

enum Thresholds {
    // ResNet50@WebFace600K 实测标定（90 人花名册 × 201 张真实教室人脸）：
    // 真脸通过率 84%@0.40，误检 0%；0.30~0.40 之间多为光线/角度不佳的真脸 → 待确认
    static var confirmed: Float = 0.40   // 单次相似度 ≥ 此值 → 绿
    static var uncertain: Float = 0.30   // ≥ 此值 → 橙（待确认）

    /// v6.7.1：特征管线版本戳。对齐块方向/像素格式任何变化都要改它，
    /// 导入花名册完成时写入 UserDefaults["featurePipelineVersion"]，
    /// 照片签到与相机扫描据此校验——旧管线特征与新探针余弦≈0
    /// （实测 0.008），必然全红，必须提示重导而不是静默误报。
    static let featurePipelineVersion = "v6.7.5"

    /// v6.7.14：构建版本戳——显示在导入结果行，一张截图即可分辨跑的是哪个
    /// 构建，杜绝"拿旧构建测新修复"的乌龙（v6.7.13 教训：用户重导失败的
    /// 截图里日志标签仍是 [v6.7.12]，证明新包根本没被编译进去）。
    /// 每次发包必改，与日志标签同号。
    static let buildVersion = "v6.7.24"
}

/// 可分享的导出文件（包装 URL 以满足 sheet(item:) 的 Identifiable 要求）
struct ShareableFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct FaceOverlay: Identifiable {
    var id: Int                    // 跟踪目标 ID
    var rect: CGRect               // 正立画面像素坐标（原点左上），尺寸见 engine.orientedImageSize
    var label: String
    var level: MatchLevel
    var score: Float
    var studentId: String?
    var candidates: [(student: Student, score: Float)]
}
