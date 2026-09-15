import Foundation
import PDFKit
import CoreFoundation
import Darwin

final class LibraryService {
    let store: VelaStore
    init(store: VelaStore) { self.store = store }
    func handle(_ method: String, _ params: JSON) throws -> Any? {
        switch method {
        case "library.list": return try store.list("library",project:checkedProject(params)).filter { params["includeArchived"] as? Bool == true || string($0,"state") != "archived" }
        case "library.get":
            let item = try scopedItem(params)
            return ["item":item,"snapshotHash":try snapshot(item)] as JSON
        case "library.update", "library.remove", "library.restore", "library.refresh":
            return try change(method,params)
        case "library.history":
            let item = try scopedItem(params)
            return try store.list("library_version",project:string(item,"project"),limit:10000).filter { string($0,"sourceId") == string(item,"id") }
        case "library.export":
            let item = try scopedItem(params)
            return ["id":string(item,"id"),"content":"# " + string(item,"title") + "\n\n" + string(item,"content") + "\n","filename":string(item,"id") + ".md","snapshotHash":try snapshot(item),"private":item["private"] ?? true,"writesSource":false] as JSON
        case "library.index", "library.index.status", "library.search":
            return try LibraryIndex(store:store).handle(method,params)
        case "library.add":
            guard Set(params.keys).isSubset(of:["id","title","content","url","path","project","private","folder"]) else { throw VelaError("Unknown library import field") }
            try validatePrivacy(params)
            guard ["content","url","path"].filter({ params[$0] != nil }).count == 1 else { throw VelaError("Select exactly one library source: content, path or URL") }
            if let id = params["id"] as? String, try store.get("library",id) != nil {
                throw VelaError("Library imports are create-only; an existing reference cannot be overwritten")
            }
            var item = params; item["title"] = try requireString(params,"title")
            if let project = try checkedProject(params) { item["project"] = project }
            if let sourceURL = params["url"] as? String {
                guard let url = URL(string:sourceURL), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw VelaError("Library URL must be an explicit HTTP or HTTPS URL without embedded credentials") }
                let downloaded = try FoundationDownload.fetch(url)
                item["content"] = try extractDocument(downloaded.0,extension:url.pathExtension,mime:downloaded.1)
                item["sourceURL"] = url.absoluteString
            } else if let source = params["path"] as? String {
                let path = canonicalProject(source); let url = URL(fileURLWithPath:path)
                item["content"] = try extractDocument(LibraryDocument.read(path),extension:url.pathExtension,mime:"")
                item["sourcePath"] = path; item.removeValue(forKey:"path")
                item["sourceLabeledPrivate"] = privateLibraryPath(source)
            }
            _ = try requireString(item,"content")
            guard string(item,"content").utf8.count <= 2 * 1024 * 1024 else { throw VelaError("Extracted library text exceeds 2 MB") }
            item["private"] = privateLibraryPath(string(item,"sourcePath")) || item["sourceLabeledPrivate"] as? Bool == true || (params["private"] as? Bool ?? true)
            try validateText(item); item["folder"] = try folder(params)
            item["tokens"] = tokenEstimate(string(item,"content")); item["state"] = "active"
            item["id"] = item["id"] ?? UUID().uuidString.lowercased(); item["version"] = 1
            item["sourceCapturedAt"] = isoNow(); item["sourceHash"] = stableHash(string(item,"content"))
            var version = item; version["sourceId"] = item["id"]; version["id"] = string(item,"id") + ".v1"; version["change"] = "import"
            return try store.putBatch([("library_version",version),("library",item)],createOnly:true)[1]
        default: return nil
        }
    }
    private func scopedItem(_ params: JSON) throws -> JSON {
        let item = try LibrarySource.fresh(store:store,id:requireString(params,"id"))
        guard string(item,"project") == (try checkedProject(params) ?? "") else { throw VelaError("Library source was not found in this project") }
        return item
    }
    private func snapshot(_ item: JSON) throws -> String { stableHash(try jsonString(item)) }
    private func validatePrivacy(_ params: JSON) throws {
        if let value = params["private"] {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw VelaError("private must be a boolean") }
        }
    }
    private func folder(_ params: JSON) throws -> String {
        guard params["folder"] == nil || params["folder"] is String else { throw VelaError("Library folder must be text") }
        let value = string(params,"folder")
        guard value.utf8.count <= 300, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0"), !value.split(separator:"/",omittingEmptySubsequences:false).contains(where:{ $0 == "." || $0 == ".." }) else { throw VelaError("Library folder must stay within the collection") }
        return value
    }
    private func validateText(_ item: JSON) throws {
        guard try requireString(item,"title").count <= 300, try requireString(item,"content").utf8.count <= 2 * 1024 * 1024, !string(item,"content").contains("\0") else { throw VelaError("Library title or extracted text exceeds its limit") }
    }
    private func change(_ method: String, _ params: JSON) throws -> JSON {
        let original = try scopedItem(params), id = string(original,"id")
        guard try snapshot(original) == requireString(params,"snapshotHash") else { throw VelaError("Library source changed since review; inspect it before retrying") }
        let common: Set<String> = ["id","project","snapshotHash"]
        guard Set(params.keys).isSubset(of:method == "library.update" ? common.union(["title","content","private","folder"]) : common) else { throw VelaError("Unknown library change field") }
        var updated = original
        if method == "library.restore" {
            guard string(original,"state") == "archived" else { throw VelaError("Library source is not archived") }; updated["state"] = "active"
        } else {
            guard string(original,"state","active") == "active" else { throw VelaError("Restore this library source before editing it") }
            if method == "library.remove" { updated["state"] = "archived"; updated["archivedAt"] = isoNow() }
            if method == "library.update" {
                try validatePrivacy(params)
                for key in ["title","content","private"] where params[key] != nil { updated[key] = params[key] }
                if params["folder"] != nil { updated["folder"] = try folder(params) }
                guard updated["private"] as? Bool != false || (!privateLibraryPath(string(original,"sourcePath")) && original["sourceLabeledPrivate"] as? Bool != true) else { throw VelaError("A private-labeled source cannot be made public") }
            }
            if method == "library.refresh" {
                if let sourceURL = original["sourceURL"] as? String, let url = URL(string:sourceURL), ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil {
                    let data = try FoundationDownload.fetch(url); updated["content"] = try extractDocument(data.0,extension:url.pathExtension,mime:data.1)
                } else if let path = original["sourcePath"] as? String, !path.isEmpty {
                    updated["content"] = try extractDocument(LibraryDocument.read(path),extension:URL(fileURLWithPath:path).pathExtension,mime:"")
                } else { throw VelaError("This source has no refreshable file or URL") }
                updated["sourceCapturedAt"] = isoNow(); updated["sourceHash"] = stableHash(string(updated,"content"))
            }
        }
        try validateText(updated)
        updated["tokens"] = tokenEstimate(string(updated,"content")); updated["version"] = max(1,intValue(original,"version")) + 1
        var version = updated; version["sourceId"] = id; version["id"] = id + ".v" + String(intValue(updated,"version")); version["change"] = method
        return try store.putBatch([("library_version",version),("library",updated)],expecting:[("library",id,try snapshot(original))],expectingAbsent:[("library_version",string(version,"id"))])[1]
    }
    private func extractDocument(_ data: Data, extension ext: String, mime: String) throws -> String {
        let ext = ext.lowercased()
        if ext == "pdf" || mime.contains("pdf") {
            guard let document = PDFDocument(data:data), let text = document.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VelaError("PDF has no extractable text; scanned PDFs require OCR before import") }
            return text
        }
        if ["doc","docx","odt","rtf","wordml"].contains(ext) || mime.contains("wordprocessingml") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-docx-" + UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:temporary) }
            let source = temporary.appendingPathComponent("document." + (ext.isEmpty ? "docx" : ext)); try data.write(to:source,options:.atomic)
            let result = try FoundationCommand.run("/usr/bin/textutil",["-convert","txt","-noload","-nostore","-stdout",source.path],timeout:15)
            guard result.code == 0, !result.output.isEmpty else { throw VelaError("Office document text extraction failed") }
            return result.output
        }
        guard let text = String(data:data,encoding:.utf8), !text.contains("\0") else { throw VelaError("Unsupported document format; use UTF-8 text, HTML, PDF or DOCX") }
        if ["html","htm"].contains(ext) || mime.contains("html") {
            return text.replacingOccurrences(of:"(?is)<(?:script|style)[^>]*>.*?</(?:script|style)>",with:"",options:.regularExpression).replacingOccurrences(of:"(?i)</?(?:p|div|br|h[1-6]|li|section|article)[^>]*>",with:"\n",options:.regularExpression).replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression).replacingOccurrences(of:"&nbsp;",with:" ").replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">").trimmingCharacters(in:.whitespacesAndNewlines)
        }
        return text
    }

}

