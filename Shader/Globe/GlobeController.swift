//
//  GlobeController.swift
//  Shader
//

import SwiftUI
import QuartzCore
import simd

/// Selection, camera and animation state for one globe.
///
/// Picking a country hides the current one (its dots collapse into a dot), flies the
/// camera to the new one, zooming out on the way if it is far, then reveals it. Picking
/// a region flies back out to a whole-globe view centred on it and lights its countries.
@Observable
final class GlobeController {
    private(set) var resources: GlobeResources?
    private(set) var region: GlobeRegion?
    private(set) var country: Country?

    var atlas: GlobeAtlas? { resources?.atlas }

    /// Slowly turns the globe while nothing is picked.
    @ObservationIgnored var spinsWhenIdle = true
    @ObservationIgnored var reduceMotion = false
    /// Called when a still globe needs to draw again.
    @ObservationIgnored var onWake: (() -> Void)?

    // Layout, in points. The globe view's frame and the globe's slot are both kept in
    // window coordinates: SwiftUI reports a view that ignores the safe area at its
    // unexpanded position, so only UIKit knows where the Metal view really is.
    @ObservationIgnored private var viewFrame: CGRect = .zero
    /// Where the whole globe sits; `nil` centres it in the view.
    @ObservationIgnored private var globeSlot: CGRect?

    @ObservationIgnored private var camera = Camera(target: GlobeMath.direction(latitude: 20, longitude: 10),
                                                    altitude: Camera.globeAltitude)
    @ObservationIgnored private var flight: Flight?
    /// Waits for the shown country to hide before flying.
    @ObservationIgnored private var pendingDestination: Camera?
    @ObservationIgnored private var isDragging = false
    /// The camera and the gesture's translation when the drag took hold.
    @ObservationIgnored private var dragOrigin: (camera: Camera, translation: CGSize)?
    /// Drag inertia: longitude and latitude, radians per second.
    @ObservationIgnored private var spinVelocity = SIMD2<Double>.zero

    /// The country whose fine dots are drawn and how far its reveal has got.
    @ObservationIgnored private var shownCountry: Country?
    @ObservationIgnored private var revealProgress = 0.0
    /// Region highlight per map ID, eased toward its target every frame.
    @ObservationIgnored private var highlight = [Float](repeating: 0, count: 256)
    @ObservationIgnored private var appearance = 0.0
    /// 0…1 while flying: dots swell and brighten in transit.
    @ObservationIgnored private var travelBoost = 0.0
    @ObservationIgnored private var lastTime: CFTimeInterval?

    private static let idleSpin = 0.05            // radians per second
    private static let hideDuration = 0.28
    private static let revealDuration = 0.42
    /// Spacing of a selected country's dots once the camera has arrived.
    private static let countryDotPitch = 4.4      // points

    // MARK: Loading and layout

    func load() async {
        guard resources == nil, let resources = await GlobeResources.shared() else { return }
        self.resources = resources
        if let code = Locale.current.region?.identifier, let home = resources.atlas.country(code: code) {
            // Start over the viewer's own country, tilted a little toward the equator.
            let latitude = min(max(home.latitude * 0.7, -35), 35)
            camera.target = GlobeMath.direction(latitude: latitude, longitude: home.longitude)
        }
        wake()
    }

    /// The Metal view's frame in window coordinates.
    func setViewFrame(_ frame: CGRect) {
        guard frame != viewFrame else { return }
        viewFrame = frame
        wake()
    }

    /// Where the whole globe should sit when zoomed out, in window (global) coordinates;
    /// `nil` centres it in the view.
    func setGlobeSlot(_ slot: CGRect?) {
        guard slot != globeSlot else { return }
        globeSlot = slot
        wake()
    }

    // MARK: Selection

    func toggle(_ region: GlobeRegion) {
        select(region: self.region == region ? nil : region)
    }

    func select(region: GlobeRegion?) {
        self.region = region
        country = nil
        if let region {
            let focus = region.focus
            fly(to: Camera(target: GlobeMath.direction(latitude: focus.latitude, longitude: focus.longitude),
                           altitude: Camera.globeAltitude))
        } else {
            fly(to: Camera(target: camera.target, altitude: Camera.globeAltitude))
        }
    }

    func toggle(_ country: Country) {
        if self.country == country {
            deselectCountry()
        } else {
            select(country)
        }
    }

    func select(_ country: Country) {
        guard self.country != country else { return }
        self.country = country
        fly(to: Camera(target: country.center, altitude: altitude(fitting: country)))
    }

    func deselectCountry() {
        guard let country else { return }
        self.country = nil
        let focus = region?.focus
        let target = focus.map { GlobeMath.direction(latitude: $0.latitude, longitude: $0.longitude) } ?? country.center
        fly(to: Camera(target: target, altitude: Camera.globeAltitude))
    }

