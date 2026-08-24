/**
 * 抖音 web 端 a_bogus 签名算法的 ArkTS 移植。
 *
 * 对应 Python 版 f2 的 `f2/utils/abogus.py`（Apache-2.0, JohnserfSeed）。
 * 移植要点：
 *   1. Python 用 `chr()/ord()` 在「字节值」与「字符」之间来回转换，中间值可能 > 255
 *      （例如毫秒时间戳 / 256^4 ≈ 407）。因此本实现内部统一用 number[] 表示码点序列，
 *      不用 Uint8Array，也不用字符串，避免截断与编码歧义。
 *   2. `bigArray` 是有状态的置换表，transformBytes 会就地修改它。
 *      每次生成签名都必须用一份全新副本，否则第二次签名结果错误。
 *   3. SM3 摘要由 core/crypto/SM3.ets 提供（Python 侧是 gmssl）。
 */

import { sm3Digest } from './SM3';

const CHARACTER_1: string = 'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
const CHARACTER_2: string = 'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';

const SALT: string = 'cus';
const UA_KEY: number[] = [0x00, 0x01, 0x0e];
const AID: number = 6383;
const PAGE_ID: number = 0;

const DEFAULT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';

const SORT_INDEX: number[] = [
  18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31, 35, 57, 39, 41, 43, 22, 28,
  32, 60, 36, 23, 29, 33, 37, 44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71,
];

const SORT_INDEX_2: number[] = [
  18, 20, 26, 30, 34, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43, 22, 28, 32, 36, 23, 29, 33, 37,
  44, 45, 46, 47, 48, 49, 50, 24, 25, 52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71,
];

const BIG_ARRAY_SEED: number[] = [
  121, 243, 55, 234, 103, 36, 47, 228, 30, 231, 106, 6, 115, 95, 78, 101, 250, 207, 198, 50,
  139, 227, 220, 105, 97, 143, 34, 28, 194, 215, 18, 100, 159, 160, 43, 8, 169, 217, 180, 120,
  247, 45, 90, 11, 27, 197, 46, 3, 84, 72, 5, 68, 62, 56, 221, 75, 144, 79, 73, 161,
  178, 81, 64, 187, 134, 117, 186, 118, 16, 241, 130, 71, 89, 147, 122, 129, 65, 40, 88, 150,
  110, 219, 199, 255, 181, 254, 48, 4, 195, 248, 208, 32, 116, 167, 69, 201, 17, 124, 125, 104,
  96, 83, 80, 127, 236, 108, 154, 126, 204, 15, 20, 135, 112, 158, 13, 1, 188, 164, 210, 237,
  222, 98, 212, 77, 253, 42, 170, 202, 26, 22, 29, 182, 251, 10, 173, 152, 58, 138, 54, 141,
  185, 33, 157, 31, 252, 132, 233, 235, 102, 196, 191, 223, 240, 148, 39, 123, 92, 82, 128, 109,
  57, 24, 38, 113, 209, 245, 2, 119, 153, 229, 189, 214, 230, 174, 232, 63, 52, 205, 86, 140,
  66, 175, 111, 171, 246, 133, 238, 193, 99, 60, 74, 91, 225, 51, 76, 37, 145, 211, 166, 151,
  213, 206, 0, 200, 244, 176, 218, 44, 184, 172, 49, 216, 93, 168, 53, 21, 183, 41, 67, 85,
  224, 155, 226, 242, 87, 177, 146, 70, 190, 12, 162, 19, 137, 114, 25, 165, 163, 192, 23, 59,
  9, 94, 179, 107, 35, 7, 142, 131, 239, 203, 149, 136, 61, 249, 14, 156,
];

