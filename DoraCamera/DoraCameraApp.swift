//
//  DoraCameraApp.swift
//  DoraCamera
//
//  Created by win95 on 2026/6/28.
//

import SwiftUI  // 导入 SwiftUI 框架，提供 App 协议、Scene、WindowGroup 等入口所需类型

@main  // 标记程序入口：编译器从这个结构体开始执行，整个 App 只能有一个 @main
struct DoraCameraApp: App {  // 遵循 App 协议，定义应用的顶层结构
    var body: some Scene {   // App 协议要求的 body，返回一个或多个 Scene 描述窗口结构
        WindowGroup {        // 标准多窗口场景：iOS 上只有单窗口，macOS/iPadOS 支持多窗口
            ContentView()    // 在窗口中挂载根视图，所有界面从 ContentView 展开
        }
    }
}