    // MARK: Gestures

    /// Picks the country under a point (global coordinates); tapping the sea or space
    /// backs out.
    func tap(at location: CGPoint) {
        let point = CGPoint(x: location.x - viewFrame.minX, y: location.y - viewFrame.minY)
        guard let atlas, let hit = hitTest(point) else {
            deselectCountry()
            return
        }
        guard let country = atlas.country(id: atlas.countryID(at: hit)) else {
            deselectCountry()
            return
        }
        if self.country == country { return }
        if region != nil, region != country.region { region = country.region }
        select(country)
    }

    /// The globe turns by hand only while zoomed out and settled; a drag that starts
    /// mid-flight takes hold once the flight lands.
    private var canDrag: Bool {
        country == nil && shownCountry == nil && flight == nil && pendingDestination == nil
    }

    /// - Parameter translation: the gesture's total translation so far.
    func drag(by translation: CGSize) {
        if !isDragging {
            guard canDrag else { return }
            isDragging = true
            dragOrigin = (camera, translation)
            spinVelocity = .zero
        }
        guard let dragOrigin else { return }
        let radius = Double(layout.globeRadius)
        let dx = Double(translation.width - dragOrigin.translation.width)
        let dy = Double(translation.height - dragOrigin.translation.height)
        camera = dragOrigin.camera.turned(longitude: -dx / radius, latitude: dy / radius)
        wake()
    }

    func endDrag(velocity: CGSize) {
        guard isDragging else { return }
        isDragging = false
        dragOrigin = nil
        let radius = Double(layout.globeRadius)
        spinVelocity = reduceMotion ? .zero : SIMD2(-Double(velocity.width) / radius, Double(velocity.height) / radius)
        wake()
    }

    // MARK: Frame

    enum Activity {
        /// Nothing moves: stop drawing.
        case still
        /// Only a slow spin or drift: a modest frame rate will do.
        case drifting
        /// A transition or a drag.
        case animating
    }

    /// Advances every animation to `now` and returns what to draw, plus how much is still
    /// moving.
    func frame(at now: CFTimeInterval, scale: Double) -> (uniforms: GlobeUniforms, highlight: [Float], activity: Activity) {
        let dt = min(max(now - (lastTime ?? now), 0), 1.0 / 20)
        lastTime = now
        let activity = advance(now: now, dt: dt)
        return (uniforms(scale: scale), highlight, activity)
    }

    private func advance(now: CFTimeInterval, dt: Double) -> Activity {
        var moving = isDragging
        if appearance < 1 {
            appearance = min(appearance + dt / 0.6, 1)
            moving = true
        }

        // Hide whatever no longer matches the selection, then fly, then reveal.
        if let shown = shownCountry, shown != country {
            revealProgress -= dt / Self.hideDuration
            if revealProgress <= 0 {
                shownCountry = nil
                revealProgress = 0
            }
            moving = true
        }
        if shownCountry == nil, let destination = pendingDestination {
            pendingDestination = nil
            startFlight(to: destination, now: now)
        }
        travelBoost = 0
        if let flight {
            let progress = flight.duration > 0 ? (now - flight.start) / flight.duration : 1
            if progress >= 1 {
                camera = flight.to
                self.flight = nil
            } else {
                camera = flight.camera(at: progress)
                travelBoost = flight.boost * pow(sin(.pi * progress), 2)
            }
            moving = true
        }
        if shownCountry == nil, let country, flight == nil, pendingDestination == nil {
            shownCountry = country
            revealProgress = 0
        }
        if shownCountry != nil, shownCountry == country, revealProgress < 1 {
            revealProgress = min(revealProgress + dt / Self.revealDuration, 1)
            moving = true
        }

        // Region highlight, off while a country is picked.
        let litRegion = country == nil ? region : nil
        let ease = Float(1 - exp(-7 * dt))
        for id in 1..<highlight.count {
            let target: Float = litRegion != nil && atlas?.region(ofID: id) == litRegion ? 1 : 0
            let delta = target - highlight[id]
            if abs(delta) > 0.002 {
                highlight[id] += delta * ease
                moving = true
            } else {
                highlight[id] = target
            }
        }
        if moving { return .animating }

        // Inertia after a drag, otherwise a slow idle spin.
        if simd_length(spinVelocity) > 0.002 {
            camera = camera.turned(longitude: spinVelocity.x * dt, latitude: spinVelocity.y * dt)
            spinVelocity *= exp(-3.2 * dt)
            return .drifting
        }
        if spinsWhenIdle, !reduceMotion, region == nil, country == nil, resources != nil {
            camera = camera.turned(longitude: Self.idleSpin * dt, latitude: 0)
            return .drifting
        }
        return .still
    }

