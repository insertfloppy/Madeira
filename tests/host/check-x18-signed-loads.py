#!/usr/bin/env python3
"""x18 emulation covers signed unsigned-offset loads (build/ntdll-unix/signal_arm64_ios.c).

Build 58 Battle.net log (2026-10-31): wow64.dll's `ldrsw x28,[x18,#0x180c]` (insn b9980e5c,
TEB64 WowTebOffset) ran on a thread whose x18 was 0; [x18-emul3] knew LDR/LDRB/LDRH but not
LDRSW, logged "UNRECOGNIZED insn=b9980e5c" and Battle.net.exe died with c0000005.

Compiles the production switch (unsigned-offset immediate loads/stores, base x18) against a
fake TEB and checks LDRSW/LDRSB/LDRSH (X and W targets) sign-extend correctly, plain LDR W
still zero-extends, and Rt=31 writes nothing.
"""
import subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text().replace('\r\n', '\n')
start = src.index('                        switch (insn & 0xffc00000)\n')
end = src.index('                        default: break;\n', start) + len('                        default: break;\n                        }\n')
body = src[start:end]
assert 'case 0xb9800000: /* LDRSW Xt */' in body

prog = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
struct { uint64_t __x[32]; } state;
static uintptr_t ios_teb_tls_slot_offset;
static int run(uint32_t insn, unsigned char *teb, uint64_t off, int *emul)
{
    uintptr_t thread_teb = (uintptr_t)teb, fault_addr = off;
    uintptr_t ea = thread_teb + fault_addr;
    int rt = insn & 0x1f, rn = (insn >> 5) & 0x1f, emulated = 0;
    (void)rn;
''' + body + r'''
    *emul = emulated;
    return 0;
}
static unsigned char teb[0x2000];
#define CHECK(c, m) do { if (!(c)) { printf("FAIL: %s\n", m); return 1; } } while (0)
int main(void)
{
    int e;
    int32_t neg = -8; memcpy(teb + 0x180c, &neg, 4);
    memset(&state, 0x55, sizeof state);
    run(0xb9980e5c, teb, 0x180c, &e);   /* ldrsw x28,[x18,#0x180c] */
    CHECK(e && state.__x[28] == (uint64_t)-8, "LDRSW Xt sign-extends (b9980e5c)");
    int32_t pos = 0x1234; memcpy(teb + 0x180c, &pos, 4);
    run(0xb9980e5c, teb, 0x180c, &e);
    CHECK(e && state.__x[28] == 0x1234, "LDRSW Xt positive");
    teb[0x10] = 0x80;
    run(0x39800000 | (0x10 << 10) | (18 << 5) | 3, teb, 0x10, &e);   /* ldrsb x3,[x18,#0x10] */
    CHECK(e && state.__x[3] == (uint64_t)(int64_t)-128, "LDRSB Xt");
    run(0x39c00000 | (0x10 << 10) | (18 << 5) | 4, teb, 0x10, &e);   /* ldrsb w4 */
    CHECK(e && state.__x[4] == 0xffffff80u, "LDRSB Wt clears the upper half");
    int16_t h = -2; memcpy(teb + 0x20, &h, 2);
    run(0x79800000 | (0x10 << 10) | (18 << 5) | 5, teb, 0x20, &e);   /* ldrsh x5,[x18,#0x20] */
    CHECK(e && state.__x[5] == (uint64_t)-2, "LDRSH Xt");
    run(0x79c00000 | (0x10 << 10) | (18 << 5) | 6, teb, 0x20, &e);   /* ldrsh w6 */
    CHECK(e && state.__x[6] == 0xfffffffeu, "LDRSH Wt");
    memcpy(teb + 0x180c, &neg, 4);
    run(0xb9580e5c, teb, 0x180c, &e);   /* ldr w28,[x18,#0x180c] */
    CHECK(e && state.__x[28] == 0xfffffff8u, "LDR Wt still zero-extends");
    state.__x[31] = 7;
    run(0xb9980e5f, teb, 0x180c, &e);   /* ldrsw xzr */
    CHECK(e && state.__x[31] == 7, "Rt=31 writes nothing");
    printf("PASS: [x18-emul3] emulates LDRSW/LDRSB/LDRSH off x18 (wow64.dll's WowTebOffset load), LDR W unchanged\n");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = Path(d) / 't.c'; c.write_text(prog)
    exe = Path(d) / 't'
    r = subprocess.run(['cc', '-Wall', '-Wno-unused-variable', '-fsanitize=address,undefined', '-o', str(exe), str(c)],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stderr); sys.exit(1)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr)
    sys.exit(r.returncode)
