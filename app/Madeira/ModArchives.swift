// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Unpacks a mod that came as .7z or .rar (Nexus Mods hands out many of both)
//  into a folder, which Game details › Mods then installs like an unpacked mod.
//
//  .7z is read here: the archive's headers (also LZMA-packed ones), the coder
//  graph of each folder, and the coders 7-Zip uses by default or at -mx9:
//  Copy, LZMA and LZMA2 (through the system's liblzma, ModArchiveLZMA.h), BCJ
//  and BCJ2 (x86 call/jump filters, here). PPMd, BZip2, Deflate and encrypted
//  archives get an error that names what is missing. Each file's CRC32 is
//  checked.
//
//  .rar goes through the system's libarchive (loaded at run time; it reads RAR
//  4 and RAR 5). Where it cannot be loaded, the error says to unpack the mod
//  first.
//
//  Foundation only (plus liblzma and dlopen): tests/host/check-mod-archives.py
//  compiles this file with a test harness.
//

import Foundation

enum ModArchiveError: LocalizedError {
    case damaged(String)
    case unsupported(String)
    case password
    case noRar

    var errorDescription: String? {
        switch self {
        case .damaged(let why): return "This archive is damaged or incomplete (\(why))."
        case .unsupported(let what): return "This .7z is packed with \(what), which Madeira can't unpack yet. Unpack it on a computer, or pack it again as .zip or as a normal .7z."
        case .password: return "This archive is protected with a password. Madeira can't unpack it."
        case .noRar: return "This version of iOS can't unpack .rar files for Madeira. Unpack the mod first, then choose its folder."
        }
    }
}

enum ModArchive {
    enum Kind { case sevenZip, rar }

    /// The archive kind from the file's first bytes, nil for anything else (zip, folders).
    static func kind(of url: URL) -> Kind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 7)) ?? Data())
        if head.count >= 6, head[0..<6] == [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] { return .sevenZip }
        if head.count >= 6, head[0..<6] == [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07] { return .rar }
        return nil
    }

    /// Unpacks `url` into `folder` (made if missing). Returns the files written, relative.
    @discardableResult
    static func unpack(_ url: URL, to folder: URL, progress: ((Double) -> Void)? = nil) throws -> [String] {
        switch kind(of: url) {
        case .sevenZip: return try SevenZipArchive(url: url).extract(to: folder, progress: progress)
        case .rar: return try LibArchive.extract(url, to: folder)
        case nil: throw ModArchiveError.damaged("not a .7z or .rar")
        }
    }

    /// A path inside the archive as a safe relative path, nil when it would leave the folder.
    static func safePath(_ name: String) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.contains(":") }) else { return nil }
        return parts.joined(separator: "/")
    }
}

// MARK: CRC32

enum ModCRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
    static func of(_ data: Data) -> UInt32 { data.withUnsafeBytes { update(0, $0) } }
}

// MARK: .7z

struct SevenZipArchive {
    struct Coder {
        var id: [UInt8]
        var inputs: Int
        var outputs: Int
        var props: [UInt8]
    }
    struct Folder {
        var coders: [Coder] = []
        var bindPairs: [(input: Int, output: Int)] = []
        var packed: [Int] = []          // folder input index of each packed stream
        var sizes: [UInt64] = []        // per coder output
        var crc: UInt32?
        var firstPack = 0               // archive pack stream index of packed[0]
        var streams: [(size: UInt64, crc: UInt32?)] = []  // files in this folder, in order

        var mainOutput: Int? {
            let total = coders.reduce(0) { $0 + $1.outputs }
            return (0..<total).first { o in !bindPairs.contains { $0.output == o } }
        }
        var size: UInt64 { mainOutput.map { sizes[$0] } ?? 0 }
    }
    struct Entry {
        var name: String
        var isDirectory: Bool
        var size: UInt64
        var folder: Int?    // nil: empty file or directory
        var crc: UInt32?
    }

