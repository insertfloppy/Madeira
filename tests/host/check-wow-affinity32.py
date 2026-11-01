#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""32-bit GROUP_AFFINITY thread attribute (build/ntdll-unix/thread_ios.c).

wow64's ps_attributes_32to64 passes the 12-byte GROUP_AFFINITY32 through
unchanged, and update_attr_list read it as the 16-byte native struct, so every
32-bit thread created with a group-affinity attribute failed with c000000d and
was terminated. Compiles ios_wow_affinity32 verbatim under ASan/UBSan and checks
the 12-byte decode (unaligned), field preservation, the opt-out switch and the
size/NULL gates, then checks update_attr_list only uses it for WoW threads.
Idea and original test: iDeck (kuscholar/iDeck, GPL-3.0-or-later).
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

s = (Path(__file__).resolve().parents[2] / 'build/ntdll-unix/thread_ios.c').read_text()
a = s.index('static int ios_wow_affinity32(')
b = s.index('static NTSTATUS update_attr_list', a)
body = s[b:s.index('\n}\n', b)]
assert 'get_wow_teb( teb ) && ios_wow_affinity32( &attr->Attributes[i], &converted )' in body, 'update_attr_list must gate on WoW TEB'
assert body.index('ios_wow_affinity32') < body.index('NtSetInformationThread( thread, ThreadGroupInformation'), 'convert before set'

code = r'''
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
typedef uintptr_t ULONG_PTR;
typedef struct { uint64_t Mask; unsigned short Group, Reserved[3]; } GROUP_AFFINITY;
typedef struct { uintptr_t Attribute, Size; void *ValuePtr; void *ReturnLength; } PS_ATTRIBUTE;
''' + s[a:b] + r'''
int main(void) {
    unsigned char *p = malloc(13), *wire = p + 1;
    unsigned mask = 0x80000001U; unsigned short tail[4] = {2, 3, 4, 5};
    GROUP_AFFINITY r; PS_ATTRIBUTE attr = {0, 12, wire, NULL};
    assert(sizeof(GROUP_AFFINITY) == 16);
    memcpy(wire, &mask, 4); memcpy(wire + 4, tail, 8);
    unsetenv("MADEIRA_WOW_AFFINITY_FIX");
    assert(ios_wow_affinity32(&attr, &r));
    assert(r.Mask == 0x80000001ULL && r.Group == 2);
    assert(r.Reserved[0] == 3 && r.Reserved[1] == 4 && r.Reserved[2] == 5);
    assert(!memcmp(wire, &mask, 4) && !memcmp(wire + 4, tail, 8));
    setenv("MADEIRA_WOW_AFFINITY_FIX", "0", 1); assert(!ios_wow_affinity32(&attr, &r));
    setenv("MADEIRA_WOW_AFFINITY_FIX", "1", 1); assert(ios_wow_affinity32(&attr, &r));
    attr.Size = 8;  assert(!ios_wow_affinity32(&attr, &r));
    attr.Size = 16; assert(!ios_wow_affinity32(&attr, &r));
    attr.Size = 12; attr.ValuePtr = NULL; assert(!ios_wow_affinity32(&attr, &r));
    free(p);
    puts("PASS: 12-byte GROUP_AFFINITY32 decode, field preservation, opt-out and size/NULL gates (ASan/UBSan)");
    return 0;
}
'''
cc = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang')
if not cc:
    print('SKIP: no C compiler'); sys.exit(0)
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 't.c').write_text(code)
    subprocess.run([cc, '-Werror', '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(p / 't.c'), '-o', str(p / 't')], check=True)
    subprocess.run([str(p / 't')], check=True)
