//
//  CameraManager.swift
//  DoraCamera
//
//  管理 AVCaptureSession，支持以低于官方相机 24fps 的帧率录制视频。
//  核心做法：选择一个支持目标低帧率的采集格式，然后锁定设备的
//  activeVideoMinFrameDuration / activeVideoMaxFrameDuration 到目标帧时长。
//

import AVFoundation
import Combine
import Photos
import UIKit

@MainActor
final class CameraManager: NSObject, ObservableObject {

    // MARK: - 对外发布的状态

    enum Status: Equatable {
        case unconfigured
        case configured
        case unauthorized
        case failed(String)
    }

    @Published var status: Status = .unconfigured
    @Published var isRecording = false
    @Published var recordedDuration: TimeInterval = 0
    /// 可选帧率（含高帧率，以及低于官方相机的 24fps 的低帧率）
    @Published var availableFrameRates: [Int] = [60, 30, 24, 18, 15, 12, 8]
    @Published var selectedFrameRate: Int = 15 {
        didSet {
            guard selectedFrameRate != oldValue else { return }
            UserDefaults.standard.set(selectedFrameRate, forKey: Self.kFrameRate)
            sessionQueue.async { [weak self, fps = selectedFrameRate, res = selectedResolution, iso = selectedISO, shutter = selectedShutter.seconds] in
                self?.applyFormat(fps: fps, resolution: res)
                self?.applyExposure(iso: iso, shutter: shutter) // 切换格式会重置曝光，需重新应用
            }
        }
    }
    /// 可选 ISO（0 表示自动曝光）
    @Published var availableISOValues: [Int] = [0, 50, 80, 100, 150, 200, 300, 400, 500, 600, 800, 1000, 1200, 1600, 1800, 2200]
    @Published var selectedISO: Int = 0 {
        didSet {
            guard selectedISO != oldValue else { return }
            UserDefaults.standard.set(selectedISO, forKey: Self.kISO)
            sessionQueue.async { [weak self, iso = selectedISO, shutter = selectedShutter.seconds] in
                self?.applyExposure(iso: iso, shutter: shutter)
            }
        }
    }
    /// 一档快门/曝光时间。seconds 为 nil 表示自动。
    struct ShutterSpeed: Hashable, Sendable {
        let label: String
        let seconds: Double?

        static let auto = ShutterSpeed(label: "自动", seconds: nil)

        /// 由快到慢的预设。整秒用 ‟n″ 表示。
        static let presets: [ShutterSpeed] = [
            .auto,
            ShutterSpeed(label: "1/6", seconds: 1.0 / 6),
            ShutterSpeed(label: "1/8", seconds: 1.0 / 8),
            ShutterSpeed(label: "1/10", seconds: 1.0 / 10),
            ShutterSpeed(label: "1/12", seconds: 1.0 / 12),
            ShutterSpeed(label: "1/15", seconds: 1.0 / 15),
            ShutterSpeed(label: "1/20", seconds: 1.0 / 20),
            ShutterSpeed(label: "1/24", seconds: 1.0 / 24),
            ShutterSpeed(label: "1/30", seconds: 1.0 / 30),
            ShutterSpeed(label: "1/60", seconds: 1.0 / 60),
            ShutterSpeed(label: "1/125", seconds: 1.0 / 125),
            ShutterSpeed(label: "1/250", seconds: 1.0 / 250),
            ShutterSpeed(label: "1/500", seconds: 1.0 / 500),
            ShutterSpeed(label: "1/1000", seconds: 1.0 / 1000),
            ShutterSpeed(label: "1/2000", seconds: 1.0 / 2000),
            ShutterSpeed(label: "1/4000", seconds: 1.0 / 4000),
        ]
    }

    /// 可选曝光时间/快门
    @Published var availableShutterSpeeds: [ShutterSpeed] = ShutterSpeed.presets
    @Published var selectedShutter: ShutterSpeed = .auto {
        didSet {
            guard selectedShutter != oldValue else { return }
            UserDefaults.standard.set(selectedShutter.label, forKey: Self.kShutter)
            sessionQueue.async { [weak self, iso = selectedISO, shutter = selectedShutter.seconds] in
                self?.applyExposure(iso: iso, shutter: shutter)
            }
        }
    }

