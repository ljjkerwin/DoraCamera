//
//  ContentView.swift
//  DoraCamera
//

import SwiftUI
import AVKit

struct ContentView: View {
    /// 可展开二级选项的工具。
    private enum Tool { case frameRate, iso, shutter }

    @StateObject private var camera = CameraManager()
    /// 当前展开二级横向选项的工具(nil 表示都收起)。
    @State private var expandedTool: Tool?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .configured, .unconfigured:
                cameraUI
            case .unauthorized:
                permissionDenied
            case .failed(let message):
                errorView(message)
            }
        }
        .onAppear { camera.configure() }
        .onDisappear { camera.stopSession() }
        .statusBarHidden()
    }

    // MARK: - 相机界面

    private var cameraUI: some View {
        ZStack(alignment: .top) {
            // 预览限制为 9:16(竖屏 16:9),顶部对齐到安全区上边界。
            CameraPreview(session: camera.session, onFocus: { camera.focus(at: $0) })
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .top)

            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
    }

    private var topBar: some View {
        HStack {
            resolutionButton
            Spacer()
            flashButton
        }
        .overlay {
            if camera.isRecording { recordingIndicator }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// 录制中的红点 + 时长，居中显示。
    private var recordingIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(timeString(camera.recordedDuration))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
        .upright(camera.controlRotationDegrees)
    }

    /// 左上角分辨率切换（点击循环 720P/1080P/4K，仿系统相机）。
    private var resolutionButton: some View {
        Button {
            camera.cycleResolution()
        } label: {
            Text(camera.selectedResolution.displayName)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 40)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.4), in: Capsule())
                .upright(camera.controlRotationDegrees)
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.5 : 1)
    }

    /// 右上角闪光灯切换（点击循环 关闭/自动/打开）。
    private var flashButton: some View {
        Button {
            camera.cycleFlash()
        } label: {
            Image(systemName: camera.selectedFlash.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(camera.selectedFlash == .off ? .white : .yellow)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.4), in: Circle())
                .upright(camera.controlRotationDegrees)
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.5 : 1)
    }

    private var bottomControls: some View {
        VStack(spacing: 20) {
            if let message = camera.lastSaveMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .upright(camera.controlRotationDegrees)
                    .transition(.opacity)
            }

            optionsRow

            toolRow

            HStack {
                Spacer()
                recordButton
                Spacer()
            }
            .overlay(alignment: .leading) {
                if !camera.isRecording {
                    thumbnailButton.padding(.leading, 32)
                }
            }
            .overlay(alignment: .trailing) {
                if !camera.isRecording {
                    switchButton.padding(.trailing, 32)
                }
            }
        }
        .animation(.easeInOut, value: camera.lastSaveMessage)
    }

    /// 录制按钮上方的一排工具按钮（目前仅帧率，后续可继续添加）。
    private var toolRow: some View {
        HStack(spacing: 24) {
            frameRateMenuButton
            shutterMenuButton
            isoMenuButton
            // 后续在此添加更多工具按钮
        }
    }

    /// ISO 切换：一级显示当前 ISO，点击在上方展开横向选项。
    private var isoMenuButton: some View {
        Button {
            toggle(.iso)
        } label: {
            toolButtonLabel(
                title: "ISO",
                value: camera.selectedISO == 0 ? "自动" : "\(camera.selectedISO)",
                active: expandedTool == .iso
            )
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.4 : 1)
    }

    /// 帧率切换：一级显示当前帧率，点击在上方展开横向选项。
    private var frameRateMenuButton: some View {
        Button {
            toggle(.frameRate)
        } label: {
            toolButtonLabel(
                title: "FPS",
                value: "\(camera.selectedFrameRate)",
                active: expandedTool == .frameRate
            )
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.4 : 1)
    }

    /// 曝光时间(快门)切换：一级显示当前快门，点击在上方展开横向选项。
    private var shutterMenuButton: some View {
        Button {
            toggle(.shutter)
        } label: {
            toolButtonLabel(
                title: "快门",
                value: camera.selectedShutter.seconds == nil ? "自动" : camera.selectedShutter.label,
                active: expandedTool == .shutter
            )
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.4 : 1)
    }

    /// 二级选项：在一级工具行上方横向滚动选择(纯文字，无图标)。
    @ViewBuilder
    private var optionsRow: some View {
        if let tool = expandedTool {
            // 横屏时药丸旋转 90°，竖向尺寸变大；为其预留行高，否则会被 ScrollView 裁掉圆角。
            let sideways = abs(abs(camera.controlRotationDegrees) - 90) < 1
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    switch tool {
                    case .frameRate:
                        ForEach(camera.availableFrameRates, id: \.self) { fps in
                            optionButton(
                                text: "\(fps) FPS",
                                selected: camera.selectedFrameRate == fps
                            ) { camera.selectedFrameRate = fps }
                        }
                    case .iso:
                        ForEach(camera.availableISOValues, id: \.self) { iso in
                            optionButton(
                                text: iso == 0 ? "自动" : "\(iso)",
                                selected: camera.selectedISO == iso
                            ) { camera.selectedISO = iso }
                        }
                    case .shutter:
                        ForEach(camera.availableShutterSpeeds, id: \.self) { s in
                            optionButton(
                                text: s.label,
                                selected: camera.selectedShutter == s
                            ) { camera.selectedShutter = s }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, sideways ? 24 : 0)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 展开/收起某个工具的二级选项。
    private func toggle(_ tool: Tool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedTool = (expandedTool == tool) ? nil : tool
        }
    }

    /// 工具按钮统一外观：上行类别名、下行当前值（active 时高亮表示其二级选项已展开）。
    private func toolButtonLabel(title: String, value: String, active: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .opacity(0.85)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(active ? .black : .white)
        .frame(minWidth: 46, minHeight: 34)
        .padding(.horizontal, 6)
        .background(
            active ? AnyShapeStyle(.yellow) : AnyShapeStyle(.black.opacity(0.25)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .upright(camera.controlRotationDegrees)
    }

    /// 二级选项按钮（纯文字，selected 时高亮表示当前值）。
    private func optionButton(
        text: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            withAnimation(.easeInOut(duration: 0.2)) { expandedTool = nil }
        } label: {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .black : .white)
                .frame(minWidth: 44, minHeight: 36)
                .padding(.horizontal, 6)
                .background(
                    selected ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.4)),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .upright(camera.controlRotationDegrees)
        }
    }

    private var recordButton: some View {
        Button {
            camera.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 5)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 31)
                    .fill(.red)
                    .frame(
                        width: camera.isRecording ? 32 : 62,
                        height: camera.isRecording ? 32 : 62
                    )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
    }

    private var thumbnailButton: some View {
        Button {
            openPhotosApp()
        } label: {
            Group {
                if let image = camera.latestThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.4))
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if camera.latestVideoURL != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
            .upright(camera.controlRotationDegrees)
        }
        .disabled(camera.latestVideoURL == nil)
        .opacity(camera.latestVideoURL == nil ? 0.5 : 1)
    }

    /// 跳转到系统「照片」App。
    private func openPhotosApp() {
        if let url = URL(string: "photos-redirect://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    private var switchButton: some View {
        Button {
            camera.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
                .upright(camera.controlRotationDegrees)
        }
    }

    // MARK: - 其它状态

    private var permissionDenied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
            Text("无法访问相机")
                .font(.headline)
                .foregroundStyle(.white)
            Text("请在「设置 > 隐私 > 相机」中允许 DoraCamera 使用相机和麦克风。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 让控件随地平线“原地转正”：界面锁定竖屏，机身翻转时反向旋转图标。
private struct UprightModifier: ViewModifier {
    let degrees: Double
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(degrees))
            .animation(.easeInOut(duration: 0.25), value: degrees)
    }
}

private extension View {
    func upright(_ degrees: Double) -> some View {
        modifier(UprightModifier(degrees: degrees))
    }
}

#Preview {
    ContentView()
}
