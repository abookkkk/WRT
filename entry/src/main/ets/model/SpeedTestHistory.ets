/** 测速历史：只保存在本机，不写入路由器。 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'openwrt_speed_test_history';
const KEY_RECORDS: string = 'records_json';
const KEEP_DAYS: number = 90;

export class SpeedTestRecord {
  timestamp: number = 0;
  latency: number = 0;
  download: number = 0;
  upload: number = 0;
}

export class SpeedTestHistory {
  private pref: preferences.Preferences | null = null;
  private records: SpeedTestRecord[] = [];

  async init(context: common.Context): Promise<void> {
    try {
      this.pref = await preferences.getPreferences(context, STORE_NAME);
      const raw: string = (await this.pref.get(KEY_RECORDS, '')).toString();
      if (raw.length > 0) {
        const parsed: Object[] = JSON.parse(raw) as Object[];
        this.records = [];
        for (let i = 0; i < parsed.length; i++) {
          const source: Record<string, Object> = parsed[i] as Record<string, Object>;
          const item: SpeedTestRecord = new SpeedTestRecord();
          item.timestamp = Number(source['timestamp'] || 0);
          item.latency = Number(source['latency'] || 0);
          item.download = Number(source['download'] || 0);
          item.upload = Number(source['upload'] || 0);
          if (item.timestamp > 0) this.records.push(item);
        }
      }
      if (this.prune()) {
        await this.persist();
      }
    } catch (e) {
      console.error('[SpeedTestHistory] 读取历史失败: ' + JSON.stringify(e));
      this.records = [];
    }
  }

  async add(record: SpeedTestRecord): Promise<boolean> {
    if (this.pref === null) return false;
    this.records.unshift(record);
    this.prune();
    try {
      await this.persist();
      return true;
    } catch (e) {
      console.error('[SpeedTestHistory] 保存历史失败: ' + JSON.stringify(e));
      return false;
    }
  }

  snapshot(): SpeedTestRecord[] {
    const out: SpeedTestRecord[] = [];
    for (let i = 0; i < this.records.length; i++) {
      const item: SpeedTestRecord = new SpeedTestRecord();
      item.timestamp = this.records[i].timestamp;
      item.latency = this.records[i].latency;
      item.download = this.records[i].download;
      item.upload = this.records[i].upload;
      out.push(item);
    }
    return out;
  }

  private prune(): boolean {
    const cutoff: number = Date.now() - KEEP_DAYS * 24 * 60 * 60 * 1000;
    const kept: SpeedTestRecord[] = [];
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].timestamp >= cutoff) kept.push(this.records[i]);
    }
    const changed: boolean = kept.length !== this.records.length;
    this.records = kept;
    return changed;
  }

  private async persist(): Promise<void> {
    if (this.pref === null) return;
    await this.pref.put(KEY_RECORDS, JSON.stringify(this.records));
    await this.pref.flush();
  }
}