    /// 分辨率档位（影响采集格式选择）。
    enum Resolution: String, CaseIterable, Sendable {
        case hd1080, uhd4k

        var displayName: String {
            switch self {
            case .hd1080: return "1080P"
            case .uhd4k: return "4K"
            }
        }
        /// 目标短边像素，用于匹配采集格式。
        var targetHeight: Int {
            switch self {
            case .hd1080: return 1080
            case .uhd4k: return 2160
            }
        }
    }
    @Published var selectedResolution: Resolution = .hd1080 {
        didSet {
            guard selectedResolution != oldValue else { return }
            UserDefaults.standard.set(selectedResolution.rawValue, forKey: Self.kResolution)
            sessionQueue.async { [weak self, fps = selectedFrameRate, res = selectedResolution, iso = selectedISO, shutter = selectedShutter.seconds] in
                self?.applyFormat(fps: fps, resolution: res)
                self?.applyExposure(iso: iso, shutter: shutter) // 切换格式会重置曝光
            }
        }
    }

    /// 闪光灯模式（视频用手电筒，录制时点亮）。
    enum FlashMode: String, CaseIterable, Sendable {
        case off, auto, on

        var icon: String {
            switch self {
            case .off: return "bolt.slash.fill"
            case .auto: return "bolt.badge.automatic.fill"
            case .on: return "bolt.fill"
            }
        }
        var torchMode: AVCaptureDevice.TorchMode {
            switch self {
            case .off: return .off
            case .auto: return .auto
            case .on: return .on
            }
        }
    }
    @Published var selectedFlash: FlashMode = .off {
        didSet {
            guard selectedFlash != oldValue else { return }
            UserDefaults.standard.set(selectedFlash.rawValue, forKey: Self.kFlash)
        }
    }

    /// 切换到下一档分辨率（左上角按钮，仿系统相机点击循环）。
    func cycleResolution() {
        let all = Resolution.allCases
        if let i = all.firstIndex(of: selectedResolution) {
            selectedResolution = all[(i + 1) % all.count]
        }
    }

    /// 切换到下一档闪光灯模式（右上角按钮）。
    func cycleFlash() {
        let all = FlashMode.allCases
        if let i = all.firstIndex(of: selectedFlash) {
            selectedFlash = all[(i + 1) % all.count]
        }
    }

