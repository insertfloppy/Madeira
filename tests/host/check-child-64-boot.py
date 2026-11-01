#!/usr/bin/env python3
"""A 64-bit child's boot thread resolves no 32-bit guest window ([child-64-boot]).

Build 63 (2026-11-01): x64 StarCraft.exe started by 32-bit Battle.net.exe got
its TEB and PEB inside the parent's window, loaded wow64.dll and took the app
down. wine_ios_child_main must turn window resolution off on a 64-bit child's
boot thread before virtual_alloc_teb and back on once the child's own TEB is
published, and ios_wow_slot_current must honour it before any other lookup.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
loader = (root / 'build/ntdll-unix/loader_ios.c').read_text()
failures = 0


def require(cond, label):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + label)
    failures += not cond


m = re.search(r'static struct ios_wow_window \*ios_wow_slot_current\(void\)\n\{(.*?)\n\}', virt, re.S)
body = m.group(1) if m else ''
require(m is not None, 'ios_wow_slot_current found')
require('if (ios_child_boot_no_window) return NULL;' in body
        and body.index('ios_child_boot_no_window') < body.index('ios_wow_slot_for_peb'),
        'the boot flag is checked before the PEB and owner lookups')
require('static __thread int ios_child_boot_no_window;' in virt, 'the flag is per thread')
require(virt.count('void ios_wow_child_boot_no_window( int on )') == 2, 'setter defined in both builds of the file')

main = loader[loader.index('DECLSPEC_EXPORT void wine_ios_child_main('):]
on = main.find('ios_wow_child_boot_no_window( 1 );')
alloc = main.find('status = virtual_alloc_teb( &teb );')
off = main.find('ios_wow_child_boot_no_window( 0 );')
publish = main.find('pthread_setspecific( ios_teb_tls_key, teb );')
i386 = main.find('status = ios_wow_window_reserve();')
require(on > 0 and alloc > on, 'set on a 64-bit child before its TEB is allocated')
require(i386 > 0 and not (i386 < on < main.find('else', i386)), 'not set on a 32-bit child')
require(off > publish > alloc, 'cleared once the child\'s own TEB is published')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: 64-bit children boot without a guest window')