/** UTF-8 编码：把字符串转成字节数组。对应 Python 的 str.encode('utf-8')。 */
export function utf8Encode(s: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c: number = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6));
      out.push(0x80 | (c & 0x3f));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      // 代理对 → 单个码点
      const lo: number = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        const cp: number = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
        out.push(0xf0 | (cp >> 18));
        out.push(0x80 | ((cp >> 12) & 0x3f));
        out.push(0x80 | ((cp >> 6) & 0x3f));
        out.push(0x80 | (cp & 0x3f));
        i++;
      } else {
        out.push(0xe0 | (c >> 12));
        out.push(0x80 | ((c >> 6) & 0x3f));
        out.push(0x80 | (c & 0x3f));
      }
    } else {
      out.push(0xe0 | (c >> 12));
      out.push(0x80 | ((c >> 6) & 0x3f));
      out.push(0x80 | (c & 0x3f));
    }
  }
  return out;
}

/** 字符串 → 码点数组（对应 Python 的 [ord(c) for c in s]）。 */
function toCodes(s: string): number[] {
  const out: number[] = new Array<number>(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i);
  }
  return out;
}

/** JS 语义的无符号右移（对应 Python 版的 js_shift_right）。 */
function jsShiftRight(val: number, n: number): number {
  return (val % 0x100000000) >>> n;
}

/**
 * 取 val 的第 shift/8 个字节，等价于 Python 的 `(val >> shift) & 255`。
 *
 * 为什么不直接写 `(val >> shift) & 255`：ArkTS/JS 的位运算会先把操作数截断成
 * int32，而毫秒时间戳约 1.79e12，远超 int32 范围。截断只会让数值相差 2^32 的整数倍，
 * 右移 ≤24 位后是 256 的倍数，恰好被 `& 255` 抹掉，所以结果其实仍然正确
 * （已与 Python 交叉验证一致）。但这依赖一个不显眼的巧合，
 * 一旦以后有人把 shift 改成 >24 或去掉掩码就会静默出错，所以这里改用浮点除法显式表达。
 */
function byteAt(val: number, shift: number): number {
  return Math.floor(val / Math.pow(2, shift)) % 256;
}

/** RC4 加密。key 与明文都用码点数组表示，输出字节数组。 */
export function rc4(key: number[], plain: number[]): number[] {
  const s: number[] = new Array<number>(256);
  for (let i = 0; i < 256; i++) {
    s[i] = i;
  }
  let j: number = 0;
  for (let i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) % 256;
    const t: number = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  let x: number = 0;
  let y: number = 0;
  const out: number[] = [];
  for (let i = 0; i < plain.length; i++) {
    x = (x + 1) % 256;
    y = (y + s[x]) % 256;
    const t: number = s[x];
    s[x] = s[y];
    s[y] = t;
    const k: number = s[(s[x] + s[y]) % 256];
    out.push((plain[i] ^ k) & 0xff);
  }
  return out;
}

/** 浏览器指纹生成器（对应 BrowserFingerprintGenerator）。 */
export class BrowserFingerprint {
  private static randInt(min: number, max: number): number {
    return min + Math.floor(Math.random() * (max - min + 1));
  }

  /** platform 取 'Win32'（Chrome/Firefox/Edge）或 'MacIntel'（Safari）。 */
  static generate(platform: string): string {
    const innerWidth: number = BrowserFingerprint.randInt(1024, 1920);
    const innerHeight: number = BrowserFingerprint.randInt(768, 1080);
    const outerWidth: number = innerWidth + BrowserFingerprint.randInt(24, 32);
    const outerHeight: number = innerHeight + BrowserFingerprint.randInt(75, 90);
    const screenX: number = 0;
    const screenY: number = Math.random() < 0.5 ? 0 : 30;
    const availWidth: number = BrowserFingerprint.randInt(1280, 1920);
    const availHeight: number = BrowserFingerprint.randInt(800, 1080);
    return `${innerWidth}|${innerHeight}|${outerWidth}|${outerHeight}|` +
      `${screenX}|${screenY}|0|0|${availWidth}|${availHeight}|` +
      `${availWidth}|${availHeight}|${innerWidth}|${innerHeight}|24|24|${platform}`;
  }
}

/** 加密工具：SM3 摘要、自定义 base64、置换表变换。 */
class CryptoUtility {
  private alphabets: string[];
  private bigArray: number[];

  constructor(alphabets: string[]) {
    this.alphabets = alphabets;
    // 必须是副本：transformBytes 会就地修改。
    this.bigArray = BIG_ARRAY_SEED.slice();
  }