    let url: URL
    private(set) var entries: [Entry] = []
    private(set) var folders: [Folder] = []
    private var packStart: UInt64 = 32
    private var packSizes: [UInt64] = []

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = [UInt8](try handle.read(upToCount: 32) ?? Data())
        guard start.count == 32, start[0..<6] == [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] else { throw ModArchiveError.damaged("no .7z signature") }
        func le(_ from: Int, _ n: Int) -> UInt64 { (0..<n).reduce(UInt64(0)) { $0 | UInt64(start[from + $1]) << (8 * UInt64($1)) } }
        let offset = le(12, 8), size = le(20, 8), crc = UInt32(le(28, 4))
        guard size > 0, size < 1 << 30 else { throw ModArchiveError.damaged(size == 0 ? "empty archive" : "header size") }
        try handle.seek(toOffset: 32 + offset)
        let header = try handle.read(upToCount: Int(size)) ?? Data()
        guard header.count == Int(size) else { throw ModArchiveError.damaged("the archive ends early") }
        guard ModCRC32.of(header) == crc else { throw ModArchiveError.damaged("header checksum") }
        var bytes = [UInt8](header)
        // A packed header (the usual case) is unpacked and read again.
        for _ in 0..<4 where bytes.first == 0x17 {
            var reader = Reader(bytes: bytes, at: 1)
            var streams = try Self.readStreamsInfo(&reader)
            guard let folder = streams.folders.first else { throw ModArchiveError.damaged("packed header") }
            packSizes = streams.packSizes
            packStart = 32 + streams.packPos
            streams.folders[0].streams = [(folder.size, folder.crc)]
            folders = streams.folders
            let sink = MemorySink()
            try decode(folder: 0, into: sink)
            if let crc = folder.crc, ModCRC32.of(sink.data) != crc { throw ModArchiveError.damaged("header checksum") }
            bytes = [UInt8](sink.data)
        }
        guard bytes.first == 0x01 else { throw ModArchiveError.damaged("header") }
        var reader = Reader(bytes: bytes, at: 1)
        try readHeader(&reader)
    }

    // MARK: Header

    struct Reader {
        let bytes: [UInt8]
        var at: Int
        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw ModArchiveError.damaged("header ends early") }
            defer { at += 1 }
            return bytes[at]
        }
        mutating func number() throws -> UInt64 {
            let first = try byte()
            var mask: UInt8 = 0x80, value: UInt64 = 0
            for i in 0..<8 {
                if first & mask == 0 {
                    let high = UInt64(first) & (UInt64(mask) - 1)
                    return value | high << (8 * UInt64(i))
                }
                value |= UInt64(try byte()) << (8 * UInt64(i))
                mask >>= 1
            }
            return value
        }
        mutating func int(_ limit: Int = 1 << 24) throws -> Int {
            let n = try number()
            guard n <= UInt64(limit) else { throw ModArchiveError.damaged("header count") }
            return Int(n)
        }
        mutating func uint32() throws -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(try byte()) << (8 * UInt32(i)) }
            return v
        }
        mutating func skip(_ n: UInt64) throws {
            guard n <= UInt64(bytes.count - at) else { throw ModArchiveError.damaged("header ends early") }
            at += Int(n)
        }
        mutating func bits(_ count: Int) throws -> [Bool] {
            var out: [Bool] = [], current: UInt8 = 0
            for i in 0..<count {
                if i % 8 == 0 { current = try byte() }
                out.append(current & (0x80 >> UInt8(i % 8)) != 0)
            }
            return out
        }
        mutating func optionalBits(_ count: Int) throws -> [Bool] {
            try byte() != 0 ? Array(repeating: true, count: count) : bits(count)
        }
        mutating func digests(_ count: Int) throws -> [UInt32?] {
            try optionalBits(count).map { try $0 ? uint32() : nil }
        }
    }

    struct StreamsInfo {
        var packPos: UInt64 = 0
        var packSizes: [UInt64] = []
        var folders: [Folder] = []
    }

    static func readStreamsInfo(_ r: inout Reader) throws -> StreamsInfo {
        var info = StreamsInfo()
        var id = try r.number()
        if id == 0x06 {  // PackInfo
            info.packPos = try r.number()
            let count = try r.int()
            while true {
                let kind = try r.number()
                if kind == 0 { break }
                if kind == 0x09 { info.packSizes = try (0..<count).map { _ in try r.number() } }
                else if kind == 0x0A { _ = try r.digests(count) }
                else { throw ModArchiveError.damaged("pack info") }
            }
            id = try r.number()
        }
        if id == 0x07 {  // UnpackInfo
            guard try r.number() == 0x0B else { throw ModArchiveError.damaged("folders") }
            let count = try r.int()
            guard try r.byte() == 0 else { throw ModArchiveError.unsupported("external folder records") }
            var pack = 0
            for _ in 0..<count {
                var folder = Folder()
                let coders = try r.int(64)
                for _ in 0..<coders {
                    let flags = try r.byte()
                    guard flags & 0x80 == 0 else { throw ModArchiveError.unsupported("alternative coders") }
                    let id = try (0..<Int(flags & 0x0F)).map { _ in try r.byte() }
                    var coder = Coder(id: id, inputs: 1, outputs: 1, props: [])
                    if flags & 0x10 != 0 { coder.inputs = try r.int(32); coder.outputs = try r.int(32) }
                    if flags & 0x20 != 0 { coder.props = try (0..<r.int(1 << 16)).map { _ in try r.byte() } }
                    folder.coders.append(coder)
                }
                let outputs = folder.coders.reduce(0) { $0 + $1.outputs }
                let inputs = folder.coders.reduce(0) { $0 + $1.inputs }
                guard outputs >= 1, inputs >= outputs - 1 else { throw ModArchiveError.damaged("coders") }
                for _ in 0..<(outputs - 1) { folder.bindPairs.append((try r.int(inputs), try r.int(outputs))) }
                let packedCount = inputs - (outputs - 1)
                if packedCount == 1 {
                    guard let free = (0..<inputs).first(where: { i in !folder.bindPairs.contains { $0.input == i } }) else {
                        throw ModArchiveError.damaged("coders")
                    }
                    folder.packed = [free]
                } else {
                    folder.packed = try (0..<packedCount).map { _ in try r.int(inputs) }
                }
                folder.firstPack = pack
                pack += packedCount
                info.folders.append(folder)
            }
            guard try r.number() == 0x0C else { throw ModArchiveError.damaged("unpack sizes") }
            for i in info.folders.indices {
                let outputs = info.folders[i].coders.reduce(0) { $0 + $1.outputs }
                info.folders[i].sizes = try (0..<outputs).map { _ in try r.number() }
            }
            while true {
                let kind = try r.number()
                if kind == 0 { break }
                guard kind == 0x0A else { throw ModArchiveError.damaged("unpack info") }
                for (i, crc) in try r.digests(info.folders.count).enumerated() { info.folders[i].crc = crc }
            }
            id = try r.number()
        }
        // One file per folder unless SubStreamsInfo says otherwise.
        var counts = Array(repeating: 1, count: info.folders.count)
        var sizes: [[UInt64]] = info.folders.map { [$0.size] }
        var crcs: [[UInt32?]] = info.folders.map { [$0.crc] }
        if id == 0x08 {
            id = try r.number()
            if id == 0x0D {
                counts = try info.folders.map { _ in try r.int() }
                id = try r.number()
            }
            for i in info.folders.indices { sizes[i] = []; crcs[i] = Array(repeating: nil, count: counts[i]) }
            let hasSizes = id == 0x09
            for (i, folder) in info.folders.enumerated() where counts[i] > 0 {
                var sum: UInt64 = 0
                for _ in 1..<counts[i] where hasSizes {
                    let size = try r.number()
                    sizes[i].append(size); sum += size
                }
                guard sum <= folder.size else { throw ModArchiveError.damaged("file sizes") }
                sizes[i].append(folder.size - sum)
            }
            if hasSizes { id = try r.number() }
            // Streams whose CRC the folder does not already give.
            var missing: [(Int, Int)] = []
            for (i, folder) in info.folders.enumerated() {
                if counts[i] == 1, let crc = folder.crc { crcs[i] = [crc] } else { for j in 0..<counts[i] { missing.append((i, j)) } }
            }
            while id != 0 {
                if id == 0x0A {
                    for (k, crc) in try r.digests(missing.count).enumerated() { crcs[missing[k].0][missing[k].1] = crc }
                } else {
                    try r.skip(try r.number())
                }
                id = try r.number()
            }
            id = try r.number()
        }
        for i in info.folders.indices {
            info.folders[i].streams = (0..<counts[i]).map { (sizes[i][$0], crcs[i][$0]) }
        }
        guard id == 0 else { throw ModArchiveError.damaged("streams info") }
        return info
    }

    private mutating func readHeader(_ r: inout Reader) throws {
        var id = try r.number()
        if id == 0x02 {  // ArchiveProperties
            while try r.number() != 0 { try r.skip(try r.number()) }
            id = try r.number()
        }
        if id == 0x03 { throw ModArchiveError.unsupported("additional streams") }
        if id == 0x04 {
            let info = try Self.readStreamsInfo(&r)
            folders = info.folders; packSizes = info.packSizes; packStart = 32 + info.packPos
            id = try r.number()
        } else {
            folders = []; packSizes = []
        }
        guard id == 0x05 else {
            guard id == 0 else { throw ModArchiveError.damaged("header") }
            return
        }
        let count = try r.int()
        var emptyStream = Array(repeating: false, count: count)
        var emptyFile: [Bool] = [], anti: [Bool] = []
        var names: [String] = Array(repeating: "", count: count)
        var attributes: [UInt32?] = Array(repeating: nil, count: count)
        while true {
            let kind = try r.number()
            if kind == 0 { break }
            let size = try r.number()
            let end = r.at + Int(min(size, UInt64(r.bytes.count)))
            guard end <= r.bytes.count else { throw ModArchiveError.damaged("file info") }
            switch kind {
            case 0x0E: emptyStream = try r.bits(count)
            case 0x0F: emptyFile = try r.bits(emptyStream.filter { $0 }.count)
            case 0x10: anti = try r.bits(emptyStream.filter { $0 }.count)
            case 0x11:
                guard try r.byte() == 0 else { throw ModArchiveError.unsupported("external names") }
                var units: [UInt16] = [], index = 0
                while index < count && r.at + 1 < end {
                    let unit = UInt16(try r.byte()) | UInt16(try r.byte()) << 8
                    if unit == 0 { names[index] = String(decoding: units, as: UTF16.self); units = []; index += 1 } else { units.append(unit) }
                }
            case 0x15:
                let defined = try r.optionalBits(count)
                guard try r.byte() == 0 else { throw ModArchiveError.unsupported("external attributes") }
                for i in 0..<count where defined[i] { attributes[i] = try r.uint32() }
            default: break
            }
            r.at = end
        }
        var folder = 0, inFolder = 0, empty = 0
        for i in 0..<count {
            if emptyStream[i] {
                let isFile = empty < emptyFile.count && emptyFile[empty]
                let isAnti = empty < anti.count && anti[empty]
                empty += 1
                if isAnti { continue }
                let isDirectory = !isFile || (attributes[i].map { $0 & 0x10 != 0 } ?? false)
                entries.append(Entry(name: names[i], isDirectory: isDirectory, size: 0, folder: nil, crc: nil))
                continue
            }
            while folder < folders.count && inFolder >= folders[folder].streams.count { folder += 1; inFolder = 0 }
            guard folder < folders.count else { throw ModArchiveError.damaged("more files than data") }
            let stream = folders[folder].streams[inFolder]
            entries.append(Entry(name: names[i], isDirectory: false, size: stream.size, folder: folder, crc: stream.crc))
            inFolder += 1
        }
    }

    // MARK: Extract

    /// Writes every file into `folder`; returns the relative paths written.
    func extract(to destination: URL, progress: ((Double) -> Void)? = nil) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var written: [String] = []
        let total = max(1, folders.reduce(UInt64(0)) { $0 + $1.size })
        var done: UInt64 = 0
        for entry in entries where entry.folder == nil {
            guard let path = ModArchive.safePath(entry.name) else { continue }
            let target = destination.appendingPathComponent(path)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = fm.createFile(atPath: target.path, contents: nil)
                written.append(path)
            }
        }
        for index in folders.indices {
            let files = entries.filter { $0.folder == index }
            let sink = try SplitSink(files: files.map { entry in
                (entry.size, ModArchive.safePath(entry.name).map { destination.appendingPathComponent($0) }, entry.crc)
            })
            sink.progress = { bytes in progress?(Double(done + bytes) / Double(total)) }
            try decode(folder: index, into: sink)
            try sink.finish()
            done += folders[index].size
            written += files.compactMap { ModArchive.safePath($0.name) }
        }
        progress?(1)
        return written
    }

    /// Decodes one folder's main output into `sink`.
    func decode(folder index: Int, into sink: ByteSink) throws {
        let folder = folders[index]
        guard let main = folder.mainOutput else { throw ModArchiveError.damaged("coders") }
        var temporary: [URL] = []
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
        try produce(output: main, folder: folder, into: sink, temporary: &temporary)
    }

    private struct Range { var url: URL; var offset: UInt64; var length: UInt64 }

    private func packRange(_ folder: Folder, input: Int) throws -> Range {
        guard let k = folder.packed.firstIndex(of: input) else { throw ModArchiveError.damaged("coders") }
        let pack = folder.firstPack + k
        guard pack < packSizes.count else { throw ModArchiveError.damaged("pack streams") }
        let offset = packStart + packSizes[..<pack].reduce(0, +)
        return Range(url: url, offset: offset, length: packSizes[pack])
    }

    private func produce(output: Int, folder: Folder, into sink: ByteSink, temporary: inout [URL]) throws {
        var outStart = 0, inStart = 0, coderIndex = -1
        for (i, coder) in folder.coders.enumerated() {
            if output < outStart + coder.outputs { coderIndex = i; break }
            outStart += coder.outputs; inStart += coder.inputs
        }
        guard coderIndex >= 0 else { throw ModArchiveError.damaged("coders") }
        let coder = folder.coders[coderIndex]
        var inputs: [Range] = []
        for k in 0..<coder.inputs {
            let input = inStart + k
            if let bound = folder.bindPairs.first(where: { $0.input == input }) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("madeira-7z-\(UUID().uuidString)")
                temporary.append(file)
                let fileSink = try FileSink(file)
                try produce(output: bound.output, folder: folder, into: fileSink, temporary: &temporary)
                try fileSink.close()
                inputs.append(Range(url: file, offset: 0, length: folder.sizes[bound.output]))
            } else {
                inputs.append(try packRange(folder, input: input))
            }
        }
        let size = folder.sizes[output]
        switch coder.id {
        case [0x00]:
            try Self.copy(inputs[0], size: size, into: sink)
        case [0x03, 0x01, 0x01]:
            guard coder.props.count == 5 else { throw ModArchiveError.damaged("LZMA properties") }
            var header = coder.props
            for i in 0..<8 { header.append(UInt8(truncatingIfNeeded: size >> (8 * UInt64(i)))) }
            try Self.lzma(inputs[0], prefix: header, filter: nil, size: size, into: sink)
        case [0x21]:
            guard let p = coder.props.first, p <= 40 else { throw ModArchiveError.damaged("LZMA2 properties") }
            let dict: UInt32 = p == 40 ? 0xFFFF_FFFF : (2 | UInt32(p & 1)) << (UInt32(p) / 2 + 11)
            try Self.lzma(inputs[0], prefix: [], filter: dict, size: size, into: sink)
        case [0x03, 0x03, 0x01, 0x03]:
            var data = try Self.load(inputs[0])
            BCJ.x86Decode(&data)
            try sink.write(Data(data))
        case [0x03, 0x03, 0x01, 0x1B]:
            guard inputs.count == 4 else { throw ModArchiveError.damaged("BCJ2") }
            try sink.write(try BCJ.bcj2Decode(main: Self.load(inputs[0]), call: Self.load(inputs[1]), jump: Self.load(inputs[2]),
                                              rc: Self.load(inputs[3]), size: Int(size)))
        case [0x06, 0xF1, 0x07, 0x01]: throw ModArchiveError.password
        case [0x03, 0x04, 0x01]: throw ModArchiveError.unsupported("PPMd")
        case [0x04, 0x02, 0x02]: throw ModArchiveError.unsupported("BZip2")
        case [0x04, 0x01, 0x08], [0x04, 0x01, 0x09]: throw ModArchiveError.unsupported("Deflate")
        default:
            throw ModArchiveError.unsupported("method " + coder.id.map { String(format: "%02X", $0) }.joined())
        }
    }

    private static func load(_ range: Range) throws -> [UInt8] {
        guard range.length < 1 << 31 else { throw ModArchiveError.unsupported("a filter stream over 2 GB") }
        let handle = try FileHandle(forReadingFrom: range.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.offset)
        let data = try handle.read(upToCount: Int(range.length)) ?? Data()
        guard data.count == Int(range.length) else { throw ModArchiveError.damaged("the archive ends early") }
        return [UInt8](data)
    }

    private static func copy(_ range: Range, size: UInt64, into sink: ByteSink) throws {
        let handle = try FileHandle(forReadingFrom: range.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.offset)
        var left = min(size, range.length)
        while left > 0 {
            let chunk = try handle.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
            guard !chunk.isEmpty else { throw ModArchiveError.damaged("the archive ends early") }
            try sink.write(chunk)
            left -= UInt64(chunk.count)
        }
    }

    /// LZMA (`filter` nil: "alone" stream, `prefix` its 13-byte header) or LZMA2 (`filter` the dictionary size).
    private static func lzma(_ range: Range, prefix: [UInt8], filter dict: UInt32?, size: UInt64, into sink: ByteSink) throws {
        let handle = try FileHandle(forReadingFrom: range.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.offset)
        var stream = madeira_lzma_stream()
        var options = madeira_lzma_options()
        let started: Int32
        if let dict {
            options.dict_size = dict; options.lc = 3; options.lp = 0; options.pb = 2
            started = withUnsafeMutablePointer(to: &options) { opt in
                var filters = [madeira_lzma_filter(id: 0x21, options: UnsafeMutableRawPointer(opt)),
                               madeira_lzma_filter(id: UInt64.max, options: nil)]
                return lzma_raw_decoder(&stream, &filters)
            }
        } else {
            started = lzma_alone_decoder(&stream, UInt64.max)
        }
        guard started == 0 else { throw ModArchiveError.damaged("LZMA setup \(started)") }
        defer { lzma_end(&stream) }
        var left = range.length
        var input = prefix
        var output = [UInt8](repeating: 0, count: 1 << 20)
        var produced: UInt64 = 0
        var inputIndex = 0
        while produced < size {
            if inputIndex >= input.count && left > 0 {
                let chunk = try handle.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
                guard !chunk.isEmpty else { throw ModArchiveError.damaged("the archive ends early") }
                left -= UInt64(chunk.count)
                input = [UInt8](chunk); inputIndex = 0
            }
            let wanted = Int(min(UInt64(output.count), size - produced))
            let (status, used, made): (Int32, Int, Int) = input.withUnsafeBufferPointer { inBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_in = inBuf.baseAddress.map { $0 + inputIndex }
                    stream.avail_in = inBuf.count - inputIndex
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = wanted
                    let status = lzma_code(&stream, 0)
                    return (status, inBuf.count - inputIndex - stream.avail_in, wanted - stream.avail_out)
                }
            }
            inputIndex += used
            if made > 0 { try output.withUnsafeBytes { try sink.write(Data($0.prefix(made))) }; produced += UInt64(made) }
            if status == 1 { break }  // stream end
            guard status == 0 else { throw ModArchiveError.damaged("LZMA data \(status)") }
            if used == 0 && made == 0 && inputIndex >= input.count && left == 0 { throw ModArchiveError.damaged("the archive ends early") }
        }
        guard produced == size else { throw ModArchiveError.damaged("the archive ends early") }
    }
}

