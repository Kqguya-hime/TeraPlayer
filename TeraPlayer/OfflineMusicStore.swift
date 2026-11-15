//
//  OfflineMusicStore.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/06.
//

import Foundation

final class OfflineMusicStore {
    
    // MARK: - 保存フォルダ
    
    // Application Support内の音楽保存フォルダ
    private func directoryURL() throws -> URL {
        
        let fileManager = FileManager.default
        
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        let musicDirectory = applicationSupport
            .appendingPathComponent("OfflineMusic", isDirectory: true)
        
        // フォルダが存在しなければ作成
        try fileManager.createDirectory(
            at: musicDirectory,
            withIntermediateDirectories: true
        )
        
        return musicDirectory
    }
    
    // MARK: - 保存先URL取得
    
    func localURL(for fileName: String) throws -> URL {
        
        return try directoryURL()
            .appendingPathComponent(fileName)
    }
    
    // MARK: - ファイル存在確認
    
    func fileExists(_ fileName: String) throws -> Bool {
        
        let url = try localURL(for: fileName)
        
        return FileManager.default.fileExists(
            atPath: url.path
        )
    }
    
    // MARK: - ダウンロードファイル保存
    
    // ダウンロード済みの一時ファイルを正式な保存場所へ移動する
    func saveDownloadedFile(
        from temporaryURL: URL,
        fileExtension: String
    ) throws -> String {
        
        let fileName = UUID().uuidString
        + "."
        + fileExtension.lowercased()
        
        let destinationURL = try localURL(for: fileName)
        
        try FileManager.default.moveItem(
            at: temporaryURL,
            to: destinationURL
        )
        
        return fileName
    }
    
    // MARK: - ファイル削除
    
    func deleteFile(_ fileName: String) throws {
        
        let url = try localURL(for: fileName)
        
        if FileManager.default.fileExists(atPath: url.path) {
            
            try FileManager.default.removeItem(at: url)
        }
    }
    
    // タグ編集後のMP3で、既存のオフライン保存ファイルを安全に置き換える。
    // 置き換えに失敗した場合は元ファイルを元の場所へ戻す。
    func replaceDownloadedFile(
        from sourceURL: URL,
        localFileName: String
    ) throws {
        let fileManager = FileManager.default
        let directory = try directoryURL()
        let destinationURL = directory.appendingPathComponent(localFileName)
        let replacementURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(destinationURL.pathExtension)
        let backupURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("backup")

        try fileManager.copyItem(at: sourceURL, to: replacementURL)

        var originalMovedToBackup = false

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                originalMovedToBackup = true
            }

            try fileManager.moveItem(at: replacementURL, to: destinationURL)

            if originalMovedToBackup {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            try? fileManager.removeItem(at: replacementURL)

            if originalMovedToBackup,
               !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }

            throw error
        }
    }

    // MARK: - ダウンロード
    
    // クラウド上のファイルをダウンロードして保存する
    func downloadFile(
        from remoteURL: URL,
        fileExtension: String
    ) async throws -> String {
        
        // ファイルを一時領域にダウンロード
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: remoteURL
        )
        
        // HTTP通信が正常に完了したか確認
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            
            throw URLError(.badServerResponse)
        }
        
        // 一時ファイルを正式な保存場所へ移動
        let savedFileName = try saveDownloadedFile(
            from: temporaryURL,
            fileExtension: fileExtension
        )
        
        return savedFileName
    }
    // MARK: - ストレージ容量確認

    // iPhoneの現在の空き容量を取得する
    func availableCapacity() throws -> Int64 {

        let homeURL = URL(
            fileURLWithPath: NSHomeDirectory()
        )

        let values = try homeURL.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]
        )

        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }

        return capacity
    }
    
}
