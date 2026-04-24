/**
 * ChineseTokenizer - 中文分词器
 *
 * 实现正向最大匹配分词算法，用于替代Python的jieba分词库。
 * 支持词典加载、分词和关键词提取功能。
 */

import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';

/**
 * 停用词集合 - 常见无意义词
 */
const STOP_WORDS: Set<string> = new Set([
  '的', '了', '和', '是', '就', '都', '而', '及', '与', '着',
  '或', '一个', '没有', '我们', '你们', '他们', '她们', '它们',
  '这个', '那个', '这些', '那些', '什么', '怎么', '如何', '为何',
  '可以', '可能', '应该', '必须', '需要', '能够', '已经', '正在',
  '在', '有', '这', '那', '为', '以', '上', '下', '不', '也',
  '但', '却', '又', '还', '再', '才', '只', '更', '很', '最',
  '我', '你', '他', '她', '它', '们', '啊', '呢', '吧', '吗',
  '呀', '哦', '嗯', '哈', '哎', '唉', '哇', '嘛', '哪', '谁',
  '某', '每', '各', '另', '其', '此', '彼', '本', '该', '某',
  '若', '如', '若', '虽', '虽', '然', '然', '若', '因', '所'
]);

/**
 * 中文分词器类
 * 使用正向最大匹配算法进行中文分词
 */
export class ChineseTokenizer {
  private dictionary: Set<string> = new Set();
  private maxWordLength: number = 4;
  private initialized: boolean = false;
  private wordFrequency: Map<string, number> = new Map();

  /**
   * 构造函数
   * @param maxWordLength 最大词长，默认为4
   */
  constructor(maxWordLength: number = 4) {
    this.maxWordLength = maxWordLength;
  }

  /**
   * 从rawfile加载词典
   * @param context 应用上下文
   * @param dictPath 词典文件路径，默认为 'dict_small.txt'
   */
  async loadDictionary(context: common.Context, dictPath: string = 'dict_small.txt'): Promise<void> {
    try {
      const resMgr: resourceManager.ResourceManager = context.resourceManager;
      const fileData: Uint8Array = await resMgr.getRawFileContent(dictPath);
      const textDecoder = util.TextDecoder.create('utf-8');
      const text: string = textDecoder.decodeToString(fileData);

      // 解析词典内容
      const lines: string[] = text.split('\n');
      for (const line of lines) {
        const word: string = line.trim();
        if (word.length > 0 && !word.startsWith('#')) {
          this.dictionary.add(word);
          // 更新最大词长
          if (word.length > this.maxWordLength) {
            this.maxWordLength = word.length;
          }
        }
      }

      this.initialized = true;
      console.info(`ChineseTokenizer: Loaded ${this.dictionary.size} words from dictionary`);
    } catch (err) {
      console.error(`ChineseTokenizer: Failed to load dictionary: ${err}`);
      // 即使加载失败，也标记为初始化完成，使用基本分词
      this.initialized = true;
    }
  }

  /**
   * 直接加载词典文本（用于测试或内嵌词典）
   * @param dictText 词典文本内容，每行一个词
   */
  loadDictionaryFromText(dictText: string): void {
    const lines: string[] = dictText.split('\n');
    for (const line of lines) {
      const word: string = line.trim();
      if (word.length > 0 && !word.startsWith('#')) {
        this.dictionary.add(word);
        if (word.length > this.maxWordLength) {
          this.maxWordLength = word.length;
        }
      }
    }
    this.initialized = true;
  }

  /**
   * 检查是否已初始化
   * @returns 是否已加载词典
   */
  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * 获取词典大小
   * @returns 词典中的词数
   */
  getDictionarySize(): number {
    return this.dictionary.size;
  }

  /**
   * 分词 - 正向最大匹配算法
   * @param text 待分词文本
   * @returns 分词结果数组
   */
  tokenize(text: string): string[] {
    if (!text || text.length === 0) {
      return [];
    }

    const tokens: string[] = [];
    let i = 0;
    const len = text.length;

    while (i < len) {
      // 跳过空白字符
      if (this.isWhitespace(text[i])) {
        i++;
        continue;
      }

      // 处理非中文字符（英文、数字、标点等）
      if (!this.isChinese(text[i])) {
        // 提取连续的非中文字符
        let nonChineseEnd = i;
        while (nonChineseEnd < len && !this.isChinese(text[nonChineseEnd]) &&
               !this.isWhitespace(text[nonChineseEnd])) {
          nonChineseEnd++;
        }
        const token = text.substring(i, nonChineseEnd);
        // 只保留有意义的非中文token（长度>1的英文或数字）
        if (this.isAlphanumeric(token) && token.length > 1) {
          tokens.push(token.toLowerCase());
        }
        i = nonChineseEnd;
        continue;
      }

      // 中文分词 - 正向最大匹配
      let matched = false;
      // 从最大词长开始尝试匹配
      for (let j = Math.min(this.maxWordLength, len - i); j >= 1; j--) {
        const candidate = text.substring(i, i + j);
        if (this.dictionary.has(candidate)) {
          tokens.push(candidate);
          i += j;
          matched = true;
          break;
        }
      }

      // 如果没有匹配到词，按单字切分
      if (!matched) {
        tokens.push(text[i]);
        i++;
      }
    }

    return tokens;
  }

