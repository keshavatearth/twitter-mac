import Foundation
import JavaScriptCore

/// Headless harness for the filter JavaScript.
///
///   TwitterMac selftest             syntax-check every user script + run the assertions
///   TwitterMac classify "<text>"    show what the filters make of one tweet
///
/// The classifiers are deliberately pure text -> {score, matches} functions, which is
/// what makes this possible without a window, a login, or a network call.
enum SelfTest {
    private struct Case {
        let text: String
        let politics: Bool
        let bait: Bool
        let note: String

        init(_ text: String, politics: Bool = false, bait: Bool = false, note: String = "") {
            self.text = text
            self.politics = politics
            self.bait = bait
            self.note = note
        }
    }

    /// Expectations. Cases marked "known miss" document where the heuristics give up and
    /// LLM grading is the answer — they assert current behaviour rather than pretending.
    private static let cases: [Case] = [
        // --- politics: hide -------------------------------------------------------
        Case("Trump just announced new tariffs on Chinese imports", politics: true),
        Case("The Supreme Court ruling on abortion changed everything", politics: true),
        Case("BJP sweeps the Lok Sabha election in UP", politics: true),
        Case("Gaza ceasefire talks collapsed again overnight", politics: true),
        Case("Why immigration is destroying this country", politics: true),
        Case("Zelensky asks NATO for more air defence", politics: true),
        Case("Voters head to the polls as the governor faces a recall", politics: true,
             note: "two medium signals stack to the threshold, no strong keyword"),

        // --- politics: keep -------------------------------------------------------
        Case("Shipped a Swift package for on-device transcription today"),
        Case("We used a conservative estimate for the p99 latency budget",
             note: "EXEMPT cancels the 'conservative' keyword"),
        Case("Liberal arts colleges are finally adding CS minors"),
        Case("The president of our company approved the redesign"),
        Case("Training regime for the marathon starts Monday", note: "'regime' alone is below threshold"),

        // --- engagement bait: hide ------------------------------------------------
        Case("Give me ONE good reason to buy a Windows laptop apart from Gaming", bait: true,
             note: "verbatim example from grading_instructions.txt"),
        Case("You won't believe what happened next!", bait: true),
        Case("Mornings like this in Namma Bengaluru🫰🏼", bait: true),
        Case("2024 recapped: my year in review", bait: true),
        Case("RT if you agree with this", bait: true),
        Case("Founder's office role has become so coveted it's the new PM", bait: true),
        Case("Earn $10,000 a week from home! Click here", bait: true),
        Case("This new diet will change your life forever!", bait: true),
        Case("Tweets like xyz happened and I am not a chill guy", bait: true),
        Case("if you're a man in your 20s you need to hear this", bait: true),
        Case("Another day another Zepto delivery in 8 minutes", bait: true),
        Case("Unpopular opinion: tabs beat spaces", bait: true),
        Case("Tag someone who needs to see this", bait: true),

        // --- engagement bait: keep (exemptions from grading_instructions.txt) -----
        Case("Looking for business journalists who have built a business outside of media. Any examples come to mind?"),
        Case("Announcing Exa Websets - a breakthrough toward perfect web search. signup for the waitlist"),
        Case("Just pushed v1.2.0 with faster incremental builds"),
        Case("We're hiring a compiler engineer, apply here"),
        Case("New paper: a benchmark for long-context retrieval"),

        // --- known heuristic misses ----------------------------------------------
        Case("Marrying a guy who loves IoT means all the switches of the new house will be like this 😂😂😂",
             note: "known miss: personal-anecdote bait needs LLM grading"),
        Case("The vibes in this office are unmatched",
             note: "known miss: no lexical signal at all")
    ]

