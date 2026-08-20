import AppKit
import Foundation

/// Process entry point. Two headless subcommands run without opening a window, which
/// is how the filter logic gets tested on a machine where nobody is logged into X:
///
///   TwitterMac selftest            parse every user script + assert classifier verdicts
///   TwitterMac classify "<text>"   show the score both filters give one tweet
@main
struct TwitterMacMain {
    static func main() {
        let args = CommandLine.arguments

        if args.count >= 2, args[1] == "selftest" {
            exit(SelfTest.run())
        }
        if args.count >= 2, args[1] == "classify" {
            let text = args.dropFirst(2).joined(separator: " ")
            guard !text.isEmpty else {
                FileHandle.standardError.write(Data("usage: TwitterMac classify \"tweet text\"\n".utf8))
                exit(2)
            }
            exit(SelfTest.classifyCLI(text: text))
        }
        if args.count >= 2, args[1] == "shot" {
            guard args.count >= 4 else {
                FileHandle.standardError.write(Data("usage: TwitterMac shot <input.html> <output.png>\n".utf8))
                exit(2)
            }
            exit(Snapshot.run(input: args[2], output: args[3]))
        }
        if args.count >= 2, args[1] == "chrome-check" {
            // Diagnostic: verify the Chrome cookie import pipeline (Keychain read,
            // PBKDF2 key derivation, AES decryption) without printing any cookie
            // values. A macOS Keychain prompt may appear — approve it to proceed.
            let importer = ChromeCookieImporter()
            do {
                let result = try importer.importCookies()
                print("profile: \(result.profileName)")
                print("cookies imported: \(result.cookieCount)")
                for cookie in result.cookies {
                    print("  \(cookie.name) on \(cookie.domain) — decrypted OK (\(cookie.value.count) chars)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("chrome-check: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if args.count >= 2, args[1] == "--help" || args[1] == "-h" {
            print("""
            TwitterMac — native x.com client with content filtering

              TwitterMac                     launch the app
              TwitterMac selftest            run the filter test suite
              TwitterMac classify "<text>"   score one tweet against the filters
              TwitterMac shot <in> <out.png> snapshot a local HTML file with filters
              TwitterMac chrome-check         verify Chrome cookie import (no values printed)

            Config:  ~/.config/twitter-mac/config.json
            Filters: Resources/userscripts/*.js (override in ~/.config/twitter-mac/userscripts/)
            """)
            exit(0)
        }

        TwitterMacApp.main()
    }
}