// MARK: Sinks

class ByteSink {
    func write(_ data: Data) throws {}
}

final class MemorySink: ByteSink {
    var data = Data()
    override func write(_ data: Data) throws { self.data.append(data) }
}

final class FileSink: ByteSink {
    private let handle: FileHandle
    init(_ url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    override func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() throws { try handle.close() }
}

/// A folder's output cut into its files, each checked against its CRC.
final class SplitSink: ByteSink {
    private var files: [(size: UInt64, url: URL?, crc: UInt32?)]
    private var index = 0
    private var left: UInt64 = 0
    private var handle: FileHandle?
    private var crc: UInt32 = 0
    private var total: UInt64 = 0
    var progress: ((UInt64) -> Void)?

    init(files: [(UInt64, URL?, UInt32?)]) throws {
        self.files = files.map { (size: $0.0, url: $0.1, crc: $0.2) }
        super.init()
        try open()
    }

    private func open() throws {
        while index < files.count && files[index].size == 0 { try create(files[index].url); try? handle?.close(); handle = nil; index += 1 }
        guard index < files.count else { return }
        left = files[index].size; crc = 0
        handle = try create(files[index].url)
    }

    @discardableResult
    private func create(_ url: URL?) throws -> FileHandle? {
        guard let url else { return nil }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    override func write(_ data: Data) throws {
        var rest = data[...]
        while !rest.isEmpty {
            guard index < files.count else { return }  // padding past the last file
            let part = rest.prefix(Int(min(left, UInt64(rest.count))))
            try handle?.write(contentsOf: part)
            crc = part.withUnsafeBytes { ModCRC32.update(crc, $0) }
            left -= UInt64(part.count); total += UInt64(part.count)
            rest = rest.dropFirst(part.count)
            if left == 0 {
                if let expected = files[index].crc, expected != crc {
                    throw ModArchiveError.damaged("checksum of \(files[index].url?.lastPathComponent ?? "a file")")
                }
                try handle?.close(); handle = nil
                index += 1
                try open()
            }
        }
        progress?(total)
    }

    func finish() throws {
        try? handle?.close()
        guard index >= files.count else { throw ModArchiveError.damaged("the archive ends early") }
    }
}

// MARK: x86 filters

enum BCJ {
    /// 7-Zip's BCJ (x86) filter, decoding in place: E8/E9 targets back to relative.
    static func x86Decode(_ data: inout [UInt8]) {
        let size = data.count
        guard size >= 5 else { return }
        let allowed: [Bool] = [true, true, true, false, true, false, false, false]
        let bitNumber: [Int] = [0, 1, 2, 2, 3, 3, 3, 3]
        func isMS(_ b: UInt8) -> Bool { b == 0 || b == 0xFF }
        var pos = 0
        var prevPos = -1
        var prevMask: UInt32 = 0
        let ip: UInt32 = 5
        data.withUnsafeMutableBufferPointer { p in
            while true {
                var i = pos
                while i < size - 4 && p[i] & 0xFE != 0xE8 { i += 1 }
                pos = i
                if i >= size - 4 { break }
                let distance = pos - prevPos
                if distance > 3 {
                    prevMask = 0
                } else {
                    prevMask = (prevMask << UInt32(distance - 1)) & 7
                    if prevMask != 0 {
                        let b = p[pos + 4 - bitNumber[Int(prevMask)]]
                        if !allowed[Int(prevMask)] || isMS(b) {
                            prevPos = pos
                            prevMask = ((prevMask << 1) & 7) | 1
                            pos += 1
                            continue
                        }
                    }
                }
                prevPos = pos
                if isMS(p[pos + 4]) {
                    var src = UInt32(p[pos + 4]) << 24 | UInt32(p[pos + 3]) << 16 | UInt32(p[pos + 2]) << 8 | UInt32(p[pos + 1])
                    var dest: UInt32
                    while true {
                        dest = src &- (ip &+ UInt32(truncatingIfNeeded: pos))
                        if prevMask == 0 { break }
                        let index = bitNumber[Int(prevMask)] * 8
                        let b = UInt8(truncatingIfNeeded: dest >> UInt32(24 - index))
                        if !isMS(b) { break }
                        src = dest ^ ((1 << UInt32(32 - index)) &- 1)
                    }
                    p[pos + 4] = ~(UInt8(truncatingIfNeeded: (dest >> 24) & 1) &- 1)
                    p[pos + 3] = UInt8(truncatingIfNeeded: dest >> 16)
                    p[pos + 2] = UInt8(truncatingIfNeeded: dest >> 8)
                    p[pos + 1] = UInt8(truncatingIfNeeded: dest)
                    pos += 5
                } else {
                    prevMask = ((prevMask << 1) & 7) | 1
                    pos += 1
                }
            }
        }
    }

