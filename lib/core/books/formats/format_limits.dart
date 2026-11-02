/// 本地导入的体积/解压上限（对齐上游 Wenku8 的分级，防 OOM 与 zip bomb）。
library;

const int kTxtByteLimit = 128 * 1024 * 1024; // 128 MiB
const int kArchiveByteLimit = 512 * 1024 * 1024; // epub / zip 512 MiB
const int kMarkupByteLimit = 32 * 1024 * 1024; // html / md 32 MiB

/// 压缩包解压总量上限（zip bomb 防护）。
const int kUnzipTotalByteLimit = 1024 * 1024 * 1024; // 1 GiB

/// 单本最大章节数（超出截断并提示，防止目录页爆炸）。
const int kMaxChapters = 10000;

/// 章节标题最大长度（超长行不当标题）。
const int kMaxHeadingLength = 90;

/// 格式 → 字节上限。
int byteLimitForExtension(String ext) {
  switch (ext) {
    case 'txt':
      return kTxtByteLimit;
    case 'epub':
    case 'zip':
      return kArchiveByteLimit;
    case 'html':
    case 'htm':
    case 'xhtml':
    case 'md':
    case 'markdown':
      return kMarkupByteLimit;
    default:
      return kMarkupByteLimit;
  }
}
