import Foundation

/// What's New for Pluck Studio's own features: kept here so basic Pluck isn't built with them
/// (it would count as a change to basic Pluck). Merged into WhatsNew.releases by version.
extension WhatsNew {
    static var studioReleases: [Release] {
        [
            Release(version: "1.17.0", items: [
                Item(symbol: "checkmark.seal", title: String(localized: "Delivery Check"),
                     detail: String(localized: "Drop a finished export and Pluck looks it over before it goes out: flash frames, black, a frozen picture, sound dropping out, loudness for where it’s going, typos in titles, text too close to the edge. Each finding opens at its moment. It runs locally on your Mac.")),
                Item(symbol: "rectangle.3.group", title: String(localized: "Brand Pack"),
                     detail: String(localized: "From a logo: lower thirds, a title card and an end card in its colours, animated and transparent, ready for the edit. One lower third per name, all at once.")),
                Item(symbol: "sparkle.magnifyingglass", title: String(localized: "Search the office archive"),
                     detail: String(localized: "In Edit Anywhere, search the office footage from home by what’s in the picture, and fetch just the shots you need. The office Mac looks at the footage with local AI; nothing leaves your team’s network.")),
            ]),
            Release(version: "1.16.0", items: [
                Item(symbol: "square.grid.2x2", title: String(localized: "All tools in one place"),
                     detail: String(localized: "Pluck Studio’s tools (Derush, Find Shots, Live Recorder, Logo Animator, Fit Music, Edit Anywhere) are under the new Tools button and Tools menu. Features your Mac can’t run are no longer shown.")),
                Item(symbol: "globe.europe.africa", title: String(localized: "Edit Anywhere"),
                     detail: String(localized: "Render DaVinci Resolve timelines on the office Mac from home, with the originals on the office storage, and get a preview back. Invite a Mac with a one-time link; everything stays on your team’s own private network.")),
                Item(symbol: "tag", title: String(localized: "Log in Resolve"),
                     detail: String(localized: "Find Shots writes what local AI on your Mac sees in every shot into your DaVinci Resolve project: a description, keywords and a marker per shot, ready to search or make smart bins from.")),
                Item(symbol: "wand.and.stars", title: String(localized: "A calmer Assemble"),
                     detail: String(localized: "In the Logo Animator, the dot or sparkle now grows in, glides to its place and settles, without bouncing around, and the name slides out cleanly.")),
            ]),
        ]
    }
}
