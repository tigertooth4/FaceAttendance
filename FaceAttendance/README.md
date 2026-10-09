# FaceAttendance —— iPhone 人脸扫描签到 App

在 iPhone 上独立运行的人脸识别签到应用：新建课程 → 导入花名册（Excel，含证件照）→ 打开相机实时扫视全班 → 人脸头顶实时标注姓名（绿=已确认 / 橙=待确认 / 红=未识别）→ 完成签到导出 Excel，历次记录永久保存、互不覆盖、可随时分享下载。

- 完全离线：人脸检测（SCRFD，含五点关键点）+ 人脸识别（ResNet50，InsightFace buffalo_l 同款）都以 Core ML 形式在本机运行，不需要网络、不需要服务器。
- 与之前的服务器版系统同源（同一 SCRFD 检测器、同一对齐模板），花名册 Excel 格式完全通用；识别模型已升级为 ResNet50，阈值重新标定（自动确认 0.40 / 待确认 0.30）。

---

## 一、环境要求

| 项目 | 要求 |
|---|---|
| Mac | 能安装 Xcode 14 及以上即可（建议 Xcode 15+） |
| iPhone | iOS 16 及以上（必须真机，模拟器没有摄像头）；建议 iPhone 12 及以上机型 |
| Apple 账号 | 免费个人开发者账号即可（Personal Team），不需要付费 |
| 网络 | 仅首次添加一个 Swift 包依赖时需要联网 |

## 二、目录结构

```
FaceAttendance/
├── FaceAttendance.xcodeproj/     # v6.8.0 起：完整 Xcode 工程（双击即开，无需再手动建工程）
├── 导出IPA安装包.command          # v6.8.0 起：双击一键导出 .ipa（用于 AltStore/Ad Hoc 安装）
├── Sources/                      # 全部 Swift 源码（19 个文件）
│   ├── FaceAttendanceApp.swift   # App 入口
│   ├── Models.swift              # 数据模型、阈值、标注颜色等级
│   ├── Database.swift            # SQLite 存储（课程 / 学生 / 人脸特征）
│   ├── RosterParser.swift        # 花名册 xlsx 解析（照片锚点 → 学号/姓名/班级）
│   ├── SCRFDDetector.swift       # SCRFD 人脸检测 + 五点关键点（1920 全精度 / 640 快检双实例）
│   ├── FaceAligner.swift         # 五点相似变换对齐到 112×112（ArcFace 模板）
│   ├── FaceRecognizer.swift      # ResNet50 特征提取 + 余弦相似度
│   ├── FaceTracker.swift         # IoU 人脸跟踪（跨帧同一人的识别结果累积）
│   ├── AttendanceEngine.swift    # 相机采集(4K) + 检测 + 识别 + 多帧融合 主引擎
│   ├── CameraView.swift          # 相机预览 + 实时标注框/姓名标签 + 双指变焦 + 点击改判
│   ├── CameraCaptureView.swift   # v6.7.15 照片签到内置连拍相机（拍完自动存相册）
│   ├── CourseViews.swift         # 课程列表 / 课程详情（导入花名册）/ 历史记录（内置预览）
│   ├── RandomPickView.swift      # v6.7.18 随机点名（均匀抽取，展示头像/学号/姓名）
│   ├── RandomNumberView.swift    # v6.7.28 随机数生成（输入 n，均匀抽取 1~n，可反复生成）
│   ├── PersonalSignInView.swift  # v6.7.19 个人签到（签到目录/前置相机识别/确认写 Excel）
│   ├── AttendanceView.swift      # 实时扫描签到页面（状态栏、计时、完成导出）
│   ├── PhotoAttendanceView.swift # 照片签到（多照片识别/标注/EXIF 时间/导出）
│   └── MakeupSignView.swift      # v6.9.0 历史记录手动补签（读原表/扫脸/头像库/写回同一份 xlsx）
├── Resources/
│   ├── SCRFD.mlmodel             # 人脸检测模型 SCRFD-10GF（8.5MB，fp16，1920×1920 张量输入，经典 NN 格式）
│   ├── SCRFD640.mlmodel          # 同权重 640² 快检版（8.5MB，v6.7.23 个人签到专用，速度 ×9）
│   ├── ResNet50Face.mlmodel      # 人脸识别模型（87MB，fp16，InsightFace w600k_r50）
│   └── 示例花名册_33310019.xlsx   # 之前实验用的花名册（已转为 xlsx，可直接导入测试）
└── README.md
```

