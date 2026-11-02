import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// RSA 测试密钥夹具：固定种子生成 + 最小 DER 编码（SPKI 公钥 / PKCS#1 私钥 PEM）。
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

Uint8List derInt(BigInt v) {
  var hexStr = v.toRadixString(16);
  if (hexStr.length.isOdd) hexStr = '0$hexStr';
  final bytes = <int>[];
  for (var i = 0; i < hexStr.length; i += 2) {
    bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
  }
  if (bytes.isNotEmpty && bytes.first & 0x80 != 0) bytes.insert(0, 0);
  if (bytes.isEmpty) bytes.add(0);
  return derTlv(0x02, bytes);
}

String pemPublic(List<int> der) =>
    '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n-----END PUBLIC KEY-----';

String pemPrivate(List<int> der) =>
    '-----BEGIN RSA PRIVATE KEY-----\n${base64.encode(der)}\n-----END RSA PRIVATE KEY-----';

(RSAPublicKey, RSAPrivateKey) rsaTestKeygen() {
  final secureRandom = FortunaRandom();
  final seed = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    seed[i] = i;
  }
  secureRandom.seed(KeyParameter(seed));
  final gen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 1024, 64),
        secureRandom));
  final pair = gen.generateKeyPair();
  return (pair.publicKey as RSAPublicKey, pair.privateKey as RSAPrivateKey);
}

/// SPKI 公钥 PEM（pointycastle 密钥对 → PEM）。
String rsaPublicPem(RSAPublicKey pub) {
  final alg = derTlv(0x30, [
    ...derTlv(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]),
    ...derTlv(0x05, <int>[]),
  ]);
  final rsaPub = derTlv(0x30, [...derInt(pub.modulus!), ...derInt(pub.exponent!)]);
  final spki = derTlv(0x30, [...alg, ...derTlv(0x03, [0, ...rsaPub])]);
  return pemPublic(spki);
}

/// PKCS#1 私钥 PEM。
String rsaPrivatePem(RSAPrivateKey priv) {
  final der = derTlv(0x30, [
    ...derInt(BigInt.zero),
    ...derInt(priv.modulus!),
    ...derInt(priv.exponent!),
    ...derInt(priv.privateExponent!),
    ...derInt(priv.p ?? BigInt.one),
    ...derInt(priv.q ?? BigInt.one),
  ]);
  return pemPrivate(der);
}
