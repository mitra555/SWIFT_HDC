"""Bit-exact reference of rtl/hv_gen_unit.sv (table-free level and position hypervectors).

Bit 1 encodes -1. Lane i of chunk c is dimension 32c+i; D must be a multiple of 32.
  H(s, k)  = mix((s + k*W) mod 2^32),  mix(x) = ((x ^ x>>16) * K mod 2^32) ^ (that >> 16)
  level q  : bit g = H(seedL, g//32)[g%32] XOR (((g*G16 + seedL[15:0]) mod 2^16) < q*step)
  position : chunk c of feature f = H(seedP, f*C + c)   (C = D/32)
"""
import numpy as np

M = 0xFFFFFFFF
W, K, G16 = 0x9E3779B9, 0x045D9F3B, 0x9E37


def H(seed, k):
    x = (np.uint64(seed) + np.asarray(k, dtype=np.uint64) * np.uint64(W)) & np.uint64(M)
    x ^= x >> np.uint64(16)
    x = (x * np.uint64(K)) & np.uint64(M)
    x ^= x >> np.uint64(16)
    return x


def step_for(nlvl):
    return (1 << 16) // (2 * (nlvl - 1)) if nlvl > 1 else 0


def seeds(so, g):
    """Per (seed set, group) constants the firmware writes to CSR GEN_SEEDL / GEN_SEEDP."""
    rs = np.random.RandomState((0x5EED + 7919 * so + 104729 * g) & 0x7FFFFFFF)
    return int(rs.randint(0, 2 ** 32, dtype=np.uint64)), int(rs.randint(0, 2 ** 32, dtype=np.uint64))


def seq_bits(seed, D):
    C = D // 32
    w = H(seed, np.arange(C))
    return ((w[:, None] >> np.arange(32, dtype=np.uint64)) & np.uint64(1)).reshape(-1).astype(np.uint8)


def level_bits(seed_l, step, q, D, base=None):
    if base is None: base = seq_bits(seed_l, D)
    g = np.arange(D, dtype=np.uint64)
    t = (g * np.uint64(G16) + np.uint64(seed_l & 0xFFFF)) & np.uint64(0xFFFF)
    return base ^ (t < np.uint64(q * step)).astype(np.uint8)


def pos_bits(seed_p, f, D, seq=None):
    C = D // 32
    w = H(seed_p, f * C + np.arange(C))
    return ((w[:, None] >> np.arange(32, dtype=np.uint64)) & np.uint64(1)).reshape(-1).astype(np.uint8)


def word(bits, c):
    """32-bit word of chunk c (lane i = bit i)."""
    b = bits[32 * c: 32 * c + 32].astype(np.uint64)
    return int((b << np.arange(32, dtype=np.uint64)).sum())


def level_table(seed_l, nlvl, D):
    base = seq_bits(seed_l, D); st = step_for(nlvl)
    return np.stack([level_bits(seed_l, st, q, D, base) for q in range(nlvl)])


def pos_table(seed_p, F, D):
    C = D // 32
    w = H(seed_p, np.arange(F * C)).reshape(F, C)
    return ((w[:, :, None] >> np.arange(32, dtype=np.uint64)) & np.uint64(1)).reshape(F, D).astype(np.uint8)
