import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:fast_gbk/fast_gbk.dart';
import 'package:pointycastle/export.dart';

/// legado `java.*` 加解密/编码宿主面的纯 Dart 实现（isolate 内直调，无 JS 依赖）。
///
/// 字节跨界约定（research §5.2）：Dart↔JS 通道只传字符串，**字节数组一律以
/// base64 表示**；`strToBytes/bytesToStr` 负责与 utf8/gbk 互转。
class LegadoJsCrypto {
  LegadoJsCrypto._();

  // ---------- 摘要 ----------

  /// `java.md5Encode`（32 位）。
  static String md5Encode(String input) =>
      hash.md5.convert(utf8.encode(input)).toString();

  /// `java.md5Encode16`（取 32 位中间 16 位，legado jsHelp.md:396-400）。
  static String md5Encode16(String input) {
    final h = md5Encode(input);
    return h.substring(8, 24);
  }

  static final _digests = <String, hash.Hash>{
    'MD5': hash.md5,
    'SHA-1': hash.sha1,
    'SHA1': hash.sha1,
    'SHA-256': hash.sha256,
    'SHA256': hash.sha256,
    'SHA-384': hash.sha384,
    'SHA384': hash.sha384,
    'SHA-512': hash.sha512,
    'SHA512': hash.sha512,
  };

  static hash.Hash _hashOf(String algorithm) {
    var name = algorithm.toUpperCase().replaceAll('_', '-');
    // HmacSHA256 等 HMAC 前缀形态：摘要部分才是查找键。
    if (name.startsWith('HMAC')) name = name.substring(4);
    final h = _digests[name];
    if (h == null) {
      throw LegadoJsCryptoException('不支持的摘要算法: $algorithm');
    }
    return h;
  }

  /// `java.digestHex(data, algorithm)`。
  static String digestHex(String data, String algorithm) =>
      _hashOf(algorithm).convert(utf8.encode(data)).toString();

  static String digestBase64Str(String data, String algorithm) =>
      base64.encode(_hashOf(algorithm).convert(utf8.encode(data)).bytes);

  static String hmacHex(String data, String algorithm, String key) =>
      _hmac(data, algorithm, key).toString();

  static String hmacBase64(String data, String algorithm, String key) =>
      base64.encode(_hmac(data, algorithm, key).bytes);

  static hash.Digest _hmac(String data, String algorithm, String key) =>
      hash.Hmac(_hashOf(algorithm), utf8.encode(key))
          .convert(utf8.encode(data));

  // ---------- 编码 ----------

  static String base64EncodeStr(String input) =>
      base64.encode(utf8.encode(input));

  static String base64DecodeStr(String input) {
    try {
      return utf8.decode(base64.decode(_normalizeB64(input)), allowMalformed: true);
    } on FormatException catch (e) {
      throw LegadoJsCryptoException('base64 解码失败: $e');
    }
  }

  static Uint8List base64DecodeBytes(String input) =>
      Uint8List.fromList(base64.decode(_normalizeB64(input)));

  /// URL-safe / 缺 padding 容错。
  static String _normalizeB64(String s) {
    var v = s.trim().replaceAll('-', '+').replaceAll('_', '/');
    final pad = v.length % 4;
    if (pad == 2) v = '$v==';
    if (pad == 3) v = '$v=';
    return v;
  }

