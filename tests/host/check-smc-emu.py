#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[smc-emu]: writes into FEX-trapped plain code pages that touch no translated code.

Project Zomboid (build 50) re-translated its JVM code cache about 658,000 times
before the main menu: every store into a write-trapped 16 KB page invalidated the
whole page. FEX now keeps a code map (fex-patches/0006, MadeiraSmcCodeMap.h) and
Madeira's fault handler completes a store through a second mapping when the
written 64-byte granules hold no code and FEX armed the page itself.

Compiles the map header from the patch (C++) and the [smc-emu] functions of
build/ntdll-unix/virtual_ios.c and ios_smc_store_insn of signal_arm64_ios.c
verbatim (C), under AddressSanitizer and UBSan, and checks:
  * the C and C++ layouts agree;
  * registration: magic and slot count checked, one map per process;
  * a page is only writable here when it is armed, in a plain view of the
    process, inside one 16 KB page and clear of every code granule;
  * marking code, a colliding page, a full-page invalidation (also of the whole
    address space), and arming/disarming (also all at once) move the answer;
  * a view going away and the process exit forget it;
  * the second mapping is cached per page, and a burst of stores into one page
    is sent to FEX's path;
  * which instructions are completed (stores, store-release) and which are not
    (loads, atomics, exclusives, prefetch), from real encodings;
  * the fault handler wiring: the gate, the post-store check, no W^X demotion.
Synthetic addresses only: no Wine, iOS or device.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
vsrc = (root / 'build/ntdll-unix/virtual_ios.c').read_text().replace('\r\n', '\n')
ssrc = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text().replace('\r\n', '\n')
patch = (root / 'build/fex-patches/0006-arm64ec-ios-smc-write-emulation-code-map.patch').read_text()
CC = os.environ.get('CC') or shutil.which('cc') or 'cc'
CXX = os.environ.get('CXX') or shutil.which('c++') or 'c++'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(src, head):
    start = src.index(head + '\n{')
    return src[start:src.index('\n}\n', start) + 3]


def new_file(path):
    marker = 'diff --git a/%s b/%s\n' % (path, path)
    body = patch[patch.index(marker):]
    body = body[body.index('@@'):]
    end = body.find('\ndiff --git ')
    if end >= 0:
        body = body[:end]
    return ''.join(l[1:] + '\n' for l in body.split('\n')[1:] if l.startswith('+'))


header = new_file('FEXCore/include/FEXCore/Utils/MadeiraSmcCodeMap.h')
mark = patch.find('+      FEXCore::Madeira::SmcMarkCode(OpAddress, MAX_INST_SIZE);')
require(mark >= 0 and patch.find(' BlockIt->BlockStatus = DecodeInstruction(OpAddress);', mark) > mark,
        'the decoder marks an instruction before it decodes it')
require('static_cast<MEMORY_INFORMATION_CLASS>(1007)' in patch and
        '#define MemoryWineIosSmcCodeMap ((MEMORY_INFORMATION_CLASS)1007)' in vsrc,
        'FEX and ntdll use the same information class')

block_start = vsrc.index('struct ios_smc_code_slot { uint64_t page, flags, bits[4]; };')
block_defs = vsrc[block_start:vsrc.index('static NTSTATUS ios_smc_register_map( void *map_ptr )', block_start)]
parts = [
    block_defs,
    function(vsrc, 'static NTSTATUS ios_smc_register_map( void *map_ptr )'),
    function(vsrc, 'static void ios_smc_plain_add( const void *base, size_t size, void *peb )'),
    function(vsrc, 'static void ios_smc_plain_remove( const void *base, size_t size )'),
    function(vsrc, 'static void ios_smc_forget_peb( void *peb )'),
    function(vsrc, 'static struct ios_smc_code_map *ios_smc_map_for( uintptr_t addr )'),
    vsrc[vsrc.index('/* [smc-why]: why the last'):vsrc.index('static __thread int ios_smc_why;') + len('static __thread int ios_smc_why;')],
    function(vsrc, 'int ios_smc_write_ok( uintptr_t addr, size_t len )'),
    function(vsrc, 'void ios_smc_count_refusal( int why )'),
    function(vsrc, 'uintptr_t ios_smc_alias( uintptr_t addr )'),
    function(vsrc, 'void ios_smc_alias_drop( uintptr_t addr )'),
    function(vsrc, 'static void ios_smc_view_gone( const void *base, size_t size )'),
    function(vsrc, 'void ios_smc_note( int emulated )'),
    function(ssrc, 'static int ios_smc_store_insn( uint32_t insn )'),
]

