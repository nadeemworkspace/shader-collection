//
//  GlobeAtlas.swift
//  Shader
//
//  Country data for the globe, baked from Natural Earth's public-domain 1:50m admin-0
//  boundaries by Tools/BakeCountryMap.swift:
//
//  - CountryMap.lzfse: an 8192 × 4096 equirectangular map of country IDs (one byte per
//    pixel, 0 = sea), north up, longitude −180° on the left.
//  - Countries.json: per-country metadata and framing (the centre and half extents of
//    the country's main body, ignoring far-flung territories).
//

import Foundation
import Metal
import simd

/// The continents offered in the region picker.
nonisolated enum GlobeRegion: String, CaseIterable, Identifiable, Sendable {
    case northAmerica = "na"
    case southAmerica = "sa"
    case europe = "eu"
    case africa = "af"
    case asia = "as"
    case oceania = "oc"

    var id: Self { self }

    var title: String {
        switch self {
        case .northAmerica: "North America"
        case .southAmerica: "South America"
        case .europe: "Europe"
        case .africa: "Africa"
        case .asia: "Asia"
        case .oceania: "Oceania"
        }
    }

    /// Where the camera looks when the region is picked (degrees).
    var focus: (latitude: Double, longitude: Double) {
        switch self {
        case .northAmerica: (42, -100)
        case .southAmerica: (-18, -60)
        case .europe: (50, 14)
        case .africa: (4, 18)
        case .asia: (34, 95)
        case .oceania: (-20, 150)
        }
    }

    /// Half the width of the region's thumbnail, as an arc on the globe (radians).
    var thumbnailSpan: Double {
        switch self {
        case .northAmerica: 0.78
        case .southAmerica: 0.6
        case .europe: 0.42
        case .africa: 0.68
        case .asia: 0.9
        case .oceania: 0.62
        }
    }
}

nonisolated struct Country: Identifiable, Hashable, Sendable {
    /// The country's value in the ID map.
    let id: Int
    /// ISO 3166-1 alpha-2.
    let code: String
    let name: String
    let region: GlobeRegion
    let population: Double
    /// Centre of the main body, in degrees.
    let latitude: Double
    let longitude: Double
    /// Half extents of the main body on the plane tangent at the centre (radians east and
    /// north), used to frame the country.
    let halfExtent: SIMD2<Double>

    var center: SIMD3<Double> { GlobeMath.direction(latitude: latitude, longitude: longitude) }

    var flag: String {
        code.unicodeScalars.reduce(into: "") { flag, scalar in
            if let indicator = UnicodeScalar(0x1F1A5 + scalar.value) {
                flag.unicodeScalars.append(indicator)
            }
        }
    }
}

nonisolated enum GlobeMath {
    /// Unit vector for a latitude / longitude in degrees: y is north, longitude 0 faces +z.
    static func direction(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        return SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
    }

    /// East and north on the plane tangent at `point` (undefined at the poles).
    static func tangentBasis(at point: SIMD3<Double>) -> (east: SIMD3<Double>, north: SIMD3<Double>) {
        let east = simd_normalize(simd_cross(SIMD3(0, 1, 0), point))
        return (east, simd_cross(point, east))
    }
}