  static String _hexEncode(List<int> bytes) {
    const digits = '0123456789abcdef';
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(digits[(b >> 4) & 0xf]);
      out.write(digits[b & 0xf]);
    }
    return out.toString();
  }

  static Uint8List _hexDecode(String input) {
    final clean = input.trim().replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.length.isOdd) {
      throw LegadoJsCryptoException('hex 长度为奇数，无法解码');
    }
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String hexEncodeToString(String input) =>
      _hexEncode(utf8.encode(input));

  static String hexDecodeToString(String input) =>
      utf8.decode(_hexDecode(input), allowMalformed: true);

  static Uint8List hexDecodeToBytes(String input) => _hexDecode(input);

  static Uint8List strToBytes(String input, String charset) {
    final cs = charset.trim().toUpperCase();
    if (cs == 'GBK' || cs == 'GB2312' || cs == 'GB18030') {
      return Uint8List.fromList(gbk.encode(input));
    }
    return Uint8List.fromList(utf8.encode(input));
  }

  static String bytesToStr(Uint8List bytes, String charset) {
    final cs = charset.trim().toUpperCase();
    if (cs == 'GBK' || cs == 'GB2312' || cs == 'GB18030') {
      return gbk.decode(bytes, allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ---------- 对称加解密 ----------

  /// `java.createSymmetricCrypto(transformation, key, iv)`。
  ///
  /// 支持 AES/DES/DESede(3DES) × ECB/CBC/CTR/CFB × PKCS5(7)/NoPadding，及裸 `RC4`。
  /// key/iv 惯例（research §5.2 ByteArray 约定）：串先按 **base64 试解**
  /// （干净 base64 且解码长度合法才算——16 字节键的 base64 恰好 24 字符，
  /// 会被 utf8 优先误判成 AES-192）；否则按 utf8 字节；utf8 长度恰合法时直用。
  static SymmetricCipher createSymmetricCrypto(
      String transformation, String key, String iv) {
    final parsed = _parseTransformation(transformation);
    final keyBytes = _keyBytes(key, parsed.algo);
    final ivBytes = (parsed.mode == 'ECB' || parsed.algo == 'RC4')
        ? null
        : _ivBytes(iv, parsed.algo);
    return SymmetricCipher._(parsed, keyBytes, ivBytes);
  }

  static ({String algo, String mode, String? padding, bool stream})
      _parseTransformation(String t) {
    var v = t.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (v == 'RC4') {
      return (algo: 'RC4', mode: '', padding: null, stream: true);
    }
    final parts = v.split('/');
    final algo = parts[0];
    if (!{'AES', 'DES', 'DESEDE', 'TRIPLEDES', 'BLOWFISH'}.contains(algo)) {
      throw LegadoJsCryptoException('不支持的对称算法: $t（支持 AES/DES/DESede/RC4）');
    }
    final algoKey = algo == 'TRIPLEDES' ? 'DESEDE' : algo;
    var mode = parts.length > 1 ? parts[1] : 'ECB';
    var padding = parts.length > 2 ? parts[2] : 'PKCS7';
    if (padding == 'PKCS5PADDING') padding = 'PKCS7PADDING';
    final noPad = padding == 'NOPADDING' || padding == 'NONE';
    final stream = mode == 'CTR' || mode == 'CFB' || mode == 'OFB';
    return (
      algo: algoKey,
      mode: mode,
      padding: noPad ? null : 'PKCS7',
      stream: stream,
    );
  }

  static Uint8List _keyBytes(String key, String algo) {
    final sizes = switch (algo) {
      'AES' => const [16, 24, 32],
      'DES' => const [8],
      'DESEDE' => const [16, 24],
      'BLOWFISH' => const [8, 16, 24, 32],
      _ => const <int>[],
    };
    // base64 优先：干净 base64 且解码长度合法才走（防 16 字节键的 24 字符
    // base64 被误判成 AES-192 utf8 键）。
    if (_looksLikeBase64(key)) {
      try {
        final decoded = base64DecodeBytes(key);
        if (sizes.contains(decoded.length)) return decoded;
      } catch (_) {}
    }
    final raw = utf8.encode(key);
    if (sizes.contains(raw.length)) {
      return Uint8List.fromList(raw);
    }
    // DES/DESede 常见短 utf8 key 截断/补零兜底。
    if (sizes.isNotEmpty) {
      final target =
          sizes.lastWhere((s) => s <= raw.length, orElse: () => sizes.first);
      final out = Uint8List(target)
        ..setRange(0, raw.length.clamp(0, target), raw);
      return out;
    }
    return Uint8List.fromList(raw);
  }

  static bool _looksLikeBase64(String s) {
    if (s.length < 8 || s.length % 4 != 0) return false;
    return RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s);
  }

  static Uint8List _ivBytes(String iv, String algo) {
    final block = algo == 'AES' ? 16 : 8;
    final raw = utf8.encode(iv);
    if (raw.length == block) return Uint8List.fromList(raw);
    try {
      final decoded = base64DecodeBytes(iv);
      if (decoded.length == block) return decoded;
    } catch (_) {}
    final out = Uint8List(block)
      ..setRange(0, raw.length.clamp(0, block), raw);
    return out;
  }

  // ---------- RSA ----------

  /// `java.createAsymmetricCrypto(transformation)`：RSA PKCS#1 v1.5。
  /// 公私钥材料支持：PEM（PUBLIC/PRIVATE KEY、RSA PUBLIC/PRIVATE KEY 四种头）、
  /// 裸 base64 DER、hex `modulus,exponent` 对。
  static RsaCipher createAsymmetricCrypto(String transformation) {
    final t = transformation.toUpperCase();
    if (t.contains('OAEP')) {
      throw LegadoJsCryptoException('RSA OAEP 暂不支持（可用 PKCS1Padding）');
    }
    final noPad = t.contains('NOPADDING');
    return RsaCipher._(noPad);
  }

  /// 解析 RSA 公钥材料 → (n, e)。
  static (BigInt, BigInt) parseRsaPublicKey(String material) {
    final s = _pemStrip(material);
    // hex `modulus,exponent` 形态。
    if (s.contains(',') && RegExp(r'^[0-9a-fA-F,\s]+$').hasMatch(s)) {
      final parts = s.split(',');
      return (BigInt.parse(parts[0].trim(), radix: 16),
          BigInt.parse(parts[1].trim(), radix: 16));
    }
    final Uint8List der;
    try {
      der = base64DecodeBytes(s);
    } on FormatException catch (err) {
      throw LegadoJsCryptoException('RSA 密钥材料不是合法 base64/PEM: $err');
    }
    final d = _Der(der);
    final outer = d.readSeq();
    // SPKI：SEQ(SEQ(OID,...), BITSTRING(SEQ(INT n, INT e)))；PKCS#1：SEQ(INT n, INT e)。
    if (outer.peekTag() == 0x30) {
      outer.readSeq(); // 算法标识
      final bits = outer.read(0x03);
      final inner = _Der(Uint8List.sublistView(bits, 1)); // 首字节 = 未用位数
      final key = inner.readSeq();
      final n = key.readInt();
      final e = key.readInt();
      return (n, e);
    }
    final n = outer.readInt();
    final e = outer.readInt();
    return (n, e);
  }

  /// 解析 RSA 私钥材料 → (n, d, p, q)。p/q 供 pointycastle 构造断言（运算只用 n/d）。
  static (BigInt, BigInt, BigInt, BigInt) parseRsaPrivateKey(String material) {
    final s = _pemStrip(material);
    final d = _Der(base64DecodeBytes(s));
    final outer = d.readSeq();
    // PKCS#8 与 PKCS#1 私钥都以 INT version 开头，区分看第二个元素：
    // PKCS#8 = INT 0, SEQ(alg), OCTETSTRING(inner SEQ(INT 0, n, e, d, p, q, ...))；
    // PKCS#1 = INT 0, INT n, INT e, INT d, INT p, INT q, ...
    outer.readInt(); // version
    if (outer.peekTag() == 0x30) {
      outer.readSeq(); // 算法标识
      final octets = outer.read(0x04);
      final inner = _Der(octets).readSeq();
      inner.readInt(); // version
      final n = inner.readInt();
      inner.readInt(); // publicExponent
      final priv = inner.readInt(); // privateExponent
      final p = inner.readInt();
      final q = inner.readInt();
      return (n, priv, p, q);
    }
    final n = outer.readInt();
    outer.readInt(); // publicExponent
    final priv = outer.readInt();
    final p = outer.readInt();
    final q = outer.readInt();
    return (n, priv, p, q);
  }

  static String _pemStrip(String material) => material
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.contains('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');

  /// `java.timeFormat(pattern, time?)`：支持 yyyy/MM/dd/HH/mm/ss/SSS 常用段。
  static String timeFormat(String pattern, [Object? time]) {
    DateTime dt;
    if (time == null || '$time' == 'now') {
      dt = DateTime.now();
    } else if (time is num) {
      dt = DateTime.fromMillisecondsSinceEpoch(
          time > 99999999999 ? time.toInt() : (time * 1000).toInt());
    } else {
      dt = DateTime.tryParse('$time') ?? DateTime.now();
    }
    return pattern
        .replaceAll('yyyy', dt.year.toString().padLeft(4, '0'))
        .replaceAll('MM', dt.month.toString().padLeft(2, '0'))
        .replaceAll('dd', dt.day.toString().padLeft(2, '0'))
        .replaceAll('HH', dt.hour.toString().padLeft(2, '0'))
        .replaceAll('mm', dt.minute.toString().padLeft(2, '0'))
        .replaceAll('ss', dt.second.toString().padLeft(2, '0'))
        .replaceAll('SSS', dt.millisecond.toString().padLeft(3, '0'));
  }
}

/// RSA 句柄：公钥加密 / 私钥解密（PKCS#1 v1.5，或 NoPadding 裸 RSA）。
class RsaCipher {
  RsaCipher._(this._noPadding);

  final bool _noPadding;
  BigInt? _n;
  BigInt? _e;
  BigInt? _d;
  BigInt? _p;
  BigInt? _q;

  void setPublicKey(String material) {
    final (n, e) = LegadoJsCrypto.parseRsaPublicKey(material);
    _n = n;
    _e = e;
  }

  void setPrivateKey(String material) {
    final (n, d, p, q) = LegadoJsCrypto.parseRsaPrivateKey(material);
    _n = n;
    _d = d;
    _p = p;
    _q = q;
  }

  /// 加密（utf8 字符串进 → base64 出）。
  String encryptB64(String data) {
    if (_n == null || _e == null) {
      throw LegadoJsCryptoException('RSA 未设置公钥');
    }
    final keyParam =
        PublicKeyParameter<RSAPublicKey>(RSAPublicKey(_n!, _e!));
    var input = Uint8List.fromList(utf8.encode(data));
    AsymmetricBlockCipher cipher;
    if (_noPadding) {
      cipher = RSAEngine()..init(true, keyParam);
      // 裸 RSA：输入须等于块长，左填充 0。
      final k = (_n!.bitLength + 7) ~/ 8;
      if (input.length != k) {
        final padded = Uint8List(k);
        padded.setRange(k - input.length, k, input);
        input = padded;
      }
    } else {
      cipher = PKCS1Encoding(RSAEngine())..init(true, keyParam);
    }
    return base64.encode(_run(cipher, input));
  }

  String encryptHex(String data) =>
      LegadoJsCrypto._hexEncode(LegadoJsCrypto.base64DecodeBytes(encryptB64(data)));

  String decryptB64(String data) {
    if (_n == null || _d == null) {
      throw LegadoJsCryptoException('RSA 未设置私钥');
    }
    final keyParam = PrivateKeyParameter<RSAPrivateKey>(
        RSAPrivateKey(_n!, _d!, _p, _q));
    final cipher = _noPadding
        ? (RSAEngine()..init(false, keyParam))
        : (PKCS1Encoding(RSAEngine())..init(false, keyParam));
    final out = _run(cipher, LegadoJsCrypto.base64DecodeBytes(data));
    if (_noPadding) {
      // 裸 RSA 输出含前导 0：剥到首个非零字节。
      var start = 0;
      while (start < out.length - 1 && out[start] == 0) {
        start++;
      }
      return base64.encode(out.sublist(start));
    }
    return base64.encode(out);
  }

  String decryptStr(String data) => utf8.decode(
      LegadoJsCrypto.base64DecodeBytes(decryptB64(data)),
      allowMalformed: true);

  Uint8List _run(AsymmetricBlockCipher cipher, List<int> input) {
    try {
      return cipher.process(Uint8List.fromList(input));
    } on LegadoJsCryptoException {
      rethrow;
    } catch (e) {
      throw LegadoJsCryptoException('RSA 运算失败: $e');
    }
  }
}

/// 最小 DER（TLV）读取器，只覆盖 RSA 密钥解析所需形态。
class _Der {
  _Der(this.bytes);
  final Uint8List bytes;
  int _pos = 0;

  int _readByte() => bytes[_pos++];

  int _readLen() {
    final b = _readByte();
    if (b & 0x80 == 0) return b;
    final n = b & 0x7f;
    var len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | _readByte();
    }
    return len;
  }

  int peekTag() => bytes[_pos];

  /// 读指定 tag 的 TLV，返回内容字节。
  Uint8List read(int tag) {
    final t = _readByte();
    if (t != tag) {
      throw LegadoJsCryptoException('DER 结构不符: 期望 0x${tag.toRadixString(16)}，实际 0x${t.toRadixString(16)}');
    }
    final len = _readLen();
    final v = Uint8List.fromList(bytes.sublist(_pos, _pos + len));
    _pos += len;
    return v;
  }

  _Der readSeq() => _Der(read(0x30));

  BigInt readInt() {
    final v = read(0x02);
    // 跳过前导 0；最高位为 1 视为正数补 0。
    var start = 0;
    while (start < v.length - 1 && v[start] == 0) {
      start++;
    }
    var hexStr = '';
    for (var i = start; i < v.length; i++) {
      hexStr += v[i].toRadixString(16).padLeft(2, '0');
    }
    if (hexStr.isEmpty) return BigInt.zero;
    return BigInt.parse(hexStr, radix: 16);
  }
}

