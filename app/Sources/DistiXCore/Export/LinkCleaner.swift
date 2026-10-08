import Foundation

/// Retire les paramètres de pistage d'un lien (utm_*, gclid…) pour l'affichage et l'export.
public enum LinkCleaner {
    static let trackingPrefixes = ["utm_", "gad_", "mc_", "pk_"]
    static let trackingNames: Set<String> = ["gclid", "gbraid", "wbraid", "fbclid", "msclkid", "dclid", "yclid",
                                             "igshid", "ref_src", "_hsenc", "_hsmi", "srsltid"]

    public static func clean(_ link: String) -> String {
        guard var c = URLComponents(string: link) else { return link }
        let kept = c.queryItems?.filter { item in
            let n = item.name.lowercased()
            return !trackingNames.contains(n) && !trackingPrefixes.contains { n.hasPrefix($0) }
        }
        c.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        return c.string ?? link
    }
}
