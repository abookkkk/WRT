/**
 * 登录凭据（用户名 + 密码）的本机存储 —— 给「记住密码 / 过期自动重登」用
 *
 * 两条路，优先走安全的那条：
 *   1. **系统安全存储 `@ohos.security.asset`（ASSET）**：密码加密存在系统密钥库里，
 *      应用沙箱的 preferences 文件里看不到明文。存密码就该用这个（实测模拟器可用）。
 *   2. ASSET 不可用时（服务没起来 / 设备不支持，`asset.add` 抛错）**退化成 preferences**，
 *      并把 `encrypted=false` 报给上层 —— 登录页据此显示「本机明文保存」，别骗用户。
 *
 * 用户名不算秘密，一直放 preferences；密码只放 ASSET。
 *
 * 写入时机：登录页勾了「记住密码」且登录成功；取消勾选则把两份都删掉。
 * 读取时机：登录页进入时预填密码；session 失效时拿它静默重登（见 Index.ets）。
 */

import asset from '@ohos.security.asset';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const STORE_NAME: string = 'openwrt_credential';
const KEY_USERNAME: string = 'username';
const KEY_PREF_PASSWORD: string = 'password_plain';
/** ASSET 里的别名：一条记录就够（一个 App 记一台路由器） */
const ASSET_ALIAS: string = 'openwrt_router_credential';
/** ASSET 的「资产不存在」错误码 */
const ASSET_NOT_FOUND: number = 24000002;

/** 读出来的凭据 */
export class SavedCredential {
  username: string = '';
  password: string = '';
  /** true = 走的 ASSET 加密存储；false = 退化成了 preferences 明文 */
  encrypted: boolean = true;
}

export class CredentialStore {
  private pref: preferences.Preferences | null = null;
  /** ASSET 写入失败过就置 true，之后都走 preferences（免得每次登录都卡一下） */
  private assetBroken: boolean = false;

  private async ensurePref(context: common.Context): Promise<void> {
    if (this.pref === null) {
      this.pref = await preferences.getPreferences(context, STORE_NAME);
    }
  }

  /**
   * 记住 / 忘掉密码。
   * @param remember 勾选状态：true 存，false 删
   * @returns 是否用了加密存储（remember=false 时返回值无意义）
   */
  async saveOrClear(context: common.Context, remember: boolean, username: string, password: string): Promise<boolean> {
    if (!remember) {
      await this.clear(context);
      return true;
    }
    await this.ensurePref(context);
    await this.removeAsset();
    if (!this.assetBroken) {
      try {
        const attr: Map<asset.Tag, asset.Value> = new Map<asset.Tag, asset.Value>();
        attr.set(asset.Tag.ALIAS, this.strToBytes(ASSET_ALIAS));
        attr.set(asset.Tag.SECRET, this.strToBytes(password));
        // DEVICE_FIRST_UNLOCKED：开机首次解锁后就能读（重启后不用再解一次锁也能自动重登）
        attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        await asset.add(attr);
        await this.putPref(KEY_USERNAME, username);
        await this.putPref(KEY_PREF_PASSWORD, '');
        console.info('[CredentialStore] 密码已加密保存（ASSET）');
        return true;
      } catch (e) {
        console.warn('[CredentialStore] ASSET 写入失败，退化成 preferences 明文: ' + JSON.stringify(e));
        this.assetBroken = true;
      }
    }
    await this.putPref(KEY_USERNAME, username);
    await this.putPref(KEY_PREF_PASSWORD, password);
    return false;
  }

  /** 读凭据；没存过返回 null */
  async load(context: common.Context): Promise<SavedCredential | null> {
    await this.ensurePref(context);
    const username: string = await this.getPref(KEY_USERNAME, '');

    if (!this.assetBroken) {
      try {
        const q: Map<asset.Tag, asset.Value> = new Map<asset.Tag, asset.Value>();
        q.set(asset.Tag.ALIAS, this.strToBytes(ASSET_ALIAS));
        q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
        const rows: Array<Map<asset.Tag, asset.Value>> = await asset.query(q);
        if (rows.length > 0) {
          const secret: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
          if (secret !== undefined) {
            const out: SavedCredential = new SavedCredential();
            out.username = username;
            out.password = this.bytesToStr(secret as Uint8Array);
            out.encrypted = true;
            return out.password.length > 0 ? out : null;
          }
        }
      } catch (e) {
        const code: number = (e as BusinessErrorLike).code;
        // 「没查到」是正常情况（用户没勾过），不当成 ASSET 坏掉
        if (code !== ASSET_NOT_FOUND) {
          console.warn('[CredentialStore] ASSET 读取失败: ' + JSON.stringify(e));
        }
      }
    }

    const plain: string = await this.getPref(KEY_PREF_PASSWORD, '');
    if (plain.length === 0) {
      return null;
    }
    const out: SavedCredential = new SavedCredential();
    out.username = username;
    out.password = plain;
    out.encrypted = false;
    return out;
  }

  /** 删掉（ASSET + preferences 两份都清） */
  async clear(context: common.Context): Promise<void> {
    await this.ensurePref(context);
    await this.removeAsset();
    await this.putPref(KEY_PREF_PASSWORD, '');
    await this.putPref(KEY_USERNAME, '');
  }

  // ==================== 内部 ====================

  private async removeAsset(): Promise<void> {
    try {
      const q: Map<asset.Tag, asset.Value> = new Map<asset.Tag, asset.Value>();
      q.set(asset.Tag.ALIAS, this.strToBytes(ASSET_ALIAS));
      await asset.remove(q);
    } catch (e) {
      const code: number = (e as BusinessErrorLike).code;
      if (code !== ASSET_NOT_FOUND) {
        console.warn('[CredentialStore] ASSET 删除失败（不影响后面写入）: ' + JSON.stringify(e));
      }
    }
  }

  private async putPref(key: string, value: string): Promise<void> {
    if (this.pref === null) {
      return;
    }
    await this.pref.put(key, value);
    await this.pref.flush();
  }

  private async getPref(key: string, fallback: string): Promise<string> {
    if (this.pref === null) {
      return fallback;
    }
    return (await this.pref.get(key, fallback)).toString();
  }

  private strToBytes(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  private bytesToStr(b: Uint8Array): string {
    return new util.TextDecoder().decodeToString(b);
  }
}

/** ASSET 抛出来的是 BusinessError，这里只关心 code */
interface BusinessErrorLike {
  code: number;
}