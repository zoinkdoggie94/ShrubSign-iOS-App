//
//  SwiftAR.swift
//  SwiftAR
//
//  Created by nekohaxx on 8/18/24.
//

import Foundation

class AR: NSObject {
    private let data: Data

    init(with url: URL) throws {
        data = try Data(contentsOf: url)
        super.init()
    }

    func extract() async throws -> [ARFileModel] {
        guard data.starts(with: Data("!<arch>\n".utf8)) else {
            throw ARError.badArchive("Invalid archive header")
        }

        var offset = 8
        var files: [ARFileModel] = []
        while offset < data.count {
            let file = try readEntry(at: offset)
            files.append(file)
            offset += 60 + file.size
            if offset < data.count { offset += offset % 2 }
        }
        return files
    }

    private func readEntry(at offset: Int) throws -> ARFileModel {
        guard data.count - offset >= 60, data[offset + 58] == 0x60, data[offset + 59] == 0x0a else {
            throw ARError.badArchive("Invalid entry header")
        }

        func field(_ start: Int, _ end: Int) -> String {
            String(decoding: data[(offset + start)..<(offset + end)], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }

        guard let size = Int(field(48, 58)), size >= 0, size <= data.count - offset - 60,
              let timestamp = Double(field(16, 28)), timestamp.isFinite,
              let owner = Int(field(28, 34)), let group = Int(field(34, 40)),
              let mode = Int(field(40, 48), radix: 8) else {
            throw ARError.badArchive("Invalid entry metadata or size")
        }

        var name = field(0, 16)
        if name.hasSuffix("/") { name.removeLast() }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0) else {
            throw ARError.badArchive("Invalid entry name")
        }

        return ARFileModel(
            name: name,
            modificationDate: Date(timeIntervalSince1970: timestamp),
            ownerId: owner,
            groupId: group,
            mode: mode,
            size: size,
            content: data.subdata(in: (offset + 60)..<(offset + 60 + size))
        )
    }
}

enum ARError: LocalizedError {
    case badArchive(String)

    var errorDescription: String? {
        switch self {
        case .badArchive(let message): return message
        }
    }
}