## 三、在 Xcode 中创建工程（约 5 分钟）

代码不依赖任何自动生成的工程文件，按下面步骤手动建一次工程即可，之后双击工程文件随时打开。

### 1. 新建工程

1. 打开 Xcode → **Create New Project…** → 选 **iOS → App** → Next
2. 填写：
   - **Product Name**: `FaceAttendance`
   - **Team**: 选你的 Apple 账号（没有就 Add Account 登录，免费账号即可）
   - **Organization Identifier**: 随便填，如 `com.yourname`
   - **Interface**: **SwiftUI**；**Language**: **Swift**；Storage: None；不勾选 Tests
3. 保存位置随意（比如桌面）。

### 2. 导入源码

1. 在 Finder 中打开本包的 `Sources/` 文件夹，全选 18 个 `.swift` 文件，**拖进 Xcode 左侧工程导航栏**（拖到蓝色的 FaceAttendance 图标下面）。
2. 弹出的选项框中勾选 **Copy items if needed**，**Add to targets: FaceAttendance 打勾**，Finish。
3. 把 Xcode 自动生成的 `ContentView.swift` **删掉**（Move to Trash）——不需要它，入口是 `FaceAttendanceApp.swift`。

### 3. 添加三个模型文件

1. 把 `Resources/` 下的 **SCRFD.mlmodel**、**SCRFD640.mlmodel** 和 **ResNet50Face.mlmodel** 三个文件**一起拖进工程导航栏**，同样勾选 Copy items + Add to targets。（SCRFD640 是 v6.7.23 新增的 640² 快检模型，个人签到专用；**漏拖它个人签到会提示"未找到 SCRFD640 模型"**）
   - **从旧版升级务必注意**：如果工程里已有旧的 SCRFD / ResNet50Face 模型（旧的是 `.mlpackage` 文件夹），先删除旧引用（Move to Trash），再把新的拖进去——v6 版模型已从 mlprogram 改为**经典 neuralnetwork 格式**（设备实测：coremltools 9 转出的 mlprogram 在 iOS 26 上对任意输入都输出"常数签名"，输入张量逐位验证正确、CPU/GPU/ANE 三个后端都试过了，确认是转换管线本身的问题，已整组弃用，换回 2017 年以来最成熟的 NN 编译路径）。
2. 首次编译时 Xcode 会自动把它们编译成 `.mlmodelc`，代码在运行时从 Bundle 加载，无需手写任何模型代码。
   - 若 Xcode 询问是否为模型生成 Swift 类，选不生成也没关系（本工程用的是动态加载）。
   - ResNet50Face 有 87MB，首次编译需要一两分钟，属正常现象。

### 4. 添加唯一的第三方依赖 ZIPFoundation（解析/生成 Excel 用）

1. 选中工程根节点 → 中间面板选 **PROJECT → FaceAttendance → Package Dependencies** 标签 → 点 **+**
2. 右上角搜索框粘贴：`https://github.com/weichsel/ZIPFoundation.git`
3. Dependency Rule 选 **Up to Next Major Version**，点 **Add Package** → 勾选 **ZIPFoundation** → Add Package。

### 5. 配置相机权限、横屏与签名

1. 工程根节点 → **TARGETS → FaceAttendance → Info** 标签 → 在任意一行上点 **+**，键名输入：
   - `Privacy - Camera Usage Description`（或直接输入原始键名 `NSCameraUsageDescription`）
   - 值：`需要使用摄像头扫描全班同学进行签到`
   - ~~再加一行相册写入权限~~（v6.7.31 起拍照不再写系统相册，此键已从工程移除，可忽略）
2. **General → Supported Interface Orientations (iPhone)**：确认勾选了 Portrait + Landscape Left + Landscape Right（Xcode 默认即勾选），这样相机扫描页才能横屏使用。
3. **Signing & Capabilities** 标签 → 勾选 **Automatically manage signing** → Team 选你的账号。
4. **（可选）开启文件共享**：仍在 **Info** 标签点 **+**，键名选 `Application supports iTunes file sharing`（原始键名 `UIFileSharingEnabled`），值设为 **YES**。开启后导出/诊断文件可在"文件"App 或 Mac 访达里直接浏览——v6.6 起画布诊断图已会直接出现在照片签到的结果列表里，此步仅为方便查看其他导出文件，不做也能正常用。
5. 首次部署到 iPhone 时，手机上会提示"不受信任的开发者"：去 **设置 → 通用 → VPN与设备管理** 中信任你的证书即可。

