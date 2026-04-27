/**
 * RootDataReader - Root设备系统数据读取服务
 *
 * 用于在已root的HarmonyOS NEXT设备上读取系统数据库
 * 包括：联系人、短信、通话记录、日历等
 *
 * 原理：root权限可以读取任意文件，绕过权限系统
 * 方法：复制系统数据库到应用目录，然后用relationalStore查询
 *
 * 使用前提：设备已root（hdc shell whoami 返回 root）
 */
import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 系统数据库路径接口
 */
export interface SystemDbPaths {
  contacts: string;
  callLog: string;
  sms: string;
  calendar: string;
}

/**
 * 系统数据库路径定义
 * 这些路径在root设备上可读
 *
 * 重要发现：
 * 1. 联系人数据在 HarmonyOS 原生数据库（非 Android 兼容层）
 *    正确路径：/data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db
 *    表结构：raw_contact（含 display_name），contact_data（含 detail_info）
 * 2. calls.db 是独立的数据库（不是 contacts2.db 的表）
 * 3. 短信数据库表名是 sms_mms_info 而不是 sms
 * 4. 需要设置 SELinux 为 Permissive 才能访问：setenforce 0
 */
export const SYSTEM_DB_PATHS: SystemDbPaths = {
  // 联系人数据库（HarmonyOS原生）
  // 已验证：raw_contact 表包含 display_name，contact_data 表包含 detail_info
  contacts: '/data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db',

  // 通话记录数据库（独立数据库）
  callLog: '/data/virt_service/rgm_hmos/anco_hmos_data/data/com.android.providers.contacts/databases/calls.db',

  // 短信数据库（HarmonyOS原生）
  sms: '/data/app/el1/100/database/com.ohos.telephonydataability/rdb/sms_mms_el1.db',

  // 日历数据库
  calendar: '/data/app/el1/100/database/com.huawei.hmos.calendardata/entry/rdb/calendardataEl1.db'
};

/**
 * 联系人数据
 */
export interface ContactData {
  id: number;
  displayName: string;
  phoneNumber: string;
  email?: string;
}

/**
 * 短信数据
 */
export interface SmsData {
  id: number;
  address: string;        // 发送者/接收者号码
  body: string;           // 短信内容
  date: number;           // 时间戳
  type: number;           // 1=接收, 2=发送
  threadId: number;       // 会话ID
}

/**
 * 通话记录数据
 */
export interface CallLogData {
  id: number;
  number: string;         // 电话号码
  date: number;           // 时间戳
  duration: number;       // 通话时长（秒）
  type: number;           // 1=来电, 2=去电, 3=未接
  name?: string;          // 联系人姓名
}

/**
 * 日历事件数据
 */
export interface CalendarEventData {
  id: number;
  title: string;
  description?: string;
  dtstart: number;        // 开始时间戳
  dtend: number;          // 结束时间戳
  eventLocation?: string; // 地点
  calendarId: number;     // 所属日历ID
}

/**
 * Root设备系统数据读取服务
 *
 * 使用说明：
 * 由于应用无法直接访问系统数据库目录（即使设备root，应用仍运行在沙箱中），
 * 需要先通过 hdc shell 命令将数据库复制到应用的 databaseDir 目录。
 *
 * 复制命令示例：
 * hdc shell "cp /data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db /data/app/el2/100/database/com.example.fileanalyzer_hos/entry/rdb/contacts.db"
 */
export class RootDataReader {
  private context: common.Context;
  private databaseDir: string; // relationalStore 的数据库目录

  constructor(context: common.Context) {
    this.context = context;
    // 获取 databaseDir（relationalStore 默认存储位置）
    // 在 HarmonyOS NEXT 中，databaseDir 通常是 /data/storage/el2/base/database/
    // 实际物理路径是 /data/app/el2/100/database/包名/entry/rdb/
    try {
      this.databaseDir = context.databaseDir || '';
      console.info(`[RootDataReader] Database directory (virtual): ${this.databaseDir}`);
    } catch (e) {
      console.warn(`[RootDataReader] databaseDir not available: ${(e as Error).message}`);
      this.databaseDir = '';
    }
  }

