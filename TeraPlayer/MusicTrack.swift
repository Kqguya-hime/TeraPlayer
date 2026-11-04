//
//  MusicTrack.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/06.
//


import Foundation
import SwiftData

@Model
final class MusicTrack {

    // クラウド上のファイルパス。一意の識別子として使用する
    @Attribute(.unique)
    var path: String

    // ファイル情報
    var fileName: String
    var fileSize: Int64

    // 音楽のメタデータ
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?

    // オフライン保存情報
    var isDownloaded: Bool
    var localFileName: String?

    // ライブラリ管理情報
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var isFavorite: Bool
    
    //更新日時と署名
    var cloudModified: String?
    var cloudSign: String?

    init(
        path: String,
        fileName: String,
        fileSize: Int64
    ) {
        self.path = path
        self.fileName = fileName
        self.fileSize = fileSize
        self.cloudModified = nil
        self.cloudSign = nil

        // 最初はファイル名を曲名として仮登録
        self.title = (fileName as NSString)
            .deletingPathExtension

        self.artist = nil
        self.album = nil
        self.duration = nil

        self.isDownloaded = false
        self.localFileName = nil

        self.dateAdded = Date()
        self.lastPlayed = nil
        self.playCount = 0
        self.isFavorite = false
    }
}