    /// 7-Zip's BCJ2: the main stream with CALL and JMP targets from their own streams,
    /// a range-coded bit per E8/E9/Jcc saying whether it was converted.
    static func bcj2Decode(main: [UInt8], call: [UInt8], jump: [UInt8], rc: [UInt8], size: Int) throws -> Data {
        var out = [UInt8](repeating: 0, count: size)
        var probs = [UInt16](repeating: 1024, count: 258)
        var rcPos = 0
        func rcByte() throws -> UInt32 {
            guard rcPos < rc.count else { throw ModArchiveError.damaged("BCJ2 stream") }
            defer { rcPos += 1 }
            return UInt32(rc[rcPos])
        }
        var code: UInt32 = 0, range: UInt32 = 0xFFFF_FFFF
        for _ in 0..<5 { code = (code << 8) | (try rcByte()) }
        var inPos = 0, outPos = 0, callPos = 0, jumpPos = 0
        var prev: UInt8 = 0
        func isJ(_ b0: UInt8, _ b1: UInt8) -> Bool { (b1 & 0xFE) == 0xE8 || (b0 == 0x0F && (b1 & 0xF0) == 0x80) }
        while outPos < size {
            var jumpByte: UInt8?, before: UInt8 = 0
            while inPos < main.count && outPos < size {
                let b = main[inPos]
                out[outPos] = b; outPos += 1; inPos += 1
                if isJ(prev, b) { before = prev; jumpByte = b; break }
                prev = b
            }
            guard let b = jumpByte, outPos < size else { break }
            // The bit's model: per preceding byte for CALL, one for JMP, one for Jcc.
            let index = b == 0xE8 ? Int(before) : (b == 0xE9 ? 256 : 257)
            let p = UInt32(probs[index])
            let bound = (range >> 11) &* p
            let taken: Bool
            if code < bound {
                range = bound; probs[index] = UInt16(p + ((2048 - p) >> 5)); taken = false
            } else {
                range = range &- bound; code = code &- bound; probs[index] = UInt16(p - (p >> 5)); taken = true
            }
            if range < 1 << 24 { range <<= 8; code = (code << 8) | (try rcByte()) }
            guard taken else { prev = b; continue }
            var src: UInt32 = 0
            if b == 0xE8 {
                guard callPos + 4 <= call.count else { throw ModArchiveError.damaged("BCJ2 call stream") }
                for k in 0..<4 { src = (src << 8) | UInt32(call[callPos + k]) }
                callPos += 4
            } else {
                guard jumpPos + 4 <= jump.count else { throw ModArchiveError.damaged("BCJ2 jump stream") }
                for k in 0..<4 { src = (src << 8) | UInt32(jump[jumpPos + k]) }
                jumpPos += 4
            }
            let dest = src &- UInt32(truncatingIfNeeded: outPos + 4)
            for k in 0..<4 where outPos < size { out[outPos] = UInt8(truncatingIfNeeded: dest >> (8 * UInt32(k))); outPos += 1 }
            prev = UInt8(truncatingIfNeeded: dest >> 24)
        }
        guard outPos == size else { throw ModArchiveError.damaged("BCJ2 output") }
        return Data(out)
    }

}

// MARK: .rar (the system's libarchive)

enum LibArchive {
    private typealias New = @convention(c) () -> OpaquePointer?
    private typealias Support = @convention(c) (OpaquePointer?) -> Int32
    private typealias OpenFile = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private typealias NextHeader = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias EntryPath = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias EntryType = @convention(c) (OpaquePointer?) -> UInt32
    private typealias ReadData = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    private typealias ErrorString = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private static let handle: UnsafeMutableRawPointer? = {
        for path in ["/usr/lib/libarchive.2.dylib", "libarchive.2.dylib", "libarchive.so.13", "libarchive.so"] {
            if let h = dlopen(path, RTLD_NOW) { return h }
        }
        return nil
    }()

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    static var available: Bool { symbol("archive_read_new", New.self) != nil }

