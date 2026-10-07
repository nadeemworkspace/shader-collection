// Bakes Natural Earth's public-domain admin-0 countries into the globe's data
// (Shader/Globe/CountryMap.lzfse and Countries.json):
//   - an equirectangular country-ID map (UInt8, 0 = sea), LZFSE-compressed
//   - per-country metadata and framing
//
//   curl -LO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson
//   swiftc -O Tools/BakeCountryMap.swift -o /tmp/bake
//   /tmp/bake ne_50m_admin_0_countries.geojson Shader/Globe 8192
//
// It also writes preview.png (IDs as grey levels) next to the output; delete it before
// building, or it ends up in the app bundle.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let W = Int(args[3]) ?? 8192
let H = W / 2

let root = try JSONSerialization.jsonObject(with: Data(contentsOf: src)) as! [String: Any]
let features = root["features"] as! [[String: Any]]

struct Entry {
    var iso: String
    var name: String
    var region: String
    var population: Double
    var labelLon: Double
    var labelLat: Double
    var selectable: Bool
    var polygons: [[[[Double]]]] = []   // polygon -> ring -> point -> [lon, lat]
}

func regionCode(_ p: [String: Any]) -> String {
    let iso = p["ISO_A2_EH"] as! String
    if iso == "RU" { return "as" }
    if iso == "GS" { return "sa" }
    if iso == "MV" { return "as" }
    switch p["CONTINENT"] as! String {
    case "North America": return "na"
    case "South America": return "sa"
    case "Europe": return "eu"
    case "Africa": return "af"
    case "Asia": return "as"
    case "Oceania": return "oc"
    case "Seven seas (open ocean)": return "af"
    default: return ""
    }
}

// Partial territories folded into a parent country (by ISO code of the parent).
let mergeInto: [String: String] = ["Somaliland": "SO", "N. Cyprus": "CY",
                                   "Indian Ocean Ter.": "AU", "Ashmore and Cartier Is.": "AU"]

var entries: [Entry] = []
var indexByISO: [String: Int] = [:]
var pending: [(String, [[[[Double]]]])] = []

func polygons(of geometry: [String: Any]) -> [[[[Double]]]] {
    let type = geometry["type"] as! String
    let coords = geometry["coordinates"]!
    func ring(_ r: Any) -> [[Double]] { (r as! [Any]).map { ($0 as! [Any]).map { ($0 as! NSNumber).doubleValue } } }
    func poly(_ p: Any) -> [[[Double]]] { (p as! [Any]).map(ring) }
    switch type {
    case "Polygon": return [poly(coords)]
    case "MultiPolygon": return (coords as! [Any]).map(poly)
    default: fatalError(type)
    }
}

for f in features {
    let p = f["properties"] as! [String: Any]
    let name = p["NAME"] as! String
    let geo = polygons(of: f["geometry"] as! [String: Any])
    if let parent = mergeInto[name] {
        pending.append((parent, geo))
        continue
    }
    var iso = p["ISO_A2_EH"] as! String
    let region = regionCode(p)
    let selectable = iso != "-99" && !region.isEmpty
    if iso == "-99" { iso = "" }
    let e = Entry(iso: iso, name: name, region: region,
                  population: (p["POP_EST"] as? NSNumber)?.doubleValue ?? 0,
                  labelLon: (p["LABEL_X"] as! NSNumber).doubleValue,
                  labelLat: (p["LABEL_Y"] as! NSNumber).doubleValue,
                  selectable: selectable, polygons: geo)
    if !iso.isEmpty { indexByISO[iso] = entries.count }
    entries.append(e)
}
for (parent, geo) in pending {
    entries[indexByISO[parent]!].polygons += geo
}
precondition(entries.count < 255)

// Order: selectable countries alphabetically by ISO for stable IDs.
entries.sort { ($0.selectable ? 0 : 1, $0.iso, $0.name) < ($1.selectable ? 0 : 1, $1.iso, $1.name) }

// MARK: Rasterise

func ringArea(_ r: [[Double]]) -> Double {
    var a = 0.0
    for i in 0..<r.count {
        let p = r[i], q = r[(i + 1) % r.count]
        a += p[0] * q[1] - q[0] * p[1]
    }
    return abs(a) / 2
}

var pixels = [UInt8](repeating: 0, count: W * H)
let gray = CGColorSpaceCreateDeviceGray()
pixels.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                        space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setShouldAntialias(false)
    ctx.setAllowsAntialiasing(false)
    ctx.interpolationQuality = .none
    let sx = Double(W) / 360, sy = Double(H) / 180
    // Big polygons first so enclaves and small neighbours win any overlap.
    var jobs: [(id: Int, poly: [[[Double]]], area: Double)] = []
    for (i, e) in entries.enumerated() {
        for poly in e.polygons { jobs.append((i + 1, poly, ringArea(poly[0]))) }
    }
    jobs.sort { $0.area > $1.area }
    for job in jobs {
        let path = CGMutablePath()
        for ring in job.poly {
            path.addLines(between: ring.map { CGPoint(x: ($0[0] + 180) * sx, y: ($0[1] + 90) * sy) })
            path.closeSubpath()
        }
        ctx.setFillColor(gray: CGFloat(job.id) / 255, alpha: 1)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
    }
}

func pixelIndex(lon: Double, lat: Double) -> Int {
    let c = min(max(Int((lon + 180) / 360 * Double(W)), 0), W - 1)
    let r = min(max(Int((90 - lat) / 180 * Double(H)), 0), H - 1)
    return r * W + c
}