    private func fly(to destination: Camera) {
        flight = nil
        isDragging = false
        dragOrigin = nil
        spinVelocity = .zero
        pendingDestination = destination
        wake()
    }

    private func startFlight(to destination: Camera, now: CFTimeInterval) {
        let layout = layout
        let angle = acos(min(max(simd_dot(camera.target, destination.target), -1), 1))
        // Zoom out far enough to see both ends at once (as a map's fly-to would).
        let neededAltitude = angle * layout.focal / Double(2 * layout.fitHalfSize.width) * 1.3
        let fromLog = log(camera.altitude)
        let toLog = log(destination.altitude)
        let peakLog = log(min(max(neededAltitude, 1e-6), Camera.globeAltitude))
        let bump = max(peakLog - max(fromLog, toLog), 0)
        let zoomTravel = abs(toLog - fromLog) + 2 * bump
        let duration = reduceMotion ? 0 : min(max(0.75 + 0.4 * angle + 0.24 * zoomTravel, 0.75), 2.1)
        flight = Flight(from: camera, to: destination, start: now, duration: duration,
                        bump: bump, boost: min(zoomTravel / 2.2, 1))
    }

    private func wake() {
        onWake?()
    }

    // MARK: Projection

    private struct Layout {
        var focus: CGPoint
        var globeRadius: CGFloat
        /// Focal length in points; fixed so the whole globe has `globeRadius` at the
        /// zoomed-out altitude.
        var focal: Double
        /// Half the area a country is fitted into.
        var fitHalfSize: CGSize
    }

    private var layout: Layout {
        let frame = globeSlot?.offsetBy(dx: -viewFrame.minX, dy: -viewFrame.minY)
            ?? CGRect(origin: .zero, size: viewFrame.size)
        let radius: CGFloat
        if globeSlot != nil {
            radius = max(min(frame.width * 0.43, frame.height * 0.4), 1)
        } else {
            radius = max(min(frame.width, frame.height) * 0.4, 1)
        }
        let distance = 1 + Camera.globeAltitude
        return Layout(focus: CGPoint(x: frame.midX, y: frame.midY),
                      globeRadius: radius,
                      focal: Double(radius) * (distance * distance - 1).squareRoot(),
                      fitHalfSize: CGSize(width: frame.width * 0.26, height: frame.height * 0.22))
    }

    private func altitude(fitting country: Country) -> Double {
        let layout = layout
        let fit = max(country.halfExtent.x / Double(layout.fitHalfSize.width),
                      country.halfExtent.y / Double(layout.fitHalfSize.height)) * layout.focal
        // The map holds ~4.9 km per pixel; stop well before its pixels outgrow the dots,
        // which also keeps a little context around the smallest countries.
        return min(max(fit, 0.14), Camera.globeAltitude)
    }

    private func hitTest(_ point: CGPoint) -> SIMD3<Double>? {
        let layout = layout
        let basis = camera.basis
        let dx = Double(point.x - layout.focus.x) / layout.focal
        let dy = Double(point.y - layout.focus.y) / layout.focal
        let direction = simd_normalize(-basis.back + basis.right * dx - basis.up * dy)
        let eye = camera.eye
        let b = simd_dot(eye, direction)
        let h = b * b - (simd_length_squared(eye) - 1)
        guard h > 0, b < 0 else { return nil }
        return eye + direction * (-b - h.squareRoot())
    }

    /// Screen position of a point on the globe, in points.
    private func project(_ point: SIMD3<Double>, layout: Layout) -> CGPoint {
        let basis = camera.basis
        let v = point - camera.eye
        let depth = max(simd_dot(v, -basis.back), 1e-4)
        return CGPoint(x: layout.focus.x + CGFloat(simd_dot(v, basis.right) / depth * layout.focal),
                       y: layout.focus.y - CGFloat(simd_dot(v, basis.up) / depth * layout.focal))
    }

