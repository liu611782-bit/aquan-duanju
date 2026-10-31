import 'cms_json_adapter.dart';
import 'source_adapter.dart';
import 'fongmi/fongmi_spider_adapter.dart';

/// 统一源适配器工厂：按 [SourceConfig.kind] 选择实现。
///
/// - cmsJson/cmsXml → [CmsJsonAdapter]
/// - spiderJs → [FongmiSpiderAdapter]（口味自动检测：CatVod 长名 / FongMi 短名）
/// - spider（jar/JVM 族）→ null（暂不支持，UI 跳过）
SourceAdapter? buildSourceAdapter(SourceConfig config) {
  switch (config.kind) {
    case SourceKind.cmsJson:
    case SourceKind.cmsXml:
      return CmsJsonAdapter(config);
    case SourceKind.spiderJs:
      return FongmiSpiderAdapter(config);
    case SourceKind.spider:
      return null;
  }
}
