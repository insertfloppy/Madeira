#!/usr/bin/env python3
"""The Video Processor MFT's COM server (msvproc.dll) is shipped where the prefix registers it.

The Planet Crafter (GOG, Unity 64-bit) hung on its loading screen: Unity's video player asks
Media Foundation for RGB frames from an H.264 MP4, so the source reader creates
CLSID_VideoProcessorMFT {88753B26-...}.  The prefix registers that class at
C:\\windows\\system32\\msvproc.dll, a thin wrapper that creates CLSID_wg_video_processor in
winegstreamer.dll, but the farm had no msvproc.dll ("couldn't load in-process dll"), so the
reader failed with MF_E_TOPO_CODEC_NOT_FOUND (0xc00d5212) before winegstreamer's raw-video
converter (tests/host/check-video-convert.py) was ever reached.  Checks the farm's msvproc.dll
(ARM64EC, COM exports, no delay imports, every import in the farm), both registrations, and that
farm rebuilds keep it.  Packaging only; a device run proves the rest.

Run with an optional DLL farm path to check an extracted App/IPA as well.
"""
from pathlib import Path
import re
import runpy
import struct
import sys
import tarfile

root = Path(__file__).resolve().parents[2]
PE = runpy.run_path(str(root / 'tools/check-wine-media-dlls.py'))['PE']
farm = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'app/Madeira/arm64ec-windows'
shipped = {p.name.lower(): p for p in farm.iterdir() if p.is_file()}
for name in ('msvproc.dll', 'winegstreamer.dll'):
    assert name in shipped, 'the farm has no ' + name
module = PE(shipped['msvproc.dll'])
pe_offset = struct.unpack_from('<I', module.data, 0x3c)[0]
machine = struct.unpack_from('<H', module.data, pe_offset + 4)[0]
assert machine in (0x8664, 0xa641), 'expected an ARM64EC-compatible COM server'
optional = pe_offset + 24
image_base = struct.unpack_from('<Q', module.data, optional + 24)[0]
config_rva, config_size = module.directories[10]
assert config_rva and config_size >= 208, 'missing ARM64EC load configuration'
metadata_va = module.unpack('<Q', module.offset(config_rva + 200, 8))[0]
assert metadata_va >= image_base, 'missing ARM64EC CHPE metadata'
exports = module.exports()
for symbol in ('DllGetClassObject', 'DllCanUnloadNow', 'DllRegisterServer', 'DllUnregisterServer'):
    assert exports.get(symbol), 'missing COM export: ' + symbol
assert not module.imports(True), 'msvproc.dll keeps ARM64EC delay imports (build-modules.sh links them as plain imports)'
missing = {dep for dep in module.imports() if dep not in shipped and
           not (dep.startswith(('api-ms-', 'ext-ms-')) and 'apisetschema.dll' in shipped)}
assert not missing, 'missing msvproc.dll imports: ' + ', '.join(sorted(missing))

with tarfile.open(root / 'app/Madeira/prefix-template.tar.gz') as archive:
    registry = archive.extractfile('prefix/system.reg').read().decode('utf-8')
for name, clsid, dll in (('VideoProcessorMFT', '{88753B26-5B24-49BD-B2E7-0C445C78C982}', 'msvproc'),
                         ('wg_video_processor', '{D527607F-89CB-4E94-9571-BCFE62175613}', 'winegstreamer')):
    section = r'[Software\\Classes\\CLSID\\' + clsid + r'\\InprocServer32]'
    assert section in registry, 'missing registration of ' + name
    entry = registry.split(section, 1)[1].split('\n[', 1)[0]
    assert re.search(r'@="C:\\\\windows\\\\system32\\\\' + dll + r'\.dll"', entry, re.I), \
        name + ' is not registered at system32\\' + dll + '.dll'
farm_list = (root / 'build/wine-pe/farm-modules.txt').read_text().split()
assert 'msvproc' in farm_list, 'build-modules.sh would not rebuild msvproc'
print('PASS: msvproc.dll shipped (ARM64EC, COM exports, imports in the farm); VideoProcessorMFT and '
      'wg_video_processor registered at system32')
