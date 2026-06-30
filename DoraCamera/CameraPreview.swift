//
//  CameraPreview.swift
//  DoraCamera
//
//  使用 AVCaptureVideoPreviewLayer 显示实时取景画面，并支持点按对焦。
//

import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let currentZoom: Double
    /// 点按对焦回调，参数为设备坐标系（0~1）的兴趣点。
    var onFocus: ((CGPoint) -> Void)?
    var onZoomBegan: (() -> Void)?
    var onZoomChanged: ((Double) -> Void)?
    var onZoomEnded: (() -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        // 用 resizeAspect 保持画面比例不被裁切，配合外层 9:16 容器即可呈现完整 16:9 画面。
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.onFocus = onFocus
        view.onZoomBegan = onZoomBegan
        view.onZoomChanged = onZoomChanged
        view.onZoomEnded = onZoomEnded
        view.currentZoom = currentZoom
        
        let tap = UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:)))
        view.addGestureRecognizer(tap)
        
        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(PreviewView.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onFocus = onFocus
        uiView.onZoomBegan = onZoomBegan
        uiView.onZoomChanged = onZoomChanged
        uiView.onZoomEnded = onZoomEnded
        uiView.currentZoom = currentZoom
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        var onFocus: ((CGPoint) -> Void)?
        var onZoomBegan: (() -> Void)?
        var onZoomChanged: ((Double) -> Void)?
        var onZoomEnded: (() -> Void)?
        var currentZoom: Double = 1.0
        private var initialZoomFactor: Double = 1.0

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            switch gr.state {
            case .began:
                initialZoomFactor = currentZoom
                onZoomBegan?()
            case .changed:
                let targetZoom = initialZoomFactor * Double(gr.scale)
                onZoomChanged?(targetZoom)
            case .ended, .cancelled:
                onZoomEnded?()
            default:
                break
            }
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            let location = gr.location(in: self)
            // 只处理落在实际画面区域内的点击（resizeAspect 可能有黑边）。
            guard bounds.contains(location) else { return }
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            showFocusReticle(at: location)
            onFocus?(devicePoint)
        }

        /// 在点击处显示一个仿系统相机的黄色对焦框，短暂动画后淡出。
        private func showFocusReticle(at point: CGPoint) {
            let size: CGFloat = 76
            let box = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            box.center = point
            box.layer.borderColor = UIColor.systemYellow.cgColor
            box.layer.borderWidth = 1.5
            box.layer.cornerRadius = 4
            box.backgroundColor = .clear
            box.isUserInteractionEnabled = false
            addSubview(box)

            box.alpha = 0
            box.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
            UIView.animate(withDuration: 0.2, animations: {
                box.alpha = 1
                box.transform = .identity
            }, completion: { _ in
                UIView.animate(withDuration: 0.3, delay: 0.7, options: []) {
                    box.alpha = 0
                } completion: { _ in
                    box.removeFromSuperview()
                }
            })
        }
    }
}
