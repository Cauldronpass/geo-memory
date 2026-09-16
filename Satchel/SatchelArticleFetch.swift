// SatchelArticleFetch.swift
// Satchel only. D407 Build 2 — pull the article body behind a saved link,
// decide whether the link is an article at all, and write the recap.
//
// **Why this file is in `Satchel/` and not beside the sweep it copies.**
// `iOSDocumentStore.extractTextForNewArrivals` lives in `Trace/`, which Dayflow
// and the Trace app both compile (checked against `project.pbxproj`, not
// assumed — see the note in `feedback_trace_target_membership`). Neither of
// them has any business carrying a hidden web view, a 90 KB JavaScript
// resource, or a reason to talk to nytimes.com. `Satchel/` is a buildable
// folder for the Satchel target alone, so a file dropped here reaches exactly
// the app that saves links and nothing else. It calls back into the store for
// the two writes it needs.
//
// **The shape, from D407.** A link is a `.webloc` plus a sidecar (D384) and
// that does not change. At arrival Satchel tries to read the page: real prose
// becomes an article and goes on the Shelf; anything else stays a plain link in
// the library exactly as today. The text lands in the sidecar's `## Text`,
// where OCR text already lives, so articles are searchable like receipts and
// there is no third file per link (E40).

import Foundation
import UIKit
import WebKit

// MARK: - The reader

/// Loads a page in a hidden web view and runs Mozilla's Readability over it.
///
/// **One page at a time, by construction.** A single shared web view, reused,
/// means a backlog of links is a queue rather than twelve simultaneous page
/// loads on a phone's radio. `SatchelArticleSweep` awaits each `read` before
/// starting the next.
///
/// **`WKWebsiteDataStore.default()` is the point, not an incidental choice.**
/// It is the same cookie store the sign-in sheet (Build 3) will use, which is
/// what lets a page he pays for arrive as him. A private store here would make
/// that sheet decorative.
@MainActor
final class SatchelArticleReader: NSObject, WKNavigationDelegate {

    static let shared = SatchelArticleReader()

    struct Article {
        var title: String?
        var byline: String?
        var text: String
        var wordCount: Int
        /// `og:type`, verbatim. "article", "product", "website", or empty.
        var ogType: String
        /// Every `@type` found in the page's JSON-LD, comma-joined.
        var ldTypes: String
        /// schema.org `isAccessibleForFree`, verbatim, or empty when the page
        /// says nothing.
        ///
        /// The standard key a publisher uses to declare a paywall, and read
        /// here for that reason — but **it describes the site at least as often
        /// as it describes the page**. CNN sets it false on articles it hands
        /// over whole. It is therefore the LAST thing `decide` consults, not
        /// the first.
        var accessibleForFree: String
        /// D419. The same article with its headings, quotes, lists and photo
        /// lines kept, meta lines on top — what the reader draws. Empty when
        /// the page gave nothing structured, and then `text` is written
        /// instead. **Never used to decide anything**: `text`, `wordCount` and
        /// `substantialParagraphs` stay exactly what they were, because a photo
        /// line two hundred characters long is not a paragraph.
        var rich: String = ""

        /// **What the page says it is, which beats what it is long enough to
        /// look like.** A product page is a product page at two hundred words
        /// and at two thousand.
        var declaresProduct: Bool {
            ogType.lowercased() == "product"
                || ldTypes.lowercased().contains("product")
                || ldTypes.lowercased().contains("offer")
        }

        var declaresPaywalled: Bool {
            accessibleForFree.lowercased() == "false"
        }

        /// Lines of at least `SatchelArticleSweep.paragraphCharacters`
        /// characters. Readability puts each paragraph on its own line, so this
        /// counts real paragraphs.
        ///
        /// **The measure that separates prose from copy**, where a word count
        /// does not. A cargo liner's page reached three hundred words as a
        /// fitment list, a SKU, a price and two short blurbs; a news story
        /// reaches it in three paragraphs and keeps going.
        var substantialParagraphs: Int {
            text.split(separator: "\n").filter { $0.count >= SatchelArticleSweep.paragraphCharacters }.count
        }
    }

