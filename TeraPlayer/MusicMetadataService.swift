//
//  MusicMetadataService.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/06.
//

import Foundation
import AVFoundation

// MP3から取得するメタデータ
struct MusicMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
}

final class MusicMetadataService {

    // 音楽ファイルのURLからメタデータを取得する
    func readMetadata(from url: URL) async throws -> MusicMetadata {

        // AVURLAssetは音声ファイルの情報を扱うクラス
        let asset = AVURLAsset(url: url)

        // MP3に含まれる共通メタデータを読み込む
        let metadata = try await asset.load(.commonMetadata)

        // 曲名を取得
        let title = metadata.first {
            $0.commonKey == .commonKeyTitle
        }?.stringValue

        // アーティスト名を取得
        let artist = metadata.first {
            $0.commonKey == .commonKeyArtist
        }?.stringValue

        // アルバム名を取得
        let album = metadata.first {
            $0.commonKey == .commonKeyAlbumName
        }?.stringValue

        // 再生時間を取得
        let assetDuration = try await asset.load(.duration)
        let seconds = assetDuration.seconds

        let duration: Double? =
            seconds.isFinite && seconds > 0 ? seconds : nil

        return MusicMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }
}
