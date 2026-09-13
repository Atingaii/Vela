import Foundation
import CoreFoundation
import CoreServices
import CryptoKit
import Darwin

enum WorkflowFileWatch {
    static let defaultExcluded = Set([".git",".vela",".build","node_modules",".DS_Store"])
    static func validate(_ input: JSON) throws -> JSON {
        guard Set(input.keys).isSubset(of:["source","paths","recursive","ignore","debounceSeconds","minItems"]), string(input,"source") == "files",
              let paths = input["paths"] as? [String], !paths.isEmpty, paths.count <= 16, Set(paths).count == paths.count,
              input["recursive"] == nil || (input["recursive"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true,
              input["ignore"] == nil || input["ignore"] is [String] else { throw VelaError("File watch requires 1–16 relative paths and a boolean recursive policy") }
        for path in paths {
            guard validPath(path), !excluded(path,ignore:[]) else { throw VelaError("File watch path is private, excluded or unsafe") }
            guard !paths.contains(where:{ $0 != path && (path == "." || $0.hasPrefix(path + "/")) }) else { throw VelaError("File watch paths must not overlap; select explicit non-overlapping roots") }
        }
        let ignore = input["ignore"] as? [String] ?? []
        guard ignore.count <= 32, ignore.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator:"/").contains("..") && $0.utf8.count <= 160 }) else { throw VelaError("Invalid file watch ignore patterns") }
        return ["source":"files","paths":paths.sorted(),"recursive":input["recursive"] as? Bool ?? true,"ignore":ignore,
                "debounceSeconds":try WorkflowContext.integer(input["debounceSeconds"],default:5,range:0...300,name:"file watch debounce"),
                "minItems":try WorkflowContext.integer(input["minItems"],default:1,range:1...100,name:"file watch minimum items")]
    }
    static func validPath(_ path: String) -> Bool {
        path == "." || (!path.isEmpty && !path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("\0") && path.utf8.count <= 1024 && path.split(separator:"/",omittingEmptySubsequences:false).count <= 32 && path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
    }
    static func glob(_ path: String, _ pattern: String, anchored: Bool = false) -> Bool {
        // Dynamic programming avoids regex backtracking on attacker-controlled
        // filenames. Literal / separates directories; only ** crosses it.
        let characters = Array(pattern), value = Array(path); var index = 0, tokens: [String] = []
        if !anchored && !pattern.contains("/") { tokens.append("**/") }
        while index < characters.count {
            if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                if index + 2 < characters.count, characters[index + 2] == "/" { tokens.append("**/"); index += 3 }
                else { tokens.append("**"); index += 2 }
            } else { tokens.append(String(characters[index])); index += 1 }
        }
        var previous = [Bool](repeating:false,count:value.count + 1); previous[0] = true
        for token in tokens {
            var row = [Bool](repeating:false,count:value.count + 1), reachable = false
            for column in 0...value.count {
                switch token {
                case "**/":
                    row[column] = previous[column] || (column > 0 && value[column - 1] == "/" && reachable)
                    reachable = reachable || previous[column]
                case "**": row[column] = previous[column] || (column > 0 && row[column - 1])
                case "*": row[column] = previous[column] || (column > 0 && value[column - 1] != "/" && row[column - 1])
                case "?": row[column] = column > 0 && value[column - 1] != "/" && previous[column - 1]
                default: row[column] = column > 0 && String(value[column - 1]) == token && previous[column - 1]
                }
            }
            previous = row
        }
        return previous[value.count] || (pattern.hasSuffix("/**") && glob(path,String(pattern.dropLast(3)),anchored:true))
    }
    static func excluded(_ path: String, ignore: [String]) -> Bool {
        privateLibraryPath(path) || path.split(separator:"/").contains { defaultExcluded.contains(String($0)) } || ignore.contains { glob(path,$0) }
    }
    static func interested(_ relative: String, policy: JSON) -> Bool {
        if relative.isEmpty { return true }
        guard !excluded(relative,ignore:policy["ignore"] as? [String] ?? []) else { return false }
        return (policy["paths"] as? [String] ?? []).contains { path in
            if path == "." { return policy["recursive"] as? Bool == true || relative.split(separator:"/").count <= 1 }
            if path == relative || path.hasPrefix(relative + "/") { return true }
            guard relative.hasPrefix(path + "/") else { return false }
            return policy["recursive"] as? Bool == true || relative.dropFirst(path.count + 1).split(separator:"/").count <= 1
        }
    }
    static func scan(project: String, policy: JSON) throws -> JSON {
        let root = Darwin.open(project,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw VelaError("File watch project is unavailable") }
        defer { Darwin.close(root) }
        var rootInfo = stat(); guard fstat(root,&rootInfo) == 0 else { throw VelaError("Cannot inspect file watch root") }
        let deadline = Date().addingTimeInterval(5), ignore = policy["ignore"] as? [String] ?? [], recursive = policy["recursive"] as? Bool == true
        var entries: JSON = [:], visited = Set<String>(), files = 0, directories = 0, totalBytes = 0, excludedCount = 0
        func checkpoint() throws {
            guard !VelaRuntimeShutdown.isRequested, Date() < deadline else { throw VelaError("File watch scan stopped or reached its 5-second bound; watermark was not advanced") }
        }
        func record(_ relative: String, info: stat, hash: String, bytes: Int, type: String) throws {
            let value: JSON = ["id":relative,"path":relative,"kind":type,"contentHash":hash,"bytes":bytes,"fileIdentity":String(info.st_dev) + ":" + String(info.st_ino)]
            let key = try WorkflowWatch.key(value,path:"id")
            entries[stableHash(key)] = ["key":key,"value":value,"hash":stableHash(try jsonString(value.filter { $0.key != "fileIdentity" }))]
            guard entries.count <= 2000 else { throw VelaError("File watch exceeds 2000 entries; watermark was not advanced") }
        }
        func visit(_ parent: Int32, name: String, relative: String, depth: Int, descend: Bool) throws {
            try checkpoint()
            if WorkflowFileWatch.excluded(relative,ignore:ignore) { excludedCount += 1; return }
            guard depth <= 32 else { throw VelaError("File watch depth exceeds 32") }
            if visited.contains(relative) { return }; visited.insert(relative)
            var before = stat()
            if fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return }; throw VelaError("File watch item is unreadable") }
            let type = before.st_mode & S_IFMT
            if type == S_IFREG {
                guard before.st_nlink == 1, before.st_size <= 2_097_152, before.st_size >= 0, totalBytes + Int(before.st_size) <= 33_554_432 else { throw VelaError("File watch requires unique regular files up to 2 MB and 32 MB per scan") }
                guard let data = try FoundationFile.readData(parent:parent,name:name) else { throw VelaError("File watch item disappeared during capture") }
                var after = stat()
                guard fstatat(parent,name,&after,AT_SYMLINK_NOFOLLOW) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw VelaError("File watch item changed during capture") }
                totalBytes += data.count; files += 1
                try record(relative,info:after,hash:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),bytes:data.count,type:"file")
            } else if type == S_IFDIR {
                directories += 1; guard directories <= 512 else { throw VelaError("File watch exceeds 512 directories") }
                if relative != "." { try record(relative,info:before,hash:"directory",bytes:0,type:"directory") }
                guard descend else { return }
                let directory = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw VelaError("File watch directory is unsafe") }; defer { Darwin.close(directory) }
                var opened = stat()
                guard fstat(directory,&opened) == 0, before.st_dev == opened.st_dev, before.st_ino == opened.st_ino else { throw VelaError("File watch directory was replaced") }
                guard let stream = fdopendir(dup(directory)) else { throw VelaError("Cannot enumerate file watch directory") }
                defer { closedir(stream) }
                var names: [String] = []
                errno = 0
                while let entry = readdir(stream) {
                    let child = withUnsafePointer(to:&entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) } }
                    if child != "." && child != ".." { names.append(child) }
                    guard names.count <= 10_000 else { throw VelaError("File watch directory has too many entries") }
                    errno = 0
                }
                guard errno == 0 else { throw VelaError("File watch directory enumeration failed") }
                for child in names.sorted() {
                    let path = relative == "." ? child : relative + "/" + child
                    try visit(directory,name:child,relative:path,depth:depth+1,descend:recursive)
                }
                var after = stat(), linked = stat()
                guard fstat(directory,&after) == 0, fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0,
                      opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino, opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw VelaError("File watch directory changed during capture") }
            } else { throw VelaError("File watch refuses symlinks, FIFOs and other non-regular targets") }
        }
        for path in policy["paths"] as? [String] ?? [] {
            if path == "." { try visit(root,name:".",relative:".",depth:0,descend:true); continue }
            let components = path.split(separator:"/").map(String.init)
            var parent = root, opened: [Int32] = [], anchors: [(Int32,String,Int32)] = [], missing = false
            defer { opened.reversed().forEach { Darwin.close($0) } }
            for name in components.dropLast() {
                let next = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 { if errno == ENOENT { missing = true; break }; throw VelaError("File watch path contains an unsafe directory") }
                anchors.append((parent,name,next)); opened.append(next); parent = next
            }
            if !missing { try visit(parent,name:components.last!,relative:path,depth:0,descend:true) }
            for (parent,name,child) in anchors {
                var old = stat(), linked = stat()
                guard fstat(child,&old) == 0, fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0, old.st_dev == linked.st_dev, old.st_ino == linked.st_ino, linked.st_mode & S_IFMT == S_IFDIR else { throw VelaError("File watch directory path changed during capture") }
            }
        }
        var linkedRoot = stat()
        guard lstat(project,&linkedRoot) == 0, rootInfo.st_dev == linkedRoot.st_dev, rootInfo.st_ino == linkedRoot.st_ino else { throw VelaError("File watch project changed during capture") }
        guard try jsonString(entries).utf8.count <= 128_000 else { throw VelaError("File watch snapshot exceeds 128 KB") }
        return ["entries":entries,"snapshotHash":stableHash(try jsonString(entries)),"filesRead":files,"directoriesRead":directories,"bytesRead":totalBytes,"excludedCount":excludedCount,"capturedAt":isoNow(),"source":"files","externalRequests":0,"history":"observed net state; intermediate edits are not reconstructed"]
    }
    static func changes(_ pending: JSON) -> [JSON] {
        var result: [JSON] = [], consumed = Set<String>()
        let keys = pending.keys.sorted { left,right in
            let a = string(pending[left] as? JSON ?? [:],"type") == "removed", b = string(pending[right] as? JSON ?? [:],"type") == "removed"
            return a == b ? left < right : a
        }
        for key in keys {
            guard !consumed.contains(key), var change = pending[key] as? JSON else { continue }
            if string(change,"type") == "removed", let before = change["before"] as? JSON, let old = before["value"] as? JSON,
               let match = keys.first(where:{ candidate in
                   guard !consumed.contains(candidate), let add = pending[candidate] as? JSON, string(add,"type") == "added", let after = add["after"] as? JSON, let new = after["value"] as? JSON else { return false }
                   return string(old,"fileIdentity") == string(new,"fileIdentity") && string(old,"contentHash") == string(new,"contentHash")
               }), let addition = pending[match] as? JSON {
                change["type"] = "renamed"; change["after"] = addition["after"]; change["previousKey"] = change["key"]; change["key"] = addition["key"]
                consumed.insert(match)
            }
            consumed.insert(key); result.append(change)
        }
        return result
    }
}

