import Foundation
import CryptoKit
import Darwin

/// Binary backup I/O anchored at an explicitly selected, canonical directory.
/// Like FoundationFile, descendant descriptors stay open until identity checks
/// finish. Opening unrelated ancestors (for example Desktop) would require a
/// separate macOS directory permission that access to the selected child lacks.
enum StoreBackupFiles {
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumDatabaseBytes = 2 * 1024 * 1024 * 1024
    static let maximumTotalBytes = 2 * 1024 * 1024 * 1024
    static let maximumFiles = 50_000

    struct Result { let sha256: String; let bytes: Int }

    static func digest(root: URL, path: String, limit: Int, deadline: Date) throws -> Result {
        try withFile(root:root,path:path,writing:false) { descriptor in
            try transfer(descriptor, to:nil, limit:limit, deadline:deadline)
        }
    }

    static func copy(root: URL, path: String, destination: URL, limit: Int, deadline: Date) throws -> Result {
        try withFile(root:root,path:path,writing:false) { input in
            var info=stat()
            guard limit >= 0, fstat(input,&info) == 0, info.st_size >= 0, info.st_size <= limit else { throw VelaError("Backup file exceeds the supported bound") }
            return try withFile(root:destination,path:path,writing:true) { output in
                try transfer(input,to:output,limit:limit,deadline:deadline)
            }
        }
    }

    static func read(root: URL, path: String, limit: Int, deadline: Date) throws -> Data {
        try withFile(root:root,path:path,writing:false) { descriptor in
            var before=stat()
            guard limit >= 0, fstat(descriptor,&before) == 0, before.st_size >= 0, before.st_size <= limit else { throw VelaError("Backup document exceeds the supported bound") }
            let input=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
            var result=Data()
            while true {
                guard Date() <= deadline else { throw VelaError("Backup document read exceeded its deadline") }
                let chunk=try input.read(upToCount:64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                guard chunk.count <= limit-result.count else { throw VelaError("Backup document grew beyond its bound") }
                result.append(chunk)
            }
            var after=stat()
            guard fstat(descriptor,&after) == 0, before.st_size == after.st_size, result.count == Int(after.st_size),
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw VelaError("Backup document changed during read") }
            return result
        }
    }

    static func writeNew(_ data: Data, root: URL, path: String) throws {
        try withFile(root:root,path:path,writing:true) { descriptor in
            try FileHandle(fileDescriptor:descriptor,closeOnDealloc:false).write(contentsOf:data)
        }
    }

    private static func transfer(_ descriptor: Int32, to output: Int32?, limit: Int, deadline: Date) throws -> Result {
        var before = stat()
        guard limit >= 0, fstat(descriptor,&before) == 0, before.st_size >= 0,
              before.st_size <= limit else { throw VelaError("Backup file exceeds the supported bound") }
        let input = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        let sink = output.map { FileHandle(fileDescriptor:$0,closeOnDealloc:false) }
        var hash = SHA256(), total = 0
        while true {
            guard Date() <= deadline else { throw VelaError("Complete backup file I/O exceeded its deadline") }
            let chunk = try input.read(upToCount:64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= limit - total else { throw VelaError("Backup file grew beyond the supported bound") }
            total += chunk.count
            hash.update(data:chunk)
            try sink?.write(contentsOf:chunk)
        }
        var after = stat()
        guard fstat(descriptor,&after) == 0, after.st_nlink == 1,
              before.st_size == after.st_size, total == Int(after.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw VelaError("Backup file changed during read") }
        return Result(sha256:hash.finalize().map { String(format:"%02x",$0) }.joined(),bytes:total)
    }

    private static func withFile<T>(root: URL, path: String, writing: Bool, _ body: (Int32) throws -> T) throws -> T {
        let parts = path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard root.path.hasPrefix("/"), canonicalProject(root.path) == root.path,
              !path.contains("\0"), parts.count <= 64,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), let name=parts.last else { throw VelaError("Backup path is unsafe") }
        let rootFD = Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw VelaError("Backup directory is unavailable or unsafe") }
        var descriptors = [rootFD], anchors: [(Int32,String,Int32)] = []
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        var parent = rootFD
        for part in parts.dropLast() {
            var child = openat(parent,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT, writing {
                guard mkdirat(parent,part,0o700) == 0 || errno == EEXIST else { throw VelaError("Cannot create backup directory safely") }
                child = openat(parent,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { throw VelaError("Backup path contains an unsafe directory") }
            anchors.append((parent,part,child)); descriptors.append(child); parent=child
        }
        let flags = (writing ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY) | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let leaf = openat(parent,name,flags,0o600)
        guard leaf >= 0 else { throw VelaError("Backup file is unavailable, already exists, or is unsafe") }
        descriptors.append(leaf)
        var opened = stat(), linked = stat()
        guard fstat(leaf,&opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1 else { throw VelaError("Backup file must be a regular file with one link") }
        let result = try body(leaf)
        guard fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0,
              linked.st_mode & S_IFMT == S_IFREG, linked.st_nlink == 1,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else { throw VelaError("Backup file identity changed") }
        guard fstat(rootFD,&opened) == 0, lstat(root.path,&linked) == 0,
              linked.st_mode & S_IFMT == S_IFDIR, canonicalProject(root.path) == root.path,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else { throw VelaError("Backup directory identity changed") }
        for (directory,component,child) in anchors {
            guard fstat(child,&opened) == 0, fstatat(directory,component,&linked,AT_SYMLINK_NOFOLLOW) == 0,
                  linked.st_mode & S_IFMT == S_IFDIR, opened.st_dev == linked.st_dev,
                  opened.st_ino == linked.st_ino else { throw VelaError("Backup ancestor identity changed") }
        }
        return result
    }
}
