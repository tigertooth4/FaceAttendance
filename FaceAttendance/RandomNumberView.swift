import SwiftUI

/// v6.7.30：随机数生成——与随机点名并列的课堂工具。
/// 输入正整数 n，点"生成"按均匀分布抽取 [1, n] 闭区间内的随机整数；
/// 可重复点击生成（每次独立），n 随时可改（改完点生成即按新范围抽）。
struct RandomNumberView: View {
    let course: Course
    @Environment(\.dismiss) private var dismiss
    @State private var nText = ""
    @State private var value: Int?
    @State private var rangeText: String?      // 已生效的范围提示
    @State private var inputError: String?
    @State private var drawId = UUID()       // 每次生成换标识：同数连出也播弹出动画
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // n 输入区：始终可编辑，随时改
                HStack(spacing: 12) {
                    Text("n =")
                        .font(.title2.bold())
                    TextField("输入正整数", text: $nText)
                        .keyboardType(.numberPad)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 160)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .focused($fieldFocused)
                        .onSubmit { generate() }
                }
                .padding(.top, 20)
                if let e = inputError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }

                Spacer()

                // 结果区：大数字，换数时弹出动画
                if let v = value {
                    Text("\(v)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .padding(.horizontal, 32)
                        .id(drawId)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    if let r = rangeText {
                        Text(r)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Image(systemName: "dice")
                        .font(.system(size: 88))
                        .foregroundStyle(.quaternary)
                }

                Spacer()

                Button(action: generate) {
                    Label("生成", systemImage: "dice.fill")
                        .font(.title3.bold())
                        .padding(.horizontal, 36)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("\(course.name) · 随机数生成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .onTapGesture { fieldFocused = false }   // 点空白处收键盘
        }
    }

    private func generate() {
        fieldFocused = false
        guard let n = Int(nText.trimmingCharacters(in: .whitespaces)), n >= 1 else {
            inputError = "请输入正整数（≥ 1）"
            return
        }
        inputError = nil
        let v = Int.random(in: 1...n)   // 闭区间均匀分布，每次独立
        print("[随机数-v6.7.30] 抽中 \(v)（范围 1...\(n)）")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            value = v
            rangeText = "范围 1 ~ \(n) · 均匀随机"
            drawId = UUID()
        }
    }
}
