/**
 * SM3 国密哈希算法（GB/T 32905-2016）的纯 ArkTS 实现。
 *
 * 抖音 web 端的 a_bogus 签名依赖 SM3 摘要。Python 版 f2 依赖 gmssl 包，
 * 鸿蒙侧没有对应的三方库，因此这里按标准自行实现，输出与 gmssl.sm3.sm3_hash 一致。
 *
 * 所有中间运算都用 `>>> 0` 收敛到无符号 32 位，避免 ArkTS number(double) 的符号扩展问题。
 */

const IV: number[] = [
  0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
  0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
];

const T0: number = 0x79cc4519;
const T1: number = 0x7a879d8a;

/** 循环左移，n 先对 32 取模（T_j 的轮转里 j 可达 63）。 */
function rotl(x: number, n: number): number {
  const s: number = n % 32;
  if (s === 0) {
    return x >>> 0;
  }
  return (((x << s) | (x >>> (32 - s))) >>> 0);
}

function ff(j: number, x: number, y: number, z: number): number {
  if (j < 16) {
    return ((x ^ y ^ z) >>> 0);
  }
  return (((x & y) | (x & z) | (y & z)) >>> 0);
}

function gg(j: number, x: number, y: number, z: number): number {
  if (j < 16) {
    return ((x ^ y ^ z) >>> 0);
  }
  return (((x & y) | ((~x) & z)) >>> 0);
}

function p0(x: number): number {
  return ((x ^ rotl(x, 9) ^ rotl(x, 17)) >>> 0);
}

function p1(x: number): number {
  return ((x ^ rotl(x, 15) ^ rotl(x, 23)) >>> 0);
}

/** 32 位模加：ArkTS 的 number 是 double，先相加再收敛无符号 32 位。 */
function add32(a: number, b: number): number {
  return (((a + b) & 0xffffffff) >>> 0);
}

/** 压缩函数 CF，就地更新 v（长度 8 的字数组）。 */
function cf(v: number[], block: number[], offset: number): void {
  const w: number[] = new Array<number>(68);
  for (let i = 0; i < 16; i++) {
    const p: number = offset + i * 4;
    w[i] = (((block[p] << 24) | (block[p + 1] << 16) | (block[p + 2] << 8) | block[p + 3]) >>> 0);
  }
  for (let j = 16; j < 68; j++) {
    const x: number = (w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) >>> 0;
    w[j] = ((p1(x) ^ rotl(w[j - 13], 7) ^ w[j - 6]) >>> 0);
  }

  let a: number = v[0];
  let b: number = v[1];
  let c: number = v[2];
  let d: number = v[3];
  let e: number = v[4];
  let f: number = v[5];
  let g: number = v[6];
  let h: number = v[7];

  for (let j = 0; j < 64; j++) {
    const t: number = j < 16 ? T0 : T1;
    const a12: number = rotl(a, 12);
    const ss1: number = rotl(add32(add32(a12, e), rotl(t, j)), 7);
    const ss2: number = (ss1 ^ a12) >>> 0;
    const wj: number = w[j];
    const wj4: number = (w[j] ^ w[j + 4]) >>> 0;
    const tt1: number = add32(add32(add32(ff(j, a, b, c), d), ss2), wj4);
    const tt2: number = add32(add32(add32(gg(j, e, f, g), h), ss1), wj);

    d = c;
    c = rotl(b, 9);
    b = a;
    a = tt1;
    h = g;
    g = rotl(f, 19);
    f = e;
    e = p0(tt2);
  }

  v[0] = (v[0] ^ a) >>> 0;
  v[1] = (v[1] ^ b) >>> 0;
  v[2] = (v[2] ^ c) >>> 0;
  v[3] = (v[3] ^ d) >>> 0;
  v[4] = (v[4] ^ e) >>> 0;
  v[5] = (v[5] ^ f) >>> 0;
  v[6] = (v[6] ^ g) >>> 0;
  v[7] = (v[7] ^ h) >>> 0;
}

/**
 * 计算 SM3 摘要。
 *
 * @param input 字节数组（0-255）
 * @returns 32 字节摘要，以 number[] 形式返回（每项 0-255）
 */
export function sm3Digest(input: number[]): number[] {
  const len: number = input.length;
  // 填充：0x80 + 若干 0x00，使 (len + 1 + k) % 64 === 56，尾部 8 字节为 bit 长度（大端）。
  let padLen: number = 56 - ((len + 1) % 64);
  if (padLen < 0) {
    padLen += 64;
  }
  const total: number = len + 1 + padLen + 8;
  const msg: number[] = new Array<number>(total);
  for (let i = 0; i < len; i++) {
    msg[i] = input[i] & 0xff;
  }
  msg[len] = 0x80;
  for (let i = len + 1; i < len + 1 + padLen; i++) {
    msg[i] = 0;
  }
  // bit 长度：高 32 位用浮点除法取，低 32 位用位运算取。
  const bitLen: number = len * 8;
  const hi: number = Math.floor(bitLen / 4294967296);
  const lo: number = bitLen >>> 0;
  let p: number = len + 1 + padLen;
  msg[p] = (hi >>> 24) & 0xff;
  msg[p + 1] = (hi >>> 16) & 0xff;
  msg[p + 2] = (hi >>> 8) & 0xff;
  msg[p + 3] = hi & 0xff;
  msg[p + 4] = (lo >>> 24) & 0xff;
  msg[p + 5] = (lo >>> 16) & 0xff;
  msg[p + 6] = (lo >>> 8) & 0xff;
  msg[p + 7] = lo & 0xff;

  const v: number[] = IV.slice();
  for (let off = 0; off < total; off += 64) {
    cf(v, msg, off);
  }

  const out: number[] = new Array<number>(32);
  for (let i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (v[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (v[i] >>> 8) & 0xff;
    out[i * 4 + 3] = v[i] & 0xff;
  }
  return out;
}

/** 便捷方法：把摘要转成小写十六进制串（便于与 gmssl 输出对照调试）。 */
export function sm3Hex(input: number[]): string {
  const d: number[] = sm3Digest(input);
  let s: string = '';
  for (let i = 0; i < d.length; i++) {
    const h: string = d[i].toString(16);
    s += h.length === 1 ? '0' + h : h;
  }
  return s;
}