# Wiring checks on the real sources.
require('ios_smc_plain_add( view->base, view->size, ios_jit_current_peb() );' in
        function(vsrc, 'static int ios_x64_rwx_is_host_data( uintptr_t b, uintptr_t e )'),
        'a view marked plain is registered')
require('ios_smc_forget_peb( peb );' in function(vsrc, 'static void ios_x64_rwx_plain_forget( void *peb )'),
        'a process exit forgets its map and views')
require('if (view->ios_flags & IOS_VIEW_X64_PLAIN) ios_smc_view_gone( view->base, view->size );' in
        function(vsrc, 'static void delete_view( struct file_view *view ) /* [in] View */'),
        'a plain view going away is forgotten')
aw = function(ssrc, 'static int ios_alias_write( uintptr_t addr, const void *source, size_t size, uintptr_t *blocked,\n                            int honor_guest_prot )')
require(aw.index('ios_smc_write_ok( at, length )') < aw.index('memcpy(') < aw.index('__atomic_thread_fence( __ATOMIC_SEQ_CST );')
        < aw.rindex('!ios_smc_write_ok( starts[i], lengths[i] )'),
        'checked, stored, fenced, checked again')
require('if (!rw && honor_guest_prot && ios_smc_write_ok( at, length )' in aw,
        'only for guest stores on pages without another alias')
require(re.search(r'if \(smc_candidate && !ios_smc_store_insn\( insn \)\)[^{]*\{[^}]*goto dispatch_guest_fault;', ssrc),
        'other instructions take FEX\'s path before anything is written')
require(re.search(r'if \(!emulated && smc_candidate\)\s*\{[^}]*goto dispatch_guest_fault;', ssrc),
        'a store not completed takes FEX\'s path')
require('if (rw_addr && honor_guest_prot && !smc_candidate && ios_alias_write_is_trapped( fault_addr ))' in ssrc,
        'the early trapped-page dispatch leaves candidates to the checked path')
require('[smc-emu]: not for a plain page, whose trap must stay. */\n                        if (!smc_candidate)' in ssrc,
        'no W^X demotion (which would drop the trap) after a completed store')
require(ssrc.count('if (smc_candidate)   /* [smc-emu]: through the checked path */') == 4,
        'the four STLR forms go through the checked path')
require('if (!rw_addr && !ios_jit_pool_pc_is_fex( (uintptr_t)fault_pc ))' in ssrc,
        'never for FEX\'s own handler writes')

c_code = r'''
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int NTSTATUS;
typedef int kern_return_t;
typedef int vm_prot_t;
typedef uint64_t mach_vm_address_t;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 0xC000000D
#define STATUS_NO_MEMORY 0xC0000017
#define KERN_SUCCESS 0
#define KERN_PROTECTION_FAILURE 2
#define VM_FLAGS_ANYWHERE 1
#define VM_INHERIT_NONE 2
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define FALSE 0
static int dprintf_n;
#define dprintf(fd, ...) ((void)(fd), dprintf_n++)
static void *cur_peb;
static void *ios_jit_current_peb(void) { return cur_peb; }
static int mach_task_self(void) { return 1; }
int remaps, deallocs, fail_remap;
static kern_return_t mach_vm_remap( int t, mach_vm_address_t *target, uint64_t size, uint64_t mask, int flags,
                                    int src, uint64_t page, int copy, vm_prot_t *cur, vm_prot_t *max, int inh )
{
    (void)t; (void)size; (void)mask; (void)flags; (void)src; (void)copy; (void)inh;
    if (fail_remap) return 1;
    remaps++; *target = page + 0x100000000000ull; *cur = 1; *max = 3;
    return KERN_SUCCESS;
}
static kern_return_t mach_vm_protect( int t, mach_vm_address_t a, uint64_t s, int set_max, int prot )
{ (void)t; (void)a; (void)s; (void)set_max; (void)prot; return KERN_SUCCESS; }
static kern_return_t mach_vm_deallocate( int t, mach_vm_address_t a, uint64_t s ) { (void)t; (void)a; (void)s; deallocs++; return 0; }
uint64_t fake_ticks;
static uint64_t ios_smc_ticks( void ) { return fake_ticks; }
''' + ''.join(parts) + r'''
size_t c_slots_offset(void) { return offsetof(struct ios_smc_code_map, slots); }
size_t c_slot_size(void) { return sizeof(struct ios_smc_code_slot); }
NTSTATUS c_register( void *map, void *peb ) { cur_peb = peb; return ios_smc_register_map( map ); }
void c_plain_add( uintptr_t b, size_t s, void *peb ) { ios_smc_plain_add( (void *)b, s, peb ); }
void c_view_gone( uintptr_t b, size_t s ) { ios_smc_view_gone( (void *)b, s ); }
void c_forget( void *peb ) { ios_smc_forget_peb( peb ); }
int c_ok( uintptr_t a, size_t n ) { return ios_smc_write_ok( a, n ); }
uintptr_t c_alias( uintptr_t a ) { return ios_smc_alias( a ); }
void c_drop( uintptr_t a ) { ios_smc_alias_drop( a ); }
int c_insn( uint32_t i ) { return ios_smc_store_insn( i ); }
void c_note( int e ) { ios_smc_note( e ); }
'''