  /**
   * 检查是否具有root权限
   * 注意：此方法无法在应用内执行shell命令，仅作为标识
   */
  isRootDevice(): boolean {
    // 实际检查需要在应用外执行 hdc shell whoami
    // 这里假设设备已root，通过尝试读取预复制的数据库来验证
    return true;
  }

  /**
   * 获取预复制的数据库路径
   * 数据库需要通过 hdc shell 预先复制到应用的 databaseDir 目录
   * @param dbType 数据库类型: contacts | sms | calendar | callLog
   * @returns 数据库文件路径（如果存在）
   */
  private getPreCopiedDatabasePath(dbType: string): string {
    switch (dbType) {
      case 'contacts':
        return `${this.databaseDir}/contacts.db`;
      case 'sms':
        return `${this.databaseDir}/sms.db`;
      case 'callLog':
        return `${this.databaseDir}/calls.db`;
      case 'calendar':
        return `${this.databaseDir}/calendar.db`;
      default:
        return '';
    }
  }

  /**
   * 检查预复制的数据库是否存在
   * @param dbType 数据库类型
   */
  async checkPreCopiedDatabaseExists(dbType: string): Promise<boolean> {
    const dbPath = this.getPreCopiedDatabasePath(dbType);
    try {
      const stat = fs.statSync(dbPath);
      console.info(`[RootDataReader] Pre-copied ${dbType} database found: ${dbPath}, size: ${stat.size} bytes`);
      return true;
    } catch (err) {
      console.warn(`[RootDataReader] Pre-copied ${dbType} database NOT found at: ${dbPath}`);
      return false;
    }
  }