    private func uniforms(scale: Double) -> GlobeUniforms {
        let layout = layout
        let basis = camera.basis
        let distance = 1 + camera.altitude
        let projectedRadius = layout.focal / (distance * distance - 1).squareRoot()

        // 0 with the whole globe in view, 1 once zoomed in on a country.
        let zoom = min(max((log(Camera.globeAltitude) - log(camera.altitude)) / (log(Camera.globeAltitude) - log(0.5)), 0), 1)

        var u = GlobeUniforms()
        u.eye = SIMD3<Float>(camera.eye)
        u.right = SIMD3<Float>(basis.right)
        u.up = SIMD3<Float>(basis.up)
        u.back = SIMD3<Float>(basis.back)
        u.viewport = SIMD2(Float(viewFrame.width * scale), Float(viewFrame.height * scale))
        u.focus = SIMD2(Float(layout.focus.x * scale), Float(layout.focus.y * scale))
        u.focal = Float(layout.focal * scale)
        u.scale = Float(scale)
        u.globeRadius = Float(projectedRadius * scale)
        u.rowStep = .pi / 128
        u.landLevel = Float(0.58 + (0.3 - 0.58) * zoom)
        u.oceanLevel = Float(0.12 + (0.22 - 0.12) * zoom)
        u.highlightLevel = 0.45
        u.countryLevel = 0.8
        u.boost = Float(travelBoost)
        u.opacity = Float(appearance * appearance * (3 - 2 * appearance))

        if let shown = shownCountry {
            let center = shown.center
            let (east, north) = GlobeMath.tangentBasis(at: center)
            // The fine lattice is sized for the country's own framing, so it stays put on
            // the globe while the camera moves.
            let framing = altitude(fitting: shown)
            let pointsPerRadian = layout.focal / camera.altitude
            let screenExtent = simd_length(shown.halfExtent) * pointsPerRadian
            let screen = project(center, layout: layout)
            u.selectedID = Int32(shown.id)
            u.selectionCenter = SIMD3<Float>(center)
            u.selectionEast = SIMD3<Float>(east)
            u.selectionNorth = SIMD3<Float>(north)
            u.selectionSpacing = Float(Self.countryDotPitch * framing / layout.focal)
            u.selectionScreen = SIMD2(Float(screen.x * scale), Float(screen.y * scale))
            u.reveal = Float(revealProgress)
            u.revealRadius = Float((screenExtent * 0.85 + 6) * scale)
            // Out to the farthest corner, so every visible part of the country (Corsica,
            // Alaska) comes in with the rest.
            let corners = [CGPoint.zero, CGPoint(x: viewFrame.width, y: 0),
                           CGPoint(x: 0, y: viewFrame.height), CGPoint(x: viewFrame.width, y: viewFrame.height)]
            let reach = corners.map { hypot($0.x - screen.x, $0.y - screen.y) }.max() ?? 0
            u.revealReach = Float((max(reach, screenExtent * 1.5) + 20) * scale)
            u.markerRadius = max(shown.halfExtent.x, shown.halfExtent.y) * pointsPerRadian < 9 ? Float(14 * scale) : 0
        }
        return u
    }
}

// MARK: - Camera

/// The camera always looks at the globe's centre from above `target`.
nonisolated struct Camera {
    /// Altitude of the whole-globe view, in globe radii.
    static let globeAltitude = 2.4
    /// Keeps the camera clear of the poles, where "north up" breaks down.
    static let maxLatitude = 80.0 * .pi / 180

    var target: SIMD3<Double>
    var altitude: Double

    var eye: SIMD3<Double> { target * (1 + altitude) }

    var basis: (right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>) {
        let back = target
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        return (right, simd_cross(back, right), back)
    }

    func turned(longitude: Double, latitude: Double) -> Camera {
        let lat = asin(min(max(target.y, -1), 1))
        let lon = atan2(target.x, target.z)
        let newLat = min(max(lat + latitude, -Self.maxLatitude), Self.maxLatitude)
        var copy = self
        copy.target = GlobeMath.direction(latitude: newLat * 180 / .pi, longitude: (lon + longitude) * 180 / .pi)
        return copy
    }
}

private nonisolated struct Flight {
    let from: Camera
    let to: Camera
    let start: CFTimeInterval
    let duration: Double
    /// Extra log-altitude at the midpoint.
    let bump: Double
    /// How much the dots swell and brighten in transit.
    let boost: Double

    func camera(at progress: Double) -> Camera {
        let e = progress < 0.5 ? 4 * progress * progress * progress : 1 - pow(-2 * progress + 2, 3) / 2
        let target = slerp(from.target, to.target, e)
        let logAltitude = log(from.altitude) + (log(to.altitude) - log(from.altitude)) * e + bump * sin(.pi * progress)
        return Camera(target: target, altitude: exp(logAltitude))
    }

    private func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let angle = acos(min(max(simd_dot(a, b), -1), 1))
        guard angle > 1e-6 else { return b }
        let s = sin(angle)
        let mixed = a * (sin((1 - t) * angle) / s) + b * (sin(t * angle) / s)
        // Keep clear of the poles mid-flight too.
        let limit = sin(Camera.maxLatitude)
        let clamped = SIMD3(mixed.x, min(max(mixed.y, -limit), limit), mixed.z)
        return simd_normalize(clamped)
    }
}
