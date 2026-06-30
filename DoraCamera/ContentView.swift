//
//  ContentView.swift
//  DoraCamera
//

import SwiftUI  // 导入 SwiftUI 框架，提供视图、动画等 UI 能力
import AVKit    // 导入 AVKit 框架，提供 AVPlayer 等音视频播放能力（CameraPreview 内部使用）

struct ContentView: View {  // 定义根视图结构体，遵循 View 协议
    /// 可展开二级选项的工具。
    private enum Tool { case zoom, frameRate, iso, shutter }  // 枚举四种可展开二级菜单的工具：变焦、帧率、ISO、快门

    @StateObject private var camera = CameraManager()   // 创建并持有 CameraManager 实例；@StateObject 保证视图生命周期内只初始化一次
    /// 当前展开二级横向选项的工具(nil 表示都收起)。
    @State private var expandedTool: Tool?  // 追踪当前展开的工具；nil 表示所有二级菜单都收起

    var body: some View {           // View 协议要求的 body，描述该视图的内容
        ZStack {                    // 将子视图叠加在同一层（黑色背景在最底层）
            Color.black.ignoresSafeArea()   // 整屏黑色背景，忽略安全区域延伸到边缘

            switch camera.status {              // 根据相机当前状态决定展示哪个子视图
            case .configured, .unconfigured:   // 已配置或首次未配置时，都展示相机界面（配置在 onAppear 触发）
                cameraUI
            case .unauthorized:                // 用户拒绝相机权限时，展示引导去设置的视图
                permissionDenied
            case .failed(let message):         // 相机初始化失败时，展示错误信息
                errorView(message)
            }
        }
        .onAppear { camera.configure() }    // 视图出现时启动相机配置流程（申请权限、创建 session）
        .onDisappear { camera.stopSession() }   // 视图消失时停止 session，释放摄像头资源
        .statusBarHidden()  // 隐藏顶部状态栏，保持全屏沉浸感
    }

    // MARK: - 相机界面

    private var cameraUI: some View {
        ZStack(alignment: .top) {   // 子视图叠加，统一顶部对齐
            CameraPreview(
                session: camera.session,
                currentZoom: camera.selectedZoomFactor,
                onFocus: { camera.focus(at: $0) },
                onZoomBegan: { camera.beginZoomGesture() },
                onZoomChanged: { camera.updateZoomGesture(factor: $0) },
                onZoomEnded: { camera.endZoomGesture() }
            )   // 相机预览层，点击对焦，双指缩放
                .aspectRatio(9.0 / 16.0, contentMode: .fit)     // 固定 9:16 宽高比，防止预览画面拉伸
                .frame(maxWidth: .infinity, alignment: .top)     // 横向撑满、顶部对齐

            VStack {            // 垂直排列：顶部工具栏 + 弹性空隙 + 底部控件
                topBar          // 顶部工具栏（分辨率、闪光灯、录制指示器）
                Spacer()        // 弹性空隙，将底部控件推到最底部
                bottomControls  // 底部控件区域（工具行、录制按钮等）
            }
        }
    }

    private var topBar: some View {
        HStack {                // 水平排列：左侧分辨率按钮 + 弹性空隙 + 右侧闪光灯按钮
            resolutionButton    // 左上角分辨率切换按钮
            Spacer()            // 将两个按钮分别推到左右两端
            flashButton         // 右上角闪光灯切换按钮
        }
        .overlay {                                              // 在 HStack 上叠加录制指示器
            if camera.isRecording { recordingIndicator }        // 仅录制中才显示红点+时长，居中覆盖
        }
        .padding(.horizontal)       // 左右各加默认水平内边距，避免贴边
        .padding(.top, 8)           // 顶部额外 8pt 间距，与安全区上沿留出呼吸空间
    }

