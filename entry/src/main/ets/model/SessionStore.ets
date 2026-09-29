/**
 * 登录会话本地持久化工具
 * 
 * 使用 @ohos.data.preferences 将路由器连接信息
 * （地址、用户名、Session ID）保存到本地，
 * 避免每次打开 App 都要重新登录。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 持久化存储的键名 */
const KEY_HOST: string = 'openwrt_host';
const KEY_PORT: string = 'openwrt_port';
const KEY_USE_HTTPS: string = 'openwrt_use_https';
const KEY_USERNAME: string = 'openwrt_username';
const KEY_SESSION_ID: string = 'openwrt_session_id';

/** 存储的 Session 数据模型 */
export interface SavedSession {
  host: string;
  port: number;
  useHttps: boolean;
  username: string;
  sessionId: string;
}

/**
 * Session 本地存储管理器
 */
export class SessionStore {
  private pref: preferences.Preferences | null = null;

  /**
   * 初始化 Preferences 实例
   * @param context 应用上下文，从 EntryAbility 中获取
   */
  async init(context: common.Context): Promise<void> {
    this.pref = await preferences.getPreferences(context, 'openwrt_session');
  }

  /**
   * 保存登录信息到本地
   */
  async save(session: SavedSession): Promise<void> {
    if (!this.pref) {
      console.error('[SessionStore] 未初始化');
      return;
    }
    await this.pref.put(KEY_HOST, session.host);
    await this.pref.put(KEY_PORT, session.port);
    await this.pref.put(KEY_USE_HTTPS, session.useHttps);
    await this.pref.put(KEY_USERNAME, session.username);
    await this.pref.put(KEY_SESSION_ID, session.sessionId);
    await this.pref.flush();
    console.info('[SessionStore] Session 已保存到本地');
  }

  /**
   * 从本地读取已保存的登录信息
   * @returns 如果存在则返回 SavedSession，否则返回 null
   */
  async load(): Promise<SavedSession | null> {
    if (!this.pref) {
      console.error('[SessionStore] 未初始化');
      return null;
    }

    const host: string = (await this.pref.get(KEY_HOST, '')).toString();
    const sessionId: string = (await this.pref.get(KEY_SESSION_ID, '')).toString();

    if (!host || !sessionId) {
      return null; // 没有保存过登录信息
    }

    const saved: SavedSession = {
      host,
      port: Number(await this.pref.get(KEY_PORT, 80)),
      useHttps: (await this.pref.get(KEY_USE_HTTPS, false)) as boolean,
      username: (await this.pref.get(KEY_USERNAME, '')).toString(),
      sessionId
    };
    return saved;
  }

  /**
   * 清除已保存的登录信息（登出时调用）
   */
  async clear(): Promise<void> {
    if (!this.pref) {
      return;
    }
    await this.pref.delete(KEY_HOST);
    await this.pref.delete(KEY_PORT);
    await this.pref.delete(KEY_USE_HTTPS);
    await this.pref.delete(KEY_USERNAME);
    await this.pref.delete(KEY_SESSION_ID);
    await this.pref.flush();
    console.info('[SessionStore] Session 已清除');
  }

  /**
   * 检查是否已保存有效的 Session 信息
   */
  async hasSavedSession(): Promise<boolean> {
    const session = await this.load();
    return session !== null && session.sessionId.length > 0;
  }
}