  /** 对应 sm3_to_array(str)：先 UTF-8 编码再摘要。 */
  sm3FromString(s: string): number[] {
    return sm3Digest(utf8Encode(s));
  }

  /** 对应 sm3_to_array(List[int])：直接把整数列表当字节数组摘要。 */
  sm3FromBytes(b: number[]): number[] {
    return sm3Digest(b);
  }

  /** 对应 params_to_array(str, add_salt)。 */
  paramsToArrayFromString(param: string, addSalt: boolean): number[] {
    const p: string = addSalt ? param + SALT : param;
    return this.sm3FromString(p);
  }

  /** 对应 params_to_array(List[int], add_salt) —— 列表输入不加盐。 */
  paramsToArrayFromBytes(param: number[]): number[] {
    return this.sm3FromBytes(param);
  }

  /**
   * 对应 transform_bytes：基于 bigArray 的流式异或变换。
   * 输入 / 输出都是码点数组（值可能 > 255，与 Python 的 chr/ord 语义一致）。
   */
  transformBytes(codes: number[]): number[] {
    const n: number = this.bigArray.length;
    const result: number[] = [];
    let indexB: number = this.bigArray[1];
    let initialValue: number = 0;
    let valueE: number = 0;

    for (let index = 0; index < codes.length; index++) {
      let sumInitial: number = 0;
      if (index === 0) {
        initialValue = this.bigArray[indexB];
        sumInitial = indexB + initialValue;
        this.bigArray[1] = initialValue;
        this.bigArray[indexB] = indexB;
      } else {
        sumInitial = initialValue + valueE;
      }

      const charValue: number = codes[index];
      sumInitial = sumInitial % n;
      const valueF: number = this.bigArray[sumInitial];
      result.push(charValue ^ valueF);

      // 交换数组元素
      valueE = this.bigArray[(index + 2) % n];
      sumInitial = (indexB + valueE) % n;
      initialValue = this.bigArray[sumInitial];
      this.bigArray[sumInitial] = this.bigArray[(index + 2) % n];
      this.bigArray[(index + 2) % n] = initialValue;
      indexB = sumInitial;
    }
    return result;
  }

  /**
   * 对应 base64_encode：按 8bit → 6bit 重组，用自定义字符表输出。
   * 输入码点须在 0-255 内（调用方传的是 RC4 输出）。
   */
  base64Encode(codes: number[], alphabetIndex: number): string {
    const table: string = this.alphabets[alphabetIndex];
    let bin: string = '';
    for (let i = 0; i < codes.length; i++) {
      let b: string = (codes[i] & 0xff).toString(2);
      while (b.length < 8) {
        b = '0' + b;
      }
      bin += b;
    }
    const padding: number = (6 - (bin.length % 6)) % 6;
    for (let i = 0; i < padding; i++) {
      bin += '0';
    }
    let out: string = '';
    for (let i = 0; i < bin.length; i += 6) {
      const idx: number = parseInt(bin.substring(i, i + 6), 2);
      out += table.charAt(idx);
    }
    const eq: number = Math.floor(padding / 2);
    for (let i = 0; i < eq; i++) {
      out += '=';
    }
    return out;
  }

  /** 对应 abogus_encode：3 字节 → 4 字符，带边界截断与 '=' 填充。 */
  abogusEncode(codes: number[], alphabetIndex: number): string {
    const table: string = this.alphabets[alphabetIndex];
    const len: number = codes.length;
    let out: string = '';
    let produced: number = 0;

    const shifts: number[] = [18, 12, 6, 0];
    const masks: number[] = [0xfc0000, 0x03f000, 0x000fc0, 0x00003f];

    for (let i = 0; i < len; i += 3) {
      let nVal: number = 0;
      if (i + 2 < len) {
        nVal = (codes[i] << 16) | (codes[i + 1] << 8) | codes[i + 2];
      } else if (i + 1 < len) {
        nVal = (codes[i] << 16) | (codes[i + 1] << 8);
      } else {
        nVal = codes[i] << 16;
      }

      for (let t = 0; t < 4; t++) {
        const j: number = shifts[t];
        if (j === 6 && i + 1 >= len) {
          break;
        }
        if (j === 0 && i + 2 >= len) {
          break;
        }
        out += table.charAt((nVal & masks[t]) >> j);
        produced++;
      }
    }

    const eq: number = (4 - (produced % 4)) % 4;
    for (let i = 0; i < eq; i++) {
      out += '=';
    }
    return out;
  }
}

