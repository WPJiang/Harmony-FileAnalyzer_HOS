/**
 * FilenameSemanticAnalyzer - 文件名语义分析器
 *
 * 判断文件名是否包含有效的语义内容，区分于：
 * - 随机字母序列（如 abcdefgh, qwertyui）
 * - 随机数字序列（如 12345678, 87654321）
 * - 时间戳序列（如 20231215, 1702345678）
 * - UUID或哈希值（如 a1b2c3d4e5f6, 550e8400e29b）
 * - 混合随机序列（如 a1b2c3d4, x7y8z9w0）
 */

/**
 * 文件名分析结果
 */
export interface FilenameAnalysisResult {
  isMeaningful: boolean;
  reason: string;
}

/**
 * FilenameSemanticAnalyzer 配置
 */
export interface FilenameAnalyzerConfig {
  minMeaningfulChars?: number;
  chineseRatioThreshold?: number;
}

export class FilenameSemanticAnalyzer {
  // 中文字符正则
  private static readonly CHINESE_PATTERN: RegExp = /[\u4e00-\u9fff]+/g;

  // 有意义的英文单词
  private static readonly MEANINGFUL_WORDS: Set<string> = new Set([
    // 文档类型
    'report', 'document', 'file', 'data', 'info', 'doc', 'docx', 'pdf', 'txt',
    'manual', 'guide', 'handbook', 'specification', 'spec', 'proposal',
    // 商务相关
    'contract', 'agreement', 'invoice', 'receipt', 'order', 'payment',
    'meeting', 'presentation', 'slides', 'proposal', 'project', 'plan',
    // 学术相关
    'paper', 'thesis', 'dissertation', 'research', 'study', 'analysis',
    'experiment', 'result', 'conclusion', 'abstract', 'summary',
    // 技术相关
    'code', 'source', 'script', 'config', 'setting', 'log', 'backup',
    'api', 'interface', 'module', 'component', 'library', 'framework',
    // 个人相关
    'resume', 'cv', 'certificate', 'diploma', 'transcript', 'photo',
    'personal', 'profile', 'application', 'letter', 'form',
    // 中文拼音（常见）
    'baogao', 'wendang', 'hetong', 'fangan', 'jihua', 'zongjie',
    'huiyi', 'peixun', 'kaoshi', 'chengji', 'zhengshu', 'jianli',
    // 其他常见
    'test', 'demo', 'sample', 'example', 'template', 'draft', 'final',
    'version', 'copy', 'original', 'new', 'old', 'backup', 'archive'
  ]);

  // 无意义模式
  private static readonly RANDOM_PATTERNS: RegExp[] = [
    /^[a-f0-9]{8,}$/i,  // 十六进制哈希
    /^[a-z]{10,}$/,  // 连续小写字母
    /^[0-9]{8,}$/,  // 连续数字
    /^[a-z]?[0-9]+[a-z]?[0-9]+[a-z]?[0-9]+/i,  // 交替数字字母
    /^[a-z]{2}[0-9]{6,}/i,  // 两字母+数字
    /^img[-_]?\d+/i,  // img + 数字
    /^image[-_]?\d+/i,  // image + 数字
    /^file[-_]?\d+/i,  // file + 数字
    /^doc[-_]?\d+/i,  // doc + 数字
    /^scan[-_]?\d+/i,  // scan + 数字
    /^untitled/i,  // untitled
    /^new\s*document/i,  // new document
    /^无标题/,  // 无标题
    /^新建/  // 新建
  ];

  // 时间戳模式
  private static readonly TIMESTAMP_PATTERNS: RegExp[] = [
    /^[12]\d{3}[01]\d[0-3]\d/,  // YYYYMMDD
    /^[12]\d{3}[-_][01]\d[-_][0-3]\d/,  // YYYY-MM-DD or YYYY_MM_DD
    /^[12]\d{3}[01]\d[0-3]\d[0-2]\d[0-5]\d/,  // YYYYMMDDHHmmss
    /^[12]\d{9}/,  // Unix timestamp (10 digits)
    /^[12]\d{8,9}[0-9]{2,3}/  // Unix timestamp with ms
  ];

  private minMeaningfulChars: number;
  private chineseRatioThreshold: number;

  constructor(config?: FilenameAnalyzerConfig) {
    this.minMeaningfulChars = config?.minMeaningfulChars ?? 3;
    this.chineseRatioThreshold = config?.chineseRatioThreshold ?? 0.3;
  }

