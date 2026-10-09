//
//  SourcesViewModel.swift
//  ShrubSign
//
//  Repository loading is intentionally scoped to the repositories the user
//  actually opens. This avoids the old behavior where opening one repository
//  could refresh every saved source at once.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

final class SourcesViewModel: ObservableObject {
    static let shared = SourcesViewModel()

    typealias RepositoryDataHandler = Result<ASRepository, Error>

    private struct RepositoryTaskResult: @unchecked Sendable {
        let offset: Int
        let repository: ASRepository?
        let errorMessage: String?
    }

    private let _dataService = NBFetchService()

    @Published var isFinished = true
    @Published var sources: [AltSource: ASRepository] = [:]
    @Published private(set) var sourceErrors: [String: String] = [:]

    func fetchSources(_ fetchedSources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 3) async {
        await fetchSources(Array(fetchedSources), refresh: refresh, batchSize: batchSize)
    }

    func fetchSources(_ requestedSources: [AltSource], refresh: Bool = false, batchSize: Int = 3) async {
        let requested = requestedSources.filter { $0.sourceURL != nil }
        guard !requested.isEmpty else { return }

        let sourcesToFetch = refresh ? requested : requested.filter { self.sources[$0] == nil }
        guard !sourcesToFetch.isEmpty else { return }

        await MainActor.run { self.isFinished = false }
        defer {
            Task { @MainActor in self.isFinished = true }
        }

        // Fetch a small batch at a time. More concurrency made large source lists
        // faster on paper, but could spike memory and crash repository navigation.
        let size = max(1, min(batchSize, 3))
        for start in stride(from: 0, to: sourcesToFetch.count, by: size) {
            if Task.isCancelled { break }
            let end = min(start + size, sourcesToFetch.count)
            let batch = Array(sourcesToFetch[start..<end])

            await withTaskGroup(of: RepositoryTaskResult.self) { group in
                for (offset, source) in batch.enumerated() {
                    guard let url = source.sourceURL else { continue }
                    group.addTask {
                        let dataService = NBFetchService()
                        return await withCheckedContinuation { continuation in
                            dataService.fetch(from: url) { (result: RepositoryDataHandler) in
                                switch result {
                                case .success(let repo):
                                    continuation.resume(returning: RepositoryTaskResult(offset: offset, repository: repo, errorMessage: nil))
                                case .failure(let error):
                                    continuation.resume(returning: RepositoryTaskResult(offset: offset, repository: nil, errorMessage: error.localizedDescription))
                                }
                            }
                        }
                    }
                }

                for await result in group {
                    guard batch.indices.contains(result.offset) else { continue }
                    let source = batch[result.offset]
                    let key = source.sourceURL?.absoluteString ?? source.identifier ?? UUID().uuidString
                    await MainActor.run {
                        if let repo = result.repository {
                            self.sources[source] = repo
                            self.sourceErrors.removeValue(forKey: key)
                        } else if let error = result.errorMessage {
                            self.sourceErrors[key] = error
                        }
                    }
                }
            }
            await Task.yield()
        }
    }
}