  /**
   * 打开预复制的数据库
   * @param dbType 数据库类型
   * @returns RdbStore实例
   */
  private async openPreCopiedDatabase(dbType: string): Promise<relationalStore.RdbStore> {
    const dbPath = this.getPreCopiedDatabasePath(dbType);
    const dbName = dbPath.split('/').pop() || 'temp.db';

    console.info(`[RootDataReader] Opening pre-copied database: ${dbPath}`);

    // 使用完整的数据库文件路径作为名称
    // HarmonyOS NEXT 的 relationalStore 可以打开 filesDir 中的数据库
    const storeConfig: relationalStore.StoreConfig = {
      name: dbName,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    try {
      // 先检查文件是否存在
      const stat = fs.statSync(dbPath);
      console.info(`[RootDataReader] Database file size: ${stat.size} bytes`);

      const store = await relationalStore.getRdbStore(this.context, storeConfig);
      console.info(`[RootDataReader] Database opened successfully: ${dbName}`);
      return store;
    } catch (err) {
      console.error(`[RootDataReader] Failed to open database ${dbPath}: ${(err as Error).message}`);
      throw new Error(`Failed to open ${dbType} database: ${(err as Error).message}`);
    }
  }

  /**
   * 打开数据库
   * @param dbType 数据库类型
   * @returns RdbStore实例
   */
  private async openDatabase(dbType: string): Promise<relationalStore.RdbStore> {
    const dbName = `${dbType}.db`;

    console.info(`[RootDataReader] Opening database: ${dbName}`);

    const storeConfig: relationalStore.StoreConfig = {
      name: dbName,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    try {
      const store = await relationalStore.getRdbStore(this.context, storeConfig);
      console.info(`[RootDataReader] Database opened successfully: ${dbName}`);
      return store;
    } catch (err) {
      const errorMsg = (err as Error).message;
      console.error(`[RootDataReader] Failed to open database ${dbName}: ${errorMsg}`);
      throw new Error(`Failed to open ${dbType} database: ${errorMsg}`);
    }
  }

  /**
   * 读取联系人数据
   * @param limit 最大返回数量，默认100
   */
  async readContacts(limit: number = 100): Promise<ContactData[]> {
    console.info(`[RootDataReader] Reading contacts (limit: ${limit})`);

    try {
      // 直接尝试打开 contacts.db（使用 relationalStore）
      const store = await this.openDatabase('contacts');

      // 查询联系人 - 使用 raw_contact 表（HarmonyOS原生表名）
      // 主键列名是 id，不是 _id
      console.info(`[RootDataReader] Querying raw_contact table...`);
      const resultSet = await store.querySql(
        `SELECT id, display_name FROM raw_contact WHERE display_name IS NOT NULL AND display_name != '' ORDER BY display_name LIMIT ${limit}`
      );

      const contacts: ContactData[] = [];
      while (resultSet.goToNextRow()) {
        const id = resultSet.getLong(resultSet.getColumnIndex('id'));
        const displayName = resultSet.getString(resultSet.getColumnIndex('display_name'));

        contacts.push({
          id: id,
          displayName: displayName,
          phoneNumber: ''
        });
      }
      resultSet.close();
      console.info(`[RootDataReader] Found ${contacts.length} contacts from raw_contact`);

      // 对于每个联系人，查询电话号码（从 contact_data 表）
      // contact_data 表：detail_info 字段包含电话/邮箱等
      for (const contact of contacts) {
        try {
          const phoneResultSet = await store.querySql(
            `SELECT detail_info FROM contact_data WHERE raw_contact_id = ${contact.id} AND type_id != 1 LIMIT 5`
          );
          const phones: string[] = [];
          while (phoneResultSet.goToNextRow()) {
            const phone = phoneResultSet.getString(phoneResultSet.getColumnIndex('detail_info'));
            if (phone && phone.trim() !== '') {
              phones.push(phone.trim());
            }
          }
          phoneResultSet.close();
          contact.phoneNumber = phones.join(', ');
        } catch (e) {
          console.warn(`[RootDataReader] Failed to query phone for contact ${contact.id}: ${(e as Error).message}`);
        }
      }

      console.info(`[RootDataReader] Contacts read: ${contacts.length}`);

      return contacts;
    } catch (err) {
      console.error(`[RootDataReader] readContacts failed: ${(err as Error).message}`);
      return [];
    }
  }

  /**
   * 读取短信数据
   * @param limit 最大返回数量，默认100
   */
  async readSms(limit: number = 100): Promise<SmsData[]> {
    console.info(`[RootDataReader] Reading SMS (limit: ${limit})`);

    try {
      // 检查预复制的数据库是否存在
      const exists = await this.checkPreCopiedDatabaseExists('sms');
      if (!exists) {
        console.error(`[RootDataReader] SMS database not found. Please copy it first using hdc shell.`);
        throw new Error('短信数据库未找到。请先通过 hdc shell 复制数据库到应用 databaseDir:\n' +
          'hdc shell "cp /data/app/el1/100/database/com.ohos.telephonydataability/rdb/sms_mms_el1.db ' +
          '/data/app/el2/100/database/com.example.fileanalyzer_hos/entry/rdb/sms.db"');
      }

      const store = await this.openPreCopiedDatabase('sms');

      // 查询sms_mms_info表
      const smsList: SmsData[] = [];

      try {
        const resultSet = await store.querySql(
          `SELECT * FROM sms_mms_info LIMIT ${limit}`
        );

        while (resultSet.goToNextRow()) {
          // 尝试获取各个字段
          try {
            smsList.push({
              id: resultSet.getLong(resultSet.getColumnIndex('_id')),
              address: '',
              body: '',
              date: 0,
              type: 0,
              threadId: 0
            });
          } catch (e) {
            // 字段可能不存在
          }
        }
        resultSet.close();
      } catch (e) {
        console.warn(`[RootDataReader] sms_mms_info query failed: ${(e as Error).message}`);
      }

      console.info(`[RootDataReader] SMS read: ${smsList.length}`);

      return smsList;
    } catch (err) {
      console.error(`[RootDataReader] readSms failed: ${(err as Error).message}`);
      return [];
    }
  }

  /**
   * 读取通话记录
   * @param limit 最大返回数量，默认100
   */
  async readCallLog(limit: number = 100): Promise<CallLogData[]> {
    console.info(`[RootDataReader] Reading call log (limit: ${limit})`);

    try {
      // 检查预复制的数据库是否存在
      const exists = await this.checkPreCopiedDatabaseExists('callLog');
      if (!exists) {
        console.error(`[RootDataReader] CallLog database not found. Please copy it first using hdc shell.`);
        throw new Error('通话记录数据库未找到。请先通过 hdc shell 复制数据库到应用 databaseDir:\n' +
          'hdc shell "cp /data/virt_service/rgm_hmos/anco_hmos_data/data/com.android.providers.contacts/databases/calls.db ' +
          '/data/app/el2/100/database/com.example.fileanalyzer_hos/entry/rdb/calls.db"');
      }

      const store = await this.openPreCopiedDatabase('callLog');

      const callLogs: CallLogData[] = [];

      try {
        const resultSet = await store.querySql(
          `SELECT _id, number, date, duration, type, name FROM calls ORDER BY date DESC LIMIT ${limit}`
        );

        while (resultSet.goToNextRow()) {
          callLogs.push({
            id: resultSet.getLong(resultSet.getColumnIndex('_id')),
            number: resultSet.getString(resultSet.getColumnIndex('number')),
            date: resultSet.getLong(resultSet.getColumnIndex('date')),
            duration: resultSet.getLong(resultSet.getColumnIndex('duration')),
            type: resultSet.getLong(resultSet.getColumnIndex('type')),
            name: resultSet.getString(resultSet.getColumnIndex('name'))
          });
        }
        resultSet.close();
      } catch (e) {
        console.warn(`[RootDataReader] calls query failed: ${(e as Error).message}`);
      }

      console.info(`[RootDataReader] Call log read: ${callLogs.length}`);

      return callLogs;
    } catch (err) {
      console.error(`[RootDataReader] readCallLog failed: ${(err as Error).message}`);
      return [];
    }
  }

  /**
   * 读取日历事件
   * @param limit 最大返回数量，默认100
   */
  async readCalendarEvents(limit: number = 100): Promise<CalendarEventData[]> {
    console.info(`[RootDataReader] Reading calendar events (limit: ${limit})`);

    try {
      // 检查预复制的数据库是否存在
      const exists = await this.checkPreCopiedDatabaseExists('calendar');
      if (!exists) {
        console.error(`[RootDataReader] Calendar database not found. Please copy it first using hdc shell.`);
        throw new Error('日历数据库未找到。请先通过 hdc shell 复制数据库到应用 databaseDir:\n' +
          'hdc shell "cp /data/app/el1/100/database/com.huawei.hmos.calendardata/entry/rdb/calendardataEl1.db ' +
          '/data/app/el2/100/database/com.example.fileanalyzer_hos/entry/rdb/calendar.db"');
      }

      const store = await this.openPreCopiedDatabase('calendar');

      const events: CalendarEventData[] = [];

      try {
        // CalendarAlerts表结构：_id, title, content, begin, end
        const resultSet = await store.querySql(
          `SELECT _id, title, content, begin, end FROM CalendarAlerts LIMIT ${limit}`
        );

        while (resultSet.goToNextRow()) {
          const id = resultSet.getLong(resultSet.getColumnIndex('_id'));
          const title = resultSet.getString(resultSet.getColumnIndex('title'));
          const content = resultSet.getString(resultSet.getColumnIndex('content'));
          const begin = resultSet.getLong(resultSet.getColumnIndex('begin'));
          const end = resultSet.getLong(resultSet.getColumnIndex('end'));

          events.push({
            id: id,
            title: title || content || '(无标题)',
            description: content,
            dtstart: begin,
            dtend: end,
            eventLocation: '',
            calendarId: 0
          });
        }
        resultSet.close();
      } catch (e) {
        console.warn(`[RootDataReader] CalendarAlerts query failed: ${(e as Error).message}`);
      }

      console.info(`[RootDataReader] Calendar events read: ${events.length}`);

      return events;
    } catch (err) {
      console.error(`[RootDataReader] readCalendarEvents failed: ${(err as Error).message}`);
      return [];
    }
  }

  /**
   * 查询数据库表结构
   * @param dbType 数据库类型
   */
  async queryTableSchema(dbType: string): Promise<string[]> {
    try {
      const exists = await this.checkPreCopiedDatabaseExists(dbType);
      if (!exists) {
        console.error(`[RootDataReader] ${dbType} database not found.`);
        return [];
      }

      const store = await this.openPreCopiedDatabase(dbType);

      // 获取表列表
      const tablesResultSet = await store.querySql(
        `SELECT name FROM sqlite_master WHERE type='table' ORDER BY name`
      );

      const tables: string[] = [];
      while (tablesResultSet.goToNextRow()) {
        tables.push(tablesResultSet.getString(tablesResultSet.getColumnIndex('name')));
      }
      tablesResultSet.close();

      return tables;
    } catch (err) {
      console.error(`[RootDataReader] queryTableSchema failed: ${(err as Error).message}`);
      return [];
    }
  }

  /**
   * 检查数据库文件是否可读（检查预复制的文件）
   * @param dbType 数据库类型
   */
  async checkDatabaseAccessible(dbType: string): Promise<boolean> {
    return await this.checkPreCopiedDatabaseExists(dbType);
  }

  /**
   * 获取所有数据库可访问状态（检查预复制的文件）
   */
  async checkAllDatabasesAccessible(): Promise<Map<string, boolean>> {
    const status = new Map<string, boolean>();
    const dbTypes = ['contacts', 'sms', 'callLog', 'calendar'];

    for (const dbType of dbTypes) {
      const accessible = await this.checkPreCopiedDatabaseExists(dbType);
      status.set(dbType, accessible);
    }

    return status;
  }
}

/**
 * 使用说明：
 *
 * 重要：应用无法直接访问系统数据库目录，需要预先通过 hdc shell 复制数据库到应用的 databaseDir 目录。
 *
 * 1. 复制数据库命令（在PC上执行）：
 *    HDC="/d/Program Files/Huawei/DevEco Studio6.1/sdk/default/openharmony/toolchains/hdc.exe"
 *    APP_RDB="/data/app/el2/100/database/com.example.fileanalyzer_hos/entry/rdb"
 *
 *    # 联系人数据库
 *    $HDC shell "cp /data/app/el2/100/database/com.ohos.contactsdataability/rdb/contacts.db ${APP_RDB}/contacts.db"
 *
 *    # 短信数据库
 *    $HDC shell "cp /data/app/el1/100/database/com.ohos.telephonydataability/rdb/sms_mms_el1.db ${APP_RDB}/sms.db"
 *
 *    # 通话记录数据库
 *    $HDC shell "cp /data/virt_service/rgm_hmos/anco_hmos_data/data/com.android.providers.contacts/databases/calls.db ${APP_RDB}/calls.db"
 *
 *    # 日历数据库
 *    $HDC shell "cp /data/app/el1/100/database/com.huawei.hmos.calendardata/entry/rdb/calendardataEl1.db ${APP_RDB}/calendar.db"
 *
 * 2. 在应用中使用：
 *    const reader = new RootDataReader(context);
 *
 *    // 检查数据库可访问性（检查预复制的文件）
 *    const status = await reader.checkAllDatabasesAccessible();
 *
 *    // 读取数据（如果数据库已预复制）
 *    if (status.get('contacts')) {
 *      const contacts = await reader.readContacts(50);
 *    }
 */