//
//  PlaybackHistory.swift
//  TeraPlayer
//
//  再生セッションごとの履歴を保存する
//

import Foundation
import SwiftData

@Model
final class PlaybackHistory {

    // 楽曲を識別するライブラリ上のパス
    var trackPath: String

    // 再生を開始した日時
    var startedAt: Date

    // 実際に再生した時間（秒）
    var listenedSeconds: Double

    // 曲の最後まで再生したか
    var completed: Bool

    // 履歴を最後に更新した日時
    // アプリ終了・クラッシュ時の復元判定にも使用する
    var lastUpdatedAt: Date

    init(
        trackPath: String,
        startedAt: Date = Date(),
        listenedSeconds: Double = 0,
        completed: Bool = false
    ) {
        self.trackPath = trackPath
        self.startedAt = startedAt
        self.listenedSeconds = listenedSeconds
        self.completed = completed
        self.lastUpdatedAt = Date()
    }
}