  /**
   * 分词并过滤停用词
   * @param text 待分词文本
   * @param filterStopWords 是否过滤停用词，默认为true
   * @returns 分词结果数组
   */
  tokenizeFiltered(text: string, filterStopWords: boolean = true): string[] {
    const tokens = this.tokenize(text);
    if (!filterStopWords) {
      return tokens;
    }
    return tokens.filter(token => !STOP_WORDS.has(token));
  }

  /**
   * 关键词提取 - 基于词频
   * @param text 待提取文本
   * @param topK 返回前K个关键词，默认为10
   * @returns 关键词数组（按词频降序）
   */
  extractKeywords(text: string, topK: number = 10): string[] {
    if (!text || text.trim().length === 0) {
      return [];
    }

    // 分词并过滤停用词
    const tokens = this.tokenizeFiltered(text, true);

    // 计算词频
    const freq: Map<string, number> = new Map();
    for (const token of tokens) {
      // 过滤单字（除非在词典中）
      if (token.length === 1 && !this.dictionary.has(token)) {
        continue;
      }
      const existingCount = freq.get(token);
      const count: number = existingCount !== undefined ? existingCount : 0;
      freq.set(token, count + 1);
    }

    // 排序并返回前topK个
    const entries: [string, number][] = Array.from(freq.entries());
    entries.sort((a, b) => b[1] - a[1]);
    const topEntries = entries.slice(0, topK);

    const result: string[] = [];
    for (const entry of topEntries) {
      result.push(entry[0]);
    }
    return result;
  }

  /**
   * 计算文本相似度（基于关键词重叠）
   * @param text1 文本1
   * @param text2 文本2
   * @param topK 用于比较的关键词数量
   * @returns 相似度分数（0-1）
   */
  calculateSimilarity(text1: string, text2: string, topK: number = 20): number {
    const keywords1 = new Set(this.extractKeywords(text1, topK));
    const keywords2 = new Set(this.extractKeywords(text2, topK));

    if (keywords1.size === 0 && keywords2.size === 0) {
      return 0;
    }

    // Jaccard相似度
    let intersection = 0;
    keywords1.forEach(word => {
      if (keywords2.has(word)) {
        intersection++;
      }
    });

    const union = keywords1.size + keywords2.size - intersection;
    return union > 0 ? intersection / union : 0;
  }

  /**
   * 判断字符是否为中文字符
   * @param char 待判断字符
   * @returns 是否为中文字符
   */
  private isChinese(char: string): boolean {
    const code = char.charCodeAt(0);
    // CJK统一汉字范围：U+4E00 到 U+9FFF
    // CJK扩展A：U+3400 到 U+4DBF
    return (code >= 0x4E00 && code <= 0x9FFF) ||
           (code >= 0x3400 && code <= 0x4DBF);
  }

  /**
   * 判断字符是否为空白字符
   * @param char 待判断字符
   * @returns 是否为空白字符
   */
  private isWhitespace(char: string): boolean {
    return char === ' ' || char === '\t' || char === '\n' ||
           char === '\r' || char === '\u3000'; // 包含全角空格
  }

  /**
   * 判断字符串是否为字母数字组合
   * @param str 待判断字符串
   * @returns 是否为字母数字组合
   */
  private isAlphanumeric(str: string): boolean {
    return /^[a-zA-Z0-9]+$/.test(str);
  }
}

/**
 * 全局分词器实例（单例模式）
 */
let globalTokenizer: ChineseTokenizer | null = null;

/**
 * 获取全局分词器实例
 * @param context 应用上下文（首次调用时需要）
 * @returns 中文分词器实例
 */
export async function getTokenizer(context?: common.Context): Promise<ChineseTokenizer> {
  if (globalTokenizer === null) {
    globalTokenizer = new ChineseTokenizer();
    if (context) {
      await globalTokenizer.loadDictionary(context);
    } else {
      // 使用内置的基本词典
      globalTokenizer.loadDictionaryFromText(getBuiltInDictionary());
    }
  }
  return globalTokenizer;
}

/**
 * 重置全局分词器（用于测试）
 */
export function resetTokenizer(): void {
  globalTokenizer = null;
}

/**
 * 获取内置基本词典（约300个常用词）
 * @returns 词典文本
 */
