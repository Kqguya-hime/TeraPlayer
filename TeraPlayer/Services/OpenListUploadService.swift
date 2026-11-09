import Foundation

final class OpenListUploadService {

    enum UploadError: LocalizedError {
        case tokenMissing
        case invalidResponse
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .tokenMissing:
                return "OpenListのAPIトークンを管理画面で登録してください。"
            case .invalidResponse:
                return "OpenListから有効な応答を受け取れませんでした。"
            case .serverError(let code, let message):
                return "アップロードエラー (\(code)): \(message)"
            }
        }
    }

    private let baseURL = "http://192.168.0.10:5244"

    func upload(
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
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(encodedPath, forHTTPHeaderField: "File-Path")
        request.setValue("false", forHTTPHeaderField: "As-Task")
        request.setValue("true", forHTTPHeaderField: "Overwrite")
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
