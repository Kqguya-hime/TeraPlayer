import Foundation

final class OpenListUploadService {

    static let uploadDirectory = "/terabox/TeraPlayer Upload"

    enum UploadError: LocalizedError {
        case tokenMissing
        case invalidResponse
        case serverError(Int, String)
        case duplicateFile(String)
        case recoveryFailed(String, String, String)

        var errorDescription: String? {
            switch self {
            case .tokenMissing:
                return "OpenListのAPIトークンを管理画面で登録してください。"
            case .invalidResponse:
                return "OpenListから有効な応答を受け取れませんでした。"
            case .serverError(let code, let message):
                return "アップロードエラー (\(code)): \(message)"
            case .duplicateFile(let name):
                return "同名ファイルがアップロード先に存在します：\(name)"
            case .recoveryFailed(let originalName, let backupName, let reason):
                return "置き換えに失敗し、元ファイルを自動復元できませんでした。元の名前：\(originalName)、退避ファイル：\(backupName)。原因：\(reason)"
            }
        }
    }

    private let baseURL = "http://192.168.0.8:5244"
    private let openListService = OpenListService()

    // 専用フォルダがなければ作成する。
    private func ensureUploadDirectory() async throws {
        let parentPath = "/terabox"
        let folderName = "TeraPlayer Upload"

        let parentFiles = try await openListService.getFiles(path: parentPath)
        let folderExists = parentFiles.contains {
            $0.is_dir && $0.name == folderName
        }

        guard !folderExists else { return }

        guard let token = try OpenListTokenStore.load(),
              !token.isEmpty else {
            throw UploadError.tokenMissing
        }

        guard let url = URL(string: "\(baseURL)/api/fs/mkdir") else {
            throw UploadError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1800
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["path": Self.uploadDirectory]
        )

        let (data, response) = try await OpenListNetworkSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let refreshedFiles = try await openListService.getFiles(path: parentPath)
            if refreshedFiles.contains(where: { $0.is_dir && $0.name == folderName }) {
                return
            }
            throw UploadError.serverError(
                httpResponse.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        let result = try JSONDecoder().decode(OpenListUploadResponse.self, from: data)
        guard result.code == 200 else {
            let refreshedFiles = try await openListService.getFiles(path: parentPath)
            if refreshedFiles.contains(where: { $0.is_dir && $0.name == folderName }) {
                return
            }
            throw UploadError.serverError(result.code, result.message)
        }
    }

    // 新規アップロード。既存ファイルは上書きしない。
    func upload(fileURL: URL) async throws {
        try await ensureUploadDirectory()

        let fileName = fileURL.lastPathComponent
        let existingFiles = try await openListService.getFiles(
            path: Self.uploadDirectory
        )

        guard !existingFiles.contains(where: { $0.name == fileName }) else {
            throw UploadError.duplicateFile(fileName)
        }

        try await sendFile(
            fileURL: fileURL,
            remotePath: "\(Self.uploadDirectory)/\(fileName)"
        )
    }

    // TeraBoxドライバーは同名ファイルのアップロードを自動リネームするため、
    // 一時名でアップロードしてから、既存ファイルと安全に入れ替える。
    func replace(fileURL: URL, remotePath: String) async throws {
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let originalName = (remotePath as NSString).lastPathComponent
        let fileExtension = (originalName as NSString).pathExtension
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"

        let stagingName = ".teraplayer-edit-\(UUID().uuidString)\(extensionSuffix)"
        let backupName = ".teraplayer-backup-\(UUID().uuidString)\(extensionSuffix)"
        let stagingPath = "\(parentPath)/\(stagingName)"
        let backupPath = "\(parentPath)/\(backupName)"

        // 先に新しい内容を別名で完全アップロードする。元ファイルには触れない。
        try await sendFile(fileURL: fileURL, remotePath: stagingPath)

        // 元ファイルを一時バックアップ名へ退避する。
        do {
            try await renameFile(path: remotePath, newName: backupName)
        } catch {
            try? await removeFile(directory: parentPath, name: stagingName)
            throw error
        }

        // 新しいファイルを元の名前へ変更する。
        do {
            try await renameFile(path: stagingPath, newName: originalName)
        } catch {
            // 置き換えに失敗した場合は、元ファイルを元の名前へ戻す。
            do {
                try await renameFile(path: backupPath, newName: originalName)
                try? await removeFile(directory: parentPath, name: stagingName)
            } catch {
                throw UploadError.recoveryFailed(
                    originalName,
                    backupName,
                    error.localizedDescription
                )
            }
            throw error
        }

        // 新しい元ファイル名への配置が成功した後にだけ、バックアップを削除する。
        do {
            try await removeFile(directory: parentPath, name: backupName)
        } catch {
            // クラウド上の本体は更新済み。バックアップ削除失敗はログに残す。
            print("編集前バックアップの削除に失敗: \(backupPath) / \(error.localizedDescription)")
        }
    }

    private func renameFile(path: String, newName: String) async throws {
        try await performFileOperation(
            endpoint: "rename",
            body: ["path": path, "name": newName]
        )
    }

    private func removeFile(directory: String, name: String) async throws {
        try await performFileOperation(
            endpoint: "remove",
            body: ["dir": directory, "names": [name]]
        )
    }

    private func performFileOperation(
        endpoint: String,
        body: [String: Any]
    ) async throws {
        guard let token = try OpenListTokenStore.load(), !token.isEmpty else {
            throw UploadError.tokenMissing
        }

        guard let url = URL(string: "\(baseURL)/api/fs/\(endpoint)") else {
            throw UploadError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1800
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await OpenListNetworkSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UploadError.serverError(
                statusCode,
                HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
        }

        let result = try JSONDecoder().decode(OpenListUploadResponse.self, from: data)
        guard result.code == 200 else {
            throw UploadError.serverError(result.code, result.message)
        }
    }

    private func sendFile(
        fileURL: URL,
        remotePath: String
    ) async throws {
        guard let token = try OpenListTokenStore.load(),
              !token.isEmpty else {
            throw UploadError.tokenMissing
        }

        let allowedCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "?#"))
        guard let encodedPath = remotePath.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) else {
            throw UploadError.invalidResponse
        }

        guard let url = URL(string: "\(baseURL)/api/fs/put") else {
            throw UploadError.invalidResponse
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(encodedPath, forHTTPHeaderField: "File-Path")
        request.setValue("false", forHTTPHeaderField: "As-Task")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await OpenListNetworkSession.shared.upload(
            for: request,
            fromFile: fileURL
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UploadError.serverError(
                httpResponse.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        let result = try JSONDecoder().decode(
            OpenListUploadResponse.self,
            from: data
        )

        guard result.code == 200 else {
            throw UploadError.serverError(result.code, result.message)
        }
    }
}

private struct OpenListUploadResponse: Decodable {
    let code: Int
    let message: String
}


