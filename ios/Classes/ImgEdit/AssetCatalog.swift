import Foundation
import UIKit

/// Enumerates bundled LUTs, sticker packs, and fonts. Looks under
/// `ios/Classes/Assets/luts/`, `assets/stickers/`, and the registered
/// font family list (CTFontManagerCopyAvailableFontFamilyNames).
///
/// The bundle is resolved by the plugin class. Returns safe defaults
/// when no resources are found.
public enum AssetCatalog {

    public static func filters() -> [[String: Any]] {
        var out: [[String: Any]] = [
            ["id": "neutral", "label": "Neutral", "lutPath": ""],
        ]
        let urls = bundle().urls(forResourcesWithExtension: "cube",
                                 subdirectory: "Assets/luts") ?? []
        for url in urls {
            let id = url.deletingPathExtension().lastPathComponent
            out.append([
                "id": id,
                "label": id.capitalized,
                "lutPath": url.path,
            ])
        }
        return out
    }

    public static func stickerPacks() -> [[String: Any]] {
        let root = bundle().resourceURL?.appendingPathComponent("Assets/stickers")
        guard let root = root,
              let packs = try? FileManager.default
                .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [[String: Any]] = []
        for pack in packs {
            let manifestURL = pack.appendingPathComponent("manifest.json")
            var label = pack.lastPathComponent
            var items: [[String: Any]] = []
            if let data = try? Data(contentsOf: manifestURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                label = (json["label"] as? String) ?? label
                if let arr = json["items"] as? [[String: Any]] {
                    for item in arr {
                        var copy = item
                        if let file = item["file"] as? String {
                            copy["path"] = pack.appendingPathComponent(file).path
                        }
                        items.append(copy)
                    }
                }
            }
            out.append([
                "packId": pack.lastPathComponent,
                "displayName": label,
                "items": items,
            ])
        }
        return out
    }

    public static func fonts() -> [[String: Any]] {
        var families: Set<String> = ["system"]
        let urls = bundle().urls(forResourcesWithExtension: "ttf",
                                 subdirectory: "Assets/fonts") ?? []
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            let family = stem.split(separator: "-").first.map(String.init) ?? stem
            families.insert(family)
        }
        return families.sorted().map { ["family": $0, "weights": ["regular"]] }
    }

    private static func bundle() -> Bundle {
        return Bundle(for: BundleLocator.self)
    }
}

private final class BundleLocator: NSObject {}
