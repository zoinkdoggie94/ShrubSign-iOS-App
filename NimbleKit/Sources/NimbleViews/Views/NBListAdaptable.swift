//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI

public struct NBListAdaptable<Content>: View where Content: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	
	private var _content: Content
	
	public init(@ViewBuilder content: () -> Content) {
		self._content = content()
	}
	
	public var body: some View {
		// A grid splits Section content into individual tiles, which broke the
		// Library layout on iPad because every header and row became its own
		// cell. Keep a real List on every size class and only change the style.
		Group {
			if horizontalSizeClass == .compact {
				List {
					_content
				}
				.listStyle(.plain)
			} else {
				List {
					_content
				}
				.listStyle(.insetGrouped)
			}
		}
	}
}
