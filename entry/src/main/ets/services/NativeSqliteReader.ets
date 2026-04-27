/**
 * NativeSqliteReader - 使用shell sqlite3命令查询系统数据库
 *
 * 在root设备上，可以通过shell执行sqlite3命令查询数据库
 * 这是最直接的方案，无需复杂的数据复制和解析
 *
 * 使用方法：
 * 1. 确保设备已root且安装了sqlite3工具
 * 2. 使用 hdc shell "sqlite3 PATH 'SQL'" 执行查询
 * 3. 解析返回的文本结果
 *
 * 注意：此服务需要在Native层实现，ArkTS无法直接执行shell命令
 * 这里提供查询SQL和数据结构定义，供Native层参考
 */

import { SYSTEM_DB_PATHS } from './RootDataReader';

/**
 * 查询组接口
 */
export interface QueryGroup {
  tables: string;
  schema?: string;
  all?: string;
  names?: string;
  phones?: string;
  dataSchema?: string;
  sessions?: string;
}

/**
 * SQLite查询SQL接口
 */
export interface SqliteQueries {
  contacts: QueryGroup;
  callLog: QueryGroup;
  sms: QueryGroup;
  calendar: QueryGroup;
}

/**
 * 数据库Schema接口
 */
export interface DbSchemaInfo {
  tables: string[];
  description: string;
  note?: string;
}

export interface DbSchema {
  contacts: DbSchemaInfo;
  callLog: DbSchemaInfo;
  sms: DbSchemaInfo;
  calendar: DbSchemaInfo;
}

/**
 * SQLite查询SQL语句定义
 * 用于查询系统数据库
 *
 * 重要说明：
 * 1. 需要先设置 SELinux 为 Permissive：setenforce 0
 * 2. 联系人数据库是 HarmonyOS 原生数据库（非 Android 兼容层）
 * 3. 表名：raw_contact（联系人），contact_data（电话等）
 * 4. 字段：display_name（姓名），detail_info（电话/邮箱）
 */
export const SQLITE_QUERIES: SqliteQueries = {
  /**
   * 联系人查询
   * contacts.db 表结构（HarmonyOS原生）
   */
  contacts: {
    // 列出所有表
    tables: `.tables`,

    // 查询所有联系人姓名
    names: `SELECT display_name FROM raw_contact WHERE display_name IS NOT NULL AND display_name != '' ORDER BY display_name LIMIT ?;`,

    // 查询联系人电话（contact_data表）
    phones: `
      SELECT
        rc.display_name,
        cd.detail_info as phone_number
      FROM contact_data cd
      JOIN raw_contact rc ON cd.raw_contact_id = rc._id
      WHERE cd.type_id != 1
      ORDER BY rc.display_name
      LIMIT ?;
    `,

    // 查询contact_data表结构
    dataSchema: `SELECT type_id, detail_info FROM contact_data LIMIT 10;`
  },

  /**
   * 通话记录查询
   * calls.db（独立数据库）表结构：calls, greetings, greeting_status
   */
  callLog: {
    // 列出所有表
    tables: `.tables`,

    // 查询通话记录
    all: `
      SELECT
        _id,
        number,
        date,
        duration,
        type,
        name
      FROM calls
      ORDER BY date DESC
      LIMIT ?;
    `,

    // 查询表结构
    schema: `PRAGMA table_info(calls);`
  },

  /**
   * 短信查询
   * sms_mms_el1.db 表：sms_mms_info, session, mms_info, mms_part 等
   */
  sms: {
    // 列出所有表
    tables: `.tables`,

    // 查询短信表结构
    schema: `PRAGMA table_info(sms_mms_info);`,

    // 查询短信数据
    all: `SELECT * FROM sms_mms_info LIMIT ?;`,

    // 查询会话
    sessions: `SELECT * FROM session LIMIT ?;`
  },

  /**
   * 日历事件查询
   * calendardataEl1.db 表：CalendarAlerts（可能只有一个表）
   */
  calendar: {
    // 列出所有表
    tables: `.tables`,

    // 查询表结构
    schema: `PRAGMA table_info(CalendarAlerts);`,

    // 查询数据
    all: `SELECT * FROM CalendarAlerts LIMIT ?;`
  }
};