/// 对称加密句柄（isolate 内存活，经句柄 id 被 shim 复用）。
class SymmetricCipher {
  SymmetricCipher._(this._spec, this._key, this._iv);

  final ({String algo, String mode, String? padding, bool stream}) _spec;
  final Uint8List _key;
  final Uint8List? _iv;

  /// 加密/解密（base64 进出；字节约定见类注释）。
  String encryptB64(String dataB64) =>
      base64.encode(_crypt(true, LegadoJsCrypto.base64DecodeBytes(dataB64)));

  String decryptB64(String dataB64) =>
      base64.encode(_crypt(false, LegadoJsCrypto.base64DecodeBytes(dataB64)));

  String decryptStr(String dataB64) => utf8.decode(
      _crypt(false, LegadoJsCrypto.base64DecodeBytes(dataB64)),
      allowMalformed: true);

  String encryptHex(String dataB64) => LegadoJsCrypto._hexEncode(
      _crypt(true, LegadoJsCrypto.base64DecodeBytes(dataB64)));

  Uint8List _crypt(bool forEncryption, Uint8List data) {
    try {
      if (_spec.algo == 'RC4') {
        return (StreamCipher('RC4')..init(forEncryption, KeyParameter(_key)))
            .process(data);
      }
      final algo = _spec.algo;
      CipherParameters params() =>
          (_iv == null || _spec.mode == 'ECB')
              ? KeyParameter(_key)
              : ParametersWithIV<CipherParameters>(
                  KeyParameter(_key), _iv);
      if (_spec.stream) {
        // CTR/CFB 流式：任意长度，无填充。
        final stream = _streamEngine(forEncryption, params());
        return stream.process(data);
      }
      final block = BlockCipher('$algo/${_spec.mode}');
      if (_spec.padding != null) {
        final cipher = PaddedBlockCipherImpl(PKCS7Padding(), block)
          ..init(forEncryption, PaddedBlockCipherParameters(params(), null));
        return cipher.process(data);
      }
      block.init(forEncryption, params());
      if (data.length % block.blockSize != 0) {
        throw LegadoJsCryptoException(
            'NoPadding 要求块大小（${block.blockSize}）整数倍，实际 ${data.length}');
      }
      return block.process(data);
    } on LegadoJsCryptoException {
      rethrow;
    } catch (e) {
      throw LegadoJsCryptoException('${_spec.algo}/${_spec.mode} 加解密失败: $e');
    }
  }

  StreamCipher _streamEngine(bool forEncryption, CipherParameters params) {
    final algo = _spec.algo;
    if (_spec.mode == 'CTR') {
      return StreamCipher('$algo/CTR')..init(forEncryption, params);
    }
    if (_spec.mode == 'CFB') {
      // pointycastle 注册名带块位数：优先 128，回落 64（DES 块 8 字节）。
      for (final bits in const ['128', '64', '8']) {
        try {
          return StreamCipher('$algo/CFB-$bits')..init(forEncryption, params);
        } catch (_) {
          continue;
        }
      }
    }
    throw LegadoJsCryptoException('不支持的流式模式: ${_spec.mode}');
  }
}

class LegadoJsCryptoException implements Exception {
  LegadoJsCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}
