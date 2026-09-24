import Foundation

@main
struct Smoke {
    static func main() throws {
        let url = URL(string: "https://example.org/altstore/source.json")!
        let fixture: [String: Any] = [
            "name": "Fixture Source", "iconURL": "./repo-icon.png",
            "apps": [
                ["name": "Fixture", "bundleIdentifier": "org.example.fixture",
                 "developerName": ["bad": "metadata"],
                 "iconURL": "./icon.png", "version": 2,
                 "versions": [["version": 2, "size": "123456", "downloadURL": "./file.ipa"]],
                 "screenshots": ["./one.png"], "appPermissions": ["invalid": 17]],
                ["name": "Marketplace only", "marketplaceID": "555"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let normalized = try ShrubCatalogJSON.normalize(data, sourceURL: url)
        let decoded = try JSONSerialization.jsonObject(with: normalized) as! [String: Any]
        let apps = decoded["apps"] as! [[String: Any]]
        assert(apps.count == 1)
        assert(decoded["iconURL"] as? String == "https://example.org/altstore/repo-icon.png")
        assert(apps[0]["iconURL"] as? String == "https://example.org/altstore/icon.png")
        assert((apps[0]["versions"] as! [[String: Any]])[0]["version"] as? String == "2")
        assert((apps[0]["versions"] as! [[String: Any]])[0]["downloadURL"] as? String == "https://example.org/altstore/file.ipa")
        print("PASS: tolerant metadata, URL resolution, version conversion, and marketplace-only filtering")
        let only: [String: Any] = ["apps": [["name": "PAL", "marketplaceID": "123"]]]
        do {
            _ = try ShrubCatalogJSON.normalize(JSONSerialization.data(withJSONObject: only), sourceURL: url)
            fatalError("Expected marketplace-only diagnostics")
        } catch ShrubCatalogJSON.FormatError.marketplaceOnly {
            print("PASS: marketplace-only source reports its actual unsupported format")
        }
    }
}
