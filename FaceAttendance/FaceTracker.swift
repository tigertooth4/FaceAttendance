import Foundation
import CoreGraphics

/// 极简 IoU 跨帧跟踪器：为检测到的人脸维持稳定的跟踪 ID
/// 仅在相机视频队列上调用，类型整体非隔离。
nonisolated final class FaceTracker {

    struct Track: Sendable {
        let id: Int
        var box: CGRect            // 正立画面像素坐标（原点左上）
        var lastSeen: Int          // 帧号
        var recognized: Bool       // 是否已提取过特征
    }

    private(set) var tracks: [Track] = []
    private var nextId = 1
    private let iouThreshold: CGFloat = 0.20   // 略降阈值，减少 ID 跳变
    // v6.7.7：8 → 60。CPU 检测一轮约 0.7–1.5s（设备日志中位 0.83s），
    // 即相邻两轮检测相隔 25–76 个帧号；maxMisses=8 时每条轨道在下一轮
    // 检测到达前就过期删除，所有脸每轮都换新 ID——识别结果永远挂不到
    // 稳定轨道上（识别全部白费、框全部停留在"…"）。
    // v6.7.8：60 → 150。实测识别与检测并发时轮间隔最差达 76 帧号，
    // 60 仍会把持续可见的脸误判过期（一轮换新 ID 约 15 条）；150 帧
    // 覆盖两个最差轮间隔。扫视残影不再靠这里控制——显示层另有
    // "新鲜度窗口"（v6.7.8 publishOverlays 只画 100 帧内见过的轨道）。
    private let maxMisses = 150    // 丢失帧数上限（按帧号计，覆盖两轮最差检测间隔）
    private let smooth: CGFloat = 0.55         // 位置平滑系数（新位置权重）

    func update(detections: [CGRect], frameIndex: Int) -> [Track] {
        var remaining = detections
        for i in tracks.indices {
            var bestIdx: Int? = nil
            var bestIou: CGFloat = 0
            for (j, det) in remaining.enumerated() {
                let v = iou(tracks[i].box, det)
                if v > bestIou { bestIou = v; bestIdx = j }
            }
            if let j = bestIdx, bestIou >= iouThreshold {
                tracks[i].box = lerp(tracks[i].box, remaining[j], smooth)  // 平滑，减少框抖动
                tracks[i].lastSeen = frameIndex
                remaining.remove(at: j)
            }
        }
        for det in remaining {
            tracks.append(Track(id: nextId, box: det, lastSeen: frameIndex,
                                recognized: false))
            nextId += 1
        }
        tracks.removeAll { frameIndex - $0.lastSeen > maxMisses }
        return tracks
    }

    func reset() { tracks = []; nextId = 1 }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let x1 = max(a.minX, b.minX), y1 = max(a.minY, b.minY)
        let x2 = min(a.maxX, b.maxX), y2 = min(a.maxY, b.maxY)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
