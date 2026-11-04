//
//  BackgroundDownloadManager.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/07.
//

import Foundation
import UIKit

// MARK: - ダウンロード結果

struct BackgroundDownloadResult: Codable {
    let path: String
    let localFileName: String?
    let errorMessage: String?
}

// MARK: - ダウンロード対象

struct BackgroundDownloadTarget: Codable, Hashable {
    let path: String
    let fileExtension: String
}

// MARK: - ダウンロード進捗

struct BackgroundDownloadProgress: Codable {
    var total: Int = 0
    var completed: Int = 0
    var failures: [String] = []
    var isActive: Bool = false
    var wasInterrupted: Bool = false
}

// MARK: - 保存する状態

private struct PersistedDownloadState: Codable {

    var progress = BackgroundDownloadProgress()
    var pendingResults: [BackgroundDownloadResult] = []
    var targets: [BackgroundDownloadTarget] = []

    // 以前のJSONにtargetsがなくても読み込めるようにする
    enum CodingKeys: String, CodingKey {
        case progress
        case pendingResults
        case targets
    }

    init() {}

    init(from decoder: Decoder) throws {

        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        progress = try container.decodeIfPresent(
            BackgroundDownloadProgress.self,
            forKey: .progress
        ) ?? BackgroundDownloadProgress()

        pendingResults = try container.decodeIfPresent(
            [BackgroundDownloadResult].self,
            forKey: .pendingResults
        ) ?? []

        targets = try container.decodeIfPresent(
            [BackgroundDownloadTarget].self,
            forKey: .targets
        ) ?? []
    }
}

// MARK: - ダウンロード情報

private struct DownloadTaskInfo: Codable {
    let path: String
    let fileExtension: String
}

// MARK: - BackgroundDownloadManager

final class BackgroundDownloadManager: NSObject, URLSessionDownloadDelegate {

    static let shared = BackgroundDownloadManager()

    private let sessionIdentifier =
        "com.teraplayer.background-downloads"

    private var session: URLSession!

    private let store = OfflineMusicStore()

    private var persistedState = PersistedDownloadState()

    private var completedTaskIDs: Set<Int> = []
    // ユーザーがキャンセルしたタスク
    private var cancelledTaskIDs: Set<Int> = []

    // ダウンロード完了時の通知
    var onCompletion: ((
        BackgroundDownloadResult,
        @escaping (Bool) -> Void
    ) -> Void)? {
        didSet {
            drainPendingResults()
        }
    }

    // 結果をContentViewに渡している最中か
    private var isDeliveringPendingResult = false

    // 進捗変更時の通知
    var onProgress: ((BackgroundDownloadProgress) -> Void)? {
        didSet {
            notifyProgress()
        }
    }

    // 現在の進捗
    var currentProgress: BackgroundDownloadProgress {
        persistedState.progress
    }
    
    // 前回のダウンロード対象
    var previousTargets: [BackgroundDownloadTarget] {
        persistedState.targets
    }

    private override init() {
        super.init()

        loadState()
        createSession()
    }

    // MARK: - 保存先

    private func stateFileURL() throws -> URL {

        let fileManager = FileManager.default

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directory = applicationSupport
            .appendingPathComponent("TeraPlayer", isDirectory: true)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory.appendingPathComponent(
            "BackgroundDownloadState.json"
        )
    }

    // MARK: - 状態の読み込み・保存

