import Foundation
import CryptoKit
import Darwin

/// Pins the native entrypoint bytes only, not its dynamic libraries or helpers.
/// Interpreted wrappers need a separately designed dependency snapshot contract.
final class ReplayExecutableSnapshot {
    let directory: URL
    let executable: String
    let sha256: String
    static let maximumBytes = 536_870_912
    static func native(_ data: Data) -> Bool {
        let magic = Array(data.prefix(4))
        return [[0xfe,0xed,0xfa,0xce],[0xce,0xfa,0xed,0xfe],[0xfe,0xed,0xfa,0xcf],[0xcf,0xfa,0xed,0xfe],
                [0xca,0xfe,0xba,0xbe],[0xbe,0xba,0xfe,0xca],[0xca,0xfe,0xba,0xbf],[0xbf,0xba,0xfe,0xca]].contains(magic)
    }
    static func read(_ path: String, write: ((Data) throws -> Void)? = nil) throws -> String {
        let descriptor = open(path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VelaError("Replay executable is unavailable or linked") }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximumBytes else { throw VelaError("Replay requires a bounded regular native executable") }
        var hash = SHA256(), count = 0
        while let data = try handle.read(upToCount:1_048_576), !data.isEmpty {
            if count == 0, !native(data) { throw VelaError("Replay native_snapshot requires a standalone macOS Mach-O executable; script and Node wrappers are unsupported") }
            count += data.count; guard count <= maximumBytes else { throw VelaError("Replay executable exceeds 512 MiB") }
            hash.update(data:data); try write?(data)
        }
        guard count > 0 else { throw VelaError("Replay executable is empty") }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    init(path: String, expectedHash: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-replay-executable-" + UUID().uuidString,isDirectory:true)
        executable = directory.appendingPathComponent("provider").path
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            let descriptor = open(executable,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o500)
            guard descriptor >= 0 else { throw VelaError("Could not create private replay executable snapshot") }
            let output = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            defer { try? output.close() }
            sha256 = try Self.read(path) { try output.write(contentsOf:$0) }
            guard sha256 == expectedHash else { throw VelaError("Replay executable changed since approval; copied bytes were rejected") }
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at:directory)
            throw error
        }
    }
    func remove() { try? FileManager.default.removeItem(at:directory) }
    deinit { remove() }
}