enum LibrarySource {
    static func fresh(store: VelaStore, id: String) throws -> JSON {
        guard let item = try store.get("library",id) else { throw VelaError("Library source is unavailable") }
        let relative = "assets/library/" + id + ".md"
        guard string(item,"assetPath") == store.root.appendingPathComponent(relative).path,
              let markdown = try FoundationFile.readUTF8(root:store.root,path:relative),
              markdown.hasPrefix("<!-- Vela metadata: "), markdown.hasSuffix("\n\n# " + string(item,"title") + "\n\n" + string(item,"content") + "\n") else { throw VelaError("Library asset is missing, unsafe or changed during read") }
        return item
    }
}

enum LibraryDocument {
    static func read(_ path: String) throws -> Data {
        guard path.hasPrefix("/"), !path.contains("\0"), canonicalProject(path) == path else { throw VelaError("Library source path is unsafe") }
        let components = URL(fileURLWithPath:path).pathComponents.dropFirst()
        guard let name = components.last, components.count <= 64 else { throw VelaError("Invalid library source path") }
        var parent = Darwin.open("/",O_RDONLY | O_DIRECTORY | O_CLOEXEC), descriptors = [Int32]()
        guard parent >= 0 else { throw VelaError("Cannot read library source root") }; descriptors.append(parent)
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        for component in components.dropLast() {
            parent = openat(parent,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw VelaError("Library source directory is unsafe") }; descriptors.append(parent)
        }
        let fd = openat(parent,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VelaError("Library source is unavailable or unsafe") }; descriptors.append(fd)
        var before = stat(), after = stat(), linked = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size <= 2_097_152, before.st_size >= 0 else { throw VelaError("Library import requires a regular document up to 2 MB") }
        var data = Data(), buffer = [UInt8](repeating:0,count:8192)
        while true {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw VelaError("Library document read failed") }
            guard data.count + count <= 2_097_152 else { throw VelaError("Library document grew beyond 2 MB") }; data.append(contentsOf:buffer.prefix(count))
        }
        guard fstat(fd,&after) == 0, lstat(path,&linked) == 0, linked.st_dev == before.st_dev, linked.st_ino == before.st_ino, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw VelaError("Library source changed during import") }
        return data
    }
}