    enum Outcome {
        /// **The page loaded.** Everything learned about it is here, including
        /// the case where Readability found nothing at all — `text` is then
        /// empty and the page's own declarations still decide. An earlier
        /// version had a separate `notReadable`, which threw the declarations
        /// away in the one case they are most useful: a paywalled page that
        /// shows a robot no article node whatsoever still says
        /// `isAccessibleForFree: false` in its metadata.
        case read(Article)
        /// **The fetch did not happen.** Offline, a dead host, a page that
        /// never finished, or the script missing. Distinct from the above
        /// because the caller must NOT write `fetched:` for this one: a link
        /// skipped because the train went into a tunnel has to be picked up
        /// again next launch, and a `fetched:` date is forever.
        case unavailable(String)
    }

    /// Long enough for a slow news site, short enough that a dead host does not
    /// hold the queue. The page's own request timeout matches.
    private static let loadTimeout: Duration = .seconds(15)
    /// A beat after `didFinish` for the last of the page's own scripts to put
    /// the article in the DOM. Readability reads the DOM, not the HTML that
    /// arrived, so a site that renders its body in JavaScript needs this.
    private static let settle: Duration = .milliseconds(700)

    // MARK: Script

    /// Mozilla's Readability, Apache 2.0, compiled in as a string — see
    /// `SatchelReadabilityScript.swift` for why it is not a bundled resource.
    ///
    /// **A missing script is `unavailable`, never "not an article".** The
    /// distinction stays in the code even though it can no longer happen: if
    /// the script were ever absent, the honest answer is that no fetch
    /// happened. Returning "not an article" instead would stamp `fetched:` and
    /// `article: false` on every link he owns, permanently, from a build
    /// mistake — a silent wrong answer, which is the failure shape this project
    /// keeps writing warnings about. Embedding the script is what makes that
    /// unreachable rather than merely handled.
    private static var source: String? {
        SatchelReadabilityScript.source.isEmpty ? nil : SatchelReadabilityScript.source
    }

    static var isScriptAvailable: Bool { source != nil }