    /// Writes every file of `url` (any format libarchive reads, RAR included) into `folder`.
    static func extract(_ url: URL, to folder: URL) throws -> [String] {
        guard let new = symbol("archive_read_new", New.self),
              let formats = symbol("archive_read_support_format_all", Support.self),
              let filters = symbol("archive_read_support_filter_all", Support.self),
              let open = symbol("archive_read_open_filename", OpenFile.self),
              let next = symbol("archive_read_next_header", NextHeader.self),
              let path = symbol("archive_entry_pathname_utf8", EntryPath.self) ?? symbol("archive_entry_pathname", EntryPath.self),
              let type = symbol("archive_entry_filetype", EntryType.self),
              let read = symbol("archive_read_data", ReadData.self),
              let free = symbol("archive_read_free", Support.self),
              let error = symbol("archive_error_string", ErrorString.self) else { throw ModArchiveError.noRar }
        guard let archive = new() else { throw ModArchiveError.noRar }
        defer { _ = free(archive) }
        _ = formats(archive); _ = filters(archive)
        func failure() -> ModArchiveError {
            let text = error(archive).map { String(cString: $0) } ?? "unknown error"
            if text.lowercased().contains("passphrase") || text.lowercased().contains("encrypt") { return .password }
            return .damaged(text)
        }
        guard open(archive, url.path, 1 << 16) == 0 else { throw failure() }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [String] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            var entry: OpaquePointer?
            let status = next(archive, &entry)
            if status == 1 { break }  // ARCHIVE_EOF
            guard status == 0 || status == -20 else { throw failure() }  // OK, WARN
            guard let raw = path(entry).map({ String(cString: $0) }), let relative = ModArchive.safePath(raw) else { continue }
            let target = folder.appendingPathComponent(relative)
            let kind = type(entry) & 0o170000
            if kind == 0o040000 { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
            guard kind == 0o100000 else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            while true {
                let count = buffer.withUnsafeMutableBytes { read(archive, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { throw failure() }
                try buffer.withUnsafeBytes { try out.write(contentsOf: Data($0.prefix(count))) }
            }
            written.append(relative)
        }
        return written
    }
}
