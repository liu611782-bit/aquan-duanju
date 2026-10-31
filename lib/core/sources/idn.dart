/// IDN（国际化域名）→ ASCII（Punycode, RFC 3492）。
///
/// 真实源里的中文域名（如 `c.小胡.icu`）常以百分号编码形态出现
/// （`c.%E5%B0%8F%E8%83%A1.icu`）：`Uri.parse` 能解析，但 **Socket 连接层**
/// 会把 host 里的 `%` 当 IPv6 scope 报「not a valid link-local address」。
/// 请求前用 [uriForRequest] 把 host 转成 xn-- ASCII 即可。
library;

/// 把 URL 的 host 转成 ASCII（Punycode）形态；已是 ASCII 原样返回。
Uri uriForRequest(String url) {
  final uri = Uri.parse(url);
  final host = uri.host;
  final nonAscii = RegExp(r'[^\x00-\x7F]');
  if (!host.contains('%') && !nonAscii.hasMatch(host)) return uri;
  final ascii = host.split('.').map((label) {
    final isAscii = !label.contains('%') && !nonAscii.hasMatch(label);
    if (isAscii || label.toLowerCase().startsWith('xn--')) {
      return label.toLowerCase();
    }
    final decoded = label.contains('%') ? Uri.decodeComponent(label) : label;
    return 'xn--${punycodeEncode(decoded)}';
  }).join('.');
  return uri.replace(host: ascii);
}

/// RFC 3492 Punycode 编码（纯 ASCII 输入原样返回）。
String punycodeEncode(String input) {
  const base = 36,
      tMin = 1,
      tMax = 26,
      skew = 38,
      damp = 700,
      initialBias = 72,
      initialN = 0x80;

  String digit(int d) =>
      d < 26 ? String.fromCharCode(0x61 + d) : String.fromCharCode(0x30 + d - 26);

  int adapt(int delta, int numPoints, bool firstTime) {
    delta = firstTime ? delta ~/ damp : delta ~/ 2;
    delta += delta ~/ numPoints;
    var k = 0;
    while (delta > ((base - tMin) * tMax) ~/ 2) {
      delta ~/= base - tMin;
      k += base;
    }
    return k + (((base - tMin + 1) * delta) ~/ (delta + skew));
  }

  // IDNA 惯例：先转小写（'München' → 'mnchen-3ya'，而非 'Mnchen-3ya'）。
  final runes = input.toLowerCase().runes.toList();
  final output = StringBuffer();
  final basic = runes.where((c) => c < 0x80).toList();
  var b = basic.length;
  var h = b;
  if (b > 0) output.write(String.fromCharCodes(basic));
  if (b == runes.length) return output.toString();
  if (b > 0) output.write('-');

  var n = initialN;
  var delta = 0;
  var bias = initialBias;
  while (h < runes.length) {
    final m = runes.where((c) => c >= n).reduce((a, b) => a < b ? a : b);
    delta += (m - n) * (h + 1);
    n = m;
    for (final c in runes) {
      if (c < n) delta++;
      if (c == n) {
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias
              ? tMin
              : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          output.write(digit(t + ((q - t) % (base - t))));
          q = (q - t) ~/ (base - t);
        }
        output.write(digit(q));
        bias = adapt(delta, h + 1, h == b);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}