    /// Runs after the library. `charThreshold` is dropped from Readability's
    /// default 500 characters to 100 **on purpose**: at the default, a paywalled
    /// page's two-paragraph teaser comes back as `null`, indistinguishable from
    /// a hardware store's product page. Keeping the stub is what lets the card
    /// say "sign in to this site" instead of silently filing the NYT beside a
    /// kettle listing.
    ///
    /// Readability mutates the document it is handed, so it gets a clone.
    private static let extractor = """
    (function () {
      function meta(key) {
        var el = document.querySelector('meta[property="' + key + '"]')
              || document.querySelector('meta[name="' + key + '"]');
        return el ? (el.getAttribute("content") || "") : "";
      }
      var ldTypes = [];
      var free = "";
      var blocks = document.querySelectorAll('script[type="application/ld+json"]');
      for (var i = 0; i < blocks.length; i++) {
        try {
          var parsed = JSON.parse(blocks[i].textContent || "");
          var queue = Array.isArray(parsed) ? parsed.slice() : [parsed];
          var seen = 0;
          while (queue.length > 0 && seen < 80) {
            seen++;
            var node = queue.shift();
            if (!node || typeof node !== "object") { continue; }
            if (node["@graph"]) { queue = queue.concat(node["@graph"]); }
            var t = node["@type"];
            if (t) { ldTypes = ldTypes.concat(Array.isArray(t) ? t : [t]); }
            if (free === "" && typeof node.isAccessibleForFree !== "undefined") {
              free = String(node.isAccessibleForFree);
            }
          }
        } catch (e) { }
      }
      var out = {
        ok: "0", title: "", byline: "", text: "",
        ogType: meta("og:type"), ldTypes: ldTypes.join(","), free: free,
        rich: "", published: ""
      };
      try {
        var clone = document.cloneNode(true);
        var article = new Readability(clone, { charThreshold: 100 }).parse();
        if (article) {
          out.ok = "1";
          out.title = article.title || "";
          out.byline = article.byline || "";
          // **Paragraphs out of the DOM, not out of `textContent`.**
          // `textContent` is every text node concatenated, and whether any
          // newlines survive depends entirely on how the page happens to be
          // marked up. CNN's came back with blank lines between paragraphs;
          // the NYT's came back as one 1954-word line, so a rule that counts
          // paragraphs by counting lines saw exactly one and refused a real
          // article. Reading the block elements back out of `article.content`
          // gives the paragraphs the page actually has, on every site.
          var holder = document.createElement("div");
          holder.innerHTML = article.content || "";
          var blocks = holder.querySelectorAll("p, li, h2, h3, h4, blockquote, pre");
          var parts = [];
          for (var k = 0; k < blocks.length; k++) {
            var t = (blocks[k].textContent || "").replace(/\\s+/g, " ").trim();
            if (t) { parts.push(t); }
          }
          out.text = parts.length > 0 ? parts.join("\\n\\n") : (article.textContent || "");

          // **D419 — the same article, with its structure kept.** `text` above
          // is untouched and still decides what the page is; this is only what
          // the reader draws. See SatchelArticleText.swift for the format.
          out.published = article.publishedTime || meta("article:published_time") || "";
          var lead = meta("og:image");
          var rich = [];
          var textBlocks = 0;
          var lastImage = false;
          var seen = {};
          var buf = "";
          function squash(v) { return String(v || "").replace(/\\s+/g, " ").trim(); }
          function lastSegment(u) {
            try { var segs = new URL(u, document.baseURI).pathname.split("/"); return (segs.pop() || segs.pop() || "").toLowerCase(); }
            catch (e) { return String(u || "").toLowerCase(); }
          }
          var bylineKey = squash(article.byline).toLowerCase();
          function pushText(line) {
            if (!line) { return; }
            // "By Jane Doe" as the first paragraph repeats the byline the
            // reader already draws under the headline.
            if (textBlocks === 0 && bylineKey && line.length < 90 && line.toLowerCase().indexOf(bylineKey) >= 0) { return; }
            rich.push(line); textBlocks++; lastImage = false;
          }
          function flush() {
            var t = squash(buf); buf = "";
            if (t.length > 1) { pushText(t); }
          }
          function bestSource(img) {
            var best = "", bestW = 0;
            var set = img.getAttribute("srcset") || img.getAttribute("data-srcset") || "";
            if (set) {
              var pieces = set.split(/,\\s+/);
              for (var s = 0; s < pieces.length; s++) {
                var bits = pieces[s].trim().split(/\\s+/);
                var w = parseInt((bits[1] || "").replace("w", ""), 10) || 0;
                if (bits[0] && w >= bestW) { best = bits[0]; bestW = w; }
              }
            }
            if (!best) { best = img.getAttribute("src") || img.getAttribute("data-src") || ""; }
            var declared = parseInt(img.getAttribute("width") || "", 10) || 0;
            return { src: best, width: declared || bestW };
          }
          // The photo rule. Body photos only, 300px or wider when the page
          // says, never a logo or a headshot, never the lead photo again, and
          // only the first of a run of photos with no text between them.
          function pushImage(img, caption) {
            if (!img || lastImage) { return; }
            if (lead && textBlocks === 0) { return; }
            var picked = bestSource(img);
            var src = picked.src;
            if (!src || src.indexOf("data:") === 0) { return; }
            try { src = new URL(src, document.baseURI).href; } catch (e) { return; }
            if (!/^https?:/i.test(src)) { return; }
            if (/\\.svg(\\?|$)/i.test(src)) { return; }
            if (picked.width > 0 && picked.width < 300) { return; }
            var hint = ((img.getAttribute("class") || "") + " " + (img.getAttribute("alt") || "") + " " + src).toLowerCase();
            if (/(^|[^a-z])(avatar|headshot|logo|icon|sprite|emoji|badge)s?([^a-z]|$)/.test(hint)) { return; }
            var key = lastSegment(src);
            if (seen[key]) { return; }
            if (lead && key === lastSegment(lead)) { return; }
            seen[key] = true;
            var cap = squash(caption).replace(/[\\[\\]]/g, "");
            src = src.replace(/\\)/g, "%29").replace(/ /g, "%20");
            rich.push("![" + cap + "](" + src + ")");
            lastImage = true;
          }
          var titleKey = squash(article.title).toLowerCase();
          var inline = /^(a|span|em|strong|b|i|u|small|sup|sub|mark|time|abbr|code|cite|q|s|del|ins|font|label)$/;
          function walk(node) {
            var kids = node.childNodes;
            for (var i = 0; i < kids.length; i++) {
              var n = kids[i];
              if (n.nodeType === 3) { buf += n.textContent; continue; }
              if (n.nodeType !== 1) { continue; }
              var tag = n.tagName.toLowerCase();
              if (inline.test(tag)) {
                var inner = n.querySelectorAll("img");
                if (inner.length === 0) { buf += n.textContent; continue; }
                flush();
                for (var a = 0; a < inner.length; a++) { pushImage(inner[a], ""); }
                continue;
              }
              if (tag === "br") { buf += " "; continue; }
              flush();
              if (/^h[1-6]$/.test(tag)) {
                var h = squash(n.textContent);
                if (h && h.toLowerCase() !== titleKey) { pushText("### " + h); }
              } else if (tag === "p") {
                var pimgs = n.querySelectorAll("img");
                var pt = squash(n.textContent);
                for (var b = 0; b < pimgs.length; b++) { pushImage(pimgs[b], pimgs.length === 1 && pt.length < 120 ? pt : ""); }
                if (pt && !(pimgs.length > 0 && pt.length < 120)) { pushText(pt); }
              } else if (tag === "blockquote") {
                var cls = (n.getAttribute("class") || "").toLowerCase();
                var qt = squash(n.textContent);
                if (qt && !/(tweet|instagram|tiktok)/.test(cls)) { pushText("> " + qt); }
              } else if (tag === "ul" || tag === "ol") {
                var num = 0;
                for (var c = 0; c < n.children.length; c++) {
                  var li = n.children[c];
                  if (li.tagName.toLowerCase() !== "li") { continue; }
                  var lt = squash(li.textContent);
                  if (!lt) { continue; }
                  num++;
                  pushText((tag === "ol" ? (num + ". ") : "- ") + lt);
                }
              } else if (tag === "figure" || tag === "picture") {
                var fc = n.querySelector("figcaption");
                pushImage(n.querySelector("img"), fc ? fc.textContent : "");
              } else if (tag === "img") {
                pushImage(n, "");
              } else if (tag === "pre") {
                pushText(squash(n.textContent));
              } else if (tag === "table") {
                var rows = n.querySelectorAll("tr");
                for (var r = 0; r < rows.length; r++) { pushText(squash(rows[r].textContent)); }
              } else if (/^(figcaption|script|style|noscript|button|svg|form|input|hr|iframe)$/.test(tag)) {
                // nothing a reader reads
              } else {
                walk(n);
              }
            }
            flush();
          }
          walk(holder);
          out.rich = textBlocks > 0 ? rich.join("\\n\\n") : "";
        }
      } catch (e) { }
      return out;
    })();
    """

