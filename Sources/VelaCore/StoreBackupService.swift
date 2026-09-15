import Foundation
import CryptoKit
import Darwin

/// CLI-owned complete local Store bundles. It deliberately has no renderer, RPC, or MCP
/// registration because destination and restore paths are local filesystem authority.
public final class StoreBackupService {
    private let store: VelaStore
    public init(store: VelaStore) { self.store = store }
    private static let format = "vela.local-store-backup"
    private static let version = 1
    private static let ownerName = ".vela-backup-owned"
    // Bounds make a pathological local asset fail closed rather than allocating an
    // arbitrary Data value. They are backup limits, not a claim that all stores fit.
    private static let maximumAssetBytes = StoreBackupFiles.maximumFileBytes
    private static let maximumAssets = StoreBackupFiles.maximumFiles
    private static let maximumTotalAssetBytes = StoreBackupFiles.maximumTotalBytes

    public func create(destination: URL) throws -> JSON {
        let destination = try Self.newOwnedDirectory(destination, label: "Backup destination")
        let token = UUID().uuidString.lowercased()
        try StoreBackupFiles.writeNew(Data(token.utf8),root:destination,path:Self.ownerName)
        do {
            let snapshot = try store.writeCompleteBackupSnapshot(to:destination)
            var manifest: JSON = ["format":Self.format,"version":Self.version,"database":["path":"vela.sqlite3","sha256":snapshot.databaseSHA256] as JSON,"assets":snapshot.assets,"outputs":snapshot.outputs,"privacy":"plain-local-private-data","credentialsIncluded":false,"runtimeIncluded":false]
            manifest["sha256"] = stableHash(try jsonString(manifest))
            let manifestURL = destination.appendingPathComponent("manifest.json")
            let manifestData = try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.withoutEscapingSlashes])
            guard manifestData.count <= 8 * 1024 * 1024 else { throw VelaError("Backup manifest exceeds the supported bound") }
            try StoreBackupFiles.writeNew(manifestData,root:destination,path:"manifest.json")
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifestURL.path)
            try FileManager.default.removeItem(at:destination.appendingPathComponent(Self.ownerName))
            return ["destination":destination.path,"sha256":manifest["sha256"]!,"assets":snapshot.assets.count,"privateDataIncluded":true,"encrypted":false,"complete":true]
        } catch {
            Self.cleanupOwned(destination, token: token)
            throw error
        }
    }

    /// Does not open the caller's configured Store. This makes CLI restore safe to
    /// invoke against a new target without migrating or otherwise touching $VELA_HOME.
    public static func restore(bundle: URL, target: URL) throws -> JSON {
        // Do not standardize before canonicalizing.  Foundation may rewrite a
        // real `/private/tmp` parent to the `/tmp` alias only after that parent
        // exists; `canonicalProject` then resolves it back to `/private/tmp`,
        // making an otherwise safe path fail its own identity guard.
        let final = try canonicalInputURL(target, label: "Restore target")
        let parent = try realExistingDirectory(final.deletingLastPathComponent(), label: "Restore target parent")
        guard final.path.hasPrefix("/"), canonicalProject(final.path) == final.path, !FileManager.default.fileExists(atPath:final.path) else { throw VelaError("Restore target must be new") }
        let parentFD=Darwin.open(parent.path,O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw VelaError("Cannot open restore parent safely") }
        defer { Darwin.close(parentFD) }
        let staging = parent.appendingPathComponent(".vela-restore-staging-" + UUID().uuidString.lowercased())
        let token=UUID().uuidString.lowercased()
        do {
            var result = try restoreInto(bundle:bundle,target:staging,assetRoot:final,token:token)
            try publish(staging:staging, final:final, parent:parent, descriptor:parentFD)
            result["target"]=final.path; result["publishedAtomically"]=true
            // Publication already succeeded. An incidental marker-cleanup error
            // cannot truthfully turn that into a failed or partial data restore.
            do { try FileManager.default.removeItem(at:final.appendingPathComponent(Self.ownerName)); result["ownershipMarkerRemoved"]=true }
            catch { result["ownershipMarkerRemoved"]=false; result["cleanupWarning"]="Store restored; temporary ownership marker could not be removed" }
            return result
        } catch { cleanupOwned(staging,token:token); throw error }
    }

    private static func restoreInto(bundle: URL, target: URL, assetRoot: URL, token: String) throws -> JSON {
        let bundle = try realExistingDirectory(bundle, label: "Backup bundle")
        let deadline=Date().addingTimeInterval(60)
        let raw = try StoreBackupFiles.read(root:bundle,path:"manifest.json",limit:8 * 1024 * 1024,deadline:deadline)
        guard let manifest = try JSONSerialization.jsonObject(with:raw) as? JSON else { throw VelaError("Backup manifest is invalid") }
        try validate(manifest,bundle:bundle,deadline:deadline)
        let target = try newOwnedDirectory(target, label: "Restore target")
        try StoreBackupFiles.writeNew(Data(token.utf8),root:target,path:Self.ownerName)
        do {
            let database = manifest["database"] as! JSON
            try verifiedCopy(root:bundle,path:"vela.sqlite3",destination:target,expected:string(database,"sha256"),limit:StoreBackupFiles.maximumDatabaseBytes,deadline:deadline)
            for row in (manifest["assets"] as! [JSON]) + (manifest["outputs"] as! [JSON]) {
                try verifiedCopy(root:bundle,path:string(row,"path"),destination:target,expected:string(row,"sha256"),limit:Self.maximumAssetBytes,deadline:deadline)
            }
            let restoredStore = try VelaStore(root:target)
            try restoredStore.rebindRestoredBackupAssets(manifest["assets"] as! [JSON], assetRoot:assetRoot)
            let restored = try restoredStore.revokeRestoredRuntimeEligibility()
            return ["target":target.path,"sha256":string(manifest,"sha256"),"restored":true,"runtimeRecovery":restored]
        } catch {
            cleanupOwned(target, token: token)
            throw error
        }
    }

    /// Source-compatible Core convenience wrapper; CLI uses the static form above
    /// so restore never opens its default Store.
    public func restore(bundle: URL, target: URL) throws -> JSON {
        try Self.restore(bundle: bundle, target: target)
    }

    private static func validate(_ manifest: JSON,bundle:URL,deadline:Date) throws {
        guard Set(manifest.keys) == ["format","version","database","assets","outputs","privacy","credentialsIncluded","runtimeIncluded","sha256"], string(manifest,"format") == Self.format, intValue(manifest,"version") == Self.version, string(manifest,"privacy") == "plain-local-private-data", manifest["credentialsIncluded"] as? Bool == false, manifest["runtimeIncluded"] as? Bool == false, let database=manifest["database"] as? JSON, let rows=manifest["assets"] as? [JSON], let outputs=manifest["outputs"] as? [JSON], rows.count + outputs.count <= Self.maximumAssets else { throw VelaError("Unsupported backup manifest") }
        var payload=manifest; payload.removeValue(forKey:"sha256"); guard string(manifest,"sha256") == stableHash(try jsonString(payload)) else { throw VelaError("Backup manifest checksum mismatch") }
        guard Set(database.keys) == ["path","sha256"], string(database,"path") == "vela.sqlite3", try StoreBackupFiles.digest(root:bundle,path:"vela.sqlite3",limit:StoreBackupFiles.maximumDatabaseBytes,deadline:deadline).sha256 == string(database,"sha256") else { throw VelaError("Backup database checksum mismatch") }
        var identities:Set<String>=[]; var total = 0
        for row in rows {
            guard Set(row.keys) == ["path","sha256","bytes","kind","id"], let bytes=row["bytes"] as? NSNumber, bytes.intValue >= 0, bytes.intValue <= Self.maximumAssetBytes else { throw VelaError("Backup asset manifest is invalid") }
            total += bytes.intValue; guard total <= Self.maximumTotalAssetBytes else { throw VelaError("Backup assets exceed the bundle limit") }
            let kind=string(row,"kind"), id=string(row,"id"), path=string(row,"path")
            guard ["memory","workflow","guideline","library","checkpoint"].contains(kind), id.range(of:"^[A-Za-z0-9_.-]{1,150}$",options:.regularExpression) != nil, path == "assets/\(kind)/\(id).md", identities.insert(kind+":"+id).inserted else { throw VelaError("Backup asset path is unsafe") }
            let actual = try StoreBackupFiles.digest(root:bundle,path:path,limit:Self.maximumAssetBytes,deadline:deadline)
            guard actual.bytes == bytes.intValue, actual.sha256 == string(row,"sha256") else { throw VelaError("Backup asset checksum mismatch") }
        }
        var outputPaths = Set<String>()
        for row in outputs {
            guard Set(row.keys) == ["path","sha256","bytes"], let bytes=row["bytes"] as? NSNumber, bytes.intValue >= 0, bytes.intValue <= Self.maximumAssetBytes else { throw VelaError("Backup output manifest is invalid") }
            total += bytes.intValue; guard total <= Self.maximumTotalAssetBytes else { throw VelaError("Backup assets and outputs exceed the bundle limit") }
            let path=string(row,"path")
            guard path.hasPrefix("output/"), path.count > "output/".count, !path.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), outputPaths.insert(path).inserted else { throw VelaError("Backup output path is unsafe") }
            let actual = try StoreBackupFiles.digest(root:bundle,path:path,limit:Self.maximumAssetBytes,deadline:deadline)
            guard actual.bytes == bytes.intValue, actual.sha256 == string(row,"sha256") else { throw VelaError("Backup output checksum mismatch") }
        }
    }

    private static func newOwnedDirectory(_ raw: URL, label: String) throws -> URL {
        let manager=FileManager.default, value=try canonicalInputURL(raw,label:label)
        let parent=try canonicalInputURL(value.deletingLastPathComponent(),label:label + " parent")
        guard value.path.hasPrefix("/"), canonicalProject(value.path) == value.path, canonicalProject(parent.path) == parent.path, manager.fileExists(atPath:parent.path), !manager.fileExists(atPath:value.path), (try? parent.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory) == true, (try? parent.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw VelaError("\(label) must be a new child of a real existing directory") }
        try manager.createDirectory(at:value,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return value
    }
    private static func realExistingDirectory(_ raw: URL, label: String) throws -> URL {
        let value=try canonicalInputURL(raw,label:label)
        guard value.path.hasPrefix("/"), canonicalProject(value.path) == value.path, (try? value.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory) == true, (try? value.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw VelaError("\(label) must be a real directory") }
        return value
    }
    /// Preserve the caller spelling while rejecting user-controlled symlink
    /// ancestors.  `canonicalProject` resolves an existing prefix and appends
    /// a non-existent suffix; equality therefore accepts real canonical paths
    /// such as `/private/tmp/new-child`, but rejects `/tmp` and other aliases.
    private static func canonicalInputURL(_ raw: URL, label: String) throws -> URL {
        let supplied=raw.path
        guard raw.isFileURL, supplied.hasPrefix("/"), !supplied.contains("\0"),
              !supplied.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0 == "." || $0 == ".." }),
              canonicalProject(supplied) == supplied else { throw VelaError("\(label) must use a canonical path without symlink ancestors") }
        return URL(fileURLWithPath:supplied)
    }
    private static func verifiedCopy(root:URL,path:String,destination:URL,expected:String,limit:Int,deadline:Date) throws {
        let copied = try StoreBackupFiles.copy(root:root,path:path,destination:destination,limit:limit,deadline:deadline)
        guard copied.sha256 == expected,
              try StoreBackupFiles.digest(root:root,path:path,limit:limit,deadline:deadline).sha256 == expected,
              try StoreBackupFiles.digest(root:destination,path:path,limit:limit,deadline:deadline).sha256 == expected else { throw VelaError("Backup file changed during restore copy") }
    }
    private static func publish(staging: URL, final: URL, parent: URL, descriptor fd:Int32) throws {
        var opened=stat(), linked=stat()
        guard fstat(fd,&opened) == 0, lstat(parent.path,&linked) == 0, linked.st_mode & S_IFMT == S_IFDIR, canonicalProject(parent.path) == parent.path, opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else { throw VelaError("Restore parent changed before publish") }
        let source=staging.lastPathComponent, destination=final.lastPathComponent
        guard renameatx_np(fd,source,fd,destination,UInt32(RENAME_EXCL)) == 0 else { throw VelaError("Restore publish refused existing or unsafe target: errno \(errno)") }
    }
    private static func cleanupOwned(_ url: URL, token: String) {
        guard let data=try? StoreBackupFiles.read(root:url,path:Self.ownerName,limit:128,deadline:Date().addingTimeInterval(2)), String(data:data,encoding:.utf8) == token, canonicalProject(url.path) == url.path else { return }
        try? FileManager.default.removeItem(at:url)
    }
}
