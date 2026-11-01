import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/error_log.dart';
import '../core/bili/bili_adapter.dart';
import '../core/bili/session.dart';
import '../core/sources/source_adapter.dart';
import '../widgets/common.dart';
import 'media_hub_screen.dart' show SourceCover;
import 'source_detail_screen.dart';
import 'source_player_screen.dart' show ResolvedPlay;

/// B 站主页：登录门（扫码）→ 推荐 feed + 搜索 → 复用统一详情/播放链路。
class BiliHomeScreen extends StatefulWidget {
  const BiliHomeScreen({super.key});

  @override
  State<BiliHomeScreen> createState() => _BiliHomeScreenState();
}

class _BiliHomeScreenState extends State<BiliHomeScreen> {
  final BiliSession session = BiliSession();
  late final BiliAdapter adapter = BiliAdapter(session);

  final _feed = <UnifiedSeries>[];
  final _searchResults = <UnifiedSeries>[];
  final _searchController = TextEditingController();

  bool _loading = true;
  bool _searching = false;
  String? _error;
  String _accountName = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _loading = true);
    await session.load();
    if (session.isLoggedIn) {
      try {
        final account = await session.fetchAccount();
        _accountName = account?.username ?? '';
      } catch (_) {}
      await _loadFeed();
    } else {
      try {
        await session.ensureRiskParams();
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFeed() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await adapter.list(categoryId: 'rcmd', page: 1);
      if (!mounted) return;
      setState(() {
        _feed
          ..clear()
          ..addAll(page.items);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() => _searching = true);
    try {
      final events = await adapter.search(query).toList();
      final hits = events.whereType<SourceHits>().toList();
      if (!mounted) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll([for (final h in hits) ...h.items]);
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '搜索失败：$e';
      });
    }
  }

  Future<void> _openDetail(UnifiedSeries series) async {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourceDetailScreen(
        source: BiliAdapter.config(),
        series: series,
        adapter: adapter,
        resolvePlay: (ep) async {
          final r = await adapter.resolvePlay(ep.url);
          return ResolvedPlay(
              videoUrl: r.videoUrl,
              audioUrl: r.audioUrl,
              notice: r.isPreview ? (r.previewHint ?? '试看内容，完整版需要登录/大会员') : null);
        },
        loadDanmaku: (ep) => adapter.loadDanmaku(ep.url),
        onSendDanmaku: session.isLoggedIn
            ? (ep, msg) => adapter.sendDanmaku(ep.url, msg)
            : null,
      ),
    ));
  }

  Future<void> _showLoginSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => _BiliLoginSheet(session: session),
    );
    await _bootstrap();
  }

  Future<void> _logout() async {
    await session.logout();
    if (mounted) {
      setState(() {
        _accountName = '';
        _feed.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _searchController.text.trim().isEmpty ? _feed : _searchResults;
    return Scaffold(
      appBar: AppBar(
        title: const Text('哔哩哔哩'),
        actions: [
          IconButton(
            tooltip: _accountName.isEmpty ? '扫码登录' : '退出登录',
            icon: Icon(_accountName.isEmpty ? Icons.login : Icons.logout),
            onPressed: _accountName.isEmpty ? _showLoginSheet : _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索视频 / 番剧（WBI 签名 + buvid 风控）',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _search,
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                if (v.isEmpty && mounted) setState(() => _searchResults.clear());
              },
            ),
          ),
          if (_accountName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('已登录：$_accountName',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ),
            )
          else
            // 未登录：推荐 feed 注定为空，给显眼引导而不是只报"推荐加载为空"。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 18, color: theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '未登录：推荐不可用，可先搜索；登录后可看推荐与发弹幕',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _showLoginSheet,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('扫码登录'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: LoadView(
              loading: _loading || _searching,
              error: _error,
              onRetry: _searchController.text.trim().isEmpty ? _loadFeed : _search,
              empty: results.isEmpty,
              emptyText: _searchController.text.trim().isEmpty
                  ? '推荐加载为空，试试搜索'
                  : '没有找到相关内容',
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  childAspectRatio: 0.62,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final item = results[index];
                  return InkWell(
                    onTap: () => _openDetail(item),
                    borderRadius: BorderRadius.circular(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SourceCover(url: item.coverUrl, fit: BoxFit.cover),
                        ),
                        const SizedBox(height: 6),
                        Text(item.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        Text(item.remarks,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 扫码登录：二维码 + 状态轮询（2s 一次，过期可刷新）。
class _BiliLoginSheet extends StatefulWidget {
  const _BiliLoginSheet({required this.session});

  final BiliSession session;

  @override
  State<_BiliLoginSheet> createState() => _BiliLoginSheetState();
}

class _BiliLoginSheetState extends State<_BiliLoginSheet> {
  String? _qrData;
  String? _qrcodeKey;
  String _status = '正在生成二维码…';
  Timer? _pollTimer;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  DateTime _qrGeneratedAt = DateTime.now();

  Future<void> _generate() async {
    setState(() {
      _expired = false;
      _status = '正在生成二维码…';
    });
    try {
      final (url, key) = await widget.session.createQrLogin();
      if (!mounted) return;
      setState(() {
        _qrData = url;
        _qrcodeKey = key;
        _qrGeneratedAt = DateTime.now();
        _status = '用 B 站 App 扫码登录';
      });
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      if (mounted) setState(() => _status = '二维码生成失败：$e');
    }
  }

  Future<void> _poll() async {
    if (_qrcodeKey == null) return;
    try {
      final poll = await widget.session.pollQrLogin(_qrcodeKey!);
      if (!mounted) return;
      switch (poll.state) {
        case BiliQrState.confirmed:
          _pollTimer?.cancel();
          setState(() => _status = '登录成功');
          if (mounted) Navigator.of(context).pop();
        case BiliQrState.scanned:
          setState(() => _status = '已扫码，请在手机上确认');
        case BiliQrState.expired:
          _pollTimer?.cancel();
          // 刚生成的二维码不可能立刻过期：多半是风控/接口异常把它伪装成了
          // 过期（用户实测「二维码 2 秒后消失」）。不清码、按失败给刷新出口。
          final tooFresh =
              DateTime.now().difference(_qrGeneratedAt) <
              const Duration(seconds: 60);
          setState(() {
            _expired = true;
            _status = tooFresh
                ? '轮询异常（可能被风控），点「刷新二维码」重试'
                : '二维码已过期';
          });
        case BiliQrState.waiting:
          break;
        case BiliQrState.failed:
          _pollTimer?.cancel();
          setState(() => _status = '登录失败，请重试');
      }
    } catch (e, stack) {
      // 之前空吞：轮询异常时用户只看到「二维码 2 秒后没了」，无任何证据。
      ErrorLog.instance.record('B站扫码', e, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('扫码登录哔哩哔哩', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('网页端二维码登录，无需 appkey；Cookie 仅存本机',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 16),
            if (_qrData != null && !_expired)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(data: _qrData!, size: 200),
              )
            else
              Container(
                width: 216,
                height: 216,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_status),
              ),
            const SizedBox(height: 12),
            Text(_status),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_expired)
                  FilledButton.tonal(
                      onPressed: _generate, child: const Text('刷新二维码')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