cxx_code = header + r'''
#include <cstddef>
#include <cstdio>
extern "C" {
size_t c_slots_offset(void); size_t c_slot_size(void);
int c_register(void *map, void *peb); void c_plain_add(uintptr_t b, size_t s, void *peb);
void c_view_gone(uintptr_t b, size_t s); void c_forget(void *peb);
int c_ok(uintptr_t a, size_t n); uintptr_t c_alias(uintptr_t a); void c_drop(uintptr_t a);
int c_insn(uint32_t i); void c_note(int e);
extern int remaps, deallocs, fail_remap; extern uint64_t fake_ticks;
}
using namespace FEXCore::Madeira;
static int bad;
#define CHECK(c, what) do { if (!(c)) { std::printf("case failed: %s (line %d)\n", what, __LINE__); bad++; } } while (0)
int main() {
  void* P1 = (void*)0x7ffe0000; void* P2 = (void*)0x7ffd0000;
  CHECK(c_slots_offset() == offsetof(SmcCodeMap, Slots) && c_slot_size() == sizeof(SmcCodeMapSlot), "layout");
  CHECK(sizeof(SmcCodeMapSlot) == 48 && offsetof(SmcCodeMap, Slots) == 16, "layout size");
  static SmcCodeMap Wrong {};
  CHECK(c_register(&Wrong, P1) != 0, "wrong magic refused");
  CHECK(c_register(&g_SmcCodeMap, P1) != 0, "magic not set yet: refused");
  g_SmcCodeMap.Magic = SmcCodeMapMagic;
  g_SmcCodeMap.SlotCount = SmcCodeMapSlots;
  g_SmcCodeMapEnabled = true;
  CHECK(c_register(&g_SmcCodeMap, P1) == 0, "registered");
  const uint64_t Base = 0x7400000000ull, Page = Base + 0x4000;
  CHECK(!c_ok(Page + 0x100, 8), "no plain view yet");
  c_plain_add(Base, 0xf000000, P1);
  CHECK(!c_ok(Page + 0x100, 8), "unknown page: FEX's path");
  SmcPagesInvalidated(Page, SmcPageSize);
  CHECK(!c_ok(Page + 0x100, 8), "invalidated but not armed");
  SmcSetArmed(Page, SmcPageSize);
  CHECK(c_ok(Page + 0x100, 8), "armed, no code: completed here");
  SmcMarkCode(Page + 0x100, 15);
  CHECK(!c_ok(Page + 0x100, 8), "code granule");
  CHECK(!c_ok(Page + 0x13c, 8), "store touching a code granule");
  CHECK(c_ok(Page + 0x140, 8) && c_ok(Page + 0xc0, 0x40), "granules next to code");
  CHECK(!c_ok(Page + 0x3ff8, 16), "store crossing the page");
  CHECK(!c_ok(Base + 0xf000000 + 0x100, 8), "outside the plain view");
  SmcClearArmed(Page + 0x1000, 0x10);
  CHECK(!c_ok(Page + 0x140, 8), "protection changed: not armed");
  SmcSetArmed(Page + 0x2000, 1);
  CHECK(c_ok(Page + 0x140, 8), "armed again, bits kept");
  const uint64_t Collide = Page + (uint64_t)SmcCodeMapSlots * SmcPageSize;
  SmcMarkCode(Collide + 0x10, 15);
  CHECK(!c_ok(Page + 0x140, 8), "slot taken by a colliding page");
  SmcSetArmed(Collide, SmcPageSize);
  CHECK(!c_ok(Collide + 0x2000, 8), "claimed by the decoder: every bit set");
  SmcPagesInvalidated(Collide - 0x1000, SmcPageSize + 0x2000);
  CHECK(c_ok(Collide + 0x2000, 8), "full-page invalidation clears the bits, keeps armed");
  SmcPagesInvalidated(Collide + 0x1000, 0x2000);
  SmcMarkCode(Collide + 0x2000, 1);
  SmcPagesInvalidated(Collide + 0x1000, 0x2000);
  CHECK(!c_ok(Collide + 0x2000, 8), "a partial invalidation keeps the bits");
  SmcPagesInvalidated(0, ~0ULL);
  CHECK(c_ok(Collide + 0x2000, 8), "invalidating everything clears every page");
  SmcClearArmed(0, ~0ULL);
  CHECK(!c_ok(Collide + 0x2000, 8), "disarming everything");
  SmcSetArmed(Collide, SmcPageSize);
  CHECK(c_ok(Collide + 0x2000, 8), "armed again");
  cur_peb_check:
  CHECK(c_register(&g_SmcCodeMap, P2) == 0, "second process");
  c_plain_add(0x7500000000ull, 0x100000, P2);
  CHECK(!c_ok(0x7500000000ull + 0x100, 8), "other process: its own pages");
  c_view_gone(Base, 0xf000000);
  CHECK(!c_ok(Collide + 0x2000, 8), "view gone");
  c_plain_add(Base, 0xf000000, P1);
  CHECK(c_ok(Collide + 0x2000, 8), "view back");
  c_forget(P1);
  CHECK(!c_ok(Collide + 0x2000, 8), "process exit");
  // Second mapping: cached per page, bursts refused.
  uintptr_t A = c_alias(Page + 0x10);
  CHECK(A == Page + 0x100000000000ull + 0x10 && remaps == 1, "second mapping made");
  CHECK(c_alias(Page + 0x20) == A + 0x10 && remaps == 1, "cached");
  int got = 2;
  while (c_alias(Page + 0x30)) got++;
  CHECK(got == 64, "a burst is sent to FEX's path");
  fake_ticks += 48001;
  CHECK(c_alias(Page + 0x30) != 0, "next window");
  c_drop(Page);
  CHECK(deallocs == 1 && c_alias(Page) && remaps == 2, "dropped mapping made again");
  fail_remap = 1;
  CHECK(c_alias(Page + (uint64_t)64 * SmcPageSize) == 0, "no mapping: FEX's path");
  fail_remap = 0;
  c_note(1); c_note(0);
  // Instructions (llvm-mc encodings).
  const uint32_t yes[] = {0xf9000001, 0x38001c01, 0xb8004401, 0xf81f8001, 0xf8226801, 0xa9000801, 0xac810400,
                          0x3d800000, 0xfd000000, 0xc89ffc01, 0x089ffc01, 0x99004001, 0xa8000801, 0x79000401};
  const uint32_t no[] = {0xf9400001, 0xa9400801, 0xf8210002, 0xf8218002, 0xc8a17c02, 0xc8037c01, 0x08207c82,
                         0xc8dffc01, 0xf9800000, 0x3dc00000};
  for (auto I : yes) CHECK(c_insn(I) == 1, "store completed here");
  for (auto I : no) CHECK(c_insn(I) == 0, "not a plain store");
  std::printf(bad ? "FAILED\n" : "ok\n");
  return bad != 0;
}
'''
cxx_code = cxx_code.replace('  cur_peb_check:\n', '')

