//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	var plistEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = "/\(id).plist"
		comps.port = port
		return comps.url!
	}

	var payloadEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = "/\(id).ipa"
		comps.port = port
		return comps.url!
	}
	
	var pageEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = "/install"
		comps.port = port
		return comps.url!
	}
	
	var externalServerLink: String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.palera.in"
        components.path = "/genPlist"
        components.queryItems = [
            URLQueryItem(name: "bundleid", value: app.identifier ?? "com.shrubsign.unknown"),
            URLQueryItem(name: "name", value: app.name ?? "ShrubSign App"),
            URLQueryItem(name: "version", value: app.version ?? "1.0"),
            URLQueryItem(name: "fetchurl", value: payloadEndpoint.absoluteString)
        ]
        let baseURL = components.url?.absoluteString ?? "https://api.palera.in/genPlist"
        return baseURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? baseURL
	}

	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}
	
	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}
	
	private func _iTunesLink(with url: String) -> String {
		return "itms-services://?action=download-manifest&url=\(url)"
	}

	var displayImageSmallEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = Self.sni
		comps.path = "/app57x57.png"
		comps.port = port
		return comps.url!
	}

	var displayImageLargeEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = Self.sni
		comps.path = "/app512x512.png"
		comps.port = port
		return comps.url!
	}
	
	var displayImageSmallData: Data {
		_createIcon(57)
	}
	
	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.accent.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData() ?? Data()
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLinkExternal)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {[
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					"kind": "display-image",
					"url": "https://ipa-and-dns-stuff.pages.dev/icons/shrubhub.png",
				],
			],
			"metadata": [
				"bundle-identifier": app.identifier ?? "com.shrubsign.unknown",
				"bundle-version": app.version ?? "1.0",
				"kind": "software",
				"title": app.name ?? "ShrubSign App",
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