/// One system stream per scheduler instance, no per-file timers or open handles.
final class WorkflowFileEvents {
    let instance = UUID().uuidString.lowercased()
    private let lock = NSRecursiveLock(), queue = DispatchQueue(label:"ai.vela.workflow.files",qos:.utility)
    private var stream: FSEventStreamRef?, roots: [String] = [], plans: [JSON] = [], signals: [String:JSON] = [:]
    deinit { stop() }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    func configure(_ workflows: [JSON]) throws {
        lock.lock(); defer { lock.unlock() }
        plans = workflows.filter { $0["enabled"] as? Bool == true && string($0,"trigger") == "watch" && string($0["watch"] as? JSON ?? [:],"source") == "files" }
        let identities = Set(plans.map { string($0,"id") }); signals = signals.filter { identities.contains($0.key) }
        let paths = Array(Set(plans.map { string($0,"project") })).sorted()
        if paths == roots, (paths.isEmpty || stream != nil) { return }
        stop(); roots = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        stream = FSEventStreamCreate(nil,{ _, info, count, rawPaths, flags, ids in
            guard let info else { return }
            let observer = Unmanaged<WorkflowFileEvents>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths,to:NSArray.self) as? [String] ?? []
            for (index,path) in paths.enumerated() where index < count { observer.receive(path:path,flags:flags[index],eventID:ids[index]) }
        },&context,paths as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.2,FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { throw VelaError("FSEvents file watch could not be created") }
        FSEventStreamSetDispatchQueue(stream,queue)
        guard FSEventStreamStart(stream) else { stop(); throw VelaError("FSEvents file watch is unavailable; no timer-only substitute was started") }
        // Restarting this same observer must also reconcile its gap. A process
        // instance token alone cannot detect stop/start within one process.
        for id in identities {
            let previous = signals[id]; var signal = previous ?? [:]
            signal["serial"] = intValue(signal,"serial") + 1
            signal["eventID"] = signal["eventID"] ?? "unavailable"
            signal["historyIncomplete"] = previous != nil
            signals[id] = signal
        }
    }
    func receive(path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId) {
        lock.lock(); defer { lock.unlock() }
        let lost = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
        for plan in plans {
            let root = string(plan,"project")
            guard path == root || path.hasPrefix(root + "/") else { continue }
            let relative = path == root ? "" : String(path.dropFirst(root.count + 1)), policy = plan["watch"] as? JSON ?? [:]
            guard lost || WorkflowFileWatch.interested(relative,policy:policy) else { continue }
            let id = string(plan,"id"); var signal = signals[id] ?? [:]
            signal["serial"] = intValue(signal,"serial") + 1; signal["eventID"] = String(eventID)
            signal["historyIncomplete"] = signal["historyIncomplete"] as? Bool == true || lost; signals[id] = signal
        }
    }
    func signal(_ id: String) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        guard stream != nil else { throw VelaError("FSEvents observer is unavailable") }
        return (signals[id] ?? ["serial":0,"eventID":"unavailable","historyIncomplete":false]).merging(["instance":instance]) { _,new in new }
    }
}
