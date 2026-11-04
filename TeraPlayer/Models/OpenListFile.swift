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

    var id: String {
        name
    }
}