    static func run() -> Int32 {
        var failures = 0
        var checks = 0

        // 1. Every script must at least parse. `new Function(src)` compiles without
        //    executing, so browser-only globals in 10-core.js are not a problem here.
        guard let parseCtx = JSContext() else {
            FileHandle.standardError.write(Data("selftest: no JSContext\n".utf8))
            return 1
        }
        let compile = parseCtx.evaluateScript("(function(src){ try { new Function(src); return ''; } catch (e) { return String(e); } })")
        for name in UserScripts.order {
            checks += 1
            guard let src = UserScripts.source(for: name) else {
                print("FAIL  \(name): not found")
                failures += 1
                continue
            }
            let err = compile?.call(withArguments: [src])?.toString() ?? "no result"
            if err.isEmpty {
                print("ok    \(name) parses (\(src.count) bytes)")
            } else {
                print("FAIL  \(name): \(err)")
                failures += 1
            }
        }

        // 2. Behaviour of the two classifiers.
        guard let ctx = makeClassifierContext() else {
            FileHandle.standardError.write(Data("selftest: could not load classifiers\n".utf8))
            return 1
        }
        print("")
        for testCase in cases {
            for (kind, expected) in [("politics", testCase.politics), ("bait", testCase.bait)] {
                checks += 1
                guard let result = classify(kind: kind, text: testCase.text, in: ctx) else {
                    print("FAIL  \(kind) classifier threw on: \(testCase.text)")
                    failures += 1
                    continue
                }
                if result.blocked == expected {
                    let mark = result.blocked ? "hide" : "keep"
                    print("ok    \(kind.padded(8)) \(mark) [\(result.score)] \(testCase.text.prefix(58))")
                } else {
                    failures += 1
                    print("FAIL  \(kind.padded(8)) expected \(expected ? "hide" : "keep"), got "
                          + "\(result.blocked ? "hide" : "keep") [score \(result.score) >= \(result.threshold)?] "
                          + "\(testCase.text)")
                    print("      matched: \(result.matches.joined(separator: " | "))")
                }
            }
            if !testCase.note.isEmpty {
                print("      note: \(testCase.note)")
            }
        }

        print("\n\(checks - failures)/\(checks) checks passed")
        return failures == 0 ? 0 : 1
    }

    static func classifyCLI(text: String) -> Int32 {
        guard let ctx = makeClassifierContext() else { return 1 }
        var anyBlocked = false
        for kind in ["politics", "bait"] {
            guard let r = classify(kind: kind, text: text, in: ctx) else { continue }
            anyBlocked = anyBlocked || r.blocked
            print("\(kind.padded(9)) score \(r.score)/\(r.threshold) -> \(r.blocked ? "HIDE" : "keep")")
            if !r.matches.isEmpty { print("          matched: \(r.matches.joined(separator: " | "))") }
        }
        print(anyBlocked ? "\nverdict: hidden behind a bar" : "\nverdict: shown")
        return 0
    }

    // MARK: - JS plumbing

    private struct Result {
        let score: Int
        let threshold: Int
        let blocked: Bool
        let matches: [String]
    }

    private static func makeClassifierContext() -> JSContext? {
        guard let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, exception in
            FileHandle.standardError.write(Data("JS exception: \(exception?.toString() ?? "?")\n".utf8))
        }
        // Minimal shim: the classifiers only need `window` and the registration hook.
        ctx.evaluateScript("""
        var window = this;
        window.console = { log: function () {}, warn: function () {}, error: function () {} };
        var console = window.console;
        window.__tmac = { registerFilter: function () {} };
        """)
        for name in ["20-politics.js", "30-engagement-bait.js"] {
            guard let src = UserScripts.source(for: name) else { return nil }
            ctx.evaluateScript(src)
        }
        return ctx
    }

    private static func classify(kind: String, text: String, in ctx: JSContext) -> Result? {
        // Text is passed as an argument, never interpolated into source.
        let fn = ctx.evaluateScript("""
        (function (kind, text) {
            var c = window.__tmacClassifiers[kind];
            var r = c.classify(text);
            return JSON.stringify({
                score: r.score,
                threshold: c.threshold,
                blocked: r.score >= c.threshold,
                matches: r.matches
            });
        })
        """)
        guard let raw = fn?.call(withArguments: [kind, text])?.toString(),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Result(
            score: json["score"] as? Int ?? 0,
            threshold: json["threshold"] as? Int ?? 0,
            blocked: json["blocked"] as? Bool ?? false,
            matches: json["matches"] as? [String] ?? []
        )
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
