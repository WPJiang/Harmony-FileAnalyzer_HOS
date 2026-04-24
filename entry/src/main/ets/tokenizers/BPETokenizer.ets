import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

/**
 * BPE (Byte Pair Encoding) Tokenizer
 * 用于 MiniLM 模型的文本分词
 * 支持从 vocab_full.json 加载 BERT 格式词汇表
 *
 * 使用 BERT 标准特殊 token ID (与 vocab_full.json 行号对应)
 * [PAD]=0, [UNK]=100, [CLS]=101, [SEP]=102, [MASK]=103
 */
export class BPETokenizer {
  // 特殊 token ID (BERT/MiniLM 标准格式)
  private static readonly CLS_TOKEN_ID: number = 101;   // [CLS] 句子开始
  private static readonly SEP_TOKEN_ID: number = 102;   // [SEP] 句子结束
  private static readonly PAD_TOKEN_ID: number = 0;     // [PAD] 填充
  private static readonly UNK_TOKEN_ID: number = 100;   // [UNK] 未知词
  private static readonly MASK_TOKEN_ID: number = 103;  // [MASK] [MASK]

  // 最大序列长度
  private maxSeqLength: number = 512;

  // 词汇表: token -> id
  private vocab: Map<string, number> = new Map();

  // 反向词汇表: id -> token
  private idToToken: Map<number, string> = new Map();

  // BPE 合并规则
  private merges: Map<string, number> = new Map();

  // 是否已加载
  private loaded: boolean = false;

  /**
   * 加载词汇表和 tokenizer 配置
   * @param context UIAbility 上下文
   * @param vocabPath vocab.json 文件路径
   * @param mergesPath merges.txt 文件路径 (可选)
   */
  async load(context: common.Context, vocabPath: string, mergesPath?: string): Promise<boolean> {
    try {
      // 1. 加载 vocab.json
      const vocabLoaded = await this.loadVocabulary(context, vocabPath);
      if (!vocabLoaded) {
        console.error('BPETokenizer: Failed to load vocabulary');
        return false;
      }

      // 2. 加载 merges.txt (如果提供)
      if (mergesPath) {
        await this.loadMerges(context, mergesPath);
      }

      this.loaded = true;
      console.info('BPETokenizer: Loaded successfully, vocab size:', this.vocab.size);
      return true;
    } catch (error) {
      console.error('BPETokenizer.load failed:', error);
      return false;
    }
  }

  /**
   * 加载词汇表
   * 支持多种格式:
   * 1. tokenizer.json 格式 (vocab 是 [token, score] 数组)
   * 2. JSON 格式 (token -> id 映射)
   * 3. 纯文本格式 (每行一个 token, 行号 = ID)
   */
  private async loadVocabulary(context: common.Context, vocabPath: string): Promise<boolean> {
    try {
      const resourceMgr = context.resourceManager;
      const vocabBuffer = await resourceMgr.getRawFileContent(vocabPath);

      if (!vocabBuffer || vocabBuffer.byteLength === 0) {
        return false;
      }

      // 转换为字符串
      const decoder = new util.TextDecoder('utf-8');
      const vocabText = decoder.decodeToString(new Uint8Array(vocabBuffer));

      // 构建映射
      this.vocab.clear();
      this.idToToken.clear();

      // 检测格式
      const trimmed = vocabText.trim();
      if (trimmed.startsWith('{"version"') || trimmed.includes('"vocab":')) {
        // tokenizer.json 格式 (XLM-RoBERTa/SentenceTransformer)
        // 定义接口类型，避免 ArkTS 索引访问限制
        interface TokenizerModelType {
          vocab: Array<[string, number]>;
        }

        interface AddedTokenType {
          id: number;
          content: string;
          special: boolean;
        }

        interface TokenizerJsonType {
          model: TokenizerModelType;
          added_tokens: AddedTokenType[];
        }

        const tokenizerJson: TokenizerJsonType = JSON.parse(vocabText);

        // vocab 是 [token, score] 数组，数组索引 = token ID
        if (tokenizerJson.model && tokenizerJson.model.vocab) {
          const vocabArray = tokenizerJson.model.vocab;
          for (let i = 0; i < vocabArray.length; i++) {
            const item = vocabArray[i];
            const token = item[0];  // item = [token, score]
            this.vocab.set(token, i);
            this.idToToken.set(i, token);
          }
          console.info(`BPETokenizer: Loaded vocab from tokenizer.json, size: ${this.vocab.size}`);
        }

        // 加载 added_tokens (特殊 token)
        if (tokenizerJson.added_tokens) {
          const addedTokens = tokenizerJson.added_tokens;
          for (const item of addedTokens) {
            const id = item.id;
            const content = item.content;
            this.vocab.set(content, id);
            this.idToToken.set(id, content);
          }
          console.info(`BPETokenizer: Loaded added_tokens, count: ${addedTokens.length}`);
        }
      } else if (trimmed.startsWith('{')) {
        // JSON 格式 (token -> id)
        const vocabEntries: [string, number][] = Object.entries(JSON.parse(vocabText));
        for (const entry of vocabEntries) {
          const token: string = entry[0];
          const id: number = entry[1];
          this.vocab.set(token, id);
          this.idToToken.set(id, token);
        }
        console.info(`BPETokenizer: Loaded vocab from JSON (token->id), size: ${this.vocab.size}`);
      } else {
        // 纯文本格式 (BERT vocab: 每行一个 token, 行号 = ID)
        const lines = vocabText.split('\n');
        for (let i = 0; i < lines.length; i++) {
          const token = lines[i].trim();
          if (token.length > 0) {
            this.vocab.set(token, i);
            this.idToToken.set(i, token);
          }
        }
        console.info(`BPETokenizer: Loaded vocab from text file, size: ${this.vocab.size}`);
      }

      return this.vocab.size > 0;
    } catch (error) {
      console.error('BPETokenizer.loadVocabulary failed:', error);
      return false;
    }
  }