    /// 录制中的红点 + 时长，居中显示。
    private var recordingIndicator: some View {
        HStack(spacing: 6) {    // 红点与时长文字水平排列，间距 6pt
            Circle()            // 绘制圆形作为录制红点
                .fill(.red)                     // 填充红色
                .frame(width: 10, height: 10)   // 固定 10×10pt 大小
            Text(timeString(camera.recordedDuration))   // 显示已录制时长，格式化为 MM:SS
                .font(.system(.body, design: .monospaced))  // 等宽字体，防止数字跳动引起布局抖动
                .foregroundStyle(.white)        // 白色文字
        }
        .padding(.horizontal, 12)   // 左右内边距，让胶囊形背景不紧贴文字
        .padding(.vertical, 6)      // 上下内边距
        .background(.black.opacity(0.4), in: Capsule())     // 半透明黑色胶囊背景
        .upright(camera.controlRotationDegrees)             // 随机身旋转反向补偿，保持视觉直立
    }

    /// 左上角分辨率切换（点击循环 720P/1080P/4K，仿系统相机）。
    private var resolutionButton: some View {
        Button {
            camera.cycleResolution()    // 点击后循环切换分辨率（720P → 1080P → 4K → 720P …）
        } label: {
            Text(camera.selectedResolution.displayName)     // 显示当前分辨率的名称字符串
                .font(.system(size: 13, weight: .bold, design: .rounded))   // 13pt 粗体圆角字体
                .foregroundStyle(.white)        // 白色文字
                .frame(minWidth: 40)            // 最小宽度 40pt，防止短文本时胶囊过窄
                .padding(.vertical, 6)          // 垂直内边距
                .padding(.horizontal, 12)       // 水平内边距
                .background(.black.opacity(0.4), in: Capsule())     // 半透明黑色胶囊背景
                .upright(camera.controlRotationDegrees)             // 随机身旋转反向补偿
        }
        .disabled(camera.isRecording)               // 录制中禁止切换分辨率（切换会中断 session）
        .opacity(camera.isRecording ? 0.5 : 1)      // 禁用时降低透明度，给用户视觉反馈
    }

    /// 右上角闪光灯切换（点击循环 关闭/自动/打开）。
    private var flashButton: some View {
        Button {
            camera.cycleFlash()     // 点击后循环切换闪光灯模式（off → auto → on → off …）
        } label: {
            Image(systemName: camera.selectedFlash.icon)    // 用 SF Symbol 显示当前闪光灯状态图标
                .font(.system(size: 16, weight: .semibold)) // 16pt 半粗体
                .foregroundStyle(camera.selectedFlash == .off ? .white : .yellow)   // 关闭时白色，其余状态黄色
                .frame(width: 38, height: 38)               // 固定 38×38pt 点击热区
                .background(.black.opacity(0.4), in: Circle())  // 半透明黑色圆形背景
                .upright(camera.controlRotationDegrees)         // 随机身旋转反向补偿
        }
        .disabled(camera.isRecording)               // 录制中禁止切换闪光灯
        .opacity(camera.isRecording ? 0.5 : 1)      // 禁用时半透明
    }

    private var bottomControls: some View {
        VStack(spacing: 20) {   // 底部各控件垂直排列，间距 20pt
            if let message = camera.lastSaveMessage {   // 有保存提示时才显示（如"已保存到相册"）
                Text(message)
                    .font(.footnote)                    // 小字体
                    .foregroundStyle(.white)            // 白色文字
                    .padding(.horizontal, 12)           // 水平内边距
                    .padding(.vertical, 6)              // 垂直内边距
                    .background(.black.opacity(0.5), in: Capsule())     // 半透明黑色胶囊背景
                    .upright(camera.controlRotationDegrees)             // 随机身旋转反向补偿
                    .transition(.opacity)               // 消失/出现时用透明度过渡动画
            }

            optionsRow  // 二级选项横向滚动行（展开某工具时才渲染）

            toolRow     // 一级工具按钮行（FPS、快门、ISO）

            HStack {                    // 最底部一行：左侧缩略图、中间录制按钮、右侧切换镜头
                Spacer()                // 左侧弹性空间，将录制按钮推向中间
                recordButton            // 中间录制按钮
                Spacer()                // 右侧弹性空间
            }
            .overlay(alignment: .leading) {         // 在 HStack 左侧叠加缩略图按钮
                if !camera.isRecording {            // 录制中隐藏，避免误触
                    thumbnailButton.padding(.leading, 32)   // 左边距 32pt，与录制按钮保持距离
                }
            }
            .overlay(alignment: .trailing) {        // 在 HStack 右侧叠加切换镜头按钮
                if !camera.isRecording {            // 录制中隐藏
                    switchButton.padding(.trailing, 32)     // 右边距 32pt
                }
            }
        }
        .animation(.easeInOut, value: camera.lastSaveMessage)  // lastSaveMessage 变化时，保存提示淡入淡出
    }