export function getBuiltInDictionary(): string {
  return `文件
分析
管理
系统
技术
文档
报告
会议
产品
项目
开发
设计
测试
部署
维护
更新
版本
功能
需求
模块
组件
接口
数据
用户
权限
配置
设置
日志
错误
异常
警告
信息
提示
状态
类型
名称
路径
目录
文件夹
存储
内存
磁盘
网络
连接
请求
响应
服务器
客户端
协议
格式
编码
解码
压缩
解压
加密
解密
安全
认证
授权
登录
注册
退出
搜索
查询
结果
列表
详情
编辑
删除
添加
创建
保存
取消
确认
提交
审核
发布
回收
备份
恢复
优化
性能
效率
质量
问题
解决
方案
计划
目标
进度
任务
工作
流程
规范
标准
策略
规则
条件
逻辑
算法
结构
框架
平台
环境
工具
资源
服务
应用
网页
网站
页面
内容
标题
描述
标签
分类
排序
筛选
过滤
统计
图表
报表
导出
导入
上传
下载
复制
粘贴
剪切
移动
重命名
属性
参数
变量
常量
函数
方法
对象
实例
类型
定义
声明
引用
调用
返回
参数
输入
输出
字符串
数字
布尔
数组
集合
映射
列表
循环
条件
判断
分支
跳转
中断
继续
返回
抛出
捕获
处理
程序
代码
脚本
命令
指令
操作
执行
运行
启动
停止
暂停
恢复
重试
等待
超时
完成
成功
失败
错误
异常
崩溃
重启
修复
更新
升级
变更
修改
调整
优化
重构
清理
检查
验证
测试
调试
监控
告警
通知
消息
邮件
短信
推送
订阅
取消
关注
收藏
分享
评论
点赞
评分
反馈
建议
意见
评价
分析
统计
计算
转换
处理
生成
创建
销毁
初始化
加载
卸载
打开
关闭
读取
写入
追加
清空
填充
排序
分组
合并
拆分
过滤
映射
遍历
迭代
递归
查找
定位
替换
匹配
比较
判断
计算
统计
汇总
平均
总计
计数
最大
最小
求和
乘积
比值
比例
百分比
概率
可能
确定
未知
无效
有效
正确
错误
合法
非法
允许
禁止
启用
禁用
显示
隐藏
展开
折叠
锁定
解锁
冻结
解冻
激活
停用
启用
重启
刷新
重置
恢复
撤销
重做
前进
后退
上一步
下一步
首页
末页
上一页
下一页
跳转
返回
退出
取消
确认
提交
保存
发布
删除
移除
清空
全部
部分
单个
多个
批量
单个
全部
当前
历史
记录
详情
摘要
概览
视图
模式
状态
阶段
步骤
过程
结果
效果
影响
原因
因素
关系
关联
依赖
引用
包含
排除
覆盖
补充
扩展
继承
实现
接口
抽象
具体
一般
特殊
公共
私有
保护
内部
外部
本地
远程
在线
离线
同步
异步
实时
定时
手动
自动
主动
被动
正向
反向
逆向
顺序
倒序
升序
降序
自然
人工
智能
机器
深度
学习
训练
预测
推理
识别
检测
分割
提取
生成
合成
翻译
转换
编码
解码
压缩
解压
加密
解密
签名
验证
认证
授权
登录
注册
注销
退出
切换
选择
输入
输出
导入
导出
上传
下载
发送
接收
推送
拉取
同步
备份
恢复
迁移
转换
适配
兼容
集成
对接
联调
测试
验收
交付
上线
发布
运维
监控
告警
日志
统计
分析
报表
大屏
仪表盘
看板
视图
图表
图形
图像
视频
音频
文本
语音
消息
通知
提醒
待办
任务
计划
项目
产品
版本
迭代
冲刺
里程碑
发布
更新
升级
变更
修复
优化
重构
清理
总结
回顾
复盘
反思
改进
提升
突破
创新
探索
研究
开发
设计
实现
测试
部署
运维
运营
推广
营销
销售
服务
支持
售后
客服
反馈
投诉
建议
评价
评分
点赞
收藏
分享
转发
评论
回复
关注
订阅
取消
购买
支付
退款
订单
商品
库存
价格
优惠
折扣
活动
促销
广告
推荐
排名
积分
等级
权限
角色
用户
账户
资产
余额
收入
支出
流水
账单
发票
合同
协议
条款
规则
政策
法律
法规
标准
规范
制度
流程
审批
签字
盖章
归档
备案
存档
记录
日志
轨迹
历史
版本
快照
镜像
备份
恢复
容灾
高可用
负载均衡
集群
分布式
微服务
容器
编排
调度
资源
配置
环境
变量
参数
选项
设置
偏好
语言
地区
时区
格式
样式
主题
皮肤
布局
组件
控件
元素
节点
属性
事件
动作
行为
状态
生命周期
初始化
挂载
更新
卸载
销毁`;
}