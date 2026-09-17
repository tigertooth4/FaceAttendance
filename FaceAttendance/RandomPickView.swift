import SwiftUI

/// v6.7.18：随机点名——在已提取人脸特征的学生中按均匀分布随机抽一人，
/// 展示证件照（导入花名册时入库的 320px 缩略图）、姓名、学号、班级；
/// 点"重新随机抽取"换一人。每次抽取相互独立，严格均匀。
struct RandomPickView: View {
    let course: Course
    let students: [Student]                 // 全部学生，内部过滤 feature != nil
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Student?

    /// 候选池：只点"提取完特征"的学生（与签到功能同一口径）
    private var candidates: [Student] { students.filter { $0.feature != nil } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("暂无可点名学生", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("请先导入花名册并成功提取人脸特征")
                    }
                } else if let p = picked {
                    // .id(p.id)：换人时整个卡片视为新视图，触发弹出动画
                    VStack(spacing: 24) {
                        avatar(p)
                        VStack(spacing: 8) {
                            Text(p.name)
                                .font(.system(size: 44, weight: .bold))
                            Text("学号 \(p.studentId)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            if !p.className.isEmpty {
                                Text(p.className)
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .id(p.id)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))

                    Button(action: reroll) {
                        Label("重新随机抽取", systemImage: "shuffle")
                            .font(.title3.bold())
                            .padding(.horizontal, 28)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("候选 \(candidates.count) 人 · 均匀随机")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("\(course.name) · 随机点名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .onAppear(perform: reroll)
        }
    }

    /// 证件照头像；旧数据（v6.7.18 之前导入的）没有照片，显示占位图
    @ViewBuilder
    private func avatar(_ s: Student) -> some View {
        if let data = s.photo, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
                .shadow(radius: 8, y: 4)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.quaternary)
                VStack(spacing: 8) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 88))
                        .foregroundStyle(.secondary)
                    Text("重新导入花名册可显示头像")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 220, height: 220)
        }
    }

    private func reroll() {
        guard !candidates.isEmpty else { return }
        let p = candidates.randomElement()!   // 均匀分布，每次独立
        print("[点名-v6.7.24] 抽中 \(p.studentId) \(p.name)（候选 \(candidates.count) 人）")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            picked = p
        }
    }
}
