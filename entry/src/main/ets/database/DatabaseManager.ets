import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  FileStatus,
  FileRecord,
  CategoryScore,
  DataBlockRecord,
  SemanticBlockRecord,
  SemanticCategoryRecord,
  ClassificationResultRecord,
  UserQueryRecord,
  SpatiotemporalAnalysisStatus,
  CaptionAnalysisStatus,
  FileBatchItem,
  MetadataUpdateItem,
  DataBlockBatchItem,
  SemanticBlockBatchItem,
  ClassificationResultBatchItem,
  FileMetadata
} from '../models/Index';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'FileAnalyzer.db',
  securityLevel: relationalStore.SecurityLevel.S1
};

// 数据库版本号 - 表结构变更时需要增加此版本号
const DB_VERSION = 4;

/**
 * URL解码工具函数
 * 用于解码数据库中存储的URL编码路径，解决中文显示问题
 * 正确处理UTF-8编码的中文字符序列
 */
function decodeUrlPath(path: string): string {
  if (!path) return path;
  try {
    // 检查是否包含URL编码字符（%后跟两位十六进制）
    if (!path.includes('%')) {
      return path;
    }

    // 正确的UTF-8解码方式：
    // 1. 将所有%XX编码转换为字节
    // 2. 将非编码部分也转换为字节（保持原样）
    // 3. 使用TextDecoder正确解码UTF-8字节序列

    const encoder = new util.TextEncoder();
    const bytes: number[] = [];
    let i = 0;

    while (i < path.length) {
      if (path[i] === '%' && i + 2 < path.length) {
        // 检查是否是有效的%XX编码
        const hex1 = path[i + 1];
        const hex2 = path[i + 2];
        const hexStr = hex1 + hex2;

        // 检查是否是有效的十六进制
        if (/^[0-9A-Fa-f]{2}$/.test(hexStr)) {
          const byteValue = parseInt(hexStr, 16);
          bytes.push(byteValue);
          i += 3;
          continue;
        }
      }
      // 非编码字符，直接编码为字节
      const charBytes = encoder.encodeInto(path[i]);
      for (const b of charBytes) {
        bytes.push(b);
      }
      i++;
    }

    // 使用TextDecoder正确解码UTF-8字节序列
    const uint8Array = new Uint8Array(bytes);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(uint8Array);
  } catch (e) {
    console.warn('[DatabaseManager] URL decode failed:', e);
    return path;
  }
}

export class DatabaseManager {
  private rdbStore: relationalStore.RdbStore | null = null;
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async initialize(): Promise<void> {
    try {
      // 检查是否需要重建数据库（版本变更）
      await this.checkAndRebuildDatabase();

      this.rdbStore = await relationalStore.getRdbStore(this.context, STORE_CONFIG);
      await this.createTables();
      await this.initializeDefaultCategories();
      console.info('[DatabaseManager] Database initialized successfully, version:', DB_VERSION);
    } catch (err) {
      console.error('[DatabaseManager] Failed to initialize database:', err);
      const error = new Error('Failed to initialize database');
      throw error;
    }
  }

