#!/usr/bin/env python3
"""Mods from .7z and .rar (app/Madeira/ModArchives.swift).

Game details › Mods unpacks a .7z (own reader: LZMA, LZMA2, BCJ, BCJ2, Copy, packed
headers, CRC32 checks) or a .rar (the system's libarchive) into a folder, then installs
it like an unpacked mod.

Source checks (every host): the file is in the app target, liblzma's declarations are
in the bridging header, the Mods page unpacks archives and picks folders on their own.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the part of
ModArchives.swift on archives made by 7-Zip 23.01 (fixtures/mod-archives; expected.json
holds each file's SHA-256), and libarchive's RAR 4 / RAR 5 test files where the host has
libarchive (macOS).
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, unicodedata

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
fixtures = Path(__file__).resolve().parent / 'fixtures/mod-archives'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


source = (app / 'ModArchives.swift').read_text(encoding='utf-8')
mods = (app / 'GameMods.swift').read_text(encoding='utf-8')
bridging = (app / 'Madeira-Bridging-Header.h').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

check(project.count('A1009C05 /* ModArchives.swift in Sources */') == 2 and project.count('A2009C05 /* ModArchives.swift */') == 3,
      'ModArchives.swift is in the app target')
check('#import "ModArchiveLZMA.h"' in bridging and 'liblzma.tbd in Frameworks' in project, "liblzma's calls are declared and linked")
check('ModArchive.unpack(' in mods and 'ModArchive.kind(of:' in mods, 'the Mods page unpacks .7z and .rar mods')
check('folder ? [.folder] : [.zip, .archive, .data]' in mods and 'asCopy: true' in mods and '.fileImporter' not in mods,
      'files and folders have their own pickers, opened as copies (in-place picks fail with a mismatched App ID)')
check('import SwiftUI' not in source and 'LibraryModel' not in source, 'ModArchives.swift is Foundation only')

expected = {unicodedata.normalize('NFC', k): v for k, v in json.loads((fixtures / 'expected.json').read_text(encoding='utf-8')).items()}

main_swift = r'''
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
for name in CommandLine.arguments.dropFirst(3) {
    let target = out.appendingPathComponent(name)
    do {
        let files = try ModArchive.unpack(dir.appendingPathComponent(name), to: target)
        print("\(name)=OK \(files.count)")
    } catch {
        print("\(name)=ERR \(error.localizedDescription)")
    }
}
print("libarchive=\(LibArchive.available)")
print("safe=" + ["a/b.txt", "..\\x", "/abs/y", "C:\\z", "./a//b"].map { ModArchive.safePath($0) ?? "nil" }.joined(separator: ","))
var bad = try! Data(contentsOf: dir.appendingPathComponent("lzma2.7z"))
bad[bad.count - 40] ^= 0xFF
try! bad.write(to: out.appendingPathComponent("broken.7z"))
do { try ModArchive.unpack(out.appendingPathComponent("broken.7z"), to: out.appendingPathComponent("broken")); print("broken=taken") }
catch { print("broken=" + (error.localizedDescription.contains("damaged") ? "refused" : error.localizedDescription)) }
'''


def tree(folder):
    found = {}
    for path in sorted(folder.rglob('*')):
        # APFS hands back names decomposed (NFD); compare them composed, as written.
        rel = unicodedata.normalize('NFC', path.relative_to(folder).as_posix())
        if path.is_dir():
            if not any(path.iterdir()):
                found[rel + '/'] = ''
        else:
            found[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return found


compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-archives-', dir=os.environ.get('TMPDIR')) as directory:
        temporary = Path(directory)
        (temporary / 'ModArchives.swift').write_text(source)
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'archives'
        link = ['-llzma'] if sys.platform == 'darwin' else ['-Xlinker', '-l:liblzma.so.5']
        subprocess.run(compiler.split() + ['-O', '-swift-version', '5', '-import-objc-header', str(app / 'ModArchiveLZMA.h'),
                                           str(temporary / 'ModArchives.swift'), str(temporary / 'main.swift'), '-o', str(binary)] + link,
                       check=True)
        names = ['lzma2.7z', 'lzma1.7z', 'bcj.7z', 'bcj2.7z', 'copy.7z', 'nonsolid.7z', 'password.7z', 'ppmd.7z', 'rar4.rar', 'rar5.rar']
        unpacked = temporary / 'out'
        unpacked.mkdir()
        run = subprocess.run([str(binary), str(fixtures), str(unpacked)] + names, capture_output=True, text=True, check=True)
        out = dict(line.split('=', 1) for line in run.stdout.splitlines())
        for name, label in [('lzma2.7z', "7-Zip's default (LZMA2, solid, packed header)"), ('lzma1.7z', 'LZMA'),
                            ('bcj.7z', 'BCJ x86 filter + LZMA2'), ('bcj2.7z', '-mx9 with BCJ2 (four streams)'),
                            ('copy.7z', 'stored, plain header'), ('nonsolid.7z', 'one folder per file')]:
            got = tree(unpacked / name)
            check(out[name].startswith('OK') and got == expected, f'{label}: every file, empty file and empty folder matches'
                  + ('' if got == expected else f' ({out[name]}; {sorted(set(got.items()) ^ set(expected.items()))[:3]})'))
        check('password' in out['password.7z'], 'an encrypted .7z says it needs a password')
        check('PPMd' in out['ppmd.7z'], 'a PPMd .7z names the method it lacks')
        check(out['broken'] == 'refused', 'a damaged .7z is refused (checksums)')
        check(out['safe'] == 'a/b.txt,nil,abs/y,nil,a/b', 'archive paths cannot leave the folder')
        if out['libarchive'] == 'true':
            check(out['rar4.rar'].startswith('OK') and (unpacked / 'rar4.rar/testdir/test.txt').read_bytes() == b'test text document\r\n',
                  'RAR 4 unpacks through libarchive')
            check(out['rar5.rar'].startswith('OK') and (unpacked / 'rar5.rar/test.bin').stat().st_size == 1200,
                  'RAR 5 unpacks through libarchive')
        else:
            check('unpack the mod first' in out['rar4.rar'], 'without libarchive a .rar says to unpack it first')
            print('SKIP: libarchive unavailable here; macOS CI unpacks the RAR fixtures')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
