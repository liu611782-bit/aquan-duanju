import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/legado_js/legado_js_crypto.dart';

import 'rsa_test_keys.dart';

/// legado js 宿主面的纯 Dart 加解密/编码单测（无 QuickJS 依赖，常驻全量）。
void main() {
  group('摘要', () {
    test('md5Encode 已知向量', () {
      expect(LegadoJsCrypto.md5Encode('abc'),
          '900150983cd24fb0d6963f7d28e17f72');
      expect(LegadoJsCrypto.md5Encode(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });
    test('md5Encode16 取中间 16 位', () {
      expect(LegadoJsCrypto.md5Encode16('abc'),
          '900150983cd24fb0d6963f7d28e17f72'.substring(8, 24));
    });
    test('digestHex / HMacHex 已知向量', () {
      expect(LegadoJsCrypto.digestHex('abc', 'SHA-256'),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          LegadoJsCrypto.hmacHex('hello', 'HmacSHA256', 'key'),
          crypto.Hmac(crypto.sha256, utf8.encode('key'))
              .convert(utf8.encode('hello'))
              .toString());
      expect(LegadoJsCrypto.digestHex('x', 'HmacSHA256'), isNotEmpty);
    });
  });

  group('编码', () {
    test('base64 / hex 往返', () {
      expect(LegadoJsCrypto.base64EncodeStr('斗罗'),
          base64.encode(utf8.encode('斗罗')));
      expect(LegadoJsCrypto.base64DecodeStr('5paX572X'), '斗罗');
      expect(LegadoJsCrypto.hexEncodeToString('AB'), '4142');
      expect(LegadoJsCrypto.hexDecodeToString('4142'), 'AB');
    });
    test('url-safe base64 容错', () {
      expect(LegadoJsCrypto.base64DecodeBytes('-_8'), [0xFB, 0xFF]);
    });
  });

  group('对称加解密', () {
    test('AES/CBC/PKCS5Padding 往返（utf8 key/iv）', () {
      final c = LegadoJsCrypto.createSymmetricCrypto(
          'AES/CBC/PKCS5Padding', '0123456789abcdef', 'abcdef9876543210');
      final data = base64.encode(utf8.encode('斗破苍穹 第一章'));
      final enc = c.encryptB64(data);
      expect(enc, isNot(data));
      expect(utf8.decode(base64.decode(c.decryptB64(enc))), '斗破苍穹 第一章');
    });
    test('AES/ECB/PKCS5Padding 往返', () {
      final c = LegadoJsCrypto.createSymmetricCrypto(
          'AES/ECB/PKCS5Padding', 'abcdefghijklmnop', '');
      final data = base64.encode(utf8.encode('plain text 123'));
      final enc = c.encryptB64(data);
      expect(utf8.decode(base64.decode(c.decryptB64(enc))), 'plain text 123');
    });
    test('AES/CTR/NoPadding 往返', () {
      final c = LegadoJsCrypto.createSymmetricCrypto(
          'AES/CTR/NoPadding', '0123456789abcdef', 'AAAABBBBCCCCDDDD');
      final data = base64.encode(utf8.encode('ctr 任意长度文本'));
      expect(utf8.decode(base64.decode(c.decryptB64(c.encryptB64(data)))),
          'ctr 任意长度文本');
    });
    test('key 为 base64（ByteArray 约定）时按解码字节', () {
      // base64 键解码后的字节与「等值 utf8 键」一致 → 产出相同密文。
      final a = LegadoJsCrypto.createSymmetricCrypto('AES/ECB/PKCS5Padding',
          base64.encode(utf8.encode('abcdefghijklmnop')), '');
      final b = LegadoJsCrypto.createSymmetricCrypto(
          'AES/ECB/PKCS5Padding', 'abcdefghijklmnop', '');
      final data = base64.encode(utf8.encode('same plaintext'));
      expect(a.encryptB64(data), b.encryptB64(data));
    });
    test('RC4 往返', () {
      final c = LegadoJsCrypto.createSymmetricCrypto('RC4', 'secretkey', '');
      final data = base64.encode(utf8.encode('rc4 stream'));
      expect(utf8.decode(base64.decode(c.decryptB64(c.encryptB64(data)))),
          'rc4 stream');
    });
    test('未知算法诚实报错', () {
      expect(
          () => LegadoJsCrypto.createSymmetricCrypto(
              'SM4/CBC/PKCS5Padding', 'k', 'i'),
          throwsA(isA<LegadoJsCryptoException>()));
    });
  });

  group('GBK', () {
    test('strToBytes/bytesToStr 往返', () {
      final bytes = LegadoJsCrypto.strToBytes('斗破', 'gbk');
      expect(LegadoJsCrypto.bytesToStr(bytes, 'gbk'), '斗破');
      expect(
          LegadoJsCrypto.bytesToStr(
              LegadoJsCrypto.strToBytes('x', 'utf-8'), 'utf-8'),
          'x');
    });
  });

  group('timeFormat', () {
    test('常见段', () {
      final out = LegadoJsCrypto.timeFormat('yyyy-MM-dd HH:mm:ss',
          DateTime(2026, 11, 2, 9, 5, 3).millisecondsSinceEpoch ~/ 1000);
      expect(out, '2026-11-02 09:05:03');
    });
  });

  group('RSA', () {
    String pem(List<int> der) =>
        '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n-----END PUBLIC KEY-----';

    String privPemOf(List<int> der) =>
        '-----BEGIN RSA PRIVATE KEY-----\n${base64.encode(der)}\n-----END RSA PRIVATE KEY-----';


    Uint8List derTlv(int tag, List<int> content) {
      final head = <int>[tag];
      final len = content.length;
      if (len < 0x80) {
        head.add(len);
      } else {
        final bytes = <int>[];
        var v = len;
        while (v > 0) {
          bytes.insert(0, v & 0xff);
          v >>= 8;
        }
        head.add(0x80 | bytes.length);
        head.addAll(bytes);
      }
      return Uint8List.fromList([...head, ...content]);
    }


    test('PEM/DER 公私钥解析 + PKCS1 加解密往返', () {
      final (pub, priv) = rsaTestKeygen();
      // SPKI：SEQ(SEQ(OID, NULL), BITSTRING(SEQ(INT n, INT e)))。
      final alg = derTlv(0x30, [
        ...derTlv(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]),
        ...derTlv(0x05, <int>[]),
      ]);
      final rsaPub =
          derTlv(0x30, [...derInt(pub.modulus!), ...derInt(pub.exponent!)]);
      final spki = derTlv(0x30, [...alg, ...derTlv(0x03, [0, ...rsaPub])]);
      final (n, e) = LegadoJsCrypto.parseRsaPublicKey(pem(spki));
      expect(n, pub.modulus);
      expect(e, pub.exponent);

      // PKCS#1 私钥：SEQ(INT 0, INT n, INT e, INT d, INT p, INT q)。
      final pkcs1Priv = derTlv(0x30, [
        ...derInt(BigInt.zero),
        ...derInt(priv.modulus!),
        ...derInt(priv.exponent!),
        ...derInt(priv.privateExponent!),
        ...derInt(priv.p ?? BigInt.one),
        ...derInt(priv.q ?? BigInt.one),
      ]);
      final (n2, d2, p2, q2) =
          LegadoJsCrypto.parseRsaPrivateKey(privPemOf(pkcs1Priv));
      expect(n2, priv.modulus);
      expect(d2, priv.privateExponent);
      expect(p2, priv.p);
      expect(q2, priv.q);

      final cipher =
          LegadoJsCrypto.createAsymmetricCrypto('RSA/ECB/PKCS1Padding')
            ..setPublicKey(pem(spki))
            ..setPrivateKey(privPemOf(pkcs1Priv));
      const plain = '被 RSA 加密的正文!';
      final enc = cipher.encryptB64(plain);
      expect(enc, isNot(plain));
      expect(cipher.decryptStr(enc), plain);
    });

    test('hex modulus,exponent 形态解析', () {
      final (n, e) = LegadoJsCrypto.parseRsaPublicKey('C1A3,10001');
      expect(n, BigInt.parse('C1A3', radix: 16));
      expect(e, BigInt.parse('10001', radix: 16));
    });

    test('非法材料诚实报错 + OAEP 明确不支持', () {
      expect(() => LegadoJsCrypto.parseRsaPublicKey('!!!not-base64!!!'),
          throwsA(isA<LegadoJsCryptoException>()));
      expect(() => LegadoJsCrypto.createAsymmetricCrypto('RSA/OAEP'),
          throwsA(isA<LegadoJsCryptoException>()));
    });
  });
}