/** 生成一组伪随机字节（对应 generate_random_bytes，默认 3 组共 12 个码点）。 */
function generateRandomBytes(groups: number): number[] {
  const out: number[] = [];
  for (let g = 0; g < groups; g++) {
    const rd: number = Math.floor(Math.random() * 10000);
    out.push(((rd & 255) & 170) | 1);
    out.push(((rd & 255) & 85) | 2);
    out.push((jsShiftRight(rd, 8) & 170) | 5);
    out.push((jsShiftRight(rd, 8) & 85) | 40);
  }
  return out;
}

/** a_bogus 生成结果。 */
export class ABogusResult {
  /** 拼好 a_bogus 的完整查询串 */
  params: string = '';
  /** a_bogus 本身（已 URL 安全字符表编码，仍需 encodeURIComponent 后拼 URL） */
  abogus: string = '';
  /** 生成签名时使用的 UA —— 请求头必须与之一致，否则校验失败 */
  userAgent: string = '';
}

/**
 * a_bogus 签名器。
 *
 * 用法：
 * ```typescript
 * const ab = new ABogus(userAgent);
 * const r = ab.generate('device_platform=webapp&aid=6383&...', 'GET');
 * const url = `${base}?${r.params}`;  // params 里已含 a_bogus
 * ```
 * 注意：请求头的 User-Agent 必须与传入的 userAgent 完全一致。
 */
export class ABogus {
  private userAgent: string;
  private browserFp: string;
  private options: number[];

  /**
   * @param userAgent 与请求头一致的 UA，空则用内置默认 UA
   * @param fp 浏览器指纹，空则随机生成 Edge 指纹
   * @param options GET 用 [0, 1, 14]，POST 用 [0, 1, 8]
   */
  constructor(userAgent: string = '', fp: string = '', options: number[] = [0, 1, 14]) {
    this.userAgent = userAgent !== '' ? userAgent : DEFAULT_UA;
    this.browserFp = fp !== '' ? fp : BrowserFingerprint.generate('Win32');
    this.options = options;
  }

