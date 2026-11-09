import Foundation
import TagLibSwift

struct MusicTagMetadata {
    var title: String
    var artist: String
    var album: String
}

final class MusicTagService {

    enum MusicTagError: LocalizedError {
        case unsupportedOrInvalidFile

        var errorDescription: String? {
            switch self {
            case .unsupportedOrInvalidFile:
                return "MP3ファイルを読み取れませんでした。"
            }
        }
    }

    func readMetadata(from url: URL) throws -> MusicTagMetadata {
        guard let audioFile = AudioFile(path: url.path),
              audioFile.isValid else {
            throw MusicTagError.unsupportedOrInvalidFile
        }

        return MusicTagMetadata(
            title: audioFile.tag.title,
            artist: audioFile.tag.artist,
            album: audioFile.tag.album
        )
    }

    // 元ファイルを変更せず、一時コピーにタグを書き込む。
    // クラウドへのアップロードが成功した後にのみ、呼び出し元が元ファイルを置き換える。
    func makeEditedCopy(
        of sourceURL: URL,
        title: String,
        artist: String,
        album: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension)

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)

        do {
            guard let audioFile = AudioFile(path: temporaryURL.path),
                  audioFile.isValid else {
                throw MusicTagError.unsupportedOrInvalidFile
            }

            audioFile.tag.title = title
            audioFile.tag.artist = artist
            audioFile.tag.album = album

            try audioFile.save()
            return temporaryURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
