//
//  DownloadItem.swift
//  ShrubSign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI

struct DownloadItem: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let localPath: URL
    var isFinished: Bool
    var progress: Double
    var totalBytes: Int64
    var bytesDownloaded: Int64
    var startedAt: Date = Date()

    var formattedFileSize: String {
        return totalBytes.formattedByteCount
    }
    
    var progressText: String {
        let downloadedStr = bytesDownloaded.formattedByteCount
        let seconds = max(1, Date().timeIntervalSince(startedAt))
        let speed = Int64(Double(bytesDownloaded) / seconds).formattedByteCount
        guard totalBytes > 0 else { return "\(downloadedStr) · \(speed)/s · Total size unknown" }
        let totalStr = totalBytes.formattedByteCount
        return "\(downloadedStr) / \(totalStr) (\(Int(progress * 100))%) · \(speed)/s"
    }
} 