/**
 * 数据库表结构文档（已验证）
 * 实际发现的表结构
 */
export const DB_SCHEMA: DbSchema = {
  /**
   * contacts.db - 联系人数据库（HarmonyOS原生）
   *
   * 实际表：contact, raw_contact, contact_data 等
   *
   * 已验证数据：
   * - raw_contact 表包含 display_name 字段（姓名）
   * - contact_data 表包含 detail_info 字段（电话/邮箱）
   * - type_id=1 表示邮箱，其他为电话号码
   */
  contacts: {
    tables: ['contact', 'raw_contact', 'contact_data', 'contacts_contact', 'deleted_contact'],
    description: '联系人数据库（HarmonyOS原生）',
    note: '已验证数据存在，raw_contact.display_name 包含姓名'
  },

  /**
   * calls.db - 通话记录数据库（独立）
   *
   * 实际表：calls, greetings, greeting_status, voicemail_status
   */
  callLog: {
    tables: ['calls', 'greetings', 'greeting_status', 'voicemail_status'],
    description: '通话记录数据库（独立于contacts2.db）',
    note: '需要验证 calls 表是否包含数据'
  },

  /**
   * sms_mms_el1.db - 短信数据库
   *
   * 实际表：sms_mms_info, session, mms_info, mms_part, mms_pdu, chatbots 等
   * 注意：没有传统的 sms 表，使用 sms_mms_info
   */
  sms: {
    tables: ['sms_mms_info', 'session', 'mms_info', 'mms_part', 'mms_pdu', 'chatbots', 'favorate_info'],
    description: '短信和彩信数据库',
    note: '表结构与传统Android不同'
  },

  /**
   * calendardataEl1.db - 日历数据库
   *
   * 实际表：CalendarAlerts（仅发现这一个表）
   * 可能日历事件存储在其他位置
   */
  calendar: {
    tables: ['CalendarAlerts'],
    description: '日历提醒数据库',
    note: '可能仅存储提醒，事件数据可能在其他位置'
  }
};

/**
 * HDC命令接口定义
 */
export interface HdcCommands {
  setSelinuxPermissive: string;
  listContactsTables: string;
  listCallLogTables: string;
  listSmsTables: string;
  listCalendarTables: string;
  queryContactNames: (limit: number) => string;
  queryCallLog: (limit: number) => string;
  querySms: (limit: number) => string;
  queryCalendar: (limit: number) => string;
  queryTableSchema: (dbPath: string, tableName: string) => string;
}

/**
 * HDC命令模板（已验证）
 * 在PC端通过hdc执行这些命令
 *
 * 重要：需要先设置 SELinux 为 Permissive
 * $HDC shell "setenforce 0"
 */
export const HDC_COMMANDS: HdcCommands = {
  /**
   * 设置 SELinux 为 Permissive（必须先执行）
   */
  setSelinuxPermissive: 'setenforce 0',

  /**
   * 查看联系人数据库所有表
   */
  listContactsTables: `sqlite3 "/data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db" ".tables"`,

  /**
   * 查看通话记录数据库所有表
   */
  listCallLogTables: `sqlite3 "${SYSTEM_DB_PATHS.callLog}" ".tables"`,

  /**
   * 查看短信数据库所有表
   */
  listSmsTables: `sqlite3 "${SYSTEM_DB_PATHS.sms}" ".tables"`,

  /**
   * 查看日历数据库所有表
   */
  listCalendarTables: `sqlite3 "${SYSTEM_DB_PATHS.calendar}" ".tables"`,

  /**
   * 查询联系人姓名
   */
  queryContactNames: (limit: number = 10) => {
    return `sqlite3 "/data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db" "SELECT display_name FROM raw_contact WHERE display_name IS NOT NULL LIMIT ${limit}"`;
  },

  /**
   * 查询通话记录
   */
  queryCallLog: (limit: number = 10) => {
    return `sqlite3 "${SYSTEM_DB_PATHS.callLog}" "SELECT _id, number, date, duration, type, name FROM calls ORDER BY date DESC LIMIT ${limit}"`;
  },

  /**
   * 查询短信数据
   */
  querySms: (limit: number = 10) => {
    return `sqlite3 "${SYSTEM_DB_PATHS.sms}" "SELECT * FROM sms_mms_info LIMIT ${limit}"`;
  },

  /**
   * 查询日历数据
   */
  queryCalendar: (limit: number = 10) => {
    return `sqlite3 "${SYSTEM_DB_PATHS.calendar}" "SELECT * FROM CalendarAlerts LIMIT ${limit}"`;
  },

  /**
   * 查询表结构
   */
  queryTableSchema: (dbPath: string, tableName: string) => {
    return `sqlite3 "${dbPath}" "PRAGMA table_info(${tableName})"`;
  }
};