  /**
   * 检查数据库版本，如果版本变更则删除旧数据库重建
   */
  private async checkAndRebuildDatabase(): Promise<void> {
    try {
      // 获取数据库文件路径
      const dbPath = `/data/app/el2/100/database/${this.context.applicationInfo.name}/rdb/FileAnalyzer.db`;
      const versionFilePath = `${this.context.cacheDir}/db_version.txt`;

      // 读取当前保存的版本号
      let currentVersion = 0;
      try {
        const file = await fileIo.open(versionFilePath, fileIo.OpenMode.READ_ONLY);
        const stat = await fileIo.stat(file.fd);
        if (stat.size > 0) {
          const buffer = new ArrayBuffer(stat.size);
          await fileIo.read(file.fd, buffer);
          await fileIo.close(file.fd);
          const decoder = new util.TextDecoder('utf-8');
          const versionStr = decoder.decodeToString(new Uint8Array(buffer));
          currentVersion = parseInt(versionStr) || 0;
        }
      } catch {
        // 版本文件不存在，说明是第一次创建
        currentVersion = 0;
      }

      console.info(`[DatabaseManager] Current DB version: ${currentVersion}, Target version: ${DB_VERSION}`);

      // 如果版本号变更，删除旧数据库
      if (currentVersion < DB_VERSION && currentVersion > 0) {
        console.info('[DatabaseManager] Database version changed, deleting old database...');
        try {
          await relationalStore.deleteRdbStore(this.context, 'FileAnalyzer.db');
          console.info('[DatabaseManager] Old database deleted successfully');
        } catch (err) {
          console.warn('[DatabaseManager] Failed to delete old database:', err);
        }
      }

      // 保存新版本号
      try {
        const encoder = new util.TextEncoder();
        const versionBytes = encoder.encodeInto(DB_VERSION.toString());
        const file = await fileIo.open(versionFilePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        await fileIo.write(file.fd, versionBytes);
        await fileIo.close(file.fd);
      } catch (err) {
        console.warn('[DatabaseManager] Failed to save version file:', err);
      }
    } catch (err) {
      console.warn('[DatabaseManager] Version check failed:', err);
    }
  }

  private async createTables(): Promise<void> {
    if (!this.rdbStore) return;

    // 文件表 - 添加新字段
    const createFilesTable = `
      CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT UNIQUE NOT NULL,
        file_name TEXT NOT NULL,
        file_size INTEGER DEFAULT 0,
        file_type TEXT,
        modified_time TEXT,
        created_time TEXT,
        analysis_status INTEGER DEFAULT 0,
        semantic_categories TEXT DEFAULT '[]',
        directory_path TEXT NOT NULL,
        added_time TEXT DEFAULT CURRENT_TIMESTAMP,
        semantic_filename TEXT,
        metadata TEXT DEFAULT '{}',
        spatiotemporal_analysis_status TEXT DEFAULT '',
        original_created_time TEXT,
        location TEXT,
        caption_analysis_status TEXT DEFAULT ''
      )
    `;

    const createDataBlocksTable = `
      CREATE TABLE IF NOT EXISTS data_blocks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        block_id TEXT UNIQUE NOT NULL,
        file_id INTEGER NOT NULL,
        modality TEXT NOT NULL,
        addr TEXT,
        page_number INTEGER DEFAULT 1,
        position TEXT,
        metadata TEXT DEFAULT '{}',
        created_time TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      )
    `;

    // 语义块表 - 添加新字段
    const createSemanticBlocksTable = `
      CREATE TABLE IF NOT EXISTS semantic_blocks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        semantic_block_id TEXT UNIQUE NOT NULL,
        data_block_ids TEXT DEFAULT '[]',
        file_id INTEGER NOT NULL,
        text_description TEXT,
        keywords TEXT DEFAULT '[]',
        semantic_vector BLOB,
        created_time TEXT DEFAULT CURRENT_TIMESTAMP,
        semantic_filename TEXT,
        metadata TEXT DEFAULT '{}',
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      )
    `;

    // 语义类别表 - 新增
    const createSemanticCategoriesTable = `
      CREATE TABLE IF NOT EXISTS semantic_categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category_name TEXT NOT NULL,
        description TEXT,
        keywords TEXT DEFAULT '[]',
        category_system_name TEXT DEFAULT '默认类别体系',
        category_source TEXT DEFAULT 'predefined',
        semantic_vector BLOB,
        created_time TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(category_name, category_system_name)
      )
    `;

    // 分类结果表 - 添加新字段
    const createClassificationResultsTable = `
      CREATE TABLE IF NOT EXISTS classification_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL,
        semantic_block_id TEXT NOT NULL,
        category_name TEXT NOT NULL,
        category_system_name TEXT DEFAULT '默认类别体系',
        confidence REAL DEFAULT 0.0,
        all_scores TEXT DEFAULT '{}',
        created_time TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      )
    `;

    const createUserQueriesTable = `
      CREATE TABLE IF NOT EXISTS user_queries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        query_text TEXT NOT NULL,
        query_vector BLOB,
        keywords TEXT DEFAULT '[]',
        top_k INTEGER DEFAULT 10,
        top_m INTEGER DEFAULT 5,
        result_count INTEGER DEFAULT 0,
        created_time TEXT DEFAULT CURRENT_TIMESTAMP
      )
    `;

    await this.rdbStore.executeSql(createFilesTable);
    await this.rdbStore.executeSql(createDataBlocksTable);
    await this.rdbStore.executeSql(createSemanticBlocksTable);
    await this.rdbStore.executeSql(createSemanticCategoriesTable);
    await this.rdbStore.executeSql(createClassificationResultsTable);
    await this.rdbStore.executeSql(createUserQueriesTable);

    // 创建索引
    await this.createIndexes();
  }

  private async createIndexes(): Promise<void> {
    if (!this.rdbStore) return;

    const indexes: string[] = [
      'CREATE INDEX IF NOT EXISTS idx_files_path ON files(file_path)',
      'CREATE INDEX IF NOT EXISTS idx_files_status ON files(analysis_status)',
      'CREATE INDEX IF NOT EXISTS idx_files_directory ON files(directory_path)',
      'CREATE INDEX IF NOT EXISTS idx_data_blocks_file ON data_blocks(file_id)',
      'CREATE INDEX IF NOT EXISTS idx_semantic_blocks_file ON semantic_blocks(file_id)',
      'CREATE INDEX IF NOT EXISTS idx_classification_file ON classification_results(file_id)',
      'CREATE INDEX IF NOT EXISTS idx_user_queries_time ON user_queries(created_time)',
      'CREATE INDEX IF NOT EXISTS idx_semantic_categories_system ON semantic_categories(category_system_name)'
    ];

    for (const sql of indexes) {
      try {
        await this.rdbStore.executeSql(sql);
      } catch (err) {
        console.warn('[DatabaseManager] Failed to create index:', err);
      }
    }
  }

  private async initializeDefaultCategories(): Promise<void> {
    if (!this.rdbStore) return;

    try {
      // 直接用SQL检查类别数量，避免getAllSemanticCategories可能的错误
      let count = 0;
      try {
        const countResult = await this.rdbStore.querySql('SELECT COUNT(*) as cnt FROM semantic_categories');
        if (countResult.goToNextRow()) {
          count = countResult.getLong(0);
        }
        countResult.close();
      } catch (e) {
        console.warn('[DatabaseManager] Failed to count categories, table may not exist yet');
      }

      if (count > 0) {
        console.info(`[DatabaseManager] Categories already exist (${count} rows), skip initialization`);
        return;
      }

      console.info('[DatabaseManager] Initializing default categories...');

      const defaultCategories: string[][] = [
        ['技术文档', '技术规范、API文档、技术手册、开发文档等', '技术,API,接口,开发,代码,系统,架构,配置,部署,服务器,程序,函数,模块,框架,数据库'],
        ['商业报告', '商业计划、市场分析、财务报告、商业提案等', '市场,销售,收入,利润,客户,竞争,战略,投资,商业,业务,增长,运营,营销,品牌,渠道'],
        ['学术论文', '研究论文、学术文章、研究报告、学位论文等', '研究,实验,方法,结果,分析,理论,模型,数据,论文,引用,摘要,结论,假设,验证,文献'],
        ['会议演示', '会议PPT、演讲稿、培训材料、汇报材料等', '会议,演示,培训,演讲,PPT,展示,介绍,汇报,方案,计划,议程,讨论,总结,要点,目标'],
        ['合同协议', '合同、协议、法律文件、条款文件等', '合同,协议,条款,甲方,乙方,法律,责任,义务,权利,签署,违约,赔偿,期限,生效,终止'],
        ['产品说明', '产品手册、使用指南、说明书、操作手册等', '产品,功能,使用,操作,说明,指南,特性,规格,型号,安装,设置,步骤,注意,维护,故障'],
        ['新闻资讯', '新闻报道、新闻稿、媒体文章、资讯内容等', '新闻,报道,发布,消息,媒体,记者,事件,宣布,最新,动态,采访,声明,关注,热点,头条'],
        ['个人文档', '简历、个人陈述、信函、个人记录等', '个人,简历,经历,教育,技能,自我,介绍,申请,工作,职位,求职,面试,推荐,背景,成就'],
      ];

      for (const cat of defaultCategories) {
        await this.addSemanticCategory(
          cat[0],
          cat[1],
          cat[2].split(','),
          '默认类别体系',
          'predefined'
        );
      }

      // 图片分类（与Python config.json image_tag_categories一致）
      const imageCategories: string[][] = [
        // 场景
        ['室内', '室内场景', '室内,房间,客厅,卧室,厨房,办公室'],
        ['户外', '户外场景', '户外,室外,街道,广场'],
        ['自然风光', '自然风光', '自然,风光,山水,湖泊,河流'],
        ['城市街景', '城市街景', '城市,街景,建筑,街道,马路'],
        ['建筑', '建筑', '建筑,大楼,桥梁,塔,寺庙'],
        ['海滩', '海滩场景', '海滩,沙滩,海浪,海岸'],
        ['山脉', '山脉场景', '山脉,山峰,山岭,峡谷'],
        ['森林', '森林场景', '森林,树林,丛林,树木'],
        ['公园', '公园场景', '公园,花园,草坪,步道'],
        ['花园', '花园场景', '花园,花朵,植物园'],
        ['田野', '田野场景', '田野,农田,庄稼,乡村'],
        ['沙漠', '沙漠场景', '沙漠,沙丘,戈壁'],
        ['雪景', '雪景', '雪景,雪地,冰天雪地'],
        ['夜景', '夜景', '夜景,灯光,城市夜景'],
        // 人物
        ['单人照', '单人照片', '单人,肖像,个人照,头像'],
        ['双人照', '双人照片', '双人,情侣,朋友,合照'],
        ['合影', '多人合影', '合影,集体照,团队,全家福'],
        ['自拍', '自拍照', '自拍,自拍杆,对镜自拍'],
        ['家庭照', '家庭合照', '家庭,全家,亲情'],
        ['儿童', '儿童相关', '儿童,小孩,宝宝,幼儿'],
        ['老人', '老人相关', '老人,老年,长辈'],
        ['朋友聚会', '朋友聚会', '朋友,聚会,聚餐'],
        ['情侣', '情侣照', '情侣,恋爱,甜蜜'],
        ['婚礼', '婚礼场景', '婚礼,结婚,新娘,新郎'],
        // 活动
        ['旅行', '旅行照片', '旅行,旅游,景点,出行'],
        ['美食', '美食照片', '美食,食物,餐饮,菜品'],
        ['运动健身', '运动健身', '运动,健身,跑步,球类'],
        ['节日庆典', '节日庆典', '节日,庆典,庆祝,烟花'],
        ['生日派对', '生日派对', '生日,蛋糕,蜡烛,派对'],
        ['毕业典礼', '毕业典礼', '毕业,学士服,学位,典礼'],
        ['会议活动', '会议活动场景', '会议,活动,讲座'],
        ['演出表演', '演出表演', '演出,表演,舞台,戏剧'],
        ['宠物', '宠物照片', '宠物,猫,狗,动物'],
        ['游戏娱乐', '游戏娱乐', '游戏,娱乐,电竞'],
        // 物品
        ['美食饮品', '美食饮品', '美食,饮品,咖啡,茶'],
        ['服饰穿搭', '服饰穿搭', '服饰,穿搭,衣服,鞋子'],
        ['电子产品', '电子产品', '电子产品,手机,电脑,相机'],
        ['交通工具', '交通工具类', '汽车,火车,飞机,自行车,公交'],
        ['家具家居', '家具家居', '家具,家居,装修,房子'],
        ['书籍文具', '书籍文具类', '书籍,文具,书本,笔,笔记本'],
        ['工艺品', '工艺品', '工艺品,手工,艺术品'],
        ['珠宝首饰', '珠宝首饰', '珠宝,首饰,项链,戒指'],
        ['化妆品', '化妆品类', '化妆品,口红,粉底,眉笔'],
        ['玩具', '玩具', '玩具,积木,玩偶'],
        // 摄影
        ['人像摄影', '人像摄影风格', '人像,肖像,写真,模特'],
        ['风景摄影', '风景摄影风格', '风景,风光,自然,全景'],
        ['微距摄影', '微距摄影', '微距,特写,细节'],
        ['街拍', '街拍', '街拍,街头,纪实'],
        ['纪实摄影', '纪实摄影', '纪实,记录,真实'],
        ['艺术摄影', '艺术摄影', '艺术,创意,抽象'],
        ['建筑摄影', '建筑摄影', '建筑,大楼,桥梁'],
        ['美食摄影', '美食摄影', '美食,菜品,食物'],
        ['产品摄影', '产品摄影风格', '产品,商品,静物,广告'],
        // 时间
        ['日出', '日出场景', '日出,黎明,朝霞'],
        ['日落', '日落场景', '日落,黄昏,晚霞'],
        ['白天', '白天场景', '白天,阳光,晴朗'],
        ['夜晚', '夜晚场景', '夜晚,夜空,星空'],
        ['春天', '春天场景', '春天,花开,嫩绿,温暖'],
        ['夏天', '夏天场景', '夏天,炎热,阳光,海滩'],
        ['秋天', '秋天场景', '秋天,落叶,金黄,凉爽'],
        ['冬天', '冬天场景', '冬天,雪,冰,寒冷'],
        // 氛围
        ['温馨', '温馨氛围', '温馨,温暖,舒适,家'],
        ['浪漫', '浪漫氛围', '浪漫,爱情,玫瑰,烛光'],
        ['欢乐', '欢乐氛围', '欢乐,开心,笑容,庆祝'],
        ['宁静', '宁静氛围', '宁静,安静,平和,悠闲'],
        ['活力', '活力氛围', '活力,运动,青春,朝气'],
        ['怀旧', '怀旧氛围', '怀旧,回忆,老照片'],
        ['清新', '清新氛围', '清新,淡雅,自然'],
        ['时尚', '时尚氛围', '时尚,潮流,现代'],
      ];

      for (const cat of imageCategories) {
        await this.addSemanticCategory(
          cat[0],
          cat[1],
          cat[2].split(','),
          '图片数据默认分类',
          'predefined'
        );
      }

      console.info('[DatabaseManager] Default categories initialized');
    } catch (err) {
      console.error('[DatabaseManager] Failed to initialize default categories:', err);
    }
  }

  /**
   * 公开方法：检查并初始化类别体系（供UI层调用）
   * 确保类别体系始终存在
   */
  async initCategorySystemsIfNeeded(): Promise<void> {
    if (!this.rdbStore) return;

    try {
      const existing = await this.getCategorySystemNames();
      if (existing.length > 0) {
        console.info(`[DatabaseManager] Category systems already exist: ${existing.join(', ')}`);
        return;
      }

      console.info('[DatabaseManager] No category systems found, initializing...');
      await this.initializeDefaultCategories();
    } catch (err) {
      console.error('[DatabaseManager] Failed to init category systems:', err);
    }
  }

  async addFile(
    filePath: string,
    fileName: string,
    fileSize: number,
    fileType: string,
    modifiedTime: string,
    createdTime: string,
    directoryPath: string
  ): Promise<number> {
    if (!this.rdbStore) return -1;

    // 判断是否是图片文件
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp', '.heic', '.heif', '.livp', '.ico', '.svg'];
    const isImage = imageExtensions.some(ext => fileType.toLowerCase() === ext);

    // 初始化时空分析和caption状态
    const spatiotemporalStatus = isImage ? SpatiotemporalAnalysisStatus.PENDING : SpatiotemporalAnalysisStatus.EMPTY;
    const captionStatus = isImage ? CaptionAnalysisStatus.PENDING : CaptionAnalysisStatus.EMPTY;

    // 获取当前时间作为 added_time（格式：YYYY-MM-DD HH:MM:SS）
    const now = new Date();
    const addedTimeStr = this.formatDateTimeString(now);

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'file_path': filePath,
        'file_name': fileName,
        'file_size': fileSize,
        'file_type': fileType,
        'modified_time': modifiedTime,
        'created_time': createdTime,
        'analysis_status': FileStatus.PENDING,
        'semantic_categories': '[]',
        'directory_path': directoryPath,
        'added_time': addedTimeStr,
        'semantic_filename': '',
        'metadata': '{}',
        'spatiotemporal_analysis_status': spatiotemporalStatus,
        'caption_analysis_status': captionStatus
      };

      const rowId = await this.rdbStore.insert('files', valueBucket);
      return rowId;
    } catch (err) {
      console.error('[DatabaseManager] Failed to add file:', err);
      return -1;
    }
  }

  /**
   * 格式化日期为 YYYY-MM-DD HH:MM:SS 格式
   */
  private formatDateTimeString(date: Date): string {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');
    const second = String(date.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
  }

  async getFileByPath(filePath: string): Promise<FileRecord | null> {
    if (!this.rdbStore) return null;

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('file_path', filePath);

      const resultSet = await this.rdbStore.query(predicates);
      if (resultSet.goToFirstRow()) {
        const record = this.resultSetToFileRecord(resultSet);
        resultSet.close();
        return record;
      }
      resultSet.close();
      return null;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get file by path:', err);
      return null;
    }
  }

  async getFileById(fileId: number): Promise<FileRecord | null> {
    if (!this.rdbStore) return null;

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const resultSet = await this.rdbStore.query(predicates);
      if (resultSet.goToFirstRow()) {
        const record = this.resultSetToFileRecord(resultSet);
        resultSet.close();
        return record;
      }
      resultSet.close();
      return null;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get file by id:', err);
      return null;
    }
  }

  async getAllFiles(): Promise<FileRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.orderByDesc('added_time');

      const resultSet = await this.rdbStore.query(predicates);
      const records: FileRecord[] = [];

      while (resultSet.goToNextRow()) {
        records.push(this.resultSetToFileRecord(resultSet));
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get all files:', err);
      return [];
    }
  }

  async updateFileStatus(fileId: number, status: FileStatus): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'analysis_status': status
      };

      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update file status:', err);
      return false;
    }
  }

  async updateFileSemanticCategories(fileId: number, categories: CategoryScore[]): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'semantic_categories': JSON.stringify(categories)
      };

      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update file semantic categories:', err);
      return false;
    }
  }

  async deleteFile(fileId: number): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const deletedRows = await this.rdbStore.delete(predicates);
      return deletedRows > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to delete file:', err);
      return false;
    }
  }

  async addDataBlock(
    blockId: string,
    fileId: number,
    modality: string,
    addr: string,
    pageNumber: number,
    position: string,
    metadata: string
  ): Promise<number> {
    if (!this.rdbStore) return -1;

    try {
      // 检查文件是否存在（外键约束）
      const fileExists = await this.checkFileExists(fileId);
      if (!fileExists) {
        console.error(`[DatabaseManager] File ${fileId} not found, cannot add data block ${blockId}`);
        return -1;
      }

      const valueBucket: relationalStore.ValuesBucket = {
        'block_id': blockId,
        'file_id': fileId,
        'modality': modality,
        'addr': addr,
        'page_number': pageNumber,
        'position': position,
        'metadata': metadata
      };

      console.info(`[DatabaseManager] Adding data block: blockId=${blockId}, fileId=${fileId}, modality=${modality}`);
      const rowId = await this.rdbStore.insert('data_blocks', valueBucket);
      console.info(`[DatabaseManager] Data block added successfully: rowId=${rowId}`);
      return rowId;
    } catch (err) {
      console.error(`[DatabaseManager] Failed to add data block: blockId=${blockId}, fileId=${fileId}, err=${err}`);
      return -1;
    }
  }

  /**
   * 检查文件是否存在
   */
  private async checkFileExists(fileId: number): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);
      const cursor = await this.rdbStore.query(predicates);
      const exists = cursor.goToNextRow();
      cursor.close();
      return exists;
    } catch {
      return false;
    }
  }

  async getDataBlocksByFile(fileId: number): Promise<DataBlockRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('data_blocks');
      predicates.equalTo('file_id', fileId);
      const cursor = await this.rdbStore.query(predicates);
      const blocks: DataBlockRecord[] = [];

      while (cursor.goToNextRow()) {
        const block = new DataBlockRecord();
        block.id = cursor.getLong(cursor.getColumnIndex('id'));
        block.blockId = cursor.getString(cursor.getColumnIndex('block_id'));
        block.fileId = cursor.getLong(cursor.getColumnIndex('file_id'));
        block.modality = cursor.getString(cursor.getColumnIndex('modality'));
        // URL解码addr字段，解决中文显示问题
        const addrRaw = cursor.getString(cursor.getColumnIndex('addr'));
        block.addr = decodeUrlPath(addrRaw);
        block.pageNumber = cursor.getLong(cursor.getColumnIndex('page_number'));
        // URL解码position字段（可能包含路径）
        const positionRaw = cursor.getString(cursor.getColumnIndex('position'));
        block.position = decodeUrlPath(positionRaw);
        const metadataStr = cursor.getString(cursor.getColumnIndex('metadata'));
        try {
          block.metadata = metadataStr ? JSON.parse(metadataStr) as FileMetadata : {} as FileMetadata;
        } catch {
          block.metadata = {} as FileMetadata;
        }
        blocks.push(block);
      }
      cursor.close();
      return blocks;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get data blocks:', err);
      return [];
    }
  }

  async addSemanticBlock(
    semanticBlockId: string,
    dataBlockIds: number[],
    fileId: number,
    textDescription: string,
    keywords: string[],
    semanticVector: Uint8Array,
    semanticFilename?: string,
    metadata?: Record<string, Record<string, number>>
  ): Promise<number> {
    if (!this.rdbStore) return -1;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'semantic_block_id': semanticBlockId,
        'data_block_ids': JSON.stringify(dataBlockIds),
        'file_id': fileId,
        'text_description': textDescription,
        'keywords': JSON.stringify(keywords),
        'semantic_vector': semanticVector,
        'semantic_filename': semanticFilename || '',
        'metadata': metadata ? JSON.stringify(metadata) : '{}'
      };

      const rowId = await this.rdbStore.insert('semantic_blocks', valueBucket);
      return rowId;
    } catch (err) {
      console.error('[DatabaseManager] Failed to add semantic block:', err);
      return -1;
    }
  }

  async addClassificationResult(
    fileId: number,
    semanticBlockId: string,
    categoryName: string,
    confidence: number,
    allScores: Record<string, number>,
    categorySystemName: string = '默认类别体系'
  ): Promise<number> {
    if (!this.rdbStore) return -1;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'file_id': fileId,
        'semantic_block_id': semanticBlockId,
        'category_name': categoryName,
        'category_system_name': categorySystemName,
        'confidence': confidence,
        'all_scores': JSON.stringify(allScores)
      };

      const rowId = await this.rdbStore.insert('classification_results', valueBucket);
      return rowId;
    } catch (err) {
      console.error('[DatabaseManager] Failed to add classification result:', err);
      return -1;
    }
  }

  async updateSemanticBlockMetadata(
    semanticBlockId: string,
    metadata: Record<string, Record<string, number>>
  ): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'metadata': JSON.stringify(metadata)
      };

      const predicates = new relationalStore.RdbPredicates('semantic_blocks');
      predicates.equalTo('semantic_block_id', semanticBlockId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update semantic block metadata:', err);
      return false;
    }
  }

  async getSemanticBlocksByFile(fileId: number): Promise<SemanticBlockRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('semantic_blocks');
      predicates.equalTo('file_id', fileId);

      const resultSet = await this.rdbStore.query(predicates);
      const records: SemanticBlockRecord[] = [];

      while (resultSet.goToNextRow()) {
        const record = new SemanticBlockRecord();
        record.id = resultSet.getLong(resultSet.getColumnIndex('id'));
        record.semanticBlockId = resultSet.getString(resultSet.getColumnIndex('semantic_block_id'));
        const dataBlockIdsStr = resultSet.getString(resultSet.getColumnIndex('data_block_ids'));
        try {
          record.dataBlockIds = dataBlockIdsStr ? JSON.parse(dataBlockIdsStr) as number[] : [];
        } catch {
          record.dataBlockIds = [];
        }
        record.fileId = resultSet.getLong(resultSet.getColumnIndex('file_id'));
        record.textDescription = resultSet.getString(resultSet.getColumnIndex('text_description')) || '';
        const keywordsStr = resultSet.getString(resultSet.getColumnIndex('keywords'));
        try {
          record.keywords = keywordsStr ? JSON.parse(keywordsStr) as string[] : [];
        } catch {
          record.keywords = [];
        }
        record.semanticVector = resultSet.getBlob(resultSet.getColumnIndex('semantic_vector')) || new Uint8Array(0);
        record.createdTime = resultSet.getString(resultSet.getColumnIndex('created_time')) || '';
        record.semanticFilename = resultSet.getString(resultSet.getColumnIndex('semantic_filename')) || '';
        const metadataStr = resultSet.getString(resultSet.getColumnIndex('metadata'));
        try {
          record.metadata = metadataStr ? JSON.parse(metadataStr) as Record<string, Record<string, number>> : {} as Record<string, Record<string, number>>;
        } catch {
          record.metadata = {} as Record<string, Record<string, number>>;
        }
        records.push(record);
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get semantic blocks by file:', err);
      return [];
    }
  }

  async getClassificationResultsByFile(fileId: number): Promise<ClassificationResultRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('classification_results');
      predicates.equalTo('file_id', fileId);

      const resultSet = await this.rdbStore.query(predicates);
      const records: ClassificationResultRecord[] = [];

      while (resultSet.goToNextRow()) {
        const record = new ClassificationResultRecord();
        record.id = resultSet.getLong(resultSet.getColumnIndex('id'));
        record.fileId = resultSet.getLong(resultSet.getColumnIndex('file_id'));
        record.semanticBlockId = resultSet.getString(resultSet.getColumnIndex('semantic_block_id'));
        record.categoryName = resultSet.getString(resultSet.getColumnIndex('category_name'));
        record.categorySystemName = resultSet.getString(resultSet.getColumnIndex('category_system_name')) || '默认类别体系';
        record.confidence = resultSet.getDouble(resultSet.getColumnIndex('confidence'));
        const allScoresStr = resultSet.getString(resultSet.getColumnIndex('all_scores'));
        try {
          record.allScores = allScoresStr ? JSON.parse(allScoresStr) as Record<string, number> : {} as Record<string, number>;
        } catch {
          record.allScores = {} as Record<string, number>;
        }
        record.createdTime = resultSet.getString(resultSet.getColumnIndex('created_time')) || '';
        records.push(record);
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get classification results:', err);
      return [];
    }
  }

  private resultSetToFileRecord(resultSet: relationalStore.ResultSet): FileRecord {
    const categoriesJson = resultSet.getString(resultSet.getColumnIndex('semantic_categories'));
    let semanticCategories: CategoryScore[] = [];
    try {
      semanticCategories = JSON.parse(categoriesJson) as CategoryScore[];
    } catch (e) {
      semanticCategories = [];
    }

    // 读取 metadata
    let metadata: FileMetadata = {} as FileMetadata;
    try {
      const metadataIndex = resultSet.getColumnIndex('metadata');
      if (metadataIndex >= 0) {
        const metadataStr = resultSet.getString(metadataIndex);
        metadata = JSON.parse(metadataStr) as FileMetadata;
      }
    } catch (e) {
      metadata = {} as FileMetadata;
    }

    const record = new FileRecord();
    record.id = resultSet.getLong(resultSet.getColumnIndex('id'));
    // URL解码路径字段，解决中文显示问题
    record.filePath = decodeUrlPath(resultSet.getString(resultSet.getColumnIndex('file_path')));
    record.fileName = decodeUrlPath(resultSet.getString(resultSet.getColumnIndex('file_name')));
    record.fileSize = resultSet.getLong(resultSet.getColumnIndex('file_size'));
    record.fileType = resultSet.getString(resultSet.getColumnIndex('file_type'));
    record.modifiedTime = resultSet.getString(resultSet.getColumnIndex('modified_time')) || '';
    record.createdTime = resultSet.getString(resultSet.getColumnIndex('created_time')) || '';
    record.analysisStatus = resultSet.getLong(resultSet.getColumnIndex('analysis_status')) as FileStatus;
    record.semanticCategories = semanticCategories;
    // URL解码目录路径
    record.directoryPath = decodeUrlPath(resultSet.getString(resultSet.getColumnIndex('directory_path')));
    record.addedTime = resultSet.getString(resultSet.getColumnIndex('added_time')) || '';
    record.metadata = metadata;

    // 读取新增字段（兼容处理）
    try {
      const semanticFilenameIndex = resultSet.getColumnIndex('semantic_filename');
      if (semanticFilenameIndex >= 0) {
        record.semanticFilename = resultSet.getString(semanticFilenameIndex) || '';
      }
    } catch (e) {
      record.semanticFilename = '';
    }

    try {
      const spatiotemporalIndex = resultSet.getColumnIndex('spatiotemporal_analysis_status');
      if (spatiotemporalIndex >= 0) {
        record.spatiotemporalAnalysisStatus = resultSet.getString(spatiotemporalIndex) || '';
      }
    } catch (e) {
      record.spatiotemporalAnalysisStatus = '';
    }

    try {
      const originalCreatedTimeIndex = resultSet.getColumnIndex('original_created_time');
      if (originalCreatedTimeIndex >= 0) {
        record.originalCreatedTime = resultSet.getString(originalCreatedTimeIndex) || '';
      }
    } catch (e) {
      record.originalCreatedTime = '';
    }

    try {
      const locationIndex = resultSet.getColumnIndex('location');
      if (locationIndex >= 0) {
        // URL解码location字段
        record.location = decodeUrlPath(resultSet.getString(locationIndex) || '');
      }
    } catch (e) {
      record.location = '';
    }

    try {
      const captionStatusIndex = resultSet.getColumnIndex('caption_analysis_status');
      if (captionStatusIndex >= 0) {
        record.captionAnalysisStatus = resultSet.getString(captionStatusIndex) || '';
      }
    } catch (e) {
      record.captionAnalysisStatus = '';
    }

    return record;
  }

  // ==================== 文件表扩展操作 ====================

  /**
   * 更新文件语义文件名
   */
  async updateFileSemanticFilename(fileId: number, semanticFilename: string): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'semantic_filename': semanticFilename
      };

      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update semantic filename:', err);
      return false;
    }
  }

  /**
   * 更新文件元数据
   */
  async updateFileMetadata(fileId: number, metadata: FileMetadata): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'metadata': JSON.stringify(metadata)
      };

      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update file metadata:', err);
      return false;
    }
  }

  /**
   * 更新时空分析状态
   */
  async updateSpatiotemporalStatus(
    fileId: number,
    status: string,
    originalCreatedTime?: string,
    location?: string
  ): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'spatiotemporal_analysis_status': status
      };

      if (originalCreatedTime !== undefined) {
        valueBucket['original_created_time'] = originalCreatedTime;
      }
      if (location !== undefined) {
        valueBucket['location'] = location;
      }

      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      console.info(`[DatabaseManager] updateSpatiotemporalStatus: fileId=${fileId}, rowsAffected=${rowsAffected}, time=${originalCreatedTime}, location=${location}`);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update spatiotemporal status:', err);
      return false;
    }
  }

  /**
   * 更新Caption分析状态
   */
  async updateCaptionStatus(fileId: number, status: string): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'caption_analysis_status': status
      };

      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('id', fileId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update caption status:', err);
      return false;
    }
  }

  /**
   * 根据时空分析状态获取文件列表
   */
  async getFilesBySpatiotemporalStatus(status: string): Promise<FileRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('spatiotemporal_analysis_status', status);
      predicates.orderByDesc('added_time');

      const resultSet = await this.rdbStore.query(predicates);
      const records: FileRecord[] = [];

      while (resultSet.goToNextRow()) {
        records.push(this.resultSetToFileRecord(resultSet));
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get files by spatiotemporal status:', err);
      return [];
    }
  }

  /**
   * 根据Caption分析状态获取文件列表
   */
  async getFilesByCaptionStatus(status: string): Promise<FileRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('files');
      predicates.equalTo('caption_analysis_status', status);
      predicates.orderByDesc('added_time');

      const resultSet = await this.rdbStore.query(predicates);
      const records: FileRecord[] = [];

      while (resultSet.goToNextRow()) {
        records.push(this.resultSetToFileRecord(resultSet));
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get files by caption status:', err);
      return [];
    }
  }

  // ==================== 语义类别表操作 ====================

  /**
   * 添加语义类别
   */
  async addSemanticCategory(
    categoryName: string,
    description: string,
    keywords: string[],
    categorySystemName: string = '默认类别体系',
    categorySource: string = 'predefined',
    semanticVector?: Uint8Array
  ): Promise<number> {
    if (!this.rdbStore) return -1;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'category_name': categoryName,
        'description': description,
        'keywords': JSON.stringify(keywords),
        'category_system_name': categorySystemName,
        'category_source': categorySource
      };

      if (semanticVector) {
        valueBucket['semantic_vector'] = semanticVector;
      }

      const rowId = await this.rdbStore.insert('semantic_categories', valueBucket);
      return rowId;
    } catch (err) {
      console.error('[DatabaseManager] Failed to add semantic category:', err);
      return -1;
    }
  }

  /**
   * 获取所有语义类别
   */
  async getAllSemanticCategories(): Promise<SemanticCategoryRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('semantic_categories');
      predicates.orderByAsc('category_name');

      const resultSet = await this.rdbStore.query(predicates);
      const records: SemanticCategoryRecord[] = [];

      while (resultSet.goToNextRow()) {
        const record = new SemanticCategoryRecord();
        record.id = resultSet.getLong(resultSet.getColumnIndex('id'));
        record.categoryName = resultSet.getString(resultSet.getColumnIndex('category_name'));
        record.description = resultSet.getString(resultSet.getColumnIndex('description')) || '';
        const keywordsStr = resultSet.getString(resultSet.getColumnIndex('keywords'));
        try {
          record.keywords = keywordsStr ? JSON.parse(keywordsStr) as string[] : [];
        } catch {
          record.keywords = [];
        }
        record.categorySystemName = resultSet.getString(resultSet.getColumnIndex('category_system_name')) || '默认类别体系';
        record.categorySource = resultSet.getString(resultSet.getColumnIndex('category_source')) || 'predefined';
        record.semanticVector = resultSet.getBlob(resultSet.getColumnIndex('semantic_vector')) || new Uint8Array(0);
        record.createdTime = resultSet.getString(resultSet.getColumnIndex('created_time')) || '';
        records.push(record);
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get semantic categories:', err);
      return [];
    }
  }

  /**
   * 根据类别体系获取语义类别
   */
  async getSemanticCategoriesBySystem(categorySystemName: string): Promise<SemanticCategoryRecord[]> {
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates('semantic_categories');
      predicates.equalTo('category_system_name', categorySystemName);
      predicates.orderByAsc('category_name');

      const resultSet = await this.rdbStore.query(predicates);
      const records: SemanticCategoryRecord[] = [];

      while (resultSet.goToNextRow()) {
        const record = new SemanticCategoryRecord();
        record.id = resultSet.getLong(resultSet.getColumnIndex('id'));
        record.categoryName = resultSet.getString(resultSet.getColumnIndex('category_name'));
        record.description = resultSet.getString(resultSet.getColumnIndex('description')) || '';
        const keywordsStr = resultSet.getString(resultSet.getColumnIndex('keywords'));
        try {
          record.keywords = keywordsStr ? JSON.parse(keywordsStr) as string[] : [];
        } catch {
          record.keywords = [];
        }
        record.categorySystemName = resultSet.getString(resultSet.getColumnIndex('category_system_name')) || '默认类别体系';
        record.categorySource = resultSet.getString(resultSet.getColumnIndex('category_source')) || 'predefined';
        record.semanticVector = resultSet.getBlob(resultSet.getColumnIndex('semantic_vector')) || new Uint8Array(0);
        record.createdTime = resultSet.getString(resultSet.getColumnIndex('created_time')) || '';
        records.push(record);
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get semantic categories by system:', err);
      return [];
    }
  }

  /**
   * 更新类别语义向量
   */
  async updateCategoryVector(categoryId: number, semanticVector: Uint8Array): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'semantic_vector': semanticVector
      };

      const predicates = new relationalStore.RdbPredicates('semantic_categories');
      predicates.equalTo('id', categoryId);

      const rowsAffected = await this.rdbStore.update(valueBucket, predicates);
      return rowsAffected > 0;
    } catch (err) {
      console.error('[DatabaseManager] Failed to update category vector:', err);
      return false;
    }
  }

  /**
   * 删除类别体系
   */
  async deleteCategorySystem(categorySystemName: string): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const predicates = new relationalStore.RdbPredicates('semantic_categories');
      predicates.equalTo('category_system_name', categorySystemName);

      const deletedRows = await this.rdbStore.delete(predicates);
      console.info(`[DatabaseManager] Deleted category system: ${categorySystemName}, rows: ${deletedRows}`);
      return true;
    } catch (err) {
      console.error('[DatabaseManager] Failed to delete category system:', err);
      return false;
    }
  }

  /**
   * 获取所有类别体系名称列表
   */
  async getCategorySystemNames(): Promise<string[]> {
    if (!this.rdbStore) return [];

    try {
      // 使用DISTINCT查询获取所有不同的类别体系名称
      const sql = 'SELECT DISTINCT category_system_name FROM semantic_categories ORDER BY category_system_name';
      const resultSet = await this.rdbStore.querySql(sql);
      const names: string[] = [];

      while (resultSet.goToNextRow()) {
        const name = resultSet.getString(0);
        if (name) {
          names.push(name);
        }
      }
      resultSet.close();
      console.info(`[DatabaseManager] Category system names: ${names.join(', ')}`);
      return names;
    } catch (err) {
      console.error('[DatabaseManager] Failed to get category system names:', err);
      return [];
    }
  }

  // ==================== 批量操作 ====================

  /**
   * 批量添加文件
   */
  async addFilesBatch(files: FileBatchItem[]): Promise<number> {
    if (!this.rdbStore) return 0;

    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp', '.heic', '.heif', '.livp', '.ico', '.svg'];
    let count = 0;

    // 获取当前时间作为 added_time
    const now = new Date();
    const addedTimeStr = this.formatDateTimeString(now);

    for (const file of files) {
      const isImage = imageExtensions.some(ext => file.fileType.toLowerCase() === ext);
      const spatiotemporalStatus = isImage ? SpatiotemporalAnalysisStatus.PENDING : SpatiotemporalAnalysisStatus.EMPTY;
      const captionStatus = isImage ? CaptionAnalysisStatus.PENDING : CaptionAnalysisStatus.EMPTY;

      try {
        const valueBucket: relationalStore.ValuesBucket = {
          'file_path': file.filePath,
          'file_name': file.fileName,
          'file_size': file.fileSize,
          'file_type': file.fileType,
          'modified_time': file.modifiedTime,
          'created_time': file.createdTime,
          'analysis_status': FileStatus.PENDING,
          'semantic_categories': '[]',
          'directory_path': file.directoryPath,
          'added_time': addedTimeStr,
          'semantic_filename': '',
          'metadata': '{}',
          'spatiotemporal_analysis_status': spatiotemporalStatus,
          'caption_analysis_status': captionStatus
        };

        await this.rdbStore.insert('files', valueBucket);
        count++;
      } catch (err) {
        // 可能是重复文件，忽略
        console.warn('[DatabaseManager] Skip file:', file.filePath, err);
      }
    }

    return count;
  }

  /**
   * 批量更新文件元数据
   */
  async updateFileMetadataBatch(updates: MetadataUpdateItem[]): Promise<number> {
    if (!this.rdbStore) return 0;

    let count = 0;
    for (const update of updates) {
      const success = await this.updateFileMetadata(update.fileId, update.metadata);
      if (success) count++;
    }
    return count;
  }

  /**
   * 批量添加数据块
   */
  async addDataBlocksBatch(blocks: DataBlockBatchItem[]): Promise<number> {
    if (!this.rdbStore) return 0;

    let count = 0;
    for (const block of blocks) {
      try {
        const valueBucket: relationalStore.ValuesBucket = {
          'block_id': block.blockId,
          'file_id': block.fileId,
          'modality': block.modality,
          'addr': block.addr,
          'page_number': block.pageNumber,
          'position': block.position,
          'metadata': block.metadata
        };

        await this.rdbStore.insert('data_blocks', valueBucket);
        count++;
      } catch (err) {
        console.warn('[DatabaseManager] Skip data block:', block.blockId, err);
      }
    }
    return count;
  }

  /**
   * 批量添加语义块
   */
  async addSemanticBlocksBatch(blocks: SemanticBlockBatchItem[]): Promise<number> {
    if (!this.rdbStore) return 0;

    let count = 0;
    for (const block of blocks) {
      try {
        const valueBucket: relationalStore.ValuesBucket = {
          'semantic_block_id': block.semanticBlockId,
          'data_block_ids': JSON.stringify(block.dataBlockIds),
          'file_id': block.fileId,
          'text_description': block.textDescription,
          'keywords': JSON.stringify(block.keywords),
          'semantic_vector': block.semanticVector
        };

        if (block.semanticFilename) {
          valueBucket['semantic_filename'] = block.semanticFilename;
        }

        await this.rdbStore.insert('semantic_blocks', valueBucket);
        count++;
      } catch (err) {
        console.warn('[DatabaseManager] Skip semantic block:', block.semanticBlockId, err);
      }
    }
    return count;
  }

  /**
   * 批量添加分类结果
   */
  async addClassificationResultsBatch(results: ClassificationResultBatchItem[]): Promise<number> {
    if (!this.rdbStore) return 0;

    let count = 0;
    for (const result of results) {
      try {
        const valueBucket: relationalStore.ValuesBucket = {
          'file_id': result.fileId,
          'semantic_block_id': result.semanticBlockId,
          'category_name': result.categoryName,
          'category_system_name': result.categorySystemName || '默认类别体系',
          'confidence': result.confidence,
          'all_scores': JSON.stringify(result.allScores)
        };

        await this.rdbStore.insert('classification_results', valueBucket);
        count++;
      } catch (err) {
        console.warn('[DatabaseManager] Skip classification result:', result.semanticBlockId, err);
      }
    }
    return count;
  }

  // ==================== 清理操作 ====================

  /**
   * 清空所有数据
   */
  async clearAllData(): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const tables = [
        'user_queries',
        'classification_results',
        'semantic_blocks',
        'data_blocks',
        'files',
        'semantic_categories'
      ];

      for (const table of tables) {
        await this.rdbStore.executeSql(`DELETE FROM ${table}`);
        console.info(`[DatabaseManager] Cleared table: ${table}`);
      }

      // 重置AUTOINCREMENT计数器
      for (const table of ['files', 'data_blocks', 'semantic_blocks', 'classification_results', 'user_queries']) {
        try {
          await this.rdbStore.executeSql(`DELETE FROM sqlite_sequence WHERE name='${table}'`);
        } catch {
          // sqlite_sequence可能不存在，忽略错误
        }
      }
      console.info('[DatabaseManager] AUTOINCREMENT counters reset');

      return true;
    } catch (err) {
      console.error('[DatabaseManager] Failed to clear all data:', err);
      return false;
    }
  }

  /**
   * 清空除类别表外的所有数据
   */
  async clearAllDataExceptCategories(): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const tables = [
        'user_queries',
        'classification_results',
        'semantic_blocks',
        'data_blocks',
        'files'
      ];

      for (const table of tables) {
        await this.rdbStore.executeSql(`DELETE FROM ${table}`);
        console.info(`[DatabaseManager] Cleared table: ${table}`);
      }

      return true;
    } catch (err) {
      console.error('[DatabaseManager] Failed to clear data:', err);
      return false;
    }
  }

  /**
   * 清空分类结果和语义数据，保留文件记录
   */
  async clearClassificationData(): Promise<boolean> {
    if (!this.rdbStore) return false;

    try {
      const tables = [
        'user_queries',
        'classification_results',
        'semantic_blocks',
        'data_blocks'
      ];

      for (const table of tables) {
        await this.rdbStore.executeSql(`DELETE FROM ${table}`);
        console.info(`[DatabaseManager] Cleared table: ${table}`);
      }

      // 重置所有文件状态为PENDING
      await this.rdbStore.executeSql(`UPDATE files SET analysis_status = 0, semantic_categories = '[]'`);

      return true;
    } catch (err) {
      console.error('[DatabaseManager] Failed to clear classification data:', err);
      return false;
    }
  }

  /**
   * 获取数据库文件路径
   */
  getDatabasePath(): string {
    // HarmonyOS RDB存储路径
    // 数据库文件位于: /data/app/el2/100/database/<bundleName>/rdb/FileAnalyzer.db
    return '/data/app/el2/100/database/com.example.fileanalyzer_hos/rdb/FileAnalyzer.db';
  }
}