// Every polygon keeps at least one pixel, so tiny islands still exist on the map.
var stamped = 0
for (i, e) in entries.enumerated() {
    for poly in e.polygons {
        let ring = poly[0]
        var lon = 0.0, lat = 0.0
        for p in ring { lon += p[0]; lat += p[1] }
        lon /= Double(ring.count); lat /= Double(ring.count)
        let minLon = ring.map { $0[0] }.min()!, maxLon = ring.map { $0[0] }.max()!
        let minLat = ring.map { $0[1] }.min()!, maxLat = ring.map { $0[1] }.max()!
        // Polygons smaller than ~2 pixels may have been skipped by the scan converter.
        if (maxLon - minLon) * Double(W) / 360 < 2.5 && (maxLat - minLat) * Double(H) / 180 < 2.5 {
            let k = pixelIndex(lon: lon, lat: lat)
            if pixels[k] == 0 { pixels[k] = UInt8(i + 1); stamped += 1 }
        }
    }
}
print("stamped", stamped)

// Verify exact IDs.
var counts = [Int](repeating: 0, count: 256)
for v in pixels { counts[Int(v)] += 1 }
for v in (entries.count + 1)..<256 where counts[v] > 0 { print("unexpected value", v, counts[v]) }

// MARK: Per-country framing

func vec(lon: Double, lat: Double) -> SIMD3<Double> {
    let l = lon * .pi / 180, p = lat * .pi / 180
    return SIMD3(cos(p) * sin(l), sin(p), cos(p) * cos(l))
}
func lonLat(_ v: SIMD3<Double>) -> (Double, Double) {
    let n = v / (v * v).sum().squareRoot()
    return (atan2(n.x, n.z) * 180 / .pi, asin(max(-1, min(1, n.y))) * 180 / .pi)
}
func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> { v / (v * v).sum().squareRoot() }

func weightedQuantile(_ values: [(Double, Double)], _ q: Double) -> Double {
    let sorted = values.sorted { $0.0 < $1.0 }
    let total = sorted.reduce(0) { $0 + $1.1 }
    var acc = 0.0
    for (v, w) in sorted {
        acc += w
        if acc >= q * total { return v }
    }
    return sorted.last?.0 ?? 0
}

var members = [[Int]](repeating: [], count: entries.count + 1)
for k in 0..<(W * H) where pixels[k] != 0 { members[Int(pixels[k])].append(k) }

let pixelSolidAngle = (2 * Double.pi / Double(W)) * (Double.pi / Double(H))
var out: [[String: Any]] = []
for (i, e) in entries.enumerated() {
    let id = i + 1
    let pts: [(SIMD3<Double>, Double)] = members[id].map { k in
        let r = k / W, c = k % W
        let lat = 90 - (Double(r) + 0.5) * 180 / Double(H)
        let lon = -180 + (Double(c) + 0.5) * 360 / Double(W)
        return (vec(lon: lon, lat: lat), cos(lat * .pi / 180))
    }
    let area = pts.reduce(0) { $0 + $1.1 } * pixelSolidAngle * 6371.0 * 6371.0

    // Robust main body: pixels within 2.5× the weighted median distance of the label
    // point, so overseas territories (French Guiana, Alaska, …) don't steer the camera.
    let label = vec(lon: e.labelLon, lat: e.labelLat)
    let dists = pts.map { (acos(max(-1, min(1, dot($0.0, label)))), $0.1) }
    let median = weightedQuantile(dists, 0.5)
    let cutoff = max(2.5 * median, 0.02)
    var body = zip(pts, dists).filter { $0.1.0 <= cutoff }.map { $0.0 }
    if body.isEmpty { body = [(label, 1)] }
    var centre = normalize(body.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.0 * $1.1 })

    // Extent on the tangent plane (east / north) around the body's centroid.
    let up = SIMD3<Double>(0, 1, 0)
    var east = normalize(cross(up, centre))
    var north = cross(centre, east)
    let us = body.map { (dot($0.0, east) / dot($0.0, centre), $0.1) }
    let vs = body.map { (dot($0.0, north) / dot($0.0, centre), $0.1) }
    let u0 = weightedQuantile(us, 0.01), u1 = weightedQuantile(us, 0.99)
    let v0 = weightedQuantile(vs, 0.01), v1 = weightedQuantile(vs, 0.99)
    // Re-centre on the box.
    centre = normalize(centre + east * (u0 + u1) / 2 + north * (v0 + v1) / 2)
    east = normalize(cross(up, centre)); north = cross(centre, east)
    let (lon, lat) = lonLat(centre)

    out.append([
        "id": id,
        "iso": e.iso,
        "name": e.name,
        "region": e.region,
        "selectable": e.selectable,
        "population": e.population,
        "area": (area * 10).rounded() / 10,
        "lon": (lon * 1e4).rounded() / 1e4,
        "lat": (lat * 1e4).rounded() / 1e4,
        // Half extents on the tangent plane, in radians.
        "halfWidth": (max((u1 - u0) / 2, 0.0005) * 1e5).rounded() / 1e5,
        "halfHeight": (max((v1 - v0) / 2, 0.0005) * 1e5).rounded() / 1e5,
    ])
}

let json = try JSONSerialization.data(withJSONObject: ["width": W, "height": H, "countries": out],
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Countries.json"))

let compressed = try (Data(pixels) as NSData).compressed(using: .lzfse) as Data
try compressed.write(to: outDir.appendingPathComponent("CountryMap.lzfse"))
print("raster", W, "x", H, "compressed bytes", compressed.count, "countries", entries.count)

// Preview (scaled IDs) for eyeballing the result.
let preview = pixels.map { $0 == 0 ? UInt8(0) : UInt8(60 + Int($0) * 195 / entries.count) }
let provider = CGDataProvider(data: Data(preview) as CFData)!
let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W, space: gray,
                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)!
let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent("preview.png") as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
