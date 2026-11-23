//
//  SourcesAddView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import NimbleJSON

// MARK: - View
struct SourcesAddView: View {
	@Environment(\.dismiss) var dismiss
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	@State private var _isImporting = false
	@State private var _sourceURL = ""
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Add Source"), displayMode: .inline) {
			Form {
				Section {
					TextField(.localized("Source Repo URL"), text: $_sourceURL)
						.keyboardType(.URL)
				} footer: {
					Text(.localized("Enter a URL to start validation."))
				}
				
				Section {
					Button(.localized("Import"), systemImage: "square.and.arrow.down") {
						_addCode(UIPasteboard.general.string) {
							UINotificationFeedbackGenerator().notificationOccurred(.success)
							dismiss()
						}
					}
					.disabled(_isImporting)
					
					Button(.localized("Export"), systemImage: "doc.on.clipboard") {
						UIPasteboard.general.string = Storage.shared.getSources().compactMap {
							$0.sourceURL?.absoluteString
						}.joined(separator: "\n")
						UINotificationFeedbackGenerator().notificationOccurred(.success)
						UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized("All sources copied to clipboard."))
					}
				} footer: {
					Text(.localized("Supports importing from KravaSign/MapleSign and ESign"))
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
				
				if !_isImporting {
					NBToolbarButton(
						.localized("Save"),
						style: .text,
						placement: .confirmationAction,
						isDisabled: _sourceURL.isEmpty
					) {
						guard !_isImporting else { return }
						_isImporting = true
						FR.handleSourceWithResult(_sourceURL) { result in
							_isImporting = false
							switch result {
							case .success:
								UINotificationFeedbackGenerator().notificationOccurred(.success)
								dismiss()
							case .failure(let error):
								UINotificationFeedbackGenerator().notificationOccurred(.error)
								UIAlertController.showAlertWithOk(title: .localized("Add Source"), message: error.localizedDescription)
							}
						}
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
					}
				}
			}
		}
	}
	
	private func _addCode(_ code: String?, completion: @escaping () -> Void) {
		guard !_isImporting else { return }
		guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			UIAlertController.showAlertWithOk(title: .localized("Import"), message: "Copy repository URLs first, then try again.")
			return
		}
		let handler = ASDeobfuscator(with: code)
		let urls = handler.decode().compactMap { URL(string: $0) }.filter {
			["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
		}
		var seen = Set<URL>()
		let repoURLs = urls.filter { seen.insert($0).inserted }
		guard !repoURLs.isEmpty else {
			UIAlertController.showAlertWithOk(title: .localized("Import"), message: "No valid repository URLs were found in your clipboard.")
			return
		}
		_isImporting = true

		actor RepositoryCollector {
			private var repositories: [URL: ASRepository] = [:]
			func add(url: URL, repository: ASRepository) { repositories[url] = repository }
			func getAllRepositories() -> [URL: ASRepository] { repositories }
		}
		let collector = RepositoryCollector()
		Task {
			// Three sources at a time prevents memory spikes with pasted lists.
			for start in stride(from: 0, to: repoURLs.count, by: 3) {
				let batch = Array(repoURLs[start..<min(start + 3, repoURLs.count)])
				await withTaskGroup(of: Void.self) { group in
					for url in batch {
						group.addTask {
							let service = NBFetchService()
							await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
								service.fetch(from: url) { (result: RepositoryDataHandler) in
									switch result {
									case .success(let repository):
										Task {
											// Do not resume until this insertion is actually done.
											await collector.add(url: url, repository: repository)
											continuation.resume()
										}
									case .failure(let error):
										print("Failed to import \(url): \(error.localizedDescription)")
										continuation.resume()
									}
								}
							}
						}
					}
				}
			}
			let repositories = await collector.getAllRepositories()
			await MainActor.run {
				guard !repositories.isEmpty else {
					_isImporting = false
					UIAlertController.showAlertWithOk(title: .localized("Import"), message: "No repositories could be loaded. Check the URLs and try again.")
					return
				}
				Storage.shared.addSources(repos: repositories) { error in
					_isImporting = false
					if let error {
						UIAlertController.showAlertWithOk(title: .localized("Import"), message: error.localizedDescription)
					} else {
						completion()
					}
				}
			}
		}
	}

}