  /**
   * 加载 BPE 合并规则
   */
  private async loadMerges(context: common.Context, mergesPath: string): Promise<boolean> {
    try {
      const resourceMgr = context.resourceManager;
      const mergesBuffer = await resourceMgr.getRawFileContent(mergesPath);

      if (!mergesBuffer || mergesBuffer.byteLength === 0) {
        return false;
      }

      const decoder = new util.TextDecoder('utf-8');
      const mergesText = decoder.decodeToString(new Uint8Array(mergesBuffer));
      const lines = mergesText.split('\n');

      this.merges.clear();
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line.length > 0) {
          this.merges.set(line, i);
        }
      }

      return true;
    } catch (error) {
      console.error('BPETokenizer.loadMerges failed:', error);
      return false;
    }
  }

  /**
   * 文本分词
   * @param text 输入文本
   * @returns token ID 数组
   */
  tokenize(text: string): number[] {
    if (!this.loaded) {
      console.warn('BPETokenizer: Not loaded, returning empty tokens');
      return [BPETokenizer.CLS_TOKEN_ID, BPETokenizer.SEP_TOKEN_ID];
    }

    // 1. 基础预处理
    const normalizedText = this.normalize(text);

    // 2. 分词
    const tokens = this.tokenizeText(normalizedText);

    // 3. 转换为 ID
    const tokenIds: number[] = [BPETokenizer.CLS_TOKEN_ID];

    for (const token of tokens) {
      const id = this.vocab.get(token);
      tokenIds.push(id !== undefined ? id : BPETokenizer.UNK_TOKEN_ID);

      // 检查最大长度
      if (tokenIds.length >= this.maxSeqLength - 1) {
        break;
      }
    }

    // 4. 添加 SEP token
    tokenIds.push(BPETokenizer.SEP_TOKEN_ID);

    // 5. 填充到固定长度
    while (tokenIds.length < this.maxSeqLength) {
      tokenIds.push(BPETokenizer.PAD_TOKEN_ID);
    }

    return tokenIds.slice(0, this.maxSeqLength);
  }

  /**
   * 文本标准化
   */
  private normalize(text: string): string {
    // 转小写
    let normalized = text.toLowerCase();

    // 移除多余空白
    normalized = normalized.replace(/\s+/g, ' ').trim();

    // 处理特殊字符
    normalized = normalized.replace(/[""]/g, '"');
    normalized = normalized.replace(/['']/g, "'");

    return normalized;
  }

  /**
   * 文本分词实现
   */
  private tokenizeText(text: string): string[] {
    const tokens: string[] = [];

    // 使用正则表达式分割
    const pattern = /\w+|[^\w\s]|\s+/g;
    let match: RegExpExecArray | null;

    while ((match = pattern.exec(text)) !== null) {
      const word = match[0];

      // 尝试在词汇表中找到
      if (this.vocab.has(word)) {
        tokens.push(word);
      } else {
        // 应用 BPE 或字符级分割
        const subTokens = this.bpeEncode(word);
        tokens.push(...subTokens);
      }
    }

    return tokens;
  }

  /**
   * BPE 编码
   */
  private bpeEncode(word: string): string[] {
    // 如果词汇表中有完整词，直接返回
    if (this.vocab.has(word)) {
      return [word];
    }

    // 将词分割为字符
    const chars = word.split('');
    const tokens: string[] = [];

    // 尝试查找子词
    let i = 0;
    while (i < chars.length) {
      let found = false;

      // 尝试匹配更长的子串
      for (let len = Math.min(chars.length - i, 10); len >= 1; len--) {
        const subWord = chars.slice(i, i + len).join('');

        // 检查不带前缀的子词
        if (this.vocab.has(subWord)) {
          tokens.push(subWord);
          i += len;
          found = true;
          break;
        }

        // 检查带 ## 前缀的子词
        const prefixedSubWord = '##' + subWord;
        if (i > 0 && this.vocab.has(prefixedSubWord)) {
          tokens.push(prefixedSubWord);
          i += len;
          found = true;
          break;
        }
      }

      if (!found) {
        // 单个字符作为 UNK
        tokens.push(chars[i]);
        i++;
      }
    }

    return tokens;
  }

  /**
   * 创建注意力掩码
   */
  createAttentionMask(tokenIds: number[]): number[] {
    const mask: number[] = [];
    for (const id of tokenIds) {
      mask.push(id === BPETokenizer.PAD_TOKEN_ID ? 0 : 1);
    }
    return mask;
  }

  /**
   * 解码 token IDs 为文本
   */
  decode(tokenIds: number[]): string {
    const tokens: string[] = [];

    for (const id of tokenIds) {
      if (id === BPETokenizer.CLS_TOKEN_ID ||
          id === BPETokenizer.SEP_TOKEN_ID ||
          id === BPETokenizer.PAD_TOKEN_ID) {
        continue;
      }

      const token = this.idToToken.get(id);
      if (token) {
        // 移除 ## 前缀
        if (token.startsWith('##')) {
          tokens.push(token.substring(2));
        } else {
          tokens.push(token);
        }
      }
    }

    return tokens.join(' ');
  }

  /**
   * 检查是否已加载
   */
  isLoaded(): boolean {
    return this.loaded;
  }

  /**
   * 获取词汇表大小
   */
  getVocabSize(): number {
    return this.vocab.size;
  }

  /**
   * 设置最大序列长度
   */
  setMaxSeqLength(length: number): void {
    this.maxSeqLength = length;
  }
}