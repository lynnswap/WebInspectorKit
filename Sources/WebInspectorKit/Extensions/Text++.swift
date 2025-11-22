//
//  Text++.swift.swift
//  WebInspectorKit
//
//  Created by lynnswap on 2025/11/21.
//
//  Based on Text++.swift from https://zenn.dev/zunda_pixel/articles/be92fefdb93f76

import SwiftUI

extension Text {
    init(
        _ key: LocalizedStringKey,
        tableName: String? = nil,
        comment: StaticString? = nil
    ) {
        self.init(
            key,
            tableName: tableName,
            bundle: .module,
            comment: comment
        )
    }
}

extension String {
    init(
        localized keyAndValue: String.LocalizationValue,
        table: String? = nil,
        locale: Locale = .current,
        comment: StaticString? = nil
    ) {
        self.init(
            localized :keyAndValue,
            table: table,
            bundle : .module,
            locale: locale,
            comment: comment
        )
    }
}
