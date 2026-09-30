/**
 * 测速服务器地址的本地存储（就一个字符串）
 *
 * 放在 preferences 里，和登录信息 / 外观设置 / 设备备注同一套机制：
 * 用户改成内网地址后，下次打开还在。读不到就用默认端点。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DEFAULT_SPEED_BASE } from './SpeedTest';

const STORE_NAME: string = 'openwrt_speedtest';
const KEY_BASE: string = 'base_url';

export class SpeedTestSettings {
  private pref: preferences.Preferences | null = null;

  /** 读出用户设的端点；没设过或读失败都回默认值 */
  async load(context: common.Context): Promise<string> {
    try {
      this.pref = await preferences.getPreferences(context, STORE_NAME);
      const v: string = (await this.pref.get(KEY_BASE, '')).toString().trim();
      return v.length > 0 ? v : DEFAULT_SPEED_BASE;
    } catch (e) {
      console.error('[SpeedTestSettings] 读取测速地址失败: ' + JSON.stringify(e));
      return DEFAULT_SPEED_BASE;
    }
  }

  /** 存端点（空串等于恢复默认） */
  async save(url: string): Promise<boolean> {
    if (this.pref === null) {
      console.error('[SpeedTestSettings] 未初始化，保存失败');
      return false;
    }
    try {
      await this.pref.put(KEY_BASE, url.trim());
      await this.pref.flush();
      return true;
    } catch (e) {
      console.error('[SpeedTestSettings] 保存测速地址失败: ' + JSON.stringify(e));
      return false;
    }
  }
}