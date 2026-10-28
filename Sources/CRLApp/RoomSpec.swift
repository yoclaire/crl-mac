import Foundation
import CoreGraphics

/// Room layout recovered from CRL32.EXE (CRect tables + bitmap resource ids), bundled as room.json.
struct RoomSpec: Decodable {
    struct Object: Decodable, Identifiable {
        let name: String
        let hit: [Int]
        let draw: [Int]?
        let variants: [String: Int]
        let tip: String
        var id: String { name }

        var hitRect: CGRect { CGRect(x: hit[0], y: hit[1], width: hit[2] - hit[0], height: hit[3] - hit[1]) }
        var drawRect: CGRect? {
            guard let d = draw, d[2] > d[0] else { return nil }
            return CGRect(x: d[0], y: d[1], width: d[2] - d[0], height: d[3] - d[1])
        }
    }
    struct Background: Decodable { let lit: Int; let dim: Int }

    let background: Background
    let objects: [Object]

    static let shared: RoomSpec = {
        let url = Bundle.module.url(forResource: "room", withExtension: "json")!
        return try! JSONDecoder().decode(RoomSpec.self, from: Data(contentsOf: url))
    }()

    func object(_ name: String) -> Object? { objects.first { $0.name == name } }
}

/// Fixed regions of the reading layout, in original 640×480 pixels (measured from a screenshot of
/// CRL32 running: Subject List over the left cabinet, article pane on the centre panel).
enum Layout {
    static let canvas = CGSize(width: 640, height: 480)
    static let subjectList = CGRect(x: 10, y: 26, width: 146, height: 250)
    static let article = CGRect(x: 192, y: 38, width: 324, height: 300)
    static let combo = CGRect(x: 192, y: 354, width: 324, height: 19)
    static let titlePlaque = CGRect(x: 214, y: 2, width: 276, height: 21)
}