  /**
   * 分析文件名是否有语义意义
   */
  analyze(filename: string): FilenameAnalysisResult {
    if (!filename || filename.trim().length === 0) {
      return { isMeaningful: false, reason: '空文件名' };
    }

    // 去除扩展名
    const name = this.removeExtension(filename).trim();
    if (name.length === 0) {
      return { isMeaningful: false, reason: '空文件名' };
    }

    // 1. 检查是否包含中文字符
    const chineseMatches = name.match(FilenameSemanticAnalyzer.CHINESE_PATTERN);
    if (chineseMatches) {
      const chineseChars = chineseMatches.join('');
      const chineseRatio = chineseChars.length / name.length;
      if (chineseRatio >= this.chineseRatioThreshold) {
        return { isMeaningful: true, reason: `包含有意义的中文内容: ${chineseMatches.slice(0, 3).join('')}...` };
      }
      if (chineseChars.length >= this.minMeaningfulChars) {
        return { isMeaningful: true, reason: `包含中文关键词: ${chineseMatches.slice(0, 3).join('')}...` };
      }
    }

    // 2. 检查是否有意义的英文单词
    const nameLower = name.toLowerCase();
    for (const word of FilenameSemanticAnalyzer.MEANINGFUL_WORDS) {
      if (nameLower.includes(word)) {
        return { isMeaningful: true, reason: `包含有意义词汇: ${word}` };
      }
    }

    // 3. 检查是否为已知的无意义模式
    for (const pattern of FilenameSemanticAnalyzer.RANDOM_PATTERNS) {
      if (pattern.test(name)) {
        return { isMeaningful: false, reason: `匹配无意义模式` };
      }
    }

    // 4. 检查是否为时间戳
    for (const pattern of FilenameSemanticAnalyzer.TIMESTAMP_PATTERNS) {
      if (pattern.test(name)) {
        return { isMeaningful: false, reason: '时间戳格式' };
      }
    }

    // 5. 检查随机字符序列
    if (/^\d+$/.test(name)) {
      if (name.length >= 8) {
        return { isMeaningful: false, reason: '纯数字序列（可能是ID或时间戳）' };
      }
      return { isMeaningful: true, reason: '短数字标识' };
    }

    if (this.isRandomSequence(name)) {
      return { isMeaningful: false, reason: '随机字符序列' };
    }

    if (this.isKeyboardSequence(name)) {
      return { isMeaningful: false, reason: '键盘输入序列' };
    }

    if (this.isRepeatedChars(name)) {
      return { isMeaningful: false, reason: '重复字符序列' };
    }

    // 6. 检查字符多样性
    const uniqueChars = new Set(name.toLowerCase()).size;
    if (uniqueChars < 3 && name.length > 5) {
      return { isMeaningful: false, reason: '字符多样性过低' };
    }

    // 7. 检查分隔符分隔的部分
    const parts = name.split(/[-_\s]+/);
    const meaningfulParts: string[] = [];
    for (const part of parts) {
      if (part.length >= 2 && !this.isRandomSequence(part)) {
        meaningfulParts.push(part);
      }
    }
    if (meaningfulParts.length > 0) {
      return { isMeaningful: true, reason: '包含有意义的内容片段' };
    }

    // 默认：如果长度适中且通过了随机检测，认为有一定意义
    if (name.length >= 2 && name.length <= 50 && uniqueChars >= 3) {
      return { isMeaningful: true, reason: '常规命名格式' };
    }

    return { isMeaningful: false, reason: '无法识别的命名模式' };
  }

  /**
   * 提取文件名中有意义的部分
   */
  getMeaningfulPart(filename: string): string {
    const result = this.analyze(filename);
    if (result.isMeaningful) {
      return this.removeExtension(filename);
    }

    // 尝试提取有意义的部分
    const name = this.removeExtension(filename);
    const parts = name.split(/[-_\s.]+/);

    const meaningfulParts: string[] = [];
    for (const part of parts) {
      if (part.length > 0) {
        const partResult = this.analyze(part);
        if (partResult.isMeaningful) {
          meaningfulParts.push(part);
        }
      }
    }

    return meaningfulParts.length > 0 ? meaningfulParts.join(' ') : '';
  }

  private removeExtension(filename: string): string {
    const dotIndex = filename.lastIndexOf('.');
    return dotIndex > 0 ? filename.substring(0, dotIndex) : filename;
  }

  private isRandomSequence(s: string): boolean {
    if (s.length < 4) return false;

    const sLower = s.toLowerCase();
    const hasLetter = /[a-z]/i.test(sLower);
    const hasDigit = /\d/.test(sLower);

    if (hasLetter && hasDigit) {
      // 检查交替模式
      let alternationCount = 0;
      for (let i = 0; i < sLower.length - 1; i++) {
        const currIsLetter = /[a-z]/i.test(sLower[i]);
        const nextIsLetter = /[a-z]/i.test(sLower[i + 1]);
        if (currIsLetter !== nextIsLetter) {
          alternationCount++;
        }
      }
      if (alternationCount >= sLower.length * 0.6) {
        return true;
      }
    }

    // 检查元音分布
    if (/^[a-z]+$/i.test(sLower) && sLower.length >= 4) {
      const vowels = new Set(['a', 'e', 'i', 'o', 'u']);
      let vowelCount = 0;
      for (const c of sLower) {
        if (vowels.has(c)) vowelCount++;
      }
      const vowelRatio = vowelCount / sLower.length;
      if (vowelRatio < 0.1 || vowelRatio > 0.6) {
        return true;
      }
    }

    return false;
  }

  private isKeyboardSequence(s: string): boolean {
    const sLower = s.toLowerCase();
    const keyboardSequences = [
      'qwerty', 'asdfgh', 'zxcvbn', 'qwertyuiop', 'asdfghjkl',
      '123456', '098765', 'abc123', '123abc'
    ];

    for (const seq of keyboardSequences) {
      if (sLower.includes(seq) || seq.includes(sLower)) {
        return true;
      }
    }

    return false;
  }

  private isRepeatedChars(s: string): boolean {
    if (s.length < 4) return false;

    const sLower = s.toLowerCase();

    // 检查连续相同字符
    for (let i = 0; i < sLower.length - 3; i++) {
      if (sLower[i] === sLower[i + 1] && sLower[i] === sLower[i + 2] && sLower[i] === sLower[i + 3]) {
        return true;
      }
    }

    // 检查整体重复
    const uniqueChars = new Set(sLower);
    if (uniqueChars.size === 1) {
      return true;
    }

    return false;
  }
}