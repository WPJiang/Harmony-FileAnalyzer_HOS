﻿import { ChineseTokenizer } from '../utils/ChineseTokenizer';
import { common } from '@kit.AbilityKit';
import { FileMetadata } from '../models/Index';

/**
 * 关键词提取器
 * 支持中文分词和TF-IDF关键词提取
 */
export class KeywordExtractor {
  private topK: number;
  private tokenizer: ChineseTokenizer | null = null;
  private initialized: boolean = false;

  constructor(topK: number = 10) {
    this.topK = topK;
  }

  /**
   * 初始化分词器
   */
  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) return;

    try {
      this.tokenizer = new ChineseTokenizer();
      await this.tokenizer.loadDictionary(context);
      this.initialized = true;
      console.info('[KeywordExtractor] Initialized with ChineseTokenizer');
    } catch (err) {
      console.warn('[KeywordExtractor] Failed to load tokenizer, using fallback:', err);
      this.initialized = true; // 使用备选方案
    }
  }

  /**
   * 提取关键词
   */
  extract(text: string): string[] {
    if (!text || text.trim().length === 0) {
      return [];
    }

    const cleanedText = this.cleanText(text);
    const words = this.tokenize(cleanedText);
    const wordFreq = this.calculateFrequency(words);
    const sortedWords = this.sortByFrequency(wordFreq);

    const result: string[] = [];
    for (let i = 0; i < this.topK && i < sortedWords.length; i++) {
      result.push(sortedWords[i]);
    }
    return result;
  }

  /**
   * 使用TF-IDF权重提取关键词（需要预计算IDF）
   */
  extractWithTFIDF(text: string, idf: Map<string, number>): string[] {
    if (!text || text.trim().length === 0) {
      return [];
    }

    const cleanedText = this.cleanText(text);
    const words = this.tokenize(cleanedText);

    // 计算TF
    const tf: Map<string, number> = new Map();
    for (const word of words) {
      tf.set(word, (tf.get(word) || 0) + 1);
    }

    // 计算TF-IDF分数
    const scores: Map<string, number> = new Map();
    tf.forEach((freq: number, word: string) => {
      const idfScore = idf.get(word) !== undefined ? idf.get(word)! : 1;
      scores.set(word, freq * idfScore);
    });

    // 按分数排序
    const sortedEntries: [string, number][] = [];
    scores.forEach((score: number, word: string) => {
      sortedEntries.push([word, score]);
    });
    sortedEntries.sort((a, b) => b[1] - a[1]);

    const result: string[] = [];
    for (let i = 0; i < Math.min(this.topK, sortedEntries.length); i++) {
      result.push(sortedEntries[i][0]);
    }
    return result;
  }

  private cleanText(text: string): string {
    let cleaned = text.replace(/[^\w\s\u4e00-\u9fff\u0030-\u0039]/g, ' ');
    cleaned = cleaned.replace(/\s+/g, ' ');
    return cleaned.trim();
  }

  private tokenize(text: string): string[] {
    // 优先使用分词器
    if (this.tokenizer) {
      return this.tokenizer.tokenize(text);
    }

    // 备选方案：简单分词
    const tokens: string[] = [];
    const chinesePattern = /[\u4e00-\u9fff]+/g;
    const englishPattern = /[a-zA-Z]+/g;
    const numberPattern = /[0-9]+/g;

    // 中文分词：使用滑动窗口
    const chineseMatches = text.match(chinesePattern) || [];
    for (const match of chineseMatches) {
      // 使用N-gram分词（2-gram为主）
      for (let i = 0; i < match.length - 1; i++) {
        tokens.push(match.substring(i, i + 2));
      }
      // 也保留单个字符
      for (let i = 0; i < match.length; i++) {
        tokens.push(match[i]);
      }
    }

    // 英文单词
    const englishMatches = text.match(englishPattern) || [];
    for (const match of englishMatches) {
      if (match.length > 2) {
        tokens.push(match.toLowerCase());
      }
    }

    // 数字
    const numberMatches = text.match(numberPattern) || [];
    for (const match of numberMatches) {
      if (match.length >= 2) {
        tokens.push(match);
      }
    }

    return tokens;
  }

  private calculateFrequency(words: string[]): Map<string, number> {
    const freq: Map<string, number> = new Map();
    for (const word of words) {
      freq.set(word, (freq.get(word) || 0) + 1);
    }
    return freq;
  }

  private sortByFrequency(freq: Map<string, number>): string[] {
    const entries: [string, number][] = [];
    freq.forEach((value, key) => {
      entries.push([key, value]);
    });

    entries.sort((a, b) => b[1] - a[1]);

    const result: string[] = [];
    for (const entry of entries) {
      result.push(entry[0]);
    }
    return result;
  }

  /**
   * 获取分词器实例
   */
  getTokenizer(): ChineseTokenizer | null {
    return this.tokenizer;
  }

  /**
   * 检查是否已初始化
   */
  isInitialized(): boolean {
    return this.initialized;
  }
}

