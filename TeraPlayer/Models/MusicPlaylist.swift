//
//  MusicPlaylist.swift
//  TeraPlayer
//
//  ユーザーが作成したプレイリストを保存する
//

import Foundation
import SwiftData

@Model
final class MusicPlaylist {

    // プレイリストを識別する一意のID
    @Attribute(.unique)
    var id: String

    // プレイリスト名
    var name: String

    // 曲のライブラリパスを順番どおりに保存
    // 曲そのものはMusicTrackを参照せず、パスで関連付ける
    var trackPaths: [String]

    // 作成・更新日時
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        trackPaths: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.trackPaths = trackPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