  /**
   * 生成 a_bogus。
   *
   * @param params 已排好序的查询串（不含 '?'，不含 a_bogus）
   * @param request 请求方法，通常传 'GET'
   */
  generate(params: string, request: string = ''): ABogusResult {
    // 每次生成都用全新的 CryptoUtility —— bigArray 是有状态的。
    const cu = new CryptoUtility([CHARACTER_1, CHARACTER_2]);

    const abDir: Map<number, number> = new Map<number, number>();
    abDir.set(8, 3);
    abDir.set(18, 44);
    abDir.set(66, 0);
    abDir.set(69, 0);
    abDir.set(70, 0);
    abDir.set(71, 0);

    const startEncryption: number = Date.now();

    // 请求体：双重 SM3（第一层加盐，第二层对字节数组）
    const array1: number[] = cu.paramsToArrayFromBytes(cu.paramsToArrayFromString(params, true));
    const array2: number[] = cu.paramsToArrayFromBytes(cu.paramsToArrayFromString(request, true));
    // UA：RC4 → 自定义 base64（字符表 2）→ SM3（不加盐）
    const uaEncrypted: number[] = rc4(UA_KEY, toCodes(this.userAgent));
    const uaBase64: string = cu.base64Encode(uaEncrypted, 1);
    const array3: number[] = cu.paramsToArrayFromString(uaBase64, false);

    const endEncryption: number = Date.now();

    // 加密开始时间（时间戳超 int32，必须用 byteAt 而不是 >>）
    abDir.set(20, byteAt(startEncryption, 24));
    abDir.set(21, byteAt(startEncryption, 16));
    abDir.set(22, byteAt(startEncryption, 8));
    abDir.set(23, startEncryption % 256);
    abDir.set(24, Math.floor(startEncryption / 256 / 256 / 256 / 256));
    abDir.set(25, Math.floor(startEncryption / 256 / 256 / 256 / 256 / 256));

    // 请求头配置
    abDir.set(26, (this.options[0] >> 24) & 255);
    abDir.set(27, (this.options[0] >> 16) & 255);
    abDir.set(28, (this.options[0] >> 8) & 255);
    abDir.set(29, this.options[0] & 255);

    // 请求方法
    abDir.set(30, Math.floor(this.options[1] / 256) & 255);
    abDir.set(31, (this.options[1] % 256) & 255);
    abDir.set(32, (this.options[1] >> 24) & 255);
    abDir.set(33, (this.options[1] >> 16) & 255);

    // 请求头加密
    abDir.set(34, (this.options[2] >> 24) & 255);
    abDir.set(35, (this.options[2] >> 16) & 255);
    abDir.set(36, (this.options[2] >> 8) & 255);
    abDir.set(37, this.options[2] & 255);

    // 请求体 / body / UA 摘要采样位
    abDir.set(38, array1[21]);
    abDir.set(39, array1[22]);
    abDir.set(40, array2[21]);
    abDir.set(41, array2[22]);
    abDir.set(42, array3[23]);
    abDir.set(43, array3[24]);

    // 加密结束时间（同上，必须用 byteAt）
    abDir.set(44, byteAt(endEncryption, 24));
    abDir.set(45, byteAt(endEncryption, 16));
    abDir.set(46, byteAt(endEncryption, 8));
    abDir.set(47, endEncryption % 256);
    abDir.set(48, abDir.get(8) as number);
    abDir.set(49, Math.floor(endEncryption / 256 / 256 / 256 / 256));
    abDir.set(50, Math.floor(endEncryption / 256 / 256 / 256 / 256 / 256));

    // 固定值
    abDir.set(51, (PAGE_ID >> 24) & 255);
    abDir.set(52, (PAGE_ID >> 16) & 255);
    abDir.set(53, (PAGE_ID >> 8) & 255);
    abDir.set(54, PAGE_ID & 255);
    abDir.set(55, PAGE_ID);
    abDir.set(56, AID);
    abDir.set(57, AID & 255);
    abDir.set(58, (AID >> 8) & 255);
    abDir.set(59, (AID >> 16) & 255);
    abDir.set(60, (AID >> 24) & 255);

    // 浏览器指纹长度
    abDir.set(64, this.browserFp.length);
    abDir.set(65, this.browserFp.length);

    const sortedValues: number[] = [];
    for (let i = 0; i < SORT_INDEX.length; i++) {
      const v: number | undefined = abDir.get(SORT_INDEX[i]);
      sortedValues.push(v === undefined ? 0 : v);
    }

    const fpCodes: number[] = toCodes(this.browserFp);

    // 异或校验位
    let abXor: number = ((this.browserFp.length & 255) >> 8) & 255;
    for (let index = 0; index < SORT_INDEX_2.length - 1; index++) {
      if (index === 0) {
        const v0: number | undefined = abDir.get(SORT_INDEX_2[index]);
        abXor = v0 === undefined ? 0 : v0;
      }
      const v1: number | undefined = abDir.get(SORT_INDEX_2[index + 1]);
      abXor = abXor ^ (v1 === undefined ? 0 : v1);
    }

    for (let i = 0; i < fpCodes.length; i++) {
      sortedValues.push(fpCodes[i]);
    }
    sortedValues.push(abXor);

    const randomPrefix: number[] = generateRandomBytes(3);
    const transformed: number[] = cu.transformBytes(sortedValues);
    const abogusCodes: number[] = randomPrefix.concat(transformed);

    const abogus: string = cu.abogusEncode(abogusCodes, 0);

    const result = new ABogusResult();
    result.abogus = abogus;
    result.params = `${params}&a_bogus=${abogus}`;
    result.userAgent = this.userAgent;
    return result;
  }
}
