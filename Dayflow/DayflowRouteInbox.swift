//  DayflowRouteInbox.swift
//  Dayflow
//
//  A place for an intent to leave a `dayflow://` link, since asking the system
//  to open one does not reach the app when the app is already running.
//
//  **The search card is Dayflow asking Dayflow to open something** (D376). It
//  runs inside Dayflow's own process, so when a result is tapped, the system is
//  told to open a URL whose handler is the app that asked. It brings Dayflow
//  forward and `onOpenURL` does not fire — the foreground transition happens and
//  the link goes nowhere. David saw exactly that: the card stayed up, Dayflow
//  appeared behind it, and behind the card was whatever screen he had been on.
//
//  So the URL is handed over directly as well. `OpenURLIntent` still runs,
//  because bringing the app forward is a thing only the system can do; this
//  carries the part the system drops.
//
//  **Deliberately not a second routing table.** This holds a URL and nothing
//  else. `ContentView.handleDeepLink` is still the only thing that knows what a
//  host means, and it is reached through one more door rather than copied.

import Foundation
import Observation

@MainActor
@Observable
final class DayflowRouteInbox {
    static let shared = DayflowRouteInbox()

    /// Set by an intent, cleared by whoever routes it.
    ///
    /// **A counter rides along** because the same URL twice in a row is a real
    /// case — search for a task, open it, come back, open it again — and
    /// `onChange` on a value that did not change does not fire. Without this the
    /// second tap on the same row would do nothing, which is the class of
    /// silent no-op this app keeps having to correct.
    private(set) var pending: (url: URL, serial: Int)?
    private var serial = 0

    private init() {}

    func deliver(_ url: URL) {
        serial += 1
        pending = (url, serial)
    }

    func consume() -> URL? {
        defer { pending = nil }
        return pending?.url
    }
}
