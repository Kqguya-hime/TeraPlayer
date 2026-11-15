//
//  OpenListService.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/04.
//



import Foundation

// 大きな音楽ファイルの取得・送信に備え、標準より長い通信時間を設定する。
enum OpenListNetworkSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
}

final class OpenListService {

    private let baseURL = "http://192.168.0.8:5244"

    private func authorizationToken() throws -> String {
        guard let token = try OpenListTokenStore.load(), !token.isEmpty else {
            throw OpenListError.missingToken
        }
        return token
    }

    // MARK: - エラー定義

    enum OpenListError: LocalizedError {
        case invalidHTTPResponse
        case httpError(Int)
        case apiError(Int, String)
        case missingFileList
        case missingToken

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse:
                return "HTTPレスポンスを取得できませんでした"

            case .httpError(let status):
                return "HTTP通信エラー: \(status)"

            case .apiError(let code, let message):
                return "OpenList APIエラー (\(code)): \(message)"

            case .missingFileList:
                return "ファイル一覧を取得できませんでした"

            case .missingToken:
                return "OpenListのAPIトークンが未設定です。管理画面で登録してください。"
            }
        }
    }

    // MARK: - 共通処理

    private func checkHTTPResponse(
        _ response: URLResponse
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenListError.invalidHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenListError.httpError(httpResponse.statusCode)
        }
    }

    // MARK: - ファイル一覧取得

    func getFiles(path: String) async throws -> [OpenListFile] {

        let token = try authorizationToken()
        let url = URL(string: "\(baseURL)/api/fs/list")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "password": "",
            "page": 1,
            "per_page": 0,
            "refresh": false
        ]

        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )

        let (data, response) = try await OpenListNetworkSession.shared.data(
            for: request
        )

        // HTTP通信自体が成功したか確認
        try checkHTTPResponse(response)

        // JSONをSwiftの構造体に変換
        let result = try JSONDecoder().decode(
            OpenListResponse.self,
            from: data
        )
        
        // OpenList APIが成功したか確認
        guard result.code == 200 else {
            throw OpenListError.apiError(
                result.code,
                result.message
            )
        }

        // contentがnullの場合は空の配列として扱う
        let content = result.data?.content ?? []
        
        print("===== OpenList API Response =====")
        print(String(data: data, encoding: .utf8) ?? "読み取り失敗")
        print("=================================")

        return content
    }

    // MARK: - 音楽ファイルURL取得

    func getMusicURL(path: String) async throws -> URL {

        let token = try authorizationToken()
        let url = URL(string: "\(baseURL)/api/fs/get")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "password": ""
        ]

        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )

        let (data, response) = try await OpenListNetworkSession.shared.data(
            for: request
        )

        try checkHTTPResponse(response)

        let result = try JSONDecoder().decode(
            OpenListGetResponse.self,
            from: data
        )

        guard result.code == 200,
              let rawURL = result.data?.raw_url,
              let musicURL = URL(string: rawURL) else {

            throw OpenListError.apiError(
                result.code,
                result.message
            )
        }

        return musicURL
    }

    // MARK: - 全フォルダの音楽ファイルを取得

    func scanMusicFiles(
        rootPath: String,
        musicExtensions: Set<String>
    ) async throws -> [ScannedMusicFile] {

        var pendingPaths = [rootPath]
        var visitedPaths = Set<String>()
        var musicFiles: [ScannedMusicFile] = []

        // 調べるフォルダがなくなるまで繰り返す
        while let currentPath = pendingPaths.popLast() {

            // 同じフォルダを二度調べない
            guard visitedPaths.insert(currentPath).inserted else {
                continue
            }

            // 失敗した場合はエラーをそのまま呼び出し元へ返す
            // 途中で失敗した場合、部分的な一覧は返さない
            let children = try await getFiles(path: currentPath)

            for file in children {

                let childPath = currentPath == "/"
                    ? "/\(file.name)"
                    : "\(currentPath)/\(file.name)"

                if file.is_dir {

                    pendingPaths.append(childPath)

                } else {

                    let ext = (file.name as NSString)
                        .pathExtension
                        .lowercased()

                    if musicExtensions.contains(ext) {

                        musicFiles.append(
                            ScannedMusicFile(
                                path: childPath,
                                file: file
                            )
                        )
                    }
                }
            }
        }

        // 全フォルダの取得に成功した場合だけ一覧を返す
        return musicFiles
    }
}

// MARK: - データ構造

struct ScannedMusicFile {
    let path: String
    let file: OpenListFile
}

struct OpenListResponse: Decodable {
    let code: Int
    let message: String
    let data: OpenListData?
}

struct OpenListData: Decodable {
    let content: [OpenListFile]?
}

struct OpenListGetResponse: Decodable {
    let code: Int
    let message: String
    let data: OpenListGetData?

    struct OpenListGetData: Decodable {
        let raw_url: String?
    }
}
