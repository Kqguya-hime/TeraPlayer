//
//  TeraPlayerApp.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/04.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct TeraPlayerApp: App {

    // UIKitのAppDelegateをSwiftUIアプリに接続する
    @UIApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [MusicTrack.self, PlaybackHistory.self, MusicPlaylist.self])
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {

    // バックグラウンド通信完了時に呼び出す処理
    var backgroundSessionCompletionHandler: (() -> Void)?

    // バックグラウンド通信イベントを受け取る
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {

        print("バックグラウンド通信イベント受信: \(identifier)")

        // iOSから渡された完了通知を保存
        backgroundSessionCompletionHandler = completionHandler

        // バックグラウンド通信セッションを復元
        BackgroundDownloadManager.shared.restoreSession()
    }

    // バックグラウンド通信イベントの処理がすべて終わったときに呼び出す
    func finishBackgroundSessionEvents() {

        backgroundSessionCompletionHandler?()
        backgroundSessionCompletionHandler = nil
    }
}