/**
 * 输出解析函数
 * sqlite3默认输出格式：列以|分隔，行以换行分隔
 */
export function parseSqliteOutput(output: string): string[][] {
  if (!output || output.trim() === '') {
    return [];
  }

  const lines = output.trim().split('\n');
  return lines.map(line => line.split('|'));
}

/**
 * 示例使用方法（PC端执行）
 *
 * ```bash
 * HDC="/d/Program Files/Huawei/DevEco Studio6.1/sdk/default/openharmony/toolchains/hdc.exe"
 *
 * # 1. 首先设置 SELinux 为 Permissive（必须执行）
 * $HDC shell "setenforce 0"
 *
 * # 2. 验证 SELinux 状态
 * $HDC shell "getenforce"
 * # 应返回: Permissive
 *
 * # 3. 查看联系人数据库所有表（HarmonyOS原生数据库）
 * $HDC shell "sqlite3 /data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db '.tables'"
 *
 * # 4. 查看通话记录数据库所有表
 * $HDC shell "sqlite3 /data/virt_service/rgm_hmos/anco_hmos_data/data/com.android.providers.contacts/databases/calls.db '.tables'"
 *
 * # 5. 查看短信数据库所有表
 * $HDC shell "sqlite3 /data/app/el1/100/database/com.ohos.telephonydataability/rdb/sms_mms_el1.db '.tables'"
 *
 * # 6. 查看日历数据库所有表
 * $HDC shell "sqlite3 /data/app/el1/100/database/com.huawei.hmos.calendardata/entry/rdb/calendardataEl1.db '.tables'"
 *
 * # 7. 查询联系人（raw_contact表）
 * $HDC shell "sqlite3 /data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db 'SELECT display_name FROM raw_contact LIMIT 10'"
 *
 * # 8. 查询联系人电话（contact_data表）
 * $HDC shell "sqlite3 /data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db 'SELECT rc.display_name, cd.detail_info FROM contact_data cd JOIN raw_contact rc ON cd.raw_contact_id = rc._id LIMIT 10'"
 *
 * # 9. 查询通话记录
 * $HDC shell "sqlite3 /data/virt_service/rgm_hmos/anco_hmos_data/data/com.android.providers.contacts/databases/calls.db 'SELECT _id, number, date, duration FROM calls LIMIT 10'"
 *
 * # 10. 查询短信
 * $HDC shell "sqlite3 /data/app/el1/100/database/com.ohos.telephonydataability/rdb/sms_mms_el1.db 'SELECT * FROM sms_mms_info LIMIT 10'"
 *
 * # 11. 查询表结构
 * $HDC shell "sqlite3 /data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db 'PRAGMA table_info(raw_contact)'"
 * ```
 *
 * 已验证结果：
 * - contacts.db (HarmonyOS原生): raw_contact 表包含 display_name，已验证有联系人数据
 * - calls.db: 独立数据库，包含 calls 表
 * - sms_mms_el1.db: 表名是 sms_mms_info 而不是 sms
 * - calendardataEl1.db: 只有 CalendarAlerts 表
 */