### 6. 运行

1. iPhone 用数据线连接 Mac，Xcode 顶部设备栏选中你的 iPhone（不要选模拟器）。
2. 按 **⌘R** 运行。首次编译模型需要一两分钟，属正常现象。

> 免费个人开发者账号签名的 App 7 天后需要重新按一次 ⌘R（不删 App 数据，直接覆盖安装即可）。

## 四、使用流程

1. **新建课程**：首页右上角 +，输入课程名（如"计算机组成原理 3 班"）。
2. **导入花名册**：进入课程 → 点"导入花名册（.xlsx）" → 选择与服务器版相同格式的 **.xlsx** 文件。
   - 包内附带的 `示例花名册_33310019.xlsx` 就是之前实验用的那份，已转换好，**可直接导入测试**（先把它 AirDrop/微信传到手机"文件"App 里）。
   - **只支持 .xlsx**；老版 `.xls` 请先在 Excel/WPS/Numbers 中"另存为 .xlsx"。
   - 导入时用 SCRFD 在证件照原始分辨率上提取关键点（不再压缩）；导入检测走 CPU fp32 专用路径（数值最准确，绕开神经网络引擎对少数照片的计算偏差），90 人约 5–10 分钟，有进度条。
   - 个别照片偶发失败（连续批量推理的瞬时波动）会**自动重试一次**；得分被异常压低的照片会自动走 0.2 低阈值兜底（带人脸几何校验）；仍失败的会在导入结果下方列出该照片当时的具体诊断（画布/张量/各层最高分）。
   - **旧版本导入过花名册的请重新导入一次**：旧特征是用 Vision 关键点 + MobileFaceNet 提取的，与新模型不通用。
   - **重导 = 全量替换**（v6.7.25 起）：本次名册里没有的学号会从库中移除（结果行会点名"已移除旧名单多出的 N 人"），在名册 Excel 里删人重导即可减员；空名册不触发删除，防止误传空表清掉整班。
3. **开始签到（相机扫描）**：点"开始签到（相机扫描）"进入相机页。
   - 相机采集已升级为 **4K**，检测在 1920 大图上进行，后排小脸也能获得准确关键点。
   - 缓慢平移扫视全班；头顶标签：**绿**=已确认（单次相似度≥0.40，或多帧均≥0.30）、**橙**=待确认（0.30–0.40）、**红**=未识别到对应学生。
   - **横屏**：直接旋转手机即可，预览与人脸框会一起转（若手机开了"竖排方向锁定"，界面不转属正常，解锁即可）。
   - 后排脸太小时：双指放大画面，或走近一些再扫，标签会逐渐变绿/变橙。
   - **点击任何人脸框**可打开人工改判：从 Top-5 候选人中选，或按学号/姓名搜索指定，也可标记"非本班人员"。人工改判优先级最高。
4. **完成签到**：右下角"完成签到"→ 自动导出 Excel 并弹出系统分享面板（可存到"文件"、发微信/邮件/AirDrop 到电脑）。

**照片签到（与相机扫描并行，可任选其一或都用）**：课程详情页 →"照片签到"→ 多选班级照片，**或点"拍摄班级照片"用内置相机连拍（自动存入系统相册）后点"开始签到"** → App 自动逐张检测、识别、在照片上标注姓名（绿/橙/红框）→ 多照片融合（同一人在多张照片中命中会提升置信度）→ **Excel 自动保存到本场次文件夹**（v6.7.24 起；历史考勤记录中可随时导出），点"保存签到结果到 Excel"可立即分享。
- 签到时间自动取照片的 **EXIF 拍摄时间**（多张照片取最早一张；无 EXIF 则用当前时间）
- 每场签到的标注图/原图/Excel/诊断图统一收在一个场次文件夹（如"9月23日周三14点05分的签到"，历史记录中可预览/分享）；旧版本遗留的散装文件在"其他文件"区，可手动清理
- 融合规则：单次相似度 ≥0.40 直接确认；同一人 ≥2 张照片均 ≥0.30 也确认；其余 0.30–0.40 为待确认
**个人签到（v6.7.19 新增）**：课程详情页 →"个人签到"→ 新建签到目录（名称+日期，自动建好签到表.xlsx）→ 点目录打开前置摄像头 → 学生逐个面对镜头，绿框显示姓名后点"确认签到"（已签过的自动置灰防重复）→ 签到表随时可从目录列表分享导出。

