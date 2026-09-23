//
//  IPADownloadManager.swift
//  ShrubSign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import WebKit

struct IPADownloadFailure: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let message: String
}

class IPADownloadManager: NSObject, ObservableObject {
    @Published var downloadItems: [DownloadItem] = []
    @Published private(set) var failedItems: [IPADownloadFailure] = []
    
    var activeItems: [DownloadItem] {
        downloadItems.filter { !$0.isFinished }
    }
    
    var finishedItems: [DownloadItem] {
        downloadItems.filter { $0.isFinished }
    }
    
    private var urlSession: URLSession!
    private var activeDownloads: [Int: String] = [:] // taskIdentifier -> downloadItem.id
    
    override init() {
        super.init()
        setupURLSession()
        loadDownloadedIPAs()
    }
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300 // 5 minutes
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }

    func isIPAFile(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "ipa"
    }

    func loadDownloadedIPAs() {
        let fileManager = FileManager.default
        
        let downloadDirectory = URL.documentsDirectory.appendingPathComponent("Downloads")
        
        
        let activeDownloads = downloadItems.filter { !$0.isFinished }
        downloadItems.removeAll()
        
        downloadItems.append(contentsOf: activeDownloads)
        
        do {
            try fileManager.createDirectoryIfNeeded(at: downloadDirectory)
            
            let fileURLs = try fileManager.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [])
            
            for fileURL in fileURLs {
                if isIPAFile(fileURL) {
                    if activeDownloads.contains(where: { $0.localPath == fileURL }) {
                        continue
                    }
                    
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    
                    let item = DownloadItem(
                        title: fileURL.lastPathComponent,
                        url: fileURL,
                        localPath: fileURL,
                        isFinished: true,
                        progress: 1.0,
                        totalBytes: fileSize,
                        bytesDownloaded: fileSize
                    )
                    downloadItems.append(item)
                }
            }
            
        } catch {
            print("Failed to load downloaded IPAs: \(error)")
        }
    }
    
    func retry(_ failure: IPADownloadFailure) {
        failedItems.removeAll { $0.id == failure.id }
        startDownload(url: failure.url, filename: failure.title)
    }

    private func fail(_ item: DownloadItem, reason: String) {
        downloadItems.removeAll { $0.id == item.id }
        failedItems.append(IPADownloadFailure(url: item.url, title: item.title, message: reason))
    }

    func startDownload(url: URL, filename: String) {
        guard !downloadItems.contains(where: { !$0.isFinished && $0.url == url }) else { return }
        let fileManager = FileManager.default
        let downloadDirectory = URL.documentsDirectory.appendingPathComponent("Downloads")
        try? fileManager.createDirectoryIfNeeded(at: downloadDirectory)
        
        let sanitized = URL(fileURLWithPath: filename).lastPathComponent
        let actualName = sanitized.isEmpty ? "download.ipa" : sanitized
        var destinationURL = downloadDirectory.appendingPathComponent(actualName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = downloadDirectory.appendingPathComponent(
                "\((actualName as NSString).deletingPathExtension)-\(UUID().uuidString.prefix(8)).ipa"
            )
        }
        let item = DownloadItem(
            title: destinationURL.lastPathComponent,
            url: url,
            localPath: destinationURL,
            isFinished: false,
            progress: 0,
            totalBytes: 0,
            bytesDownloaded: 0
        )
        
        DispatchQueue.main.async {
            self.downloadItems.insert(item, at: 0)
        }
        
        let task = urlSession.downloadTask(with: url)
        
        activeDownloads[task.taskIdentifier] = item.id.uuidString
        
        task.resume()
    }
    
    
    func cancelDownload(_ item: DownloadItem) {
        urlSession.getAllTasks { tasks in
            if let task = tasks.first(where: { task in
                self.activeDownloads[task.taskIdentifier] == item.id.uuidString
            }) {
                task.cancel()
            }
        }
    }
    
    func handleITMSServicesURL(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let manifestURLString = queryItems.first(where: { $0.name == "url" })?.value,
              let manifestURL = URL(string: manifestURLString) else {
            completion(.failure(NSError(domain: "ITMSError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest URL"])))
            return
        }
        
        urlSession.dataTask(with: manifestURL) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(NSError(domain: "ITMSError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data"]))); return }
            
            self.parseManifestPlist(data) { result in
                switch result {
                case .success(let url):
                    let filename = url.lastPathComponent.isEmpty ? "app.ipa" : url.lastPathComponent
                    self.startDownload(url: url, filename: filename)
                    completion(.success(filename))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    func checkFileTypeAndDownload(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        if isIPAFile(url) {
            startDownload(url: url, filename: url.lastPathComponent)
            completion(.success(url.lastPathComponent))
        } else {
            completion(.failure(NSError(domain: "FileTypeError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid file type"])))
        }
    }
    
    private func parseManifestPlist(_ data: Data, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let items = plist["items"] as? [[String: Any]],
               let firstItem = items.first,
               let assets = firstItem["assets"] as? [[String: Any]] {
                
                for asset in assets {
                    if let kind = asset["kind"] as? String, kind == "software-package",
                       let urlString = asset["url"] as? String,
                       let url = URL(string: urlString) {
                        completion(.success(url))
                        return
                    }
                }
            }
            completion(.failure(NSError(domain: "ManifestParseError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No IPA URL found"])))
        } catch {
            completion(.failure(error))
        }
    }
}

    // MARK: - URLSessionDownloadDelegate

extension IPADownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemID = activeDownloads[downloadTask.taskIdentifier],
              let item = downloadItems.first(where: { $0.id.uuidString == itemID }) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            fail(item, reason: "HTTP \(response.statusCode) from the IPA server")
            activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
            return
        }
        let header = (try? FileHandle(forReadingFrom: location)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return handle.readData(ofLength: 4)
        }
        guard let header, header.count == 4, header[0] == 0x50, header[1] == 0x4B,
              [UInt8(0x03), 0x05, 0x07].contains(header[2]) else {
            fail(item, reason: "This link returned an HTML page or another non-IPA file.")
            activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: item.localPath)
            if let index = downloadItems.firstIndex(where: { $0.id == item.id }) {
                var completed = item
                completed.isFinished = true
                completed.progress = 1
                let attributes = try FileManager.default.attributesOfItem(atPath: item.localPath.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                completed.totalBytes = size
                completed.bytesDownloaded = size
                downloadItems[index] = completed
            }
        } catch {
            fail(item, reason: "Could not save download: \(error.localizedDescription)")
        }
        activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let itemID = activeDownloads[downloadTask.taskIdentifier],
              let index = downloadItems.firstIndex(where: { $0.id.uuidString == itemID }) else { return }
        var item = downloadItems[index]
        item.progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        item.bytesDownloaded = totalBytesWritten
        item.totalBytes = totalBytesExpectedToWrite
        downloadItems[index] = item
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let itemID = activeDownloads.removeValue(forKey: task.taskIdentifier),
              let item = downloadItems.first(where: { $0.id.uuidString == itemID }) else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            downloadItems.removeAll { $0.id == item.id }
        } else {
            fail(item, reason: error.localizedDescription)
        }
    }

}