    private func loadState() {

        do {
            let url = try stateFileURL()

            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }

            let data = try Data(contentsOf: url)

            persistedState = try JSONDecoder().decode(
                PersistedDownloadState.self,
                from: data
            )

        } catch {
            print("ダウンロード状態の読み込み失敗: \(error)")
        }
    }

    private func saveState() {

        do {
            let url = try stateFileURL()

            let data = try JSONEncoder().encode(persistedState)

            try data.write(to: url, options: .atomic)

        } catch {
            print("ダウンロード状態の保存失敗: \(error)")
        }
    }

    // MARK: - セッション作成

    private func createSession() {

        let configuration = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier
        )

        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1

        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - セッション復元

    func restoreSession() {

        if session == nil {
            createSession()
        }

        session.getAllTasks { [weak self] tasks in

            guard let self else { return }

            DispatchQueue.main.async {

                let progress = self.persistedState.progress

                if tasks.isEmpty &&
                    progress.completed < progress.total &&
                    progress.total > 0 {

                    self.persistedState.progress.isActive = false
                    self.persistedState.progress.wasInterrupted = true

                    self.saveState()
                }

                self.notifyProgress()

                print("復元されたダウンロードタスク数: \(tasks.count)")
            }
        }
    }

    // MARK: - 新しいダウンロードバッチ

    func startBatch(targets: [BackgroundDownloadTarget]) {

        // 今回の対象曲を永続保存
        persistedState.targets = targets

        persistedState.progress = BackgroundDownloadProgress(
            total: targets.count,
            completed: 0,
            failures: [],
            isActive: !targets.isEmpty,
            wasInterrupted: false
        )

        saveState()
        notifyProgress()
    }

    // MARK: - 前回の対象曲を再試行

    func startRetryBatch() {

        let total = persistedState.targets.count

        persistedState.progress = BackgroundDownloadProgress(
            total: total,
            completed: 0,
            failures: [],
            isActive: total > 0,
            wasInterrupted: false
        )

        // targetsは変更しない
        saveState()
        notifyProgress()
    }
    
    // 既存のContentViewとの一時的な互換用
    func startBatch(total: Int) {

        persistedState.progress = BackgroundDownloadProgress(
            total: total,
            completed: 0,
            failures: [],
            isActive: total > 0,
            wasInterrupted: false
        )

        saveState()
        notifyProgress()
    }

    func startDownload(
        from remoteURL: URL,
        path: String,
        fileExtension: String
    ) {

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 300

        let task = session.downloadTask(with: request)

        let info = DownloadTaskInfo(
            path: path,
            fileExtension: fileExtension
        )

        if let data = try? JSONEncoder().encode(info) {
            task.taskDescription = data.base64EncodedString()
        }

        task.resume()
    }

    // URL取得に失敗した場合の記録
    func recordPreparationFailure(fileName: String) {

        persistedState.progress.completed += 1
        persistedState.progress.failures.append(fileName)

        updateActiveState()
        saveState()
        notifyProgress()
    }

    // MARK: - キャンセル

    func cancelAllDownloads() {

        session.getAllTasks { [weak self] tasks in

            guard let self else { return }

            // キャンセル対象のタスクIDを先に記録する
            for task in tasks {
                self.cancelledTaskIDs.insert(task.taskIdentifier)
                task.cancel()
            }

            DispatchQueue.main.async {

                // キャンセルは失敗ではなく、ユーザーによる中断として扱う
                self.persistedState.progress.isActive = false
                self.persistedState.progress.wasInterrupted = false

                self.saveState()
                self.notifyProgress()
            }
        }
    }

    // MARK: - ダウンロード完了

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {

        guard let info = taskInfo(from: downloadTask) else {

            completedTaskIDs.insert(downloadTask.taskIdentifier)

            recordResult(
                BackgroundDownloadResult(
                    path: "",
                    localFileName: nil,
                    errorMessage: "ダウンロード情報を取得できませんでした"
                )
            )

            return
        }

        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {

            completedTaskIDs.insert(downloadTask.taskIdentifier)

            recordResult(
                BackgroundDownloadResult(
                    path: info.path,
                    localFileName: nil,
                    errorMessage: "HTTP通信に失敗しました"
                )
            )

            return
        }

        do {

            let savedFileName = try store.saveDownloadedFile(
                from: location,
                fileExtension: info.fileExtension
            )

            completedTaskIDs.insert(downloadTask.taskIdentifier)

            recordResult(
                BackgroundDownloadResult(
                    path: info.path,
                    localFileName: savedFileName,
                    errorMessage: nil
                )
            )

            print("バックグラウンドダウンロード完了: \(info.path)")

        } catch {

            completedTaskIDs.insert(downloadTask.taskIdentifier)

            recordResult(
                BackgroundDownloadResult(
                    path: info.path,
                    localFileName: nil,
                    errorMessage: error.localizedDescription
                )
            )
        }
    }

    // MARK: - 通信エラー

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {

        guard let error else {
            return
        }

        guard !completedTaskIDs.contains(task.taskIdentifier) else {
            return
        }

        completedTaskIDs.insert(task.taskIdentifier)

        // ユーザーがキャンセルしたタスクは失敗にしない
        if cancelledTaskIDs.remove(task.taskIdentifier) != nil {
            print("ダウンロードをキャンセルしました: \(task.taskIdentifier)")
            return
        }

        let info = taskInfo(from: task)

        recordResult(
            BackgroundDownloadResult(
                path: info?.path ?? "",
                localFileName: nil,
                errorMessage: error.localizedDescription
            )
        )
    }

    // MARK: - バックグラウンドイベント終了

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {

        DispatchQueue.main.async {

            let appDelegate =
                UIApplication.shared.delegate as? AppDelegate

            appDelegate?.finishBackgroundSessionEvents()
        }
    }

    // MARK: - 結果の永続保存

    private func recordResult(_ result: BackgroundDownloadResult) {

        persistedState.pendingResults.append(result)

        persistedState.progress.completed += 1

        if result.localFileName == nil {
            persistedState.progress.failures.append(
                result.path.isEmpty ? "不明なファイル" : result.path
            )
        }

        updateActiveState()

        saveState()
        notifyProgress()
        drainPendingResults()
    }

    private func updateActiveState() {

        if persistedState.progress.completed >=
            persistedState.progress.total {

            persistedState.progress.isActive = false
            persistedState.progress.wasInterrupted = false

        } else {

            persistedState.progress.isActive = true
        }
    }

    // MARK: - 未処理結果の引き渡し

    private func drainPendingResults() {

        guard let onCompletion else {
            return
        }

        // 既に別の結果を処理中なら待つ
        guard !isDeliveringPendingResult else {
            return
        }

        // 未処理結果がなければ終了
        guard let result = persistedState.pendingResults.first else {
            return
        }

        isDeliveringPendingResult = true

        // ContentView側に結果を渡す
        onCompletion(result) { [weak self] success in

            guard let self else {
                return
            }

            DispatchQueue.main.async {

                if success {

                    // 保存成功時だけ、処理待ち結果を削除する
                    if let index = self.persistedState.pendingResults.firstIndex(
                        where: {
                            $0.path == result.path &&
                            $0.localFileName == result.localFileName &&
                            $0.errorMessage == result.errorMessage
                        }
                    ) {
                        self.persistedState.pendingResults.remove(at: index)
                        self.saveState()
                    }

                } else {

                    print("結果を保持します。SwiftDataへの保存に失敗しました")
                }

                self.isDeliveringPendingResult = false

                // 成功なら次の結果へ進む
                if success {
                    self.drainPendingResults()
                }
            }
        }
    }
    
    // MARK: - 保留中の結果を再処理

    func retryPendingResults() {

        guard !isDeliveringPendingResult else {
            return
        }

        drainPendingResults()
    }

    // MARK: - 進捗通知

    private func notifyProgress() {

        guard let onProgress else {
            return
        }

        let progress = persistedState.progress

        DispatchQueue.main.async {
            onProgress(progress)
        }
    }

    // MARK: - タスク情報の復元

    private func taskInfo(
        from task: URLSessionTask
    ) -> DownloadTaskInfo? {

        guard let description = task.taskDescription,
              let data = Data(base64Encoded: description) else {
            return nil
        }

        return try? JSONDecoder().decode(
            DownloadTaskInfo.self,
            from: data
        )
    }
}
