//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

extension String {

    /// Whether the string appears to contain HTML markup.
    ///
    /// A cheap check used to avoid running the (slower) HTML transforms
    /// on the common case of plain metadata text.
    var containsHTML: Bool {
        range(of: "<", options: .literal) != nil && range(of: ">", options: .literal) != nil
    }

    /// The string with HTML tags removed and common entities decoded.
    ///
    /// Intended for plain-text contexts such as truncated labels and condensed
    /// views, where layout must not break from raw tags like `<br>` or `<i>`.
    var htmlStripped: String {
        guard containsHTML else { return self }

        var result = self
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        let entityReplacements: [(pattern: String, replacement: String)] = [
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&quot;", "\""),
        ]
        for entity in entityReplacements {
            result = result.replacingOccurrences(
                of: entity.pattern,
                with: entity.replacement,
                options: .caseInsensitive
            )
        }

        let lines = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    /// The string rendered as an `AttributedString` from its HTML.
    ///
    /// Intended for full-text contexts with room (such as the overview popup),
    /// preserving formatting like line breaks, italics, and bold while stripping
    /// anything `AttributedString` does not understand. Falls back to the plain
    /// string when it is not valid HTML.
    var htmlAttributedString: AttributedString {
        guard containsHTML else { return AttributedString(self) }

        return (try? AttributedString(html: self)) ?? AttributedString(self)
    }
}
