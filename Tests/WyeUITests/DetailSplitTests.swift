#if os(macOS)
import CoreGraphics
import Testing
@testable import WyeUI

/// How a repository window's list and the detail on its right share the
/// window's width.
@Suite struct DetailSplitTests {
    /// The room the two have in a window this wide, its sidebar at its
    /// narrowest.
    private func room(inWindow width: CGFloat) -> CGFloat {
        width - 170
    }

    @Test func aChangeInTheWindowsWidthGoesToTheDetail() {
        let opened = DetailSplitWidths(preferred: 490, available: room(inWindow: 1220))
        #expect(opened.list == 490)
        #expect(opened.detail == 559)

        let wider = DetailSplitWidths(preferred: 490, available: room(inWindow: 1600))
        #expect(wider.list == 490)
        #expect(wider.detail == 939)

        let narrower = DetailSplitWidths(preferred: 490, available: room(inWindow: 1000))
        #expect(narrower.list == 490)
        #expect(narrower.detail == 339)
    }

    @Test func theListHasTheWidthTheDividerWasDraggedTo() {
        let widths = DetailSplitWidths(preferred: 640, available: 1400)
        #expect(widths.list == 640)
        #expect(widths.detail == 759)
        // And keeps it at the window's next width.
        #expect(DetailSplitWidths(preferred: 640, available: 1700).list == 640)
        #expect(DetailSplitWidths(preferred: 640, available: 1100).list == 640)
    }

    @Test func theDetailGivesWayFirstThenTheList() {
        // The detail, down to its narrowest.
        let tight = DetailSplitWidths(preferred: 490, available: 490 + 1 + 320)
        #expect(tight.list == 490)
        #expect(tight.detail == 320)
        // Then the list, down to its own.
        let squeezed = DetailSplitWidths(preferred: 490, available: 750)
        #expect(squeezed.list == 429)
        #expect(squeezed.detail == 320)
        let narrowest = DetailSplitWidths(preferred: 490, available: DetailSplitWidths.minimumWidth(showsDetail: true))
        #expect(narrowest.list == DetailSplitWidths.listMinimum)
        #expect(narrowest.detail == DetailSplitWidths.detailMinimum)
        // The list has its width back as soon as there is room for it.
        #expect(DetailSplitWidths(preferred: 490, available: 900).list == 490)
    }

    @Test func theListKeepsItsNarrowestWhereTheWindowCouldNotBe() {
        let cramped = DetailSplitWidths(preferred: 490, available: 600)
        #expect(cramped.list == 380)
        #expect(cramped.detail == 219)
        let none = DetailSplitWidths(preferred: 490, available: 300)
        #expect(none.list == 380)
        #expect(none.detail == 0)
    }

    @Test func aDragStaysWithinWhatFits() {
        // Past the detail's narrowest.
        #expect(DetailSplitWidths(preferred: 2000, available: 1000) == DetailSplitWidths(preferred: 679, available: 1000))
        #expect(DetailSplitWidths(preferred: 2000, available: 1000).detail == 320)
        // Past the list's.
        #expect(DetailSplitWidths(preferred: 100, available: 1000).list == 380)
        #expect(DetailSplitWidths(preferred: -50, available: 1000).detail == 619)
    }

    @Test func theTwoAndTheirDividerFillTheRoom() {
        for available in stride(from: CGFloat(701), through: 2400, by: 97) {
            for preferred in [CGFloat(200), 380, 490, 900, 3000] {
                let widths = DetailSplitWidths(preferred: preferred, available: available)
                #expect(widths.list + DetailSplitWidths.divider + widths.detail == available)
                #expect(widths.list >= DetailSplitWidths.listMinimum)
                #expect(widths.detail >= DetailSplitWidths.detailMinimum)
            }
        }
    }

    @Test func aWidthThatIsNoWidthIsTheUsualOne() {
        #expect(DetailSplitWidths(preferred: .nan, available: 1400).list == DetailSplitWidths.defaultListWidth)
        #expect(DetailSplitWidths(preferred: .infinity, available: 1400).list == DetailSplitWidths.defaultListWidth)
    }

    @Test func theWindowIsNoNarrowerThanWhatItShows() {
        #expect(DetailSplitWidths.minimumWidth(showsDetail: false) == 380)
        #expect(DetailSplitWidths.minimumWidth(showsDetail: true) == 701)
    }
}
#endif
