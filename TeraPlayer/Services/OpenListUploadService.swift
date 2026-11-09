import Foundation

final class OpenListUploadService {

    static let uploadDirectory = "/terabox/TeraPlayer Upload"

    enum UploadError: LocalizedError {
        case tokenMissing
        case invalidResponse
        case serverError(Int, String)
        case destinationUnavailable
        case duplicateFile(String)

        var errorDescription: String? {
            switch self {
            case .tokenMissing:
                return "OpenListのAPIトークンを管理画面で登録してください。"
            case .invalidResponse:
                return "OpenListから有効な応答を受け取れませんでした。"
            case .serverError(let code, let message):
                return "アップロードエラー (\(code)): \(message)"
            case .destinationUnavailable:
                return "アップロード先フォルダを準備できませんでした。"
            case .duplicateFile(let name):
                return "同名ファイルがアップロード先に存在します：\(name)"
            }
        }
    }

    private let baseURL = "http://192.168.0.10:5244"
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
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["path": Self.uploadDirectory]
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // 別の処理が同時に作成した可能性を考慮して、作成後の状態を再確認する。
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

    func upload(fileURL: URL) async throws {
        try await ensureUploadDirectory()

        let fileName = fileURL.lastPathComponent
        let existingFiles = try await openListService.getFiles(
            path: Self.uploadDirectory
        )

        guard !existingFiles.contains(where: { $0.name == fileName }) else {
            throw UploadError.duplicateFile(fileName)
        }

        guard let token = try OpenListTokenStore.load(),
              !token.isEmpty else {
            throw UploadError.tokenMissing
        }

        let remotePath = "\(Self.uploadDirectory)/\(fileName)"
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
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(encodedPath, forHTTPHeaderField: "File-Path")
        request.setValue("false", forHTTPHeaderField: "As-Task")
        request.setValue("false", forHTTPHeaderField: "Overwrite")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.upload(
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