with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    (d / 'smc.c').write_text(c_code)
    (d / 'smc.cpp').write_text(cxx_code)
    flags = ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-Wall', '-Wno-unused-function']
    r1 = subprocess.run([CC, *flags, '-c', str(d / 'smc.c'), '-o', str(d / 'smc_c.o')], capture_output=True, text=True)
    r2 = subprocess.run([CXX, *flags, '-std=c++17', '-c', str(d / 'smc.cpp'), '-o', str(d / 'smc_cpp.o')],
                        capture_output=True, text=True)
    if r1.returncode or r2.returncode:
        print(r1.stderr[-3000:], r2.stderr[-3000:])
        require(False, 'compiles')
    else:
        r3 = subprocess.run([CXX, *flags, str(d / 'smc_c.o'), str(d / 'smc_cpp.o'), '-o', str(d / 'smc'), '-lpthread'],
                            capture_output=True, text=True)
        require(r3.returncode == 0, 'links' + (': ' + r3.stderr[-2000:] if r3.returncode else ''))
        if r3.returncode == 0:
            r = subprocess.run([str(d / 'smc')], capture_output=True, text=True)
            print(r.stdout.strip())
            require(r.returncode == 0 and 'ok' in r.stdout and not r.stderr.strip(),
                    'every case passed, no sanitizer report' + (': ' + r.stderr[-2000:] if r.stderr.strip() else ''))

print('PASS' if not failures else 'FAIL (%d)' % failures)
sys.exit(1 if failures else 0)