    /// 最近一次保存到相册的提示（显示约 3 秒后自动消失）
    @Published var lastSaveMessage: String? {
        didSet {
            guard let msg = lastSaveMessage else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if self.lastSaveMessage == msg { self.lastSaveMessage = nil }
            }
        }
    }
    /// 最近一次录制的视频缩略图与本地文件（用于左下角预览入口）
    @Published var latestThumbnail: UIImage?
    @Published var latestVideoURL: URL?

    // MARK: - 会话

    nonisolated(unsafe) let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.yahoteam.DoraCamera.session")
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()

    /// 本地保留最近一次录制，供 App 内预览/回放（同时也会存入系统相册）。
    private let recordingsDir: URL = {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var durationTimer: Timer?
    private var recordingStart: Date?

    /// “拍出水平正向画面”所需的视频旋转角（90=竖屏）。由 RotationCoordinator
    /// 随重力方向实时更新，录制开始时写入输出连接，使成片方向与持机方向一致。
    private var orientationAngle: CGFloat = 90
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// 控件需要旋转的角度（度，顺时针，归一化到 (-180,180]）。界面锁定竖屏，
    /// 机身翻转时由它让按钮图标“原地转正”，始终相对地平线竖直。
    @Published private(set) var controlRotationDegrees: Double = 0

    // MARK: - 设置持久化

    private static let kFrameRate = "selectedFrameRate"
    private static let kISO = "selectedISO"
    private static let kShutter = "selectedShutterLabel"
    private static let kResolution = "selectedResolution"
    private static let kFlash = "selectedFlash"

    override init() {
        super.init()
        // 恢复上次的选择（init 内赋值不会触发 didSet）。
        let d = UserDefaults.standard
        if let fps = d.object(forKey: Self.kFrameRate) as? Int, availableFrameRates.contains(fps) {
            selectedFrameRate = fps
        }
        if let iso = d.object(forKey: Self.kISO) as? Int, availableISOValues.contains(iso) {
            selectedISO = iso
        }
        if let label = d.string(forKey: Self.kShutter),
           let match = availableShutterSpeeds.first(where: { $0.label == label }) {
            selectedShutter = match
        }
        if let raw = d.string(forKey: Self.kResolution), let res = Resolution(rawValue: raw) {
            selectedResolution = res
        }
        if let raw = d.string(forKey: Self.kFlash), let flash = FlashMode(rawValue: raw) {
            selectedFlash = flash
        }
    }

    deinit {
        rotationObservation?.invalidate()
    }

    // MARK: - 方向识别

    /// 用 RotationCoordinator 跟踪重力方向，得到“拍出水平正向画面”所需的旋转角。
    /// 即使界面锁定竖屏，它也能在横屏/倒置时给出正确角度（依据加速度计，而非
    /// UIDevice.orientation——后者在近水平持机时会回报 faceUp/unknown，导致方向识别失败）。
    /// 在会话配置完成、以及前后摄像头切换后调用（设备实例变化时需重建）。
    private func setupRotationCoordinator() {
        guard let device = currentVideoDevice() else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        updateOrientation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.updateOrientation(angle) }
        }
    }

    /// 由“水平正向”的拍摄角推导出成片旋转角与控件反向旋转角。
    private func updateOrientation(_ captureAngle: CGFloat) {
        orientationAngle = captureAngle
        // 控件需相对竖屏(90°)反向旋转，才能在机身翻转后保持竖直。
        var deg = 90 - Double(captureAngle)
        while deg <= -180 { deg += 360 } // 归一化，按最短路径转动
        while deg > 180 { deg -= 360 }
        controlRotationDegrees = deg
    }

    /// 将指定旋转角写入录制输出连接（不支持的角度安全跳过）。
    private nonisolated func applyRotationAngle(_ angle: CGFloat) {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - 权限与配置

    /// 请求相机/麦克风权限，并在通过后配置会话。
    func configure() {
        refreshRecordings()
        Task {
            let camOK = await requestPermission(for: .video)
            let micOK = await requestPermission(for: .audio)
            guard camOK else {
                status = .unauthorized
                return
            }
            // 麦克风未授权也允许继续（仅录画面）。
            let fps = selectedFrameRate
            let res = selectedResolution
            let iso = selectedISO
            let shutter = selectedShutter.seconds
            let angle = orientationAngle
            sessionQueue.async { [weak self] in
                self?.configureSession(withAudio: micOK, fps: fps, resolution: res, iso: iso, shutter: shutter, angle: angle)
            }
        }
    }

    private func requestPermission(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: type)
        default:
            return false
        }
    }

    private nonisolated func configureSession(withAudio: Bool, fps: Int, resolution: Resolution, iso: Int, shutter: Double?, angle: CGFloat) {
        session.beginConfiguration()
        session.sessionPreset = .high

        // 视频输入
        guard let device = Self.bestCamera(for: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in self.status = .failed("无法访问相机") }
            return
        }
        session.addInput(input)

        // 音频输入
        if withAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        // 输出
        guard session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            Task { @MainActor in self.status = .failed("无法添加视频输出") }
            return
        }
        session.addOutput(movieOutput)
        configureVideoConnection(position: .back, angle: angle)

        session.commitConfiguration()

        applyFormat(fps: fps, resolution: resolution)
        applyExposure(iso: iso, shutter: shutter) // 应用恢复的 ISO/快门
        applyContinuousAutoFocus() // 显式开启连续自动对焦（不依赖设备默认）

        if !session.isRunning {
            session.startRunning()
        }
        Task { @MainActor in
            self.setupRotationCoordinator() // 会话就绪后开始跟踪方向
            self.status = .configured
        }
    }

    private nonisolated func configureVideoConnection(position: AVCaptureDevice.Position, angle: CGFloat) {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle // 跟随设备方向
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = (position == .front)
        }
    }

    // MARK: - 帧率控制（核心）

    /// 按帧率 + 分辨率挑选最佳采集格式并锁定帧时长。
    private nonisolated func applyFormat(fps: Int, resolution: Resolution) {
        guard let device = currentVideoDevice() else { return }
        let target = Double(fps)

        do {
            try device.lockForConfiguration()

            if let best = Self.bestFormat(for: device, fps: target, resolution: resolution) {
                device.activeFormat = best
            }

            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.status = .failed("设置格式失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 曝光控制（ISO + 快门）

    /// 统一应用曝光：iso/shutter 均为 0 时走连续自动曝光；任一为自定义值则进入
    /// custom 模式，未指定的一项沿用当前值（iOS 不支持快门优先，故二者绑定）。
    private nonisolated func applyExposure(iso: Int, shutter: Double?) {
        guard let device = currentVideoDevice() else { return }
        do {
            try device.lockForConfiguration()
            if iso == 0 && shutter == nil {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            } else if device.isExposureModeSupported(.custom) {
                let isoValue: Float = iso == 0
                    ? AVCaptureDevice.currentISO
                    : min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO)

                let duration: CMTime
                if let shutter {
                    let target = CMTime(seconds: shutter, preferredTimescale: 1_000_000)
                    let minD = device.activeFormat.minExposureDuration
                    let maxD = device.activeFormat.maxExposureDuration
                    duration = CMTimeClampToRange(target, range: CMTimeRange(start: minD, duration: maxD - minD))
                } else {
                    duration = AVCaptureDevice.currentExposureDuration
                }

                device.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
            }
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.status = .failed("设置曝光失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 点对焦

    /// 开启画面中心连续自动对焦（启动/切换摄像头后调用）。
    private nonisolated func applyContinuousAutoFocus() {
        guard let device = currentVideoDevice() else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch { /* 忽略对焦设置失败 */ }
    }

    /// 在指定兴趣点（设备坐标 0~1）对焦；若当前为自动曝光，则同时把测光点移过去。
    func focus(at point: CGPoint) {
        let autoExposure = (selectedISO == 0 && selectedShutter.seconds == nil)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice() else { return }
            do {
                try device.lockForConfiguration()
                // 关掉平滑对焦，让点按对焦快速合焦（而非缓慢推拉）。
                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = false
                }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                // 在该点对焦并继续连续跟焦（仿系统相机），不支持时退回一次性对焦。
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if autoExposure {
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = point
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch { /* 忽略对焦失败 */ }
        }
    }

    private nonisolated static func format(_ format: AVCaptureDevice.Format, supports fps: Double) -> Bool {
        format.videoSupportedFrameRateRanges.contains { range in
            fps >= range.minFrameRate && fps <= range.maxFrameRate
        }
    }

    /// 选择支持目标帧率、优先 16:9 且分辨率最接近目标的格式。
    private nonisolated static func bestFormat(for device: AVCaptureDevice, fps: Double, resolution: Resolution) -> AVCaptureDevice.Format? {
        let targetH = resolution.targetHeight
        let candidates = device.formats.filter { format($0, supports: fps) }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { a, b in
            let da = a.formatDescription.dimensions
            let db = b.formatDescription.dimensions
            // 先按是否接近 16:9 排序（16:9 优先），再按高度接近目标排序。
            let is169A = abs(Double(da.width) / Double(da.height) - 16.0 / 9.0) < 0.1
            let is169B = abs(Double(db.width) / Double(db.height) - 16.0 / 9.0) < 0.1
            if is169A != is169B { return is169A }
            return abs(Int(da.height) - targetH) < abs(Int(db.height) - targetH)
        }
    }

    private nonisolated func currentVideoDevice() -> AVCaptureDevice? {
        session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?
            .device
    }

    private nonisolated static func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInDualCamera,
            .builtInTripleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: position
        )
        return discovery.devices.first
    }

    // MARK: - 会话开关

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    // MARK: - 切换前后摄像头

    func switchCamera() {
        let fps = selectedFrameRate
        let res = selectedResolution
        let iso = selectedISO
        let shutter = selectedShutter.seconds
        let angle = orientationAngle
        sessionQueue.async { [weak self] in
            guard let self,
                  let currentDevice = self.currentVideoDevice(),
                  let currentInput = self.session.inputs
                    .compactMap({ $0 as? AVCaptureDeviceInput })
                    .first(where: { $0.device.hasMediaType(.video) }) else { return }

            let newPosition: AVCaptureDevice.Position =
                (currentDevice.position == .back) ? .front : .back
            guard let newDevice = Self.bestCamera(for: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(currentInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
            } else {
                self.session.addInput(currentInput)
            }
            self.configureVideoConnection(position: newPosition, angle: angle)
            self.session.commitConfiguration()

            self.applyFormat(fps: fps, resolution: res)
            self.applyExposure(iso: iso, shutter: shutter)
            self.applyContinuousAutoFocus()
            Task { @MainActor in self.setupRotationCoordinator() } // 设备已更换，重建协调器
        }
    }

    // MARK: - 录制

    func toggleRecording() {
        if isRecording {
            sessionQueue.async { [weak self] in
                self?.movieOutput.stopRecording()
                self?.setTorch(.off) // 停止录制即关灯
            }
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            let torch = selectedFlash.torchMode
            let angle = orientationAngle
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.applyRotationAngle(angle) // 录制前按当前持机方向锁定成片方向
                self.setTorch(torch) // 按闪光灯设置点亮（off/auto/on）
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    /// 设置手电筒模式（前置无手电筒时安全跳过）。
    private nonisolated func setTorch(_ mode: AVCaptureDevice.TorchMode) {
        guard let device = currentVideoDevice(), device.hasTorch,
              device.isTorchModeSupported(mode) else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch { /* 忽略手电筒设置失败 */ }
    }

    private func startDurationTimer() {
        recordingStart = Date()
        recordedDuration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStart else { return }
                self.recordedDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStart = nil
    }

    // MARK: - 录制完成处理（本地留存 + 缩略图 + 存入相册）

    /// 把临时文件移到本地保留目录，更新列表/缩略图，再存入系统相册。
    private func handleFinishedRecording(_ tempURL: URL) {
        let dest = recordingsDir.appendingPathComponent(tempURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            // 移动失败则退回直接使用临时文件
            saveToPhotos(tempURL, deleteAfter: true)
            return
        }
        refreshRecordings()
        saveToPhotos(dest, deleteAfter: false)
    }

    /// 扫描本地录制目录：只保留最新一条作为左下角缩略图，其余删除以节省空间。
    private func refreshRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }

        // 仅保留最新一条，其余删除（视频已另存进系统相册）。
        for old in sorted.dropFirst() {
            try? FileManager.default.removeItem(at: old)
        }

        latestVideoURL = sorted.first

        if let newest = sorted.first {
            Task { [newest] in
                self.latestThumbnail = await Self.generateThumbnail(for: newest)
            }
        } else {
            latestThumbnail = nil
        }
    }

    private nonisolated static func generateThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - 保存到相册

    private func saveToPhotos(_ url: URL, deleteAfter: Bool) {
        Task {
            let authorized = await requestPhotoAddPermission()
            guard authorized else {
                lastSaveMessage = "未获得相册权限，视频未保存"
                return
            }

            // 保存前确认文件确实存在且非空，否则 Photos 会以含糊的
            // “operation couldn't be completed” 报错。
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard FileManager.default.fileExists(atPath: url.path), size > 0 else {
                lastSaveMessage = "保存失败：录制文件无效（\(size) 字节）"
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: .video, fileURL: url, options: options)
                }
                lastSaveMessage = "已保存到相册"
            } catch {
                let ns = error as NSError
                lastSaveMessage = "保存失败：\(ns.domain) \(ns.code) - \(ns.localizedDescription)"
            }
            if deleteAfter {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func requestPhotoAddPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let new = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return new == .authorized || new == .limited
        default:
            return false
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.isRecording = true
            self.startDurationTimer()
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.stopDurationTimer()
            if let error {
                self.lastSaveMessage = "录制出错：\(error.localizedDescription)"
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            self.handleFinishedRecording(outputFileURL)
        }
    }
}
