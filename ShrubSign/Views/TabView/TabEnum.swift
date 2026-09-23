//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
    case home
    case catalog
    case files
	case sources
	case library
	case settings
	case certificates
	case appstore
    case downloader
	var title: String {
		switch self {
        case .home:         return "Home"
        case .catalog:      return "ShrubLibrary"
        case .files:        return .localized("Files")
		case .sources:     	return .localized("Sources")
		case .library: 		return .localized("Library")
		case .settings: 	return .localized("Settings")
		case .certificates:	return .localized("Certificates")
		case .appstore: 	return .localized("App Store")
        case .downloader:   return .localized("Downloads")
		}
	}
	
	var icon: String {
		switch self {
        case .home:         return "house.fill"
        case .catalog:      return "books.vertical.fill"
        case .files:        return "folder.fill"
		case .sources: 		return "globe.desk"
		case .library: 		return "square.grid.2x2"
		case .settings: 	return "gearshape.2"
		case .certificates: return "person.text.rectangle"
		case .appstore: 	return "plus.app.fill"
        case .downloader:    return "square.and.arrow.down.fill"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
        case .home: ShrubHomeView()
        case .catalog: ShrubCatalogView()
        case .files: FilesView()
		case .sources: SourcesView()
		case .library: LibraryView()
		case .settings: SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		case .appstore: AppstoreView()
        case .downloader: DownloaderView()
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
            .home,
            .catalog,
            .library,
            .downloader,
            .settings,
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return [
            .sources,
            .files,
            .appstore,
			.certificates
		]
	}
}
