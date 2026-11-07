#!/usr/bin/env python3
# =============================================================================
#  Gate 05c (M8 confirmation experiment): add S/U-execute to ONE domain region
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Reads a DTS decompiled from the domain DTB, finds the OpenSBI memregion whose
#  base is --base, and in the 'regions' list of the domain --domain adds the
#  S/U-execute bit to the permissions of that region only. Everything else is
#  copied unchanged.
#
#  Safety: the permission bit values are read from OpenSBI's sbi_domain.h
#  (not assumed); the current permissions must be exactly M:(R,W) S/U:(R,W);
#  exactly one memregion and exactly one matching regions entry must exist.
#  On any mismatch nothing is written and the exit status is non-zero.
#
#  Exit status: 0 written, 2 input/parse problem, 3 unexpected current state
# =============================================================================
import argparse
import re
import sys

NODE_OPEN = re.compile(r'^(\s*)(?:[\w-]+:\s*)?([^\s=;{}][^=;{}]*?)\s*\{\s*$')
NODE_CLOSE = re.compile(r'^\s*\};\s*$')
PROP = re.compile(r'^(\s*)([\w,.#+@-]+)\s*=\s*(.*);\s*$')


def bits_from_header(path):
    names = ["M_READABLE", "M_WRITABLE", "M_EXECUTABLE", "SU_READABLE", "SU_WRITABLE", "SU_EXECUTABLE"]
    text = open(path, encoding="utf-8", errors="replace").read()
    bits = {}
    for n in names:
        m = re.search(r'#define\s+SBI_DOMAIN_MEMREGION_' + n + r'\s+\(\s*1UL?\s*<<\s*(\d+)\s*\)', text)
        if not m:
            raise ValueError(f"SBI_DOMAIN_MEMREGION_{n} not found in {path}")
        bits[n] = 1 << int(m.group(1))
    return bits


def decode(perm, b):
    m = ",".join(x for x, k in (("R", "M_READABLE"), ("W", "M_WRITABLE"), ("X", "M_EXECUTABLE")) if perm & b[k])
    s = ",".join(x for x, k in (("R", "SU_READABLE"), ("W", "SU_WRITABLE"), ("X", "SU_EXECUTABLE")) if perm & b[k])
    return f"M: ({m}) S/U: ({s})"


def cells(value):
    m = re.fullmatch(r'<([^>]*)>', value.strip())
    return [int(t, 0) for t in m.group(1).split()] if m else None


def parse(lines):
    """minimal DTS parser: list of nodes with name, depth, props {name: (line_index, raw_value)}"""
    nodes, stack = [], []
    for i, line in enumerate(lines):
        if NODE_CLOSE.match(line):
            if stack:
                stack.pop()
            continue
        m = NODE_OPEN.match(line)
        if m:
            node = {"name": m.group(2).strip(), "props": {}, "path": "/".join(n["name"] for n in stack + [])}
            nodes.append(node)
            stack.append(node)
            continue
        m = PROP.match(line)
        if m and stack:
            stack[-1]["props"][m.group(2)] = (i, m.group(3))
    return nodes


def main():
    ap = argparse.ArgumentParser(description="grant S/U-execute to one OpenSBI domain region (experiment)")
    ap.add_argument("--dts-in", required=True)
    ap.add_argument("--dts-out", required=True)
    ap.add_argument("--sbi-domain-h", required=True)
    ap.add_argument("--domain", default="trusted-domain")
    ap.add_argument("--base", required=True, help="base address of the memregion, e.g. 0xf1180000")
    a = ap.parse_args()
    try:
        b = bits_from_header(a.sbi_domain_h)
    except (OSError, ValueError) as exc:
        print(f"[NG]   {exc}"); return 2
    print("permission bits from sbi_domain.h: " + ", ".join(f"{k}=0x{v:02x}" for k, v in b.items()))
    lines = open(a.dts_in, encoding="utf-8").read().split("\n")
    nodes = parse(lines)
    base = int(a.base, 0)

    regions = []
    for n in nodes:
        if "compatible" in n["props"] and "opensbi,domain,memregion" in n["props"]["compatible"][1]:
            c_base = cells(n["props"].get("base", (0, ""))[1]) or []
            c_order = cells(n["props"].get("order", (0, ""))[1]) or []
            c_ph = cells(n["props"].get("phandle", (0, ""))[1]) or []
            if len(c_base) in (1, 2) and len(c_order) == 1 and len(c_ph) == 1:
                rb = (c_base[0] << 32 | c_base[1]) if len(c_base) == 2 else c_base[0]
                regions.append((n["name"], rb, c_order[0], c_ph[0]))
    print("memregions in the device tree:")
    for name, rb, order, ph in regions:
        print(f"  {name:<24} base 0x{rb:010x}  order {order:2d}  size 0x{1 << order:x}  phandle 0x{ph:x}")
    target = [r for r in regions if r[1] == base]
    if len(target) != 1:
        print(f"[NG]   expected exactly one memregion with base 0x{base:x}, found {len(target)}"); return 2
    t_name, _, t_order, t_ph = target[0]

    doms = [n for n in nodes if n["name"].split("@")[0] == a.domain
            and "opensbi,domain,instance" in n["props"].get("compatible", (0, ""))[1]]
    if len(doms) != 1 or "regions" not in doms[0]["props"]:
        print(f"[NG]   expected exactly one domain instance '{a.domain}' with a regions property, found {len(doms)}"); return 2
    li, raw = doms[0]["props"]["regions"]
    c = cells(raw)
    if not c or len(c) % 2:
        print(f"[NG]   cannot parse regions of '{a.domain}': {raw}"); return 2
    pairs = [(c[i], c[i + 1]) for i in range(0, len(c), 2)]
    print(f"regions of '{a.domain}' before the change:")
    by_ph = {ph: (name, rb, order) for name, rb, order, ph in regions}
    for ph, perm in pairs:
        name, rb, order = by_ph.get(ph, ("?", 0, 0))
        print(f"  phandle 0x{ph:x} {name:<20} 0x{rb:010x}/{order:2d}  perm 0x{perm:02x}  {decode(perm, b)}")
    idx = [i for i, (ph, _) in enumerate(pairs) if ph == t_ph]
    if len(idx) != 1:
        print(f"[NG]   expected exactly one entry for phandle 0x{t_ph:x} in regions, found {len(idx)}"); return 2
    old = pairs[idx[0]][1]
    expect = b["M_READABLE"] | b["M_WRITABLE"] | b["SU_READABLE"] | b["SU_WRITABLE"]
    if old != expect:
        print(f"[NG]   current permission 0x{old:02x} ({decode(old, b)}) is not the expected {decode(expect, b)} - nothing written")
        return 3
    new = old | b["SU_EXECUTABLE"]
    c[2 * idx[0] + 1] = new
    indent = re.match(r'^(\s*)', lines[li]).group(1)
    lines[li] = f"{indent}regions = <{' '.join(f'0x{x:02x}' for x in c)}>;"
    open(a.dts_out, "w", encoding="utf-8").write("\n".join(lines))
    print(f"[OK]   {t_name} (base 0x{base:x}, order {t_order}): 0x{old:02x} {decode(old, b)}  ->  0x{new:02x} {decode(new, b)}")
    print(f"[OK]   written {a.dts_out} (only the regions line of '{a.domain}' differs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
