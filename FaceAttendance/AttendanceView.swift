import SwiftUI
import UniformTypeIdentifiers

/// 扫描签到界面：全屏相机 + 实时人脸标签 + 底部状态栏 + 修正弹窗
struct AttendanceView: View {
    let course: Course
    let students: [Student]

    @StateObject private var engine = AttendanceEngine()
    @Environment(\.dismiss) private var dismiss

    @State private var tappedOverlay: FaceOverlay?
    @State private var showFinishAlert = false
    @State private var exportedFile: ShareableFile?
    @State private var finishError: String?

    var body: some View {
        ZStack {
            CameraView(engine: engine) { overlay in
                tappedOverlay = overlay
            }
            .ignoresSafeArea()

            VStack {
                // 顶部状态条
                HStack(spacing: 16) {
                    Label("\(engine.confirmedCount)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Label("\(engine.uncertainCount)", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                    Label("\(engine.unknownFaces)", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    if let t = engine.startedAt {
                        Text(t, style: .timer).monospacedDigit()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()

                Spacer()

                // v6.7.6：方向自校准未锁定期间（框暂缓发布）给出提示，
                // 避免用户疑惑"怎么一个框都没有"；锁定后自动消失
                if !engine.orientationLocked {
                    Text("正在校准画面方向…对准全班后数秒内出框")
                        .font(.footnote)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                // v6.7.11：待识别的脸不再画框，识别到谁才亮谁的框——
                // 提示语同步说明，避免"框变少以为没检测到"的误解
                Text("缓慢扫视全班，扫到人脸停半秒（v6.7.16 起识别大幅提速，停顿即多次采样）；剩余人数看顶部红色计数；可走近或双指放大让后排变绿")
                    .font(.footnote)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())

                HStack {
                    Button(role: .destructive) {
                        engine.stop()
                        dismiss()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Spacer()

                    Button { showFinishAlert = true } label: {
                        Label("完成签到", systemImage: "checkmark")
                            .font(.headline)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding()
            }

            if let err = engine.error {
                VStack {
                    Spacer()
                    Text(err)
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                    Spacer()
                }
            }
        }
        .onAppear {
            engine.configure(course: course, students: students)
            engine.start()
        }
        .onDisappear { engine.stop() }
        .alert("结束本次签到并保存考勤表？", isPresented: $showFinishAlert) {
            Button("保存", role: .none) { finish() }
            Button("继续签到", role: .cancel) {}
        } message: {
            Text("已确认 \(engine.confirmedCount) 人，待确认 \(engine.uncertainCount) 人")
        }
        .alert("导出失败", isPresented: .constant(finishError != nil)) {
            Button("好") { finishError = nil }
        } message: { Text(finishError ?? "") }
        .sheet(item: $tappedOverlay) { overlay in
            CorrectionSheet(overlay: overlay, students: students) { sid in
                engine.manualAssign(trackId: overlay.id, studentId: sid)
                tappedOverlay = nil
            }
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func finish() {
        guard let result = engine.finish() else { return }
        engine.stop()
        do {
            let url = try AttendanceExporter().export(
                courseName: course.name, startedAt: result.startedAt, rows: result.rows)
            exportedFile = ShareableFile(url: url)  // 弹出分享面板；文件已长期保存在 Documents/exports/
        } catch {
            finishError = error.localizedDescription
        }
    }
}

// MARK: - 修正弹窗

struct CorrectionSheet: View {
    let overlay: FaceOverlay
    let students: [Student]
    let onSelect: (String?) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !overlay.candidates.isEmpty {
                    Section("候选（按相似度排序）") {
                        // 元组数组不能直接用于 key-path，按下标遍历
                        ForEach(overlay.candidates.indices, id: \.self) { i in
                            let c = overlay.candidates[i]
                            candidateRow(c.student, score: c.score)
                        }
                    }
                }
                Section("全部学生") {
                    TextField("搜索学号 / 姓名", text: $search)
                    ForEach(filtered, id: \.studentId) { s in
                        candidateRow(s, score: nil)
                    }
                }
                Section {
                    Button("标记为「非本班」", role: .destructive) {
                        onSelect(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("修正：\(overlay.label)")
            .toolbar { Button("取消") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    private var filtered: [Student] {
        if search.isEmpty { return [] }
        return students.filter {
            $0.studentId.contains(search) || $0.name.contains(search)
        }
    }

    private func candidateRow(_ s: Student, score: Float?) -> some View {
        Button {
            onSelect(s.studentId)
            dismiss()
        } label: {
            HStack {
                Text("\(s.className)  \(s.name)（\(s.studentId)）")
                    .foregroundStyle(.primary)
                Spacer()
                if let score {
                    Text(String(format: "%.1f%%", score * 100))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