**随机点名（v6.7.18 新增）**：课程详情页 →"随机点名"→ 从已提取特征的学生中均匀随机抽一人，展示证件照/姓名/学号/班级；点"重新随机抽取"换下一人。旧花名册重导一次即可显示头像。

5. **历史记录**：课程详情页 → "历史考勤记录"，列出每次签到的 Excel（文件名含日期时间，**每次考勤都是新文件，绝不覆盖旧文件**）。点文件名可在 App 内直接预览表格；点右侧分享图标可导出/发送；左滑删除。

### 导出的 Excel 列

`序号 / 学号 / 姓名 / 班级 / 签到状态 / 确认方式 / 命中帧数 / 最高相似度 / 签到时间`

- 签到状态：已签到（绿）/ 待确认（橙，行底色浅黄）/ 缺勤（红，行底色浅红）
- 确认方式：自动确认 / 多角度确认 / 人工修正 / —（缺勤）

## 五、识别精度说明（本次升级的依据）

用之前的 90 人花名册 + 5 张真实教室照片（共 201 张人脸）做了对照实验：

| 指标 | 旧 MobileFaceNet | 新 ResNet50 |
|---|---|---|
| 阈值 0.40 时真脸通过率 | 63% | **84%** |
| 阈值 0.40 时误判率 | ~0% | **0%** |
| 跨照片同一人识别一致性 | 84% | **89%** |

识别模型升级之外，更关键的是**检测与对齐**：旧版用 Apple Vision 地标，小脸（后排）关键点抖动大，导致对齐歪、分数低；现在改用与服务器版同源的 **SCRFD 检测器**（1920 大图输入），五点关键点精度显著提升——这正是服务器版效果好的原因。 检测输入渲染完全自控（letterbox 居中补黑、小图 1:1 不放大），不经 Vision 黑盒。

- **橙色是正常且必要的中间态**：证件照 vs 现场抓拍差异客观存在，光线/角度不佳的真脸会落在 0.30–0.40，点橙色框手动确认即可。
- **两个人被识别成同一人**：同框两张脸都匹配到同一学生时，分数高者保留，另一张自动降为待确认；此外 top1/top2 分差 < 0.05 的歧义结果不会自动变绿。
- **光线**：逆光或太暗会显著降低识别率，尽量面向窗户/光源方向扫视。
- **花名册里有人没照片**：该学生无法被自动识别，签到时可手动点任意红框改判成他，或事后在 Excel 里补录。

## 六、调参

| 想调整什么 | 改哪里 |
|---|---|
| 自动确认阈值（默认 0.40） | `Models.swift` 中 `Thresholds.confirmed` |
| 待确认阈值（默认 0.30） | `Models.swift` 中 `Thresholds.uncertain` |
| 跟踪丢失容忍帧数 | `FaceTracker.swift` 中 `maxMisses` |
| 框平滑程度（0~1，越大越跟手但越抖） | `FaceTracker.swift` 中 `smooth` |
| 检测频率（默认每 2 帧一次） | `AttendanceEngine.swift` 中 `frameIndex % 2`（手机发热可改为 3） |
| 检测大图尺寸（默认 1920） | 需重新转换模型，见 `SCRFDDetector.swift` 注释 |

- **换手机/重装 App 后数据**：课程与历史 Excel 存在 App 沙盒 Documents 内，卸载 App 会删除；重要记录请及时用分享面板导出保存。

## 七、与服务器版的关系

- 花名册 Excel 格式、检测器（SCRFD-10GF）、对齐模板完全一致，两边结果可互相印证。
- 识别模型：服务器版默认 MobileFaceNet（轻量），iOS 版已升级 ResNet50（w600k_r50，buffalo_l 同款）。如需对齐，服务器版替换识别模型后按本 README 第五节的标定方法重设阈值即可。
- iOS 版为单机离线 App，不依赖服务器；服务器版继续可用，互不影响。


