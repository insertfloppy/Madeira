#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Per-process ProcessWow64Information (build/ntdll-unix/process_ios.c).

Pseudo-processes share the native wow_peb global and the loader clears it while
a sibling boots, so a current-process ProcessWow64Information query could get a
sibling's PEB32 or NULL (wow64.dll then writes NULL+0x480). ios_current_wow_peb
answers from the caller's own PEB. Compiled verbatim under ASan/UBSan with three
concurrent owners (two WoW, one native) and foreign/NULL shared values, plus the
opt-out switch, and NtQueryInformationProcess must route through it.
Idea and original test: iDeck (kuscholar/iDeck, GPL-3.0-or-later).
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

s = (Path(__file__).resolve().parents[2] / 'build/ntdll-unix/process_ios.c').read_text()
a = s.index('static ULONG_PTR ios_current_wow_peb(')
b = s.index('NTSTATUS WINAPI NtQueryInformationProcess(', a)
assert 'ios_current_wow_peb( is_old_wow64() ? (ULONG_PTR)peb : (ULONG_PTR)wow_peb )' in s[b:], 'query must use it'

code = r'''
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
typedef uintptr_t ULONG_PTR;
typedef _Atomic int LONG;
typedef struct { void *Peb; } TEB;
static _Thread_local TEB current;
static _Thread_local int missing_teb;
static int is_win64 = 1;
static const ULONG_PTR page_size = 4096;
static TEB *NtCurrentTeb(void) { return missing_teb ? NULL : &current; }
static int InterlockedIncrement(LONG *p) { return atomic_fetch_add(p, 1) + 1; }
static ULONG_PTR ios_wow_base_for_peb(void *p) {
    if ((uintptr_t)p == 0x7900310000ULL) return 0x7900000000ULL;
    if ((uintptr_t)p == 0x7800310000ULL) return 0x7800000000ULL;
    return 0;
}
''' + s[a:b] + r'''
static void *worker(void *id) {
    uintptr_t owner = (uintptr_t)id;
    current.Peb = (void *)owner;
    for (int i = 0; i < 1000; i++) {
        uintptr_t legacy = i & 1 ? 0 : 0x7700311000ULL;
        uintptr_t wanted = ios_wow_base_for_peb((void *)owner) ? owner + page_size : 0;
        assert(ios_current_wow_peb(legacy) == wanted);
    }
    return NULL;
}
int main(void) {
    current.Peb = (void *)0x7900310000ULL;
    setenv("MADEIRA_WOW_PEB_PER_PROCESS", "0", 1); assert(ios_current_wow_peb(456) == 456);
    unsetenv("MADEIRA_WOW_PEB_PER_PROCESS");
    assert(ios_current_wow_peb(0) == 0x7900311000ULL);
    is_win64 = 0; assert(ios_current_wow_peb(789) == 789); is_win64 = 1;
    missing_teb = 1; assert(ios_current_wow_peb(123) == 0); missing_teb = 0;
    current.Peb = NULL; assert(ios_current_wow_peb(123) == 0);
    pthread_t t[3]; uintptr_t owners[] = {0x7900310000ULL, 0x7800310000ULL, 0x100400000ULL};
    for (int i = 0; i < 3; i++) assert(!pthread_create(&t[i], NULL, worker, (void *)owners[i]));
    for (int i = 0; i < 3; i++) assert(!pthread_join(t[i], NULL));
    puts("PASS: per-process PEB32 answer, native zero, foreign/NULL shared value, opt-out and concurrent siblings (ASan/UBSan)");
    return 0;
}
'''
cc = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang')
if not cc:
    print('SKIP: no C compiler'); sys.exit(0)
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 't.c').write_text(code)
    subprocess.run([cc, '-Werror', '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(p / 't.c'), '-o', str(p / 't'), '-lpthread'], check=True)
    subprocess.run([str(p / 't')], check=True, stderr=subprocess.DEVNULL)
