export type MetadataValue = string | number | boolean | string[];
export type FileMetadata = Record<string, MetadataValue>;

export enum FileStatus {
  PENDING = 0,
  PARSED = 1,
  PRELIMINARY = 2,
  DEEP = 3
}

export class CategoryScore {
  category: string = ''
  confidence: number = 0

  constructor() {
  }
}

/**
 * 时空分析状态
 */
export class SpatiotemporalAnalysisStatus {
  static readonly EMPTY = '' // 非图片文件，默认为空
  static readonly PENDING = '待分析' // 图片文件，初始化为待分析
  static readonly NOT_SUPPORTED = '不支持' // 不支持的图片格式
  static readonly ANALYZED_NO_INFO = '已分析无信息' // 支持但无信息
  static readonly ANALYZED_HAS_INFO = '已分析有信息' // 提取到至少一个信息
}

/**
 * Caption打标状态
 */
export class CaptionAnalysisStatus {
  static readonly EMPTY = '' // 非图片文件，默认为空
  static readonly PENDING = '待分析' // 图片文件，初始化为待分析
  static readonly NOT_SUPPORTED = '不支持' // 不支持的图片格式
  static readonly ANALYZED_FAILED = '已分析不成功' // caption和标签都没生成
  static readonly ANALYZED_HAS_INFO = '已分析有信息' // 提取到至少一个
}

export class FileRecord {
  id: number = 0
  filePath: string = ''
  fileName: string = ''
  fileSize: number = 0
  fileType: string = ''
  modifiedTime: string = ''
  createdTime: string = ''
  analysisStatus: FileStatus = FileStatus.PENDING
  semanticCategories: CategoryScore[] = []
  directoryPath: string = ''
  addedTime: string = ''
  // 新增字段
  semanticFilename: string = '' // 语义文件名（用于搜索）
  metadata: FileMetadata = {} as FileMetadata // 文件元数据（拍摄时间、地点、caption、tags等）
  spatiotemporalAnalysisStatus: string = '' // 时空分析状态
  originalCreatedTime: string = '' // 原文件创建时间
  location: string = '' // 地点
  captionAnalysisStatus: string = '' // Caption打标状态

  constructor() {
  }
}

export class DataBlockRecord {
  id: number = 0
  blockId: string = ''
  fileId: number = 0
  modality: string = ''
  addr: string = ''  // 数据块文件路径（cache目录下）
  pageNumber: number = 1
  position: string = ''
  metadata: FileMetadata = {} as FileMetadata
  createdTime: string = ''

  constructor() {
  }
}

export class SemanticBlockRecord {
  id: number = 0
  semanticBlockId: string = ''
  dataBlockIds: number[] = []
  fileId: number = 0
  textDescription: string = ''
  keywords: string[] = []
  semanticVector: Uint8Array = new Uint8Array(0)
  createdTime: string = ''
  // 新增字段
  semanticFilename: string = '' // 语义文件名
  metadata: Record<string, Record<string, number>> = {} // {类别体系名: {类别名: 相似度}}

  constructor() {
  }
}

/**
 * 语义类别记录
 */
export class SemanticCategoryRecord {
  id: number = 0
  categoryName: string = ''
  description: string = ''
  keywords: string[] = []
  categorySystemName: string = '默认类别体系' // 所属类别体系名称
  categorySource: string = 'predefined' // 类别来源: predefined/imported/generated
  semanticVector: Uint8Array = new Uint8Array(0) // 类别中心向量
  createdTime: string = ''

  constructor() {
  }
}

export class ClassificationResultRecord {
  id: number = 0
  fileId: number = 0
  semanticBlockId: string = ''
  categoryName: string = ''
  categorySystemName: string = '默认类别体系' // 使用的类别体系名称
  confidence: number = 0
  allScores: Record<string, number> = {}
  createdTime: string = ''

  constructor() {
  }
}

export class UserQueryRecord {
  id: number = 0
  queryText: string = ''
  queryVector: Uint8Array = new Uint8Array(0)
  keywords: string[] = []
  topK: number = 10
  topM: number = 5
  resultCount: number = 0
  createdTime: string = ''

  constructor() {
  }
}

// ==================== 批量操作接口 ====================

/**
 * 批量添加文件参数
 */
export interface FileBatchItem {
  filePath: string;
  fileName: string;
  fileSize: number;
  fileType: string;
  modifiedTime: string;
  createdTime: string;
  directoryPath: string;
}

/**
 * 批量更新元数据参数
 */
export interface MetadataUpdateItem {
  fileId: number;
  metadata: FileMetadata;
}

/**
 * 批量添加数据块参数
 */
export interface DataBlockBatchItem {
  blockId: string;
  fileId: number;
  modality: string;
  addr: string;  // 数据块文件路径
  pageNumber: number;
  position: string;
  metadata: string;
}

/**
 * 批量添加语义块参数
 */
export interface SemanticBlockBatchItem {
  semanticBlockId: string;
  dataBlockIds: number[];
  fileId: number;
  textDescription: string;
  keywords: string[];
  semanticVector: Uint8Array;
  semanticFilename?: string;
}

/**
 * 批量添加分类结果参数
 */
export interface ClassificationResultBatchItem {
  fileId: number;
  semanticBlockId: string;
  categoryName: string;
  categorySystemName?: string;
  confidence: number;
  allScores: Record<string, number>;
}
