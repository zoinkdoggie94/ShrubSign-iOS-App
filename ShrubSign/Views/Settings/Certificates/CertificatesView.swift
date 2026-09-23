//
//  CertificatesView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
struct CertificatesView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
    @AppStorage("ShrubSign.preferredCertificateUUID") private var preferredUUID = ""
	
    @State private var certificateSearch = ""
    @State private var certificateFilter = 0
    @State private var certificateOrder = 0
	@State private var _isAddingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
    private var filteredCertificates: [(offset: Int, element: CertificatePair)] {
        var all = Array(certificates.enumerated()).filter { item in
            (certificateSearch.isEmpty ||
             (item.element.nickname ?? "").localizedCaseInsensitiveContains(certificateSearch) ||
             (Storage.shared.getProvisionFileDecoded(for: item.element)?.Name ?? "").localizedCaseInsensitiveContains(certificateSearch))
            && (certificateFilter == 0 ||
                (certificateFilter == 1 && (item.element.expiration ?? .distantPast) > Date() && !item.element.revoked) ||
                (certificateFilter == 2 && (item.element.expiration ?? .distantPast) <= Date().addingTimeInterval(30 * 86400)) ||
                (certificateFilter == 3 && item.element.revoked))
        }
        if certificateOrder == 1 {
            all.sort { ($0.element.nickname ?? "").localizedStandardCompare($1.element.nickname ?? "") == .orderedAscending }
        } else if certificateOrder == 2 {
            all.sort { ($0.element.expiration ?? .distantFuture) < ($1.element.expiration ?? .distantFuture) }
        }
        return all
    }

    private var expiringCount: Int {
        certificates.filter { ($0.expiration ?? .distantFuture) <= Date().addingTimeInterval(30 * 86400) }.count
    }

	//
	private var _bindingSelectedCert: Binding<Int>?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
	}
	
	init(selectedCert: Binding<Int>? = nil) {
		self._bindingSelectedCert = selectedCert
	}
	
	// MARK: Body
	var body: some View {
		NBGrid {
			ForEach(filteredCertificates, id: \.element.uuid) { index, cert in
				_cellButton(for: cert, at: index)
			}
		}
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("\(certificates.count) identities", systemImage: "checkmark.shield")
                    Spacer()
                    if expiringCount > 0 {
                        Text("\(expiringCount) expiring / expired").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                HStack {
                    Picker("Status", selection: $certificateFilter) {
                        Text("All").tag(0)
                        Text("Not expired").tag(1)
                        Text("Expiring").tag(2)
                        Text("Flagged").tag(3)
                    }
                    .pickerStyle(.menu)
                    Picker("Sort", selection: $certificateOrder) {
                        Text("Recently added").tag(0)
                        Text("Name").tag(1)
                        Text("Expiration").tag(2)
                    }
                    .pickerStyle(.menu)
                }
                Text("Expiration and a saved revocation flag do not establish live Apple certificate status.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .onAppear(perform: restorePreferredCertificate)
        .onChange(of: certificates.map { $0.uuid ?? "" }) { _ in restorePreferredCertificate() }
        .searchable(text: $certificateSearch, prompt: "Search certificates")
		.navigationTitle(.localized("Certificates"))
		.navigationBarTitleDisplayMode(.inline)
        .overlay {
            if certificates.isEmpty || filteredCertificates.isEmpty {
                if #available(iOS 17, *) {
                    ContentUnavailableView {
                        Label(certificates.isEmpty ? "No Certificates" : "No matching certificates", systemImage: "questionmark.folder.fill")
                    } description: {
                        Text(certificates.isEmpty ? "Get started signing by importing your first certificate." : "Try a different certificate name.")
                    } actions: {
                        if certificates.isEmpty {
                            Button {
                                _isAddingPresenting = true
                            } label: {
                                Text("Import").bg()
                            }
                        }
                    }
                }
            }
        }
		.toolbar {
			if _bindingSelectedCert == nil {
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing
				) {
					_isAddingPresenting = true
				}
			}
			if certificates.count > 0 {
			NBToolbarButton(
				systemImage: "arrow.counterclockwise",
				style: .icon,
				placement: .topBarTrailing
				) {
					for cert in certificates {
						Storage.shared.revokagedCertificate(for: cert)
					}
				}
			}
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
		}
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
	}
}

extension CertificatesView {
    private func restorePreferredCertificate() {
        guard !preferredUUID.isEmpty,
              let index = certificates.firstIndex(where: { $0.uuid == preferredUUID }) else { return }
        if _bindingSelectedCert == nil && _storedSelectedCert != index { _storedSelectedCert = index }
    }

	@ViewBuilder
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
		Button {
			_selectedCertBinding.wrappedValue = index
		} label: {
			CertificatesCellView(
				cert: cert
			)
			.padding()
			.background(
				RoundedRectangle(cornerRadius: _cornerRadius)
					.fill(Color(uiColor: .quaternarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: _cornerRadius)
					.strokeBorder(
						_selectedCertBinding.wrappedValue == index ? Color.accentColor : Color.clear,
						lineWidth: 2
					)
			)
			.contextMenu {
				_contextActions(for: cert)
				Divider()
				_actions(for: cert)
			}
			.animation(.smooth, value: _selectedCertBinding.wrappedValue)
		}
		.buttonStyle(.plain)
	}
    
    private var _cornerRadius: CGFloat {
        if #available(iOS 26.0, *) {
            return 28.0
        } else {
            return 17.0
        }
    }
    
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(role: .destructive) {
			if certificates.count == 1 {
                UIAlertController.showAlertWithOk(
                    title: .localized("You don't want to do this!"),
                    message: .localized("You don't want to delete your only certificate, right >.<?"),
                    isCancel: true
                )
            } else {
                Storage.shared.deleteCertificate(for: cert)
            }
		} label: {
			Label(.localized("Delete"), systemImage: "trash")
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button {
			_isSelectedInfoPresenting = cert
		} label: {
			Label(.localized("Get Info"), systemImage: "info.circle")
		}
	}
	

}