/**
 * 文本描述生成器
 * 支持本地生成和云端LLM生成
 */
export class TextDescriptionGenerator {
  private maxLength: number;

  constructor(maxLength: number = 512) {
    this.maxLength = maxLength;
  }

  setMaxLength(length: number): void {
    this.maxLength = length > 0 ? length : 512;
  }

  generate(text: string): string {
    if (!text || text.trim().length === 0) {
      return '';
    }

    const cleanedText = this.cleanText(text);

    if (cleanedText.length <= this.maxLength) {
      return cleanedText;
    }

    return this.summarize(cleanedText);
  }

  /**
   * 生成结构化描述（用于语义块）
   */
  generateStructured(text: string, metadata?: Record<string, Object>): string {
    let description = '';

    // 添加元数据信息
    if (metadata) {
      if (metadata['fileName']) {
        description += `文件名: ${metadata['fileName']}\n`;
      }
      if (metadata['fileType']) {
        description += `类型: ${metadata['fileType']}\n`;
      }
      if (metadata['pageNumber']) {
        description += `页码: ${metadata['pageNumber']}\n`;
      }
    }

    // 添加文本摘要
    const summary = this.generate(text);
    description += `内容摘要: ${summary}`;

    return description;
  }

  private cleanText(text: string): string {
    let cleaned = text.replace(/\s+/g, ' ');
    cleaned = cleaned.trim();
    return cleaned;
  }

  private summarize(text: string): string {
    const sentences = text.split(/[。！？.!?]/).filter(s => s.trim().length > 0);

    if (sentences.length === 0) {
      return text.substring(0, this.maxLength);
    }

    // 计算每句话的重要性（基于位置和长度）
    const sentenceScores: [string, number][] = sentences.map((s, idx) => {
      let score = 0;
      // 首句权重高
      if (idx === 0) score += 2;
      // 末句权重较高
      if (idx === sentences.length - 1) score += 1;
      // 长度适中的句子权重高
      if (s.length >= 10 && s.length <= 100) score += 1;
      return [s, score] as [string, number];
    });

    // 按分数排序，但保持原始顺序
    sentenceScores.sort((a, b) => b[1] - a[1]);

    // 选择最重要的句子，不超过长度限制
    let result = '';
    const selectedIndices = new Set<number>();

    for (const entry of sentenceScores) {
      const sentence = entry[0];
      if (result.length + sentence.length + 1 <= this.maxLength) {
        const idx = sentences.indexOf(sentence);
        if (!selectedIndices.has(idx)) {
          selectedIndices.add(idx);
        }
      }
    }

    // 按原始顺序组合
    const sortedIndices = Array.from(selectedIndices).sort((a, b) => a - b);
    for (const idx of sortedIndices) {
      if (result.length > 0) result += '。';
      result += sentences[idx];
    }

    return result || text.substring(0, this.maxLength);
  }
}