    /// 录制按钮上方的一排工具按钮（目前仅帧率，后续可继续添加）。
    private var toolRow: some View {
        HStack(spacing: 24) {   // 工具按钮水平排列，间距 24pt
            zoomMenuButton       // 变焦工具按钮
            frameRateMenuButton  // 帧率工具按钮
            shutterMenuButton    // 快门工具按钮
            isoMenuButton        // ISO 工具按钮
            // 后续在此添加更多工具按钮
        }
    }

    /// 变焦切换：一级显示当前变焦倍数，点击在上方展开横向选项。
    private var zoomMenuButton: some View {
        Button {
            toggle(.zoom)    // 点击时展开/收起变焦二级选项
        } label: {
            let displayVal = camera.availableZoomOptions.first(where: { abs($0.factor - camera.selectedZoomFactor) < 0.05 })?.label ?? "\(String(format: "%.1f", camera.selectedZoomFactor))x"
            toolButtonLabel(
                title: "变焦",
                value: displayVal,
                active: expandedTool == .zoom
            )
        }
    }

    /// ISO 切换：一级显示当前 ISO，点击在上方展开横向选项。
    private var isoMenuButton: some View {
        Button {
            toggle(.iso)    // 点击时展开/收起 ISO 二级选项
        } label: {
            toolButtonLabel(
                title: "ISO",   // 按钮上行显示类别名
                value: camera.selectedISO == 0 ? "自动" : "\(camera.selectedISO)",  // ISO 为 0 表示自动，否则显示数值
                active: expandedTool == .iso    // ISO 二级菜单展开时高亮按钮
            )
        }
        .disabled(camera.isRecording)               // 录制中不允许修改 ISO
        .opacity(camera.isRecording ? 0.4 : 1)      // 禁用时降低透明度
    }

    /// 帧率切换：一级显示当前帧率，点击在上方展开横向选项。
    private var frameRateMenuButton: some View {
        Button {
            toggle(.frameRate)  // 点击时展开/收起帧率二级选项
        } label: {
            toolButtonLabel(
                title: "FPS",               // 按钮上行显示类别名
                value: "\(camera.selectedFrameRate)",   // 下行显示当前帧率数值
                active: expandedTool == .frameRate      // 帧率二级菜单展开时高亮按钮
            )
        }
        .disabled(camera.isRecording)               // 录制中不允许修改帧率
        .opacity(camera.isRecording ? 0.4 : 1)      // 禁用时降低透明度
    }

    /// 曝光时间(快门)切换：一级显示当前快门，点击在上方展开横向选项。
    private var shutterMenuButton: some View {
        Button {
            toggle(.shutter)    // 点击时展开/收起快门二级选项
        } label: {
            toolButtonLabel(
                title: "快门",  // 按钮上行显示类别名
                value: camera.selectedShutter.seconds == nil ? "自动" : camera.selectedShutter.label,  // nil 表示自动快门，否则显示具体值
                active: expandedTool == .shutter    // 快门二级菜单展开时高亮按钮
            )
        }
        .disabled(camera.isRecording)               // 录制中不允许修改快门
        .opacity(camera.isRecording ? 0.4 : 1)      // 禁用时降低透明度
    }

