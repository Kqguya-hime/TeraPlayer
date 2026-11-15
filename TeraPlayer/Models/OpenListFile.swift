//
//  OpenListFile.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/04.
//

import Foundation

struct OpenListFile: Identifiable, Decodable {
    let name: String
    let size: Int64
    let is_dir: Bool
    let modified: String?
    let created: String?
    let sign: String?
    let path: String?
    // オフライン表示用の仮想パス。pathは曲の安定した識別パスとして維持する。
    let displayPath: String?

    init(
        name: String,
        size: Int64,
        is_dir: Bool,
        modified: String?,
        created: String?,
        sign: String?,
        path: String? = nil,
        displayPath: String? = nil
    ) {
        self.name = name
        self.size = size
        self.is_dir = is_dir
        self.modified = modified
        self.created = created
        self.sign = sign
        self.path = path
        self.displayPath = displayPath
    }

    var id: String {
        path ?? displayPath ?? name
    }
}
