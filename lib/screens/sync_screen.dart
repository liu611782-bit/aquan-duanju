import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/sync/book_sync.dart';
import '../core/sync/remote_store.dart';

/// 书库云同步：配置 WebDAV / S3，手动「备份到远端」或「从远端合并恢复」。
///
/// 恢复是**记录级合并**（进度新者胜、书签划线并集、本地书只补缺失），
/// 不会整包覆盖本地；写盘后提示重启生效。
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, this.configStore, this.storeOverride});

  final SyncConfigStore? configStore;
  final RemoteStore? storeOverride;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final SyncConfigStore _configStore =
      widget.configStore ?? SyncConfigStore();

  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _bucket = TextEditingController();
  final _region = TextEditingController(text: 'us-east-1');
  final _prefix = TextEditingController(text: 'aquan/');

  SyncBackendType _type = SyncBackendType.webdav;
  bool _busy = false;
  String _status = '';
  bool _statusError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_url, _user, _pass, _bucket, _region, _prefix]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final config = await _configStore.load();
    if (!mounted) return;
    setState(() {
      _type = config.type;
      _url.text = config.url;
      _user.text = config.username;
      _pass.text = config.password;
      _bucket.text = config.bucket;
      _region.text = config.region;
      _prefix.text = config.prefix;
    });
  }

  SyncConfig get _config => SyncConfig(
        type: _type,
        url: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        bucket: _bucket.text.trim(),
        region: _region.text.trim().isEmpty ? 'us-east-1' : _region.text.trim(),
        prefix: _prefix.text.trim(),
      );

  Future<BookSyncService?> _service() async {
    final config = _config;
    if (!config.isConfigured) {
      _fail(config.type == SyncBackendType.webdav
          ? '请先填写 WebDAV 地址'
          : '请先填写 S3 地址与 Bucket');
      return null;
    }
    await _configStore.save(config);
    final support = await getApplicationSupportDirectory();
    return BookSyncService(
      supportDir: support,
      libraryDir: Directory('${support.path}/book_library'),
      store: widget.storeOverride ?? config.buildStore(),
    );
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusError = true;
    });
  }

  void _ok(String message) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusError = false;
    });
  }

  Future<void> _run(Future<String> Function(BookSyncService service) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final service = await _service();
      if (service == null) return;
      final message = await action(service);
      _ok(message);
    } catch (e) {
      _fail(e is RemoteStoreException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isS3 = _type == SyncBackendType.s3;
    return Scaffold(
      appBar: AppBar(title: const Text('书库云同步')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          SegmentedButton<SyncBackendType>(
            segments: [
              for (final type in SyncBackendType.values)
                ButtonSegment(value: type, label: Text(type.label)),
            ],
            selected: {_type},
            onSelectionChanged: (value) =>
                setState(() => _type = value.first),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _url,
            decoration: InputDecoration(
              labelText: isS3 ? 'Endpoint（如 https://s3.example.com）' : 'WebDAV 地址',
              hintText: isS3 ? '' : 'https://dav.example.com/remote.php/dav/files/me/',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (isS3) ...[
            TextField(
              controller: _bucket,
              decoration: const InputDecoration(
                labelText: 'Bucket',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _region,
                    decoration: const InputDecoration(
                      labelText: 'Region',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _prefix,
                    decoration: const InputDecoration(
                      labelText: '对象前缀',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _user,
            decoration: InputDecoration(
              labelText: isS3 ? 'Access Key' : '用户名',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: InputDecoration(
              labelText: isS3 ? 'Secret Key' : '密码',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run((service) async {
                          await service.store.ping();
                          return '连接成功（${service.store.label}）';
                        }),
                child: const Text('测试连接'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run((service) async {
                          final path = await service.backup();
                          return '已备份到远端：$path';
                        }),
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('立即备份'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run((service) async {
                          final report = await service.restore();
                          return report.summary;
                        }),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('从远端恢复'),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _status,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _statusError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: 22),
          Text('同步内容', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '· 阅读进度（同书取较新的一条）\n'
            '· 书签与划线（按 id 取并集）\n'
            '· 本地书文件（只补远端有、本地缺的书，不覆盖已有文件）\n'
            '· 不含：在线书源配置、章节缓存、统计数据（可重算）\n\n'
            '恢复后需要重启应用才会加载新数据。',
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.7,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