    // MARK: Web view

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    /// Which read the pending continuation belongs to.
    ///
    /// **Without this the timeout is a time bomb aimed at the next page.** The
    /// 15-second timer is started per read and cannot be cancelled from inside
    /// `withCheckedContinuation`; a page that finishes in two seconds leaves it
    /// running, and thirteen seconds later it would fire into whatever read is
    /// in flight by then and fail a page that was loading perfectly well. The
    /// sweep does up to five pages in a row, so that is the normal case, not
    /// the rare one.
    private var loadToken = 0

    /// A FRESH web view per page, torn down when the page has been read.
    ///
    /// **The reused one had a race, found on re-reading rather than on
    /// device.** Dropping the page meant loading `about:blank` into the shared
    /// view, and that is a navigation like any other: it calls `didFinish`.
    /// If that callback landed after the NEXT read had set its continuation —
    /// and the only thing separating them was however long an API call to
    /// Anthropic took — it would resume that read as "loaded" while its real
    /// page was still in flight, and Readability would run over a blank
    /// document. The article would come back "not readable", correctly filed,
    /// permanently wrong, with nothing anywhere saying why.
    ///
    /// A view per page costs a web content process per link, at most five per
    /// sweep, and removes the shared mutable thing the race needed. Cookies are
    /// unaffected: they live in `WKWebsiteDataStore.default()`, not in the view,
    /// which is the whole reason Build 3's sign-in will reach this fetch.
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A real size, not `.zero`. Sites branch on viewport width, and a page
        // laid out for a one-pixel window is a page whose article body may
        // never be built.
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366),
                            configuration: config)
        web.navigationDelegate = self
        web.isHidden = true
        return web
    }

    // MARK: Read

    func read(_ urlString: String) async -> Outcome {
        guard let url = TraceMacDocument.openableURL(urlString) else {
            return .unavailable("Not a web address.")
        }
        guard let script = Self.source else {
            return .unavailable("The Readability script is missing.")
        }

        let web = makeWebView()
        webView = web
        defer { teardown(web) }

        loadToken += 1
        let token = loadToken
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loadContinuation = continuation
            web.load(URLRequest(url: url, timeoutInterval: 15))
            Task { [weak self] in
                try? await Task.sleep(for: Self.loadTimeout)
                self?.finishLoad(false, token: token)
            }
        }

        guard finished else {
            return .unavailable("The page did not finish loading.")
        }

        try? await Task.sleep(for: Self.settle)

        let fields = await evaluate(script + "\n" + Self.extractor, in: web)
        guard !fields.isEmpty else {
            return .unavailable("The page returned nothing at all.")
        }

        let text = Self.tidy(fields["text"] ?? "")
        return .read(Article(
            title: Self.trimmedOrNil(fields["title"]),
            byline: Self.trimmedOrNil(fields["byline"]),
            text: text,
            wordCount: text.split(whereSeparator: { $0.isWhitespace }).count,
            ogType: fields["ogType"] ?? "",
            ldTypes: fields["ldTypes"] ?? "",
            accessibleForFree: fields["free"] ?? "",
            rich: Self.richText(fields)
        ))
    }

    /// Run the script and come back with strings.
    ///
    /// **The completion-handler form, wrapped, not the `async` one.**
    /// `evaluateJavaScript`'s async overload traps when the script's value is
    /// `undefined`, because it force-unwraps what the callback hands back. The
    /// script above always returns an object, so that should never happen —
    /// but "should never happen" on a page someone else wrote, in a sweep that
    /// runs unattended at launch, is a crash on his phone rather than a link
    /// that failed to read.
    ///
    /// **Returns `[String: String]`, empty for "no article", rather than the
    /// raw `Any?`.**
    ///
    /// **A continuation is an isolation boundary and `Any?` does not cross it.**
    /// Resuming with the untyped value WebKit hands back is a Sendable
    /// complaint under strict concurrency, and the fix is not to silence it: the
    /// bridging belongs in the callback, where the types are known, not fifty
    /// lines later in a `as?` chain that would have to be right about a
    /// dictionary it received from someone else's JavaScript.
    private func evaluate(_ js: String, in web: WKWebView) async -> [String: String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: String], Never>) in
            web.evaluateJavaScript(js) { value, _ in
                guard let dict = value as? [String: Any] else {
                    continuation.resume(returning: [:])
                    return
                }
                // Every value is a string on the JavaScript side, `ok`
                // included, so nothing here depends on how WebKit chooses to
                // bridge a boolean.
                continuation.resume(returning: [
                    "ok": dict["ok"] as? String ?? "0",
                    "title": dict["title"] as? String ?? "",
                    "byline": dict["byline"] as? String ?? "",
                    "text": dict["text"] as? String ?? "",
                    "ogType": dict["ogType"] as? String ?? "",
                    "ldTypes": dict["ldTypes"] as? String ?? "",
                    "free": dict["free"] as? String ?? "",
                    "rich": dict["rich"] as? String ?? "",
                    "published": dict["published"] as? String ?? ""
                ])
            }
        }
    }

    /// Drop the page and the view with it. The delegate goes first: a view
    /// that can still call back is a view that can still resume the wrong
    /// continuation, which is the race this replaced.
    private func teardown(_ web: WKWebView) {
        web.navigationDelegate = nil
        web.stopLoading()
        if webView === web { webView = nil }
    }

    private func finishLoad(_ ok: Bool, token: Int? = nil) {
        if let token, token != loadToken { return }
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(returning: ok)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(false)
    }

    // MARK: Text

    /// Readability's `textContent` keeps the page's own spacing, which on a news
    /// site is a run of blank lines between every paragraph. Collapsed here
    /// rather than at render so the sidecar on disk is the readable thing.
    private static func tidy(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !blank, !out.isEmpty { out.append("") }
                blank = true
            } else {
                out.append(line)
                blank = false
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The structured body with its two meta lines on top (D419).
    ///
    /// `-->` is stripped from the byline because it would close the comment
    /// early and put the rest of the byline on the page in Obsidian.
    private static func richText(_ fields: [String: String]) -> String {
        let body: String = tidy(fields["rich"] ?? "")
        guard !body.isEmpty else { return "" }
        var head: [String] = []
        if let byline = trimmedOrNil(fields["byline"]) {
            let safe: String = byline.replacingOccurrences(of: "--", with: "-")
            head.append("\(SatchelArticleText.bylinePrefix) \(safe) -->")
        }
        let published: String = (fields["published"] ?? "").trimmingCharacters(in: .whitespaces)
        if published.count >= 10 {
            let day: String = String(published.prefix(10))
            if day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                head.append("\(SatchelArticleText.publishedPrefix) \(day) -->")
            }
        }
        if head.isEmpty { return body }
        return head.joined(separator: "\n") + "\n\n" + body
    }

    private static func trimmedOrNil(_ raw: String?) -> String? {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - The sweep

/// Reads every saved link that has never been tried, one at a time.
///
/// The sibling of `iOSDocumentStore.extractTextForNewArrivals`, which does the
/// same job for images and PDFs, and called from the same three places in
/// `SatchelLibraryView`. Deliberately NOT in the share extension: the extension
/// stages bytes and makes no network call by design (D395).
enum SatchelArticleSweep {

    // MARK: The rule
    //
    // **Version one was "three hundred words of anything", and four real links
    // were enough to break it.** A cargo liner's product page cleared three
    // hundred words of fitment copy and became an article. A paywalled NYT page
    // cleared it on two paragraphs plus "thank you for your patience while we
    // verify access" and became an article too — a truncated piece filed as a
    // complete one, which is worse, because the screen then looks finished and
    // nothing anywhere says it is not.
    //
    // The rule now reads the page's own declarations as well as measuring it,
    // and it ranks the two: see `decide`, where the order is the whole design
    // and where getting it wrong filed a complete CNN article as blocked.

    /// Words of extracted text below which nothing is an article.
    static let articleWordCount = 300
    /// Characters that make a line count as a real paragraph.
    static let paragraphCharacters = 200
    /// How many such paragraphs an article needs.
    ///
    /// **Measured, after guessing wrong once.** From a partial view of the
    /// extracted text I wrote that the cargo liner had two of these and the CNN
    /// piece six, and said so to David. Counted properly against the files on
    /// disk: CNN 15, the cargo liner **4**, Rivian 0.
    ///
    /// So this test does NOT separate a product page from an article, and
    /// nothing here should pretend it does. What actually keeps the cargo liner
    /// out is its own `Product` declaration. This catches the thin page —
    /// Rivian's marketing splash, a login screen, a search result — where
    /// `wordCount` alone would let a long run of fragments through.
    ///
    /// A product page that declares nothing WILL be filed as an article. The
    /// answer to that is D407's manual flip, not a threshold tuned until it
    /// happens to split four samples.
    static let articleParagraphs = 3

    /// Phrases a page uses when it is showing a stub INSTEAD of the piece.
    ///
    /// **A list of strings is a poor instrument, and it is the second one used
    /// here, not the first.** `isAccessibleForFree` is the standard declaration
    /// and is checked ahead of this; this catches the sites that show the wall
    /// without declaring it. Matched only against the head and tail of the
    /// text, where a wall notice sits.
    ///
    /// **Every phrase here had to be one a free article would not carry**, and
    /// two candidates were cut for failing that: "already a subscriber" and "to
    /// continue reading" both appear in the footer of pieces that are perfectly
    /// readable, and blocking on them would hide a free article behind a
    /// sign-in prompt it does not need. What survives describes the wall
    /// itself, not the marketing around it. NYT's stub opens with "you have a
    /// preview view of this article while we are checking your access" and
    /// closes on "we verify access", so it is caught twice over.
    static let wallPhrases = [
        "verify access",
        "checking your access",
        "preview view of this article",
        "subscribe to continue reading",
        "log in to continue reading",
        "this article is for subscribers",
        "this content is for subscribers",
        "create a free account to continue"
    ]

    /// What the page turned out to be.
    ///
    /// **Order matters, and the first order was wrong.** It asked
    /// `isAccessibleForFree` before measuring, and CNN's Emmys piece came back
    /// blocked with the entire article sitting in `## Text`: 1154 words, 15
    /// paragraphs, no wall language anywhere in it. CNN declares
    /// `isAccessibleForFree: false` on pages it serves in full, and it is not
    /// alone — the flag is commonly set once for a whole site rather than per
    /// page.
    ///
    /// So the evidence is ranked by how direct it is:
    ///
    /// 1. The page says it is a product. Nothing about a product page's length
    ///    changes that.
    /// 2. The text we pulled contains the wall itself. That is not a claim
    ///    about the page, it is the page telling the reader it is showing a
    ///    stub, inside the stub.
    /// 3. **We have an article, measured.** Three hundred words in three real
    ///    paragraphs means the piece is in hand, and a publisher's blanket
    ///    paywall flag cannot take it away again.
    /// 4. Only now the declaration, which explains a page we did NOT get.
    ///
    /// A paywall claim is worth something when the goods are missing and
    /// nothing when they are not.
    static func decide(_ article: SatchelArticleReader.Article) -> ArticleState {
        if article.declaresProduct { return .link }
        if looksWalled(article.text) { return .blocked }

        if article.wordCount >= articleWordCount,
           article.substantialParagraphs >= articleParagraphs {
            return .article
        }

        if article.declaresPaywalled { return .blocked }
        return .link
    }

    private static func looksWalled(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let head = text.prefix(400).lowercased()
        let tail = text.suffix(800).lowercased()
        return wallPhrases.contains { head.contains($0) || tail.contains($0) }
    }

    /// How many links one pass will read. A first run over a long backlog would
    /// otherwise hold the radio for minutes on a launch he only wanted in order
    /// to look at a receipt. The rest are picked up on the next launch, because
    /// nothing wrote `fetched:` on them.
    static let perSweep = 5

    @MainActor
    static func run(store: iOSDocumentStore, noteStore: NoteStore) async {
        let pending = store.documents.filter { doc in
            doc.isLink && doc.fetchedOn == nil && !doc.url.isEmpty
        }
        guard !pending.isEmpty, SatchelArticleReader.isScriptAvailable else { return }

        var wrote = false
        for doc in pending.prefix(perSweep) {
            // **The disk decides, not the in-memory tags.** A sidecar that has
            // not finished downloading parses as no tags at all, which reads as
            // "not private" — the exact defect that sent a private document to
            // Anthropic once already (see `privacyOnDisk`). `unknown` is a skip
            // with no `fetched:` written, so the link is simply tried again once
            // its sidecar has arrived.
            guard store.privacyOnDisk(doc) == .notPrivate else { continue }

            let outcome = await SatchelArticleReader.shared.read(doc.url)
            let today = Date()

            switch outcome {
            case .unavailable:
                // Nothing is written. Not an answer, so not a record.
                continue

            case .read(let article):
                let state = decide(article)
                // Whatever came back goes to `## Text`: the piece for an
                // article, the teaser for a blocked one, the marketing copy for
                // a product page. All three are searchable, which is what
                // `## Text` is for, and the state beside it is now explicit
                // rather than something a screen has to infer from length.
                //
                // D419: an ARTICLE keeps its structure, because the reader draws
                // it. A blocked stub or a product page stays flat — nobody reads
                // those, and they are in `## Text` only to be searched.
                let stored: String = (state == .article && !article.rich.isEmpty) ? article.rich : article.text
                if !stored.isEmpty {
                    try? store.writeExtractedText(stored, for: doc)
                }
                _ = try? store.updateSidecar(for: doc, articleState: state, fetchedOn: .some(today))
                wrote = true

                if state == .article {
                    await recap(doc: doc, text: article.text, store: store, noteStore: noteStore)
                }
            }
        }

        if wrote { await store.reload() }
    }

    /// Read a link again from scratch (D407 Build 3).
    ///
    /// **Clears the verdict AND the date, then runs the ordinary sweep.**
    /// `fetched:` is what keeps the sweep off a link forever, so clearing it is
    /// the retry; clearing `article:` with it means a page that now reads
    /// differently is judged fresh rather than argued with. Nothing else is
    /// special-cased, so a retry cannot drift from a first read.
    ///
    /// `## Text` is deliberately left alone. If the retry succeeds the fetch
    /// overwrites it; if the page is still refusing, the stub that is there is
    /// better than an empty section, and it is still searchable.
    @MainActor
    static func retry(_ doc: TraceMacDocument, store: iOSDocumentStore, noteStore: NoteStore) async {
        _ = try? store.updateSidecar(for: doc, articleState: .some(nil), fetchedOn: .some(nil))
        await run(store: store, noteStore: noteStore)
    }

    /// The two-line recap and the tags, from the pulled text.
    ///
    /// The same Ask AI path every scanned document goes through, so the tags
    /// come with `buildPrompt`'s existing-list preference already applied —
    /// which is the whole guard against a vocabulary that grows a near-duplicate
    /// per article. Nothing new was built for this.
    ///
    /// **The title is never touched.** The page named itself through
    /// `LPMetadataProvider` at save (D384), and a headline read off the page is
    /// better than one a small model invents from the first 3000 characters of
    /// its own body.
    @MainActor
    private static func recap(doc: TraceMacDocument, text: String,
                              store: iOSDocumentStore, noteStore: NoteStore) async {
        let existing = Array(Set(store.documents.flatMap { $0.tags })).sorted()
        guard let result = try? await iOSDocumentScanService.scan(
            doc: doc,
            noteStore: noteStore,
            existingTags: existing,
            filenameIsGenerated: false,
            knownPeople: PeopleIndex.read().map(\.name),
            articleText: text
        ) else { return }

        // Failure here is not failure of the fetch. `article:` and `fetched:`
        // are already on disk, the text is already searchable, and the article
        // is already on the Shelf; it simply arrives without a recap. Silence
        // is right for an unattended pass, and Ask AI on the document remains
        // the way to try again.
        try? store.saveSidecar(
            for: doc,
            title: doc.title,
            tags: result.tags.isEmpty ? doc.tags : result.tags,
            linkedNote: doc.linkedNote,
            people: doc.people,
            description: result.description.isEmpty ? doc.description : result.description,
            date: doc.created
        )
    }
}