    /// 二级选项：在一级工具行上方横向滚动选择(纯文字，无图标)。
    @ViewBuilder    // 允许在函数体内使用条件/循环等控制流，动态构建视图
    private var optionsRow: some View {
        if let tool = expandedTool {    // 只有展开某工具时才渲染此行，nil 时行消失
            // 横屏时药丸旋转 90°，竖向尺寸变大；为其预留行高，否则会被 ScrollView 裁掉圆角。
            let sideways = abs(abs(camera.controlRotationDegrees) - 90) < 1  // 判断当前是否横屏（旋转接近 ±90°）
            ScrollView(.horizontal, showsIndicators: false) {   // 横向滚动，隐藏滚动条
                HStack(spacing: 8) {    // 选项按钮水平排列，间距 8pt
                    switch tool {       // 根据当前展开的工具，渲染对应的选项列表
                    case .zoom:
                        ForEach(camera.availableZoomOptions) { option in
                            optionButton(
                                text: option.label,
                                selected: abs(camera.selectedZoomFactor - option.factor) < 0.05
                            ) {
                                camera.selectedZoomFactor = option.factor
                            }
                        }
                    case .frameRate:
                        ForEach(camera.availableFrameRates, id: \.self) { fps in    // 遍历可用帧率列表
                            optionButton(
                                text: "\(fps) FPS",                         // 选项文字
                                selected: camera.selectedFrameRate == fps   // 当前选中状态
                            ) { camera.selectedFrameRate = fps }            // 点击后更新帧率
                        }
                    case .iso:
                        ForEach(camera.availableISOValues, id: \.self) { iso in     // 遍历可用 ISO 列表
                            optionButton(
                                text: iso == 0 ? "自动" : "\(iso)",         // 0 显示为"自动"
                                selected: camera.selectedISO == iso         // 当前选中状态
                            ) { camera.selectedISO = iso }                  // 点击后更新 ISO
                        }
                    case .shutter:
                        ForEach(camera.availableShutterSpeeds, id: \.self) { s in  // 遍历可用快门速度列表
                            optionButton(
                                text: s.label,                              // 显示快门速度标签（如 1/60）
                                selected: camera.selectedShutter == s       // 当前选中状态
                            ) { camera.selectedShutter = s }               // 点击后更新快门
                        }
                    }
                }
                .padding(.horizontal, 8)                // 列表首尾水平留白
                .padding(.vertical, sideways ? 24 : 0)  // 横屏时增加垂直内边距，为旋转后的按钮留高度
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))  // 展开时从底部滑入+淡入，收起时反向
        }
    }

    /// 展开/收起某个工具的二级选项。
    private func toggle(_ tool: Tool) {
        withAnimation(.easeInOut(duration: 0.2)) {          // 0.2 秒缓入缓出动画包裹状态变更
            expandedTool = (expandedTool == tool) ? nil : tool  // 点击已展开的工具则收起（置 nil），否则展开该工具
        }
    }

    /// 工具按钮统一外观：上行类别名、下行当前值（active 时高亮表示其二级选项已展开）。
    private func toolButtonLabel(title: String, value: String, active: Bool = false) -> some View {
        VStack(spacing: 2) {    // 上下两行文字垂直排列，行间距 2pt
            Text(title)         // 上行：类别名（如 FPS、ISO）
                .font(.system(size: 10, weight: .medium, design: .rounded)) // 10pt 中等粗细圆角字体
                .opacity(0.85)  // 略微降低透明度，与下行值形成视觉层次
            Text(value)         // 下行：当前具体值（如 30、自动）
                .font(.system(size: 10, weight: .bold, design: .rounded))   // 10pt 粗体，视觉突出
        }
        .foregroundStyle(active ? .black : .white)  // 展开时文字变黑（配合黄色背景），收起时白色
        .frame(minWidth: 46, minHeight: 34)         // 最小点击区域，防止按钮过小
        .padding(.horizontal, 6)                    // 水平内边距
        .background(
            active ? AnyShapeStyle(.yellow) : AnyShapeStyle(.black.opacity(0.25)),  // 展开时黄色背景，收起时半透明黑色
            in: RoundedRectangle(cornerRadius: 10)  // 圆角矩形背景形状
        )
        .upright(camera.controlRotationDegrees)     // 随机身旋转反向补偿，保持视觉直立
    }

    /// 二级选项按钮（纯文字，selected 时高亮表示当前值）。
    private func optionButton(
        text: String,               // 按钮显示的文字
        selected: Bool,             // 是否为当前选中值
        action: @escaping () -> Void    // 点击后执行的回调（更新对应参数）
    ) -> some View {
        Button {
            action()    // 执行外部传入的参数更新操作
            withAnimation(.easeInOut(duration: 0.2)) { expandedTool = nil } // 选完后收起二级菜单
        } label: {
            Text(text)  // 显示选项文字
                .font(.system(size: 10, weight: .bold, design: .rounded))   // 10pt 粗体圆角字体
                .foregroundStyle(selected ? .black : .white)                // 选中时黑色文字（配合黄底），未选中白色
                .frame(minWidth: 44, minHeight: 36)                         // 最小点击区域
                .padding(.horizontal, 6)                                    // 水平内边距
                .background(
                    selected ? AnyShapeStyle(.yellow) : AnyShapeStyle(.black.opacity(0.25)),    // 选中黄底，未选中半透明黑底
                    in: RoundedRectangle(cornerRadius: 10)                  // 圆角矩形背景
                )
                .upright(camera.controlRotationDegrees)     // 随机身旋转反向补偿
        }
    }

    private var recordButton: some View {
        Button {
            camera.toggleRecording()    // 点击后切换录制状态（开始/停止录制）
        } label: {
            ZStack {    // 外圈白边圆环 + 内部红色形状叠加
                Circle()
                    .strokeBorder(.white, lineWidth: 5)     // 白色描边圆环，线宽 5pt
                    .frame(width: 78, height: 78)           // 外圈固定 78×78pt
                RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 31) // 录制中变为圆角矩形（停止图标），未录制时近似圆形
                    .fill(.red)                             // 内部填充红色
                    .frame(
                        width: camera.isRecording ? 32 : 62,    // 录制中缩小为 32pt（方形停止符），未录制时 62pt（大圆）
                        height: camera.isRecording ? 32 : 62
                    )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)    // 录制状态切换时，内部形状变化有 0.2 秒动画
    }

    private var thumbnailButton: some View {
        Button {
            openPhotosApp()     // 点击跳转到系统「照片」App
        } label: {
            Group {     // 用 Group 统一两种子视图的后续修饰符
                if let image = camera.latestThumbnail {     // 有最新录制视频的缩略图时显示缩略图
                    Image(uiImage: image)
                        .resizable()        // 允许图片缩放
                        .scaledToFill()     // 填满容器，可能裁剪边缘
                } else {
                    Image(systemName: "photo.on.rectangle.angled")  // 无缩略图时显示占位 SF Symbol
                        .font(.title3)              // 图标大小
                        .foregroundStyle(.white)    // 白色图标
                }
            }
            .frame(width: 42, height: 42)           // 固定 42×42pt 大小
            .background(.black.opacity(0.4))        // 半透明黑色背景（图片加载前的底色）
            .clipShape(Circle())                    // 裁剪为圆形
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)   // 圆形白色描边，区分背景
            }
            .overlay(alignment: .bottomTrailing) {
                if camera.latestVideoURL != nil {   // 有视频时，右下角显示播放图标，提示可点击播放
                    Image(systemName: "play.circle.fill")
                        .font(.caption)             // 小号图标
                        .foregroundStyle(.white)    // 白色
                }
            }
            .upright(camera.controlRotationDegrees)     // 随机身旋转反向补偿
        }
        .disabled(camera.latestVideoURL == nil)         // 没有视频时禁止点击
        .opacity(camera.latestVideoURL == nil ? 0.5 : 1)    // 没有视频时半透明
    }

    /// 跳转到系统「照片」App。
    private func openPhotosApp() {
        if let url = URL(string: "photos-redirect://"), UIApplication.shared.canOpenURL(url) {  // 构造照片 App 的 URL Scheme，并检查系统能否打开
            UIApplication.shared.open(url)  // 打开「照片」App
        }
    }

    private var switchButton: some View {
        Button {
            camera.switchCamera()   // 点击后切换前后摄像头
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera") // 双箭头相机 SF Symbol，表示翻转摄像头
                .font(.title3)              // 图标大小
                .foregroundStyle(.white)    // 白色图标
                .frame(width: 42, height: 42)               // 固定 42×42pt 点击热区
                .background(.black.opacity(0.4), in: Circle()) // 半透明黑色圆形背景
                .upright(camera.controlRotationDegrees)     // 随机身旋转反向补偿
        }
    }

    // MARK: - 其它状态

    private var permissionDenied: some View {
        VStack(spacing: 16) {   // 垂直排列：图标、标题、说明文字、跳转按钮，间距 16pt
            Image(systemName: "camera.fill")    // 相机图标，表明是相机权限问题
                .font(.largeTitle)              // 大号图标
                .foregroundStyle(.white)        // 白色
            Text("无法访问相机")
                .font(.headline)                // 标题字体
                .foregroundStyle(.white)        // 白色
            Text("请在「设置 > 隐私 > 相机」中允许 DoraCamera 使用相机和麦克风。")
                .font(.subheadline)             // 副标题字体
                .foregroundStyle(.white.opacity(0.7))   // 70% 白色，比标题略淡
                .multilineTextAlignment(.center)        // 多行居中对齐
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { // 获取系统设置页的 URL
                    UIApplication.shared.open(url)  // 跳转到系统设置，让用户手动开启权限
                }
            }
            .buttonStyle(.borderedProminent)    // 使用系统填充样式按钮，视觉突出
        }
        .padding()  // 四周加默认内边距，防止文字贴边
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {   // 垂直排列：警告图标 + 错误信息，间距 12pt
            Image(systemName: "exclamationmark.triangle.fill")  // 警告三角图标
                .font(.largeTitle)          // 大号图标
                .foregroundStyle(.yellow)   // 黄色，与错误语义匹配
            Text(message)                   // 显示具体错误信息字符串
                .font(.subheadline)         // 副标题字体
                .foregroundStyle(.white)    // 白色文字
                .multilineTextAlignment(.center)    // 多行居中对齐
        }
        .padding()  // 四周加默认内边距
    }

    private func timeString(_ t: TimeInterval) -> String {  // 将秒数转换为 MM:SS 格式字符串
        let total = Int(t)  // 截断小数，转为整秒数
        return String(format: "%02d:%02d", total / 60, total % 60)  // 分钟和秒数各补零至两位
    }
}

/// 让控件随地平线"原地转正"：界面锁定竖屏，机身翻转时反向旋转图标。
private struct UprightModifier: ViewModifier {  // 自定义 ViewModifier，将旋转逻辑封装复用
    let degrees: Double     // 需要旋转的角度（由 CameraManager 根据设备方向计算）
    func body(content: Content) -> some View {  // ViewModifier 协议要求实现 body，对原始视图进行变换
        content
            .rotationEffect(.degrees(degrees))              // 对内容施加旋转变换（顺/逆时针补偿机身倾斜）
            .animation(.easeInOut(duration: 0.25), value: degrees) // 旋转角度变化时有 0.25 秒缓动动画
    }
}

private extension View {
    func upright(_ degrees: Double) -> some View {  // 为所有 View 添加 .upright() 快捷方法，语义更清晰
        modifier(UprightModifier(degrees: degrees)) // 内部调用 UprightModifier
    }
}

#Preview {          // Xcode 预览宏，在 Preview Canvas 中实时渲染 ContentView
    ContentView()   // 直接预览根视图
}
