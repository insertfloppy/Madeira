#!/usr/bin/env python3
"""No host fault while virtual_mutex is held may freeze the session ([fault-deadlock]).

Build 63 (2026-11-01): StarCraft's ClientSdk.dll unmapped itself and mapped a
section at its own base. mprotect_exec, under virtual_mutex, named the module
with ios_pe_module_name, whose plain reads faulted on the new view; the Mach
exception thread then blocked on virtual_mutex in
ios_virtual_handle_fault_for_thread and the whole session froze.

Checks: ios_pe_module_name reads only through mach_vm_read_overwrite (compiled
here against a stub that refuses unreadable ranges), and the fault handler takes
virtual_mutex with a bounded trylock instead of a blocking lock.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
failures = 0


def require(cond, label):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + label)
    failures += not cond


i = virt.index('const char *ios_pe_module_name( const void *image_base, size_t image_size )\n{')
fn = virt[i:virt.index('\n}\n', i) + 3]
body = fn[fn.index('{'):]
require(not re.search(r'\*\(const uint(16|32)_t \*\)', body) and 'b[0]' not in body, 'no plain dereference of the image')

h = virt.index('NTSTATUS ios_virtual_handle_fault_for_thread( EXCEPTION_RECORD *rec, TEB *teb )\n{')
handler = virt[h:h + 4000]
lock = handler.index('pthread_mutex_trylock( &virtual_mutex )')
require('mutex_lock( &virtual_mutex );' not in handler[:lock], 'the fault handler does not block on virtual_mutex first')
require('[fault-deadlock]' in handler and 'return STATUS_ACCESS_VIOLATION;' in handler[lock:lock + 2500],
        'after the bounded wait the fault is reported, not serviced')

prog = r'''
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
typedef uint64_t mach_vm_address_t, mach_vm_size_t; typedef int kern_return_t;
#define KERN_SUCCESS 0
static uintptr_t lo, hi;   /* the only readable range */
static int mach_task_self(void) { return 0; }
static kern_return_t mach_vm_read_overwrite(int t, mach_vm_address_t a, mach_vm_size_t n, mach_vm_address_t d, mach_vm_size_t *got)
{
    if (a < lo || a + n > hi) { *got = 0; return 1; }
    memcpy((void *)d, (void *)a, n); *got = n; return 0;
}
''' + fn + r'''
int main(void)
{
    unsigned char *img = aligned_alloc(0x4000, 0x8000);
    memset(img, 0, 0x8000);
    img[0] = 'M'; img[1] = 'Z'; *(uint32_t *)(img + 0x3c) = 0x80;
    img[0x80] = 'P'; img[0x81] = 'E'; *(uint16_t *)(img + 0x98) = 0x20b;
    *(uint32_t *)(img + 0x108) = 0x1000; *(uint32_t *)(img + 0x100c) = 0x3ffa;
    strcpy((char *)img + 0x3ffa, "ClientSdk.dll");   /* crosses the 16 KB page */
    lo = (uintptr_t)img; hi = lo + 0x8000;
    printf("%s\n", ios_pe_module_name(img, 0x8000));
    hi = lo + 0x1000;   /* export directory unreadable: must not fault */
    printf("%s\n", ios_pe_module_name(img, 0x8000));
    hi = lo + 0x4000;   /* name runs into an unreadable page */
    printf("%s\n", ios_pe_module_name(img, 0x8000));
    return 0;
}
'''
cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if not cc:
    print('SKIP: no C compiler; the compiled check did not run')
else:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / 'pe.c'
        src.write_text(prog)
        exe = Path(tmp) / 'pe'
        build = subprocess.run([cc, '-std=gnu11', '-w', '-o', str(exe), str(src)])
        require(build.returncode == 0, 'ios_pe_module_name compiles on the host')
        if build.returncode == 0:
            out = subprocess.run([str(exe)], capture_output=True, text=True)
            require(out.returncode == 0, 'no fault on unreadable headers (exit %d)' % out.returncode)
            require(out.stdout.split() == ['ClientSdk.dll', '?', '?'], 'names and refusals: %r' % out.stdout.split())

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: faults under virtual_mutex cannot freeze the session')