/// Countries, the ID map and the dot thumbnails of each region.
nonisolated final class GlobeAtlas: Sendable {
    /// Selectable countries, most populous first.
    let countries: [Country]
    let mapWidth: Int
    let mapHeight: Int
    let map: Data
    /// Dot positions for each region's thumbnail, in a unit square (y down).
    let thumbnails: [GlobeRegion: [SIMD2<Float>]]

    private let countriesByID: [Int: Country]
    private let countriesByRegion: [GlobeRegion: [Country]]
    /// Region of every map ID, for per-frame lookups.
    private let regionsByID: [GlobeRegion?]

    init(bundle: Bundle = .main) throws {
        guard let jsonURL = bundle.url(forResource: "Countries", withExtension: "json"),
              let mapURL = bundle.url(forResource: "CountryMap", withExtension: "lzfse")
        else { throw CocoaError(.fileNoSuchFile) }

        let file = try JSONDecoder().decode(CountryFile.self, from: Data(contentsOf: jsonURL))
        mapWidth = file.width
        mapHeight = file.height
        map = try (Data(contentsOf: mapURL) as NSData).decompressed(using: .lzfse) as Data
        guard map.count == mapWidth * mapHeight else { throw CocoaError(.fileReadCorruptFile) }

        let locale = Locale.current
        countries = file.countries
            .compactMap { entry -> Country? in
                guard entry.selectable, let region = GlobeRegion(rawValue: entry.region) else { return nil }
                return Country(id: entry.id,
                               code: entry.iso,
                               name: locale.localizedString(forRegionCode: entry.iso) ?? entry.name,
                               region: region,
                               population: entry.population,
                               latitude: entry.lat,
                               longitude: entry.lon,
                               halfExtent: SIMD2(entry.halfWidth, entry.halfHeight))
            }
            .sorted { $0.population > $1.population }
        countriesByID = Dictionary(uniqueKeysWithValues: countries.map { ($0.id, $0) })
        countriesByRegion = Dictionary(grouping: countries, by: \.region)
        var regionsByID = [GlobeRegion?](repeating: nil, count: 256)
        for country in countries { regionsByID[country.id] = country.region }
        self.regionsByID = regionsByID

        var thumbnails: [GlobeRegion: [SIMD2<Float>]] = [:]
        for region in GlobeRegion.allCases {
            thumbnails[region] = Self.thumbnailDots(for: region, map: map, width: mapWidth, height: mapHeight,
                                                    regionOf: { regionsByID[$0] })
        }
        self.thumbnails = thumbnails
    }

    func country(id: Int) -> Country? {
        countriesByID[id]
    }

    func region(ofID id: Int) -> GlobeRegion? {
        regionsByID.indices.contains(id) ? regionsByID[id] : nil
    }

    func country(code: String) -> Country? {
        countries.first { $0.code == code }
    }

    /// Countries listed for a region (all of them when `nil`), most populous first.
    func countries(in region: GlobeRegion?) -> [Country] {
        guard let region else { return countries }
        return countriesByRegion[region] ?? []
    }

    /// The value in the ID map under a point on the unit sphere.
    func countryID(at point: SIMD3<Double>) -> Int {
        Self.countryID(at: point, map: map, width: mapWidth, height: mapHeight)
    }

    private static func countryID(at point: SIMD3<Double>, map: Data, width: Int, height: Int) -> Int {
        let longitude = atan2(point.x, point.z)
        let latitude = asin(min(max(point.y, -1), 1))
        let x = min(max(Int((longitude + .pi) / (2 * .pi) * Double(width)), 0), width - 1)
        let y = min(max(Int((.pi / 2 - latitude) / .pi * Double(height)), 0), height - 1)
        return Int(map[y * width + x])
    }

    /// Samples the region on a square grid in an orthographic view centred on its focus,
    /// like a small piece of the globe.
    private static func thumbnailDots(for region: GlobeRegion, map: Data, width: Int, height: Int,
                                      regionOf: (Int) -> GlobeRegion?) -> [SIMD2<Float>] {
        let focus = region.focus
        let center = GlobeMath.direction(latitude: focus.latitude, longitude: focus.longitude)
        let (east, north) = GlobeMath.tangentBasis(at: center)
        let columns = 34
        let rows = 21
        let span = region.thumbnailSpan
        let step = 2 * span / Double(columns - 1)
        var dots: [SIMD2<Float>] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = -span + Double(column) * step
                let y = (Double(rows - 1) / 2 - Double(row)) * step
                let depth = 1 - x * x - y * y
                guard depth > 0 else { continue }
                let point = center * depth.squareRoot() + east * x + north * y
                let id = countryID(at: point, map: map, width: width, height: height)
                guard id != 0, regionOf(id) == region else { continue }
                dots.append(SIMD2(Float(column) / Float(columns - 1), Float(row) / Float(rows - 1)))
            }
        }
        return dots
    }
}

private nonisolated struct CountryFile: Decodable {
    struct Entry: Decodable {
        let id: Int
        let iso: String
        let name: String
        let region: String
        let selectable: Bool
        let population: Double
        let lat: Double
        let lon: Double
        let halfWidth: Double
        let halfHeight: Double
    }

    let width: Int
    let height: Int
    let countries: [Entry]
}

// MARK: - GPU resources

/// The render pipeline and the ID map as a texture, shared by every globe on screen.
nonisolated final class GlobeResources: @unchecked Sendable {
    let atlas: GlobeAtlas
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let map: MTLTexture

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { throw CocoaError(.featureUnsupported) }
        let atlas = try GlobeAtlas()

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "globeVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "globeFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint, width: atlas.mapWidth, height: atlas.mapHeight, mipmapped: false)
        textureDescriptor.usage = .shaderRead
        guard let map = device.makeTexture(descriptor: textureDescriptor) else {
            throw CocoaError(.featureUnsupported)
        }
        atlas.map.withUnsafeBytes { bytes in
            map.replace(region: MTLRegionMake2D(0, 0, atlas.mapWidth, atlas.mapHeight),
                        mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: atlas.mapWidth)
        }

        self.atlas = atlas
        self.device = device
        self.pipeline = pipeline
        self.map = map
    }

    @MainActor private static var loading: Task<GlobeResources?, Never>?

    /// Loads once (decompressing the map takes a moment) and shares the result.
    @MainActor static func shared() async -> GlobeResources? {
        if let loading { return await loading.value }
        let task = Task.detached(priority: .userInitiated) { () -> GlobeResources? in
            do {
                return try GlobeResources()
            } catch {
                assertionFailure("Globe resources failed to load: \(error)")
                return nil
            }
        }
        loading = task
        return await task.value
    }
}
