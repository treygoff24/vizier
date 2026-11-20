import AppKit
import QuartzCore
import Testing
import VizierEngine
@testable import Vizier

@Suite @MainActor struct StripRenderingTests {
    @Test func lampReusesQuantizedArtworkAndKeepsOffDistinctFromQuiet() throws {
        let lamp = LampView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        lamp.updateLayer()
        let off = try contents(lamp)
        lamp.level = 0
        lamp.updateLayer()
        let quiet = try contents(lamp)
        #expect(pixels(off) != pixels(quiet))

        lamp.level = 0.5
        lamp.updateLayer()
        let middle = try contents(lamp)
        let layer = try #require(lamp.layer)
        layer.displayIfNeeded()
        lamp.level = 0.501
        #expect(!layer.needsDisplay())
        lamp.updateLayer()
        #expect(try contents(lamp) === middle)
        lamp.level = 1
        #expect(layer.needsDisplay())
        lamp.updateLayer()
        #expect(pixels(try contents(lamp)) != pixels(middle))
        lamp.level = 0.5
        lamp.updateLayer()
        #expect(try contents(lamp) === middle)
    }

    @Test func lampCacheTracksClippingSizeAndBackingScale() throws {
        let lamp = LampView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        lamp.level = 1
        lamp.board = lamp.bounds
        lamp.updateLayer()
        let full = try contents(lamp)
        lamp.board = NSRect(x: 50, y: 0, width: 50, height: 100)
        lamp.updateLayer()
        let clipped = try contents(lamp)
        #expect(pixels(full) != pixels(clipped))

        lamp.frame.size.width = 120
        lamp.updateLayer()
        let wider = try contents(lamp)
        #expect(wider.width == Int(120 * (lamp.layer?.contentsScale ?? 1)))
        #expect(wider !== clipped)

        lamp.layer?.contentsScale = 2
        lamp.viewDidChangeBackingProperties()
        lamp.updateLayer()
        let retina = try contents(lamp)
        #expect(retina.width == 240)
        #expect(retina.height == 200)
    }

    @Test func retinaGlowKeepsTheSamePointSize() throws {
        let lamp = LampView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        lamp.level = 1
        let layer = try #require(lamp.layer)
        layer.contentsScale = 1
        lamp.updateLayer()
        let standard = NSBitmapImageRep(cgImage: try contents(lamp))
        layer.contentsScale = 2
        lamp.updateLayer()
        let retina = NSBitmapImageRep(cgImage: try contents(lamp))
        for x in [75, 80, 85] {
            let expected = try #require(standard.colorAt(x: x, y: 50)).alphaComponent
            let actual = try #require(retina.colorAt(x: x * 2, y: 100)).alphaComponent
            #expect(expected > 0.01)
            #expect(abs(actual - expected) < 0.025)
        }
    }

    @Test func lampClipsTheGlowToTheTopOfItsFlippedBoard() throws {
        let lamp = LampView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        lamp.layer?.contentsScale = 1
        lamp.level = 1
        lamp.board = NSRect(x: 0, y: 0, width: 100, height: 50)
        lamp.updateLayer()
        let bitmap = NSBitmapImageRep(cgImage: try contents(lamp))
        let top = try #require(bitmap.colorAt(x: 50, y: 20)).alphaComponent
        let bottom = try #require(bitmap.colorAt(x: 50, y: 80)).alphaComponent
        #expect(top > 0.01)
        #expect(bottom == 0)
    }

    @Test func unchangedStripStateDoesNotRequestAnotherDraw() throws {
        let strip = StripView(frame: NSRect(x: 0, y: 0, width: 880, height: 62))
        strip.wantsLayer = true
        let layer = try #require(strip.layer)
        strip.state.status = .init(text: "DELAYED", tone: .plain, sub: "+1.0 S")
        strip.state.words = [.init("synthetic", settled: false)]
        let state = strip.state
        layer.displayIfNeeded()
        strip.state = state
        #expect(!layer.needsDisplay())
        strip.state.words[0].settled = true
        #expect(layer.needsDisplay())
        layer.displayIfNeeded()
        strip.state.status?.tone = .red
        #expect(layer.needsDisplay())
        layer.displayIfNeeded()
        strip.state.seconds += 1
        #expect(layer.needsDisplay())
    }

    @Test func recordingAndFinalizingUseSeparateBoundedSchedules() throws {
        _ = NSApplication.shared
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var ticks = 0
        let clock = StripRefreshClock { _ in ticks += 1 }
        defer { clock.stop() }
        clock.record(in: view)
        let link = try #require(clock.displayLink)
        #expect(link.preferredFrameRateRange.maximum == 30)
        #expect(link.preferredFrameRateRange.preferred == 30)
        #expect(clock.timer == nil)

        clock.finalize()
        #expect(clock.displayLink == nil)
        let timer = try #require(clock.timer)
        #expect(timer.timeInterval == 0.5)
        timer.fire()
        #expect(ticks == 1)
        clock.record(in: view)
        #expect(!timer.isValid)
        #expect(clock.timer == nil)
        clock.stop()
        #expect(clock.displayLink == nil)
    }

    @Test func releasingClockInvalidatesItsTimer() throws {
        var clock: StripRefreshClock? = StripRefreshClock { _ in }
        clock?.finalize()
        let timer = try #require(clock?.timer)
        defer { timer.invalidate() }
        clock = nil
        #expect(!timer.isValid)
    }

    private func contents(_ lamp: LampView) throws -> CGImage {
        let object = try #require(lamp.layer?.contents)
        try #require(CFGetTypeID(object as CFTypeRef) == CGImage.typeID)
        return object as! CGImage
    }

    private func pixels(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
