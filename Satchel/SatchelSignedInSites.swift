// SatchelSignedInSites.swift
// Satchel only. D407 Build 3 — sign in to a site once, so the article fetch
// arrives as David.
//
// **The whole mechanism is one shared cookie jar.** `SatchelArticleReader`
// loads pages in a hidden `WKWebView` built on `WKWebsiteDataStore.default()`.
// This screen puts a VISIBLE web view on the same store. Sign in here and the
// cookies the site sets are the cookies the fetch sends, because there is only
// one store; nothing is copied, forwarded or stored by us, and no credential
// ever passes through Trace's own code.
//
// It is also separate from Safari, which is the point rather than a limitation:
// Satchel's jar is Satchel's, so signing in here does not touch his browser and
// a site he signs out of here stays signed in there.
//
// Caveats, both stated to David when D407 was agreed and both accepted: one
// sign-in per site, and a site can change how it blocks at any time.

import SwiftUI
import WebKit

// MARK: - The sheet

struct SatchelSignedInSitesView: View {

    @Environment(\.dismiss) private var dismiss

    /// Domains the shared store is holding cookies for.
    @State private var sites: [String] = []
    @State private var isLoading = true
    /// The address typed into the field, before it becomes a sign-in session.
    @State private var typed: String = ""
    /// The site currently open in the web view, or nil when the list is showing.
    @State private var signingInTo: URL? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let url = signingInTo {
                    SatchelSignInWeb(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    list
                }
            }
            .navigationTitle(signingInTo == nil ? "Signed-in sites" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if signingInTo != nil {
                        // **"Done", not "Cancel".** Leaving the web view is how
                        // a sign-in finishes: the cookies are already in the
                        // store the moment the site sets them, so there is
                        // nothing here to confirm or discard.
                        Button("Done") {
                            signingInTo = nil
                            Task { await load() }
                        }
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("nytimes.com", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { beginSignIn() }
                    Button("Sign in", action: beginSignIn)
                        .disabled(TraceMacDocument.openableURL(typed) == nil)
                }
            } header: {
                Text("Add a site")
            } footer: {
                Text("Satchel opens the site in its own browser. Sign in once and it stays signed in here. Your password is never seen by Trace.")
            }

            Section {
                if isLoading {
                    Text("Reading…").foregroundStyle(.secondary)
                } else if sites.isEmpty {
                    // An honest empty state rather than none: this list is the
                    // answer to a question he asked by opening the screen, and
                    // a blank section reads as broken.
                    Text("No sites signed in yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(sites, id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer(minLength: 8)
                            Button("Sign out") {
                                Task { await signOut(site) }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("Signed in")
            } footer: {
                Text("Signing out deletes this site's cookies from Satchel. It does not touch Safari.")
            }
        }
        .task { await load() }
    }

    // MARK: Actions

    private func beginSignIn() {
        guard let url = TraceMacDocument.openableURL(typed) else { return }
        signingInTo = url
        typed = ""
    }

    /// **"Signed in" means "this store holds cookies for that domain".**
    ///
    /// It is a proxy and worth naming as one: a site can leave a cookie without
    /// a login, so a domain can appear here that he never signed into. The
    /// honest alternative — asking each site whether he is authenticated — does
    /// not exist. The proxy is the same one every browser's "website data"
    /// screen uses, and Sign out does exactly what it says whether or not there
    /// was a session behind it.
    private func load() async {
        isLoading = true
        let records = await WKWebsiteDataStore.default()
            .dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        sites = records.map(\.displayName).sorted()
        isLoading = false
    }

    private func signOut(_ site: String) async {
        let records = await WKWebsiteDataStore.default()
            .dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter { $0.displayName == site }
        guard !matching.isEmpty else { return }
        // Every data type, not only cookies: a site that keeps its session in
        // local storage would otherwise stay signed in after a "Sign out",
        // which is the one thing this button must not do.
        await WKWebsiteDataStore.default()
            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
        await load()
    }
}

// MARK: - The web view

/// A plain `WKWebView` on the DEFAULT data store.
///
/// The store is the entire reason this exists. A default `WKWebView` in a
/// `UIViewRepresentable` would already use `.default()`, and it is written out
/// explicitly anyway so that nobody later "tidies" it into a non-persistent
/// store and silently breaks the fetch it exists to serve.
struct SatchelSignInWeb: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard web.url == nil else { return }
        web.load(URLRequest(url: url))
    }
}
