/// 朗读流式合成：把一章正文切成**合成单元**并按序流式产出
/// （`11-02-listen-tts-streaming` S2）。
///
/// 设计要点：
/// - **单元 = 段落合并到 ≥ [minChars]**：在线语音每段一次网络往返，切太细会把
///   请求数放大到限速区；太粗又失去「首段先出」的意义。
/// - **首单元不排队**：先发第一段，播放在它返回时即可开始。
/// - **并发 2**：再多容易触发在线服务限流（实测 Edge/微软接口）。
/// - **按序产出**：可以并行合成，但对外严格按单元序号 yield，播放器不用处理乱序。
/// - **可取消**：每步检查 `isCancelled`，过期立即停止（epoch 语义由调用方提供）。
library;

import 'dart:async';
import 'dart:typed_data';

/// 一个合成单元。
class TtsUnit {
  const TtsUnit({required this.index, required this.text});

  final int index;
  final String text;

  @override
  String toString() => 'TtsUnit($index, ${text.length}字)';
}

/// 单元合成结果。
class UnitProduct {
  const UnitProduct({
    required this.index,
    required this.text,
    required this.audio,
    required this.durationMs,
  });

  final int index;
  final String text;
  final Uint8List audio;

  /// 由合成层给出（拿不到就 0，调用方按音频实测补）。
  final int durationMs;
}

/// 单段合成回调：入参是单元文本，返回音频字节。
typedef UnitSynthesizer = Future<Uint8List> Function(
  String text, {
  Duration? timeout,
});

/// 把段落按「合并到 ≥ minChars」切成单元；超长段落再按 [maxChars] 硬切。
///
/// 返回顺序与原段落一致，空段落直接丢弃。
List<TtsUnit> mergeIntoTtsUnits(
  List<String> paragraphs, {
  int minChars = 120,
  int maxChars = 600,
}) {
  final out = <TtsUnit>[];
  final buffer = StringBuffer();
  var bufferLen = 0;
  var index = 0;

  void flush() {
    final text = buffer.toString().trim();
    buffer.clear();
    bufferLen = 0;
    if (text.isEmpty) return;
    // 超长单元再切：单次请求体太大同样会超时/被拒。
    for (var start = 0; start < text.length; start += maxChars) {
      final end = (start + maxChars).clamp(0, text.length);
      final piece = text.substring(start, end).trim();
      if (piece.isEmpty) continue;
      out.add(TtsUnit(index: index++, text: piece));
    }
  }

  for (final raw in paragraphs) {
    final text = raw.trim();
    if (text.isEmpty) continue;
    if (bufferLen > 0) {
      buffer.write('\n');
      bufferLen += 1;
    }
    buffer.write(text);
    bufferLen += text.length;
    if (bufferLen >= minChars) flush();
  }
  flush();
  return out;
}

/// 流式合成：按序产出每个单元的音频。
///
/// [isCancelled] 由调用方注入（通常是 `epoch != _epoch`）。取消后不再发起新请求，
/// 已发出的请求结果直接丢弃。
Stream<UnitProduct> produceUnits({
  required List<TtsUnit> units,
  required UnitSynthesizer synthesize,
  bool Function()? isCancelled,
  int concurrency = 2,
  Duration? perUnitTimeout,
}) async* {
  if (units.isEmpty) return;
  bool cancelled() => isCancelled?.call() ?? false;

  final width = concurrency < 1 ? 1 : concurrency;
  final pending = <int, Future<UnitProduct>>{};

  Future<UnitProduct> launch(TtsUnit unit) async {
    final audio = await synthesize(unit.text, timeout: perUnitTimeout);
    return UnitProduct(
      index: unit.index,
      text: unit.text,
      audio: audio,
      durationMs: 0,
    );
  }

  var next = 0;
  // 先填满并发槽（含首单元：它排在最前，返回即可播）。
  while (next < units.length && pending.length < width) {
    if (cancelled()) return;
    pending[next] = launch(units[next]);
    next++;
  }

  for (var i = 0; i < units.length; i++) {
    final task = pending.remove(i);
    if (task == null) return; // 被取消
    final product = await task;
    if (cancelled()) return;
    yield product;
    // 补一个槽位，保持流水线不断。
    while (next < units.length && pending.length < width) {
      if (cancelled()) return;
      pending[next] = launch(units[next]);
      next++;
    }
  }
}
