import Foundation
import BottomlessCore

// Imports a Google Photos export (Google Takeout zips or extracted folders) into Bottomless.
//   bottomless-import --api https://... --token-file ~/bottomless/.secrets/app_token [--state FILE] [--delete-zips] PATH...
// Zips are extracted next to the state file one at a time; with --delete-zips the zip is removed as soon as the
// extraction is verified and the extracted copy after a clean import, so the disk only ever holds about one part. Re-running is safe: finished items are skipped and the server dedupes by hash.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(2)
}

func say(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

@discardableResult
func run(_ tool: String, _ arguments: [String], output: Pipe? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    if let output { p.standardOutput = output }
    do { try p.run() } catch { return -1 }
    if let output { _ = output.fileHandleForReading.readDataToEndOfFile() }
    p.waitUntilExit()
    return p.terminationStatus
}

func zipFileCount(_ zip: URL) -> Int {
    let pipe = Pipe(), p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    p.arguments = ["-1", zip.path]
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return -1 }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.split(separator: "\n").filter { !$0.hasSuffix("/") }.count
}

func fileCount(_ dir: URL) -> Int {
    var n = 0
    let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = walker?.nextObject() as? URL { if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 } }
    return n
}

var args = Array(CommandLine.arguments.dropFirst())
var api: String?, tokenFile: String?, state: String?, concurrency = 6, deleteZips = false, paths: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        if args.isEmpty { fail("\(a) needs a value") }
        return args.removeFirst()
    }
    switch a {
    case "--api": api = value()
    case "--token-file": tokenFile = value()
    case "--state": state = value()
    case "--concurrency": concurrency = Int(value()) ?? 6
    case "--delete-zips": deleteZips = true
    case "-h", "--help": print("usage: bottomless-import --api URL --token-file FILE [--state FILE] [--concurrency N] [--delete-zips] PATH..."); exit(0)
    default: paths.append((a as NSString).expandingTildeInPath)
    }
}
guard let api, let base = URL(string: api), let tokenFile else { fail("--api and --token-file are required") }
guard let token = try? String(contentsOfFile: (tokenFile as NSString).expandingTildeInPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { fail("cannot read the token file") }
guard !paths.isEmpty else { fail("give at least one Takeout zip or folder") }

let statePath = (state.map { ($0 as NSString).expandingTildeInPath }) ?? (NSHomeDirectory() + "/bottomless/.import/takeout-state.sqlite")
let workDir = URL(fileURLWithPath: statePath).deletingLastPathComponent()
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

let client = APIClient(config: APIConfig(baseURL: base, token: token))
let importer: TakeoutImporter
do { importer = try TakeoutImporter(api: client, statePath: statePath, concurrency: concurrency, log: { say($0) }) }
catch { fail("cannot open state: \(error)") }

do { _ = try await client.health() } catch { fail("server not reachable: \(error)") }

var total = TakeoutImporter.Stats()
for path in paths {
    let url = URL(fileURLWithPath: path)
    var root = url
    var extracted: URL?
    if url.pathExtension.lowercased() == "zip" {
        let dest = workDir.appendingPathComponent("extract-" + url.deletingPathExtension().lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        say("extracting \(url.lastPathComponent)")
        guard run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path]) == 0 else { fail("could not extract \(url.lastPathComponent)") }
        let expected = zipFileCount(url), got = fileCount(dest)
        guard expected == got else { fail("\(url.lastPathComponent): zip lists \(expected) files but \(got) were extracted") }
        if deleteZips { try? FileManager.default.removeItem(at: url); say("extracted \(got) files, removed \(url.lastPathComponent)") }
        root = dest; extracted = dest
    }
    do {
        let s = try await importer.importFolder(root)
        say("\(url.lastPathComponent): uploaded \(s.uploaded) (\(String(format: "%.2f GB", Double(s.bytes) / 1e9))), already there \(s.existing), skipped as done \(s.alreadyDone), failed \(s.failed), plain tiles \(s.placeholders), late metadata fixed \(s.patched), Live Photos joined \(s.merged), duplicate clips removed \(s.duplicateClips)")
        total.uploaded += s.uploaded; total.existing += s.existing; total.failed += s.failed; total.bytes += s.bytes
        total.patched += s.patched; total.placeholders += s.placeholders; total.alreadyDone += s.alreadyDone; total.merged += s.merged
        total.duplicateClips += s.duplicateClips
        // Keep the extracted copy when something failed so a re-run can pick it up (pass the folder instead of the zip).
        if let extracted {
            if s.failed == 0 { try? FileManager.default.removeItem(at: extracted) } else { say("kept \(extracted.path) for a re-run") }
        }
    } catch let e as TakeoutImporter.CapReached {
        fail("stopped: the server's monthly cap was reached (\(e.message)). Raise CAP_NEW_ASSETS_MONTH and re-run.")
    } catch {
        fail("\(url.lastPathComponent): \(error)")
    }
}
say("done: uploaded \(total.uploaded) (\(String(format: "%.2f GB", Double(total.bytes) / 1e9))), already there \(total.existing), failed \(total.failed), late metadata fixed \(total.patched), Live Photos joined \(total.merged), duplicate clips removed \(total.duplicateClips)")
say("state: \(importer.counts())")
exit(total.failed == 0 ? 0 : 1)
