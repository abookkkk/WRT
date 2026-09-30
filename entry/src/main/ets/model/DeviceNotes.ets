/**
 * 设备备注 —— **只存本机，不动路由器**
 *
 * 为什么不写进路由器：
 *   · 路由器上能改的是 `dhcp` 里的静态租约 / hostname，那会真的改变 dnsmasq 的分配行为；
 *     而"备注"只是给自己看的名字（客厅电视、米家网关……），跟网络本身无关；
 *   · 本机存储不需要额外 ACL 权限，也不会因为换路由器而写坏配置。
 *
 * 键用 **MAC（小写、冒号分隔）**：DHCP 租约里 MAC 唯一且稳定，IP 会变、hostname 可能是空的。
 *
 * 存储走 preferences（和登录信息、外观设置同一套机制），整个映射序列化成一个 JSON 字符串。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'openwrt_device_notes';
const KEY_NOTES: string = 'notes_json';

export class DeviceNotes {
  private pref: preferences.Preferences | null = null;
  private notes: Record<string, string> = {};

  /** 读出全部备注；读失败就当没有备注（不能影响设备列表本身） */
  async init(context: common.Context): Promise<void> {
    try {
      this.pref = await preferences.getPreferences(context, STORE_NAME);
      const raw: string = (await this.pref.get(KEY_NOTES, '')).toString();
      if (raw.length > 0) {
        this.notes = JSON.parse(raw) as Record<string, string>;
      }
    } catch (e) {
      console.error('[DeviceNotes] 读取备注失败: ' + JSON.stringify(e));
      this.notes = {};
    }
  }

  /** 取一台设备的备注，没设过返回空串 */
  get(mac: string): string {
    const v: string | undefined = this.notes[mac.toLowerCase()];
    return v === undefined ? '' : v;
  }

  /**
   * 记下一台设备的备注（传空串 = 清除）。
   * 空值直接存空串、不去 delete 键 —— ArkTS 里少用 delete，读的时候按空串处理更省事。
   */
  async set(mac: string, note: string): Promise<boolean> {
    if (!this.pref) {
      console.error('[DeviceNotes] 未初始化，备注保存失败');
      return false;
    }
    this.notes[mac.toLowerCase()] = note.trim();
    try {
      await this.pref.put(KEY_NOTES, JSON.stringify(this.notes));
      await this.pref.flush();
      return true;
    } catch (e) {
      console.error('[DeviceNotes] 保存备注失败: ' + JSON.stringify(e));
      return false;
    }
  }

  /** 一份拷贝：ArkUI 的 @State 要换成新引用才会重绘（直接改原对象检测不到） */
  snapshot(): Record<string, string> {
    const out: Record<string, string> = {};
    const keys: string[] = Object.keys(this.notes);
    for (let i = 0; i < keys.length; i++) {
      out[keys[i]] = this.notes[keys[i]];
    }
    return out;
  }
}