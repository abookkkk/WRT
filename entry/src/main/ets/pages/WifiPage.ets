/**
 * 无线（WiFi）管理页
 *
 * 数据源全部来自 ubus（已在真机路由器上逐项实测）：
 *   - luci-rpc.getWirelessDevices  → 射频开关 / SSID / 隐藏 / 密钥 / 接口名 / 信道 / 功率
 *   - iwinfo.assoclist             → 该 AP 上已连接的客户端
 *   - iwinfo.scan                  → 周边 AP 扫描（160MHz 跨 DFS 时驱动会拒绝，返回空）
 *   - iwinfo.freqlist              → 可用信道
 *
 * 写入链路（实测可用，且不会踢掉已连接客户端）：
 *   uci set wireless.<section>.<option>  →  uci commit wireless  →  rc.init network reload
 *
 * 断开客户端：hostapd.<ifname>.del_client
 * （不要用 hostapd.*.get_clients 取客户端列表，ACL 没放行，会 -32002）
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type {
  WirelessRadio,
  WirelessIface,
  IwinfoData,
  WifiClient,
  IwinfoScanResult
} from '../model/OpenWrtModels';

const COLOR_CARD_BG: ResourceColor = '#F2FFFFFF';
const COLOR_SECONDARY: ResourceColor = '#666666';
const COLOR_TERTIARY: ResourceColor = '#999999';
const COLOR_PRIMARY: ResourceColor = '#0078D4';
const COLOR_GREEN: ResourceColor = '#1DB954';
const COLOR_RED: ResourceColor = '#E84040';
const COLOR_ORANGE: ResourceColor = '#FF8800';

/** 页面用的客户端条目 */
class ClientItem {
  mac: string = '';
  signal: number = 0;
  rxBytes: number = 0;
  txBytes: number = 0;
  onlineSec: number = 0;
}

/** 页面用的射频条目 */
class RadioItem {
  radioName: string = '';
  ifaceSection: string = '';
  ifname: string = '';
  bandLabel: string = '';
  enabled: boolean = false;
  ssid: string = '';
  password: string = '';
  hidden: boolean = false;
  encryption: string = '';
  configChannel: string = '';
  configHtMode: string = '';
  liveChannel: number = 0;
  txpower: number = 0;
  hwmodes: string = '';
  /** 该射频可用的信道（优先取 iwinfo.freqlist，射频关闭时用频段默认值兜底） */
  channels: number[] = [];
  /** 该射频支持的频宽（来自 iwinfo.htmodes） */
  htModes: string[] = [];
  clients: ClientItem[] = [];
}

/** 扫描结果条目 */
class ScanItem {
  ssid: string = '';
  bssid: string = '';
  channel: number = 0;
  signal: number = 0;
}

@Component
export struct WifiPage {
  private client!: OpenWrtClient;

  @State private radios: RadioItem[] = [];
  @State private scanResult: ScanItem[] = [];
  @State private scanHint: string = '';
  @State private scanFor: string = '';
  @State private isLoading: boolean = true;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  @State private busy: boolean = false;
  @State private scanning: boolean = false;
  /** 每次加载自增，用来强制 ForEach 重建（ArkUI 复用条目时不会刷新属性） */
  @State private dataVersion: number = 0;

  aboutToAppear(): void {
    this.loadAll();
  }

  build() {
    Stack() {
      if (!this.isLoading && !this.hasError) {
        Scroll() {
          Column() {
            // ===== 顶部说明 =====
            Row() {
              Text('无线网络').fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1);
              Button('刷新')
                .fontSize(14).height(32).type(ButtonType.Capsule)
                .enabled(!this.busy)
                .onClick(() => this.loadAll());
            }
            .width('100%').margin({ bottom: 12 });

            // ===== 每个射频一张卡片 =====
            ForEach(this.radios, (radio: RadioItem) => {
              Column() {
                // --- 标题：频段 + 开关 ---
                Row() {
                  Text(radio.enabled ? '📶' : '📴').fontSize(20).margin({ right: 8 });
                  Text(radio.bandLabel).fontSize(17).fontWeight(FontWeight.Bold);
                  Text(radio.radioName).fontSize(12).fontColor(COLOR_TERTIARY).margin({ left: 8 });
                  Blank();
                  Text(radio.enabled ? '已开启' : '已关闭')
                    .fontSize(12).fontColor(Color.White)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor(radio.enabled ? COLOR_GREEN : COLOR_TERTIARY)
                    .borderRadius(9)
                    .margin({ right: 8 });
                  Toggle({ type: ToggleType.Switch, isOn: radio.enabled })
                    .enabled(!this.busy)
                    .onChange((v: boolean) => this.toggleRadio(radio, v));
                }
                .width('100%').margin({ bottom: 12 });

                if (radio.enabled) {
                  // --- 实时状态 ---
                  this.infoLine('当前信道', radio.liveChannel > 0 ? String(radio.liveChannel) : '--');
                  this.infoLine('发射功率', radio.txpower > 0 ? (radio.txpower + ' dBm') : '--');
                  this.infoLine('支持模式', radio.hwmodes.length > 0 ? radio.hwmodes : '--');
                  this.infoLine('已连设备', String(radio.clients.length) + ' 台');

                  Divider().margin({ top: 8, bottom: 12 });

                  // --- 信道选择 ---
                  Row() {
                    Text('信道').fontSize(14).fontColor(COLOR_SECONDARY).layoutWeight(1);
                    Select(this.channelOptions(radio))
                      .selected(this.channelIndex(radio))
                      .value(radio.configChannel)
                      .font({ size: 14 })
                      .enabled(!this.busy)
                      .onSelect((index: number, value?: string) => {
                        if (value !== undefined) {
                          radio.configChannel = value;
                        }
                      });
                  }
                  .width('100%').margin({ bottom: 8 });

                  // --- 频宽选择 ---
                  Row() {
                    Text('频宽').fontSize(14).fontColor(COLOR_SECONDARY).layoutWeight(1);
                    Select(this.htModeOptions(radio))
                      .selected(this.htModeIndex(radio))
                      .value(radio.configHtMode.length > 0 ? radio.configHtMode : '未设置')
                      .font({ size: 14 })
                      .enabled(!this.busy)
                      .onSelect((index: number, value?: string) => {
                        if (value !== undefined) {
                          radio.configHtMode = value;
                        }
                      });
                  }
                  .width('100%').margin({ bottom: 8 });

                  Text('信道 / 频宽改完后，点下面的「保存并应用」才会生效')
                    .fontSize(11).fontColor(COLOR_TERTIARY).width('100%');

                  if (radio.configHtMode.indexOf('160') >= 0) {
                    Text('⚠️ 160MHz 会占用跨 DFS 的宽信道，MT7981 驱动会拒绝后台扫描（信道扫描会扫不到东西）')
                      .fontSize(11).fontColor(COLOR_ORANGE).width('100%')
                      .lineHeight(16).margin({ top: 4 });
                  }

                  Divider().margin({ top: 12, bottom: 12 });

                  // --- SSID ---
                  Text('WiFi 名称 (SSID)').fontSize(13).fontColor(COLOR_SECONDARY).width('100%');
                  TextInput({ text: radio.ssid, placeholder: '输入 SSID' })
                    .width('100%').margin({ top: 4, bottom: 10 })
                    .onChange((v: string) => { radio.ssid = v.trim(); });

                  // --- 密码 ---
                  Text('WiFi 密码').fontSize(13).fontColor(COLOR_SECONDARY).width('100%');
                  TextInput({ text: radio.password, placeholder: '输入密码（至少 8 位）' })
                    .type(InputType.Password)
                    .width('100%').margin({ top: 4, bottom: 10 })
                    .onChange((v: string) => { radio.password = v; });

                  // --- 隐藏 SSID ---
                  Row() {
                    Column() {
                      Text('隐藏 WiFi 名称').fontSize(14);
                      Text('隐藏后新设备需要手动输入名称才能连接')
                        .fontSize(11).fontColor(COLOR_TERTIARY).margin({ top: 2 });
                    }
                    .alignItems(HorizontalAlign.Start).layoutWeight(1);

                    Toggle({ type: ToggleType.Switch, isOn: radio.hidden })
                      .enabled(!this.busy)
                      .onChange((v: boolean) => this.toggleHidden(radio, v));
                  }
                  .width('100%').margin({ top: 4, bottom: 14 });

                  // --- 应用按钮 ---
                  Button(this.busy ? '正在应用...' : '保存并应用')
                    .width('100%').height(40).type(ButtonType.Capsule)
                    .backgroundColor(COLOR_PRIMARY)
                    .enabled(!this.busy)
                    .onClick(() => this.applyEdits(radio));

                  // --- 扫描按钮 ---
                  Button(this.scanning ? '扫描中...' : ('扫描 ' + radio.bandLabel + ' 周边 WiFi'))
                    .width('100%').height(36).type(ButtonType.Capsule)
                    .backgroundColor(COLOR_ORANGE)
                    .margin({ top: 8 })
                    .enabled(!this.busy && !this.scanning)
                    .onClick(() => this.doScan(radio));

                  // --- 已连接客户端 ---
                  if (radio.clients.length > 0) {
                    Text('已连接设备')
                      .fontSize(15).fontWeight(FontWeight.Bold)
                      .width('100%').margin({ top: 18, bottom: 8 });

                    ForEach(radio.clients, (c: ClientItem) => {
                      Row() {
                        Column() {
                          Text(c.mac).fontSize(13).fontWeight(FontWeight.Medium);
                          Text(this.signalText(c.signal) + '   ↓' + this.formatBytes(c.rxBytes) +
                               '  ↑' + this.formatBytes(c.txBytes) + '   在线 ' + this.formatDuration(c.onlineSec))
                            .fontSize(11).fontColor(COLOR_TERTIARY).margin({ top: 3 });
                        }
                        .alignItems(HorizontalAlign.Start).layoutWeight(1);

                        Button('断开')
                          .fontSize(12).height(30).type(ButtonType.Capsule)
                          .backgroundColor(COLOR_RED)
                          .enabled(!this.busy)
                          .onClick(() => this.kickClient(radio, c));
                      }
                      .width('100%')
                      .padding({ top: 8, bottom: 8 })
                    }, (c: ClientItem) => c.mac + '#' + this.dataVersion);
                  }
                } else {
                  Text('该射频已关闭，打开开关即可启用 WiFi')
                    .fontSize(13).fontColor(COLOR_TERTIARY).width('100%');
                }
              }
              .width('100%').padding(16)
              .backgroundColor(COLOR_CARD_BG).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM)
              .margin({ bottom: 12 });
            }, (radio: RadioItem) => radio.radioName + '#' + this.dataVersion)

            // ===== 扫描结果 =====
            if (this.scanResult.length > 0 || this.scanHint.length > 0) {
              Column() {
                Text('周边 WiFi（' + this.scanFor + '）')
                  .fontSize(15).fontWeight(FontWeight.Bold).width('100%').margin({ bottom: 8 });

                if (this.scanHint.length > 0) {
                  Text(this.scanHint)
                    .fontSize(12).fontColor(COLOR_ORANGE).width('100%').lineHeight(18);
                }

                ForEach(this.scanResult, (s: ScanItem) => {
                  Row() {
                    Text(s.ssid.length > 0 ? s.ssid : '(隐藏网络)')
                      .fontSize(13).layoutWeight(1).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis });
                    Text('信道 ' + s.channel).fontSize(12).fontColor(COLOR_SECONDARY).margin({ right: 10 });
                    Text(String(s.signal) + ' dBm')
                      .fontSize(12)
                      .fontColor(s.signal > -60 ? COLOR_GREEN : (s.signal > -75 ? COLOR_ORANGE : COLOR_TERTIARY));
                  }
                  .width('100%').padding({ top: 6, bottom: 6 })
                }, (s: ScanItem) => s.bssid);
              }
              .width('100%').padding(16)
              .backgroundColor(COLOR_CARD_BG).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM)
              .margin({ bottom: 12 });
            }

            // ===== 说明 =====
            Column() {
              Text('说明').fontSize(15).fontWeight(FontWeight.Bold).width('100%').margin({ bottom: 8 });
              Text('· 数据来自 luci-rpc.getWirelessDevices / iwinfo.assoclist')
                .fontSize(12).fontColor(COLOR_TERTIARY).margin({ bottom: 4 });
              Text('· 保存后走 uci commit + rc.init network reload，实测不会断开已有连接')
                .fontSize(12).fontColor(COLOR_TERTIARY).margin({ bottom: 4 });
              Text('· 信道扫描在 5G 为 HE160（跨 DFS 宽信道）时驱动会拒绝，降到 80MHz 通常可扫到')
                .fontSize(12).fontColor(COLOR_TERTIARY).margin({ bottom: 4 });
              Text('· 断开设备用 hostapd.<接口>.del_client，不拉黑，客户端可立即重连')
                .fontSize(12).fontColor(COLOR_TERTIARY);
            }
            .width('100%').padding(16)
            .backgroundColor(COLOR_CARD_BG).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM);
          }
          .width('100%').padding(16)
        }
        .width('100%').height('100%')
        .edgeEffect(EdgeEffect.Spring)
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(32).height(32);
          Text('正在获取无线信息...').fontSize(14).margin({ top: 12 });
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center);
      }

      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(14).margin({ top: 12 });
          Button('重试').type(ButtonType.Capsule).margin({ top: 16 })
            .onClick(() => this.loadAll());
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center);
      }
    }
    .width('100%').height('100%')
  }

  /**
   * 键值对行。
   * 注意：必须直接读 this 传进来的这些是**纯展示、随条目一起重建**的值，
   * 且调用方在 ForEach 内、key 里带了 dataVersion，所以不会有 @Builder 不刷新的问题。
   */
  @Builder
  infoLine(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor(COLOR_SECONDARY);
      Text(value).fontSize(13).fontWeight(FontWeight.Medium)
        .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 6 })
  }

  // ==================== 数据加载 ====================

  private async loadAll(): Promise<void> {
    if (!this.client.isLoggedIn()) {
      this.hasError = true;
      this.errorMsg = '未登录';
      this.isLoading = false;
      return;
    }

    this.isLoading = true;
    this.hasError = false;

    try {
      const resp = await this.client.getWirelessDevices();
      if (!resp.success || !resp.data) {
        this.hasError = true;
        this.errorMsg = resp.error || '获取无线信息失败';
        return;
      }

      const devices: Record<string, WirelessRadio> = resp.data;
      const names: string[] = Object.keys(devices);
      const items: RadioItem[] = [];

      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        const radio: WirelessRadio = devices[name];
        const item: RadioItem = new RadioItem();

        item.radioName = name;
        item.enabled = radio.disabled !== true;

        const cfg: Record<string, Object> | undefined = radio.config;
        if (cfg) {
          item.bandLabel = this.bandLabel(String(cfg['band'] || ''));
          item.configChannel = String(cfg['channel'] || 'auto');
          item.configHtMode = String(cfg['htmode'] || '');
        } else {
          item.bandLabel = name;
          item.configChannel = 'auto';
        }

        const live: IwinfoData | undefined = radio.iwinfo;
        if (live) {
          item.liveChannel = live.channel || 0;
          item.txpower = live.txpower || 0;
          item.hwmodes = live.hwmodes_text || '';
          item.htModes = this.toStringArray(live.htmodes);
        }

        const ifaces: WirelessIface[] = radio.interfaces || [];
        if (ifaces.length > 0) {
          const ap: WirelessIface = ifaces[0];
          item.ifname = ap.ifname || '';
          item.ifaceSection = ap.section || '';

          const apCfg = ap.config;
          if (apCfg) {
            item.ssid = apCfg.ssid || '';
            item.password = apCfg.key || '';
            item.hidden = apCfg.hidden === true;
            item.encryption = apCfg.encryption || '';
          }

          if (item.ifname.length > 0 && item.enabled) {
            const cr = await this.client.getWifiClients(item.ifname);
            if (cr.success && cr.data) {
              item.clients = this.toClientItems(cr.data);
            }

            const fr = await this.client.getWifiChannels(item.ifname);
            if (fr.success && fr.data) {
              const chs: number[] = [];
              for (let k = 0; k < fr.data.length; k++) {
                const ch: number = fr.data[k].channel || 0;
                if (ch > 0) {
                  chs.push(ch);
                }
              }
              item.channels = chs;
            }
          }
        }

        // 射频关着的时候没有 AP 接口，iwinfo.freqlist 用不了，用频段默认信道兜底
        if (item.channels.length === 0) {
          item.channels = this.defaultChannelsFor(item.bandLabel);
        }

        items.push(item);
      }

      this.radios = items;
      this.dataVersion = this.dataVersion + 1;
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '加载异常: ' + JSON.stringify(e);
    } finally {
      this.isLoading = false;
    }
  }

  private toClientItems(raw: WifiClient[]): ClientItem[] {
    const out: ClientItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      const c: WifiClient = raw[i];
      const item: ClientItem = new ClientItem();
      item.mac = c.mac || '';
      item.signal = c.signal || 0;
      item.rxBytes = c.rx ? (c.rx.bytes || 0) : 0;
      item.txBytes = c.tx ? (c.tx.bytes || 0) : 0;
      item.onlineSec = c.connected_time || 0;
      out.push(item);
    }
    return out;
  }

  // ==================== 操作 ====================

  /** 开关整个射频 */
  private async toggleRadio(radio: RadioItem, on: boolean): Promise<void> {
    radio.enabled = on;
    this.busy = true;
    try {
      const ok: boolean = await this.client.setWifiOption(radio.radioName, 'disabled', on ? '0' : '1');
      if (!ok) {
        this.toast('写入配置失败');
        return;
      }
      await this.applyChanges(on ? '正在开启射频...' : '正在关闭射频...');
    } finally {
      this.busy = false;
    }
  }

  /** 隐藏 / 显示 SSID */
  private async toggleHidden(radio: RadioItem, hidden: boolean): Promise<void> {
    radio.hidden = hidden;
    this.busy = true;
    try {
      const ok: boolean = await this.client.setWifiOption(radio.ifaceSection, 'hidden', hidden ? '1' : '0');
      if (!ok) {
        this.toast('写入配置失败');
        return;
      }
      await this.applyChanges(hidden ? '正在隐藏 WiFi...' : '正在取消隐藏...');
    } finally {
      this.busy = false;
    }
  }

  /** 保存 SSID / 密码 / 隐藏 / 信道 / 频宽 并应用 */
  private async applyEdits(radio: RadioItem): Promise<void> {
    if (radio.ssid.length === 0) {
      this.toast('WiFi 名称不能为空');
      return;
    }
    if (radio.password.length > 0 && radio.password.length < 8) {
      this.toast('WPA 密码至少 8 位');
      return;
    }

    this.busy = true;
    try {
      let ok: boolean = await this.client.setWifiOption(radio.ifaceSection, 'ssid', radio.ssid);
      if (ok && radio.password.length > 0) {
        ok = await this.client.setWifiOption(radio.ifaceSection, 'key', radio.password);
      }
      if (ok) {
        ok = await this.client.setWifiOption(radio.ifaceSection, 'hidden', radio.hidden ? '1' : '0');
      }
      // 信道和频宽是射频级配置，section 用 radio0 / radio1
      if (ok && radio.configChannel.length > 0) {
        ok = await this.client.setWifiOption(radio.radioName, 'channel', radio.configChannel);
      }
      if (ok && radio.configHtMode.length > 0) {
        ok = await this.client.setWifiOption(radio.radioName, 'htmode', radio.configHtMode);
      }
      if (!ok) {
        this.toast('写入配置失败');
        return;
      }
      await this.applyChanges('正在应用，无线会重载几秒...');
    } finally {
      this.busy = false;
    }
  }

  /** commit + 应用 + 重新加载 */
  private async applyChanges(tip: string): Promise<void> {
    this.toast(tip);
    const committed: boolean = await this.client.commitWifi();
    if (!committed) {
      this.toast('提交配置失败');
      return;
    }
    const applied: boolean = await this.client.applyWifi();
    if (!applied) {
      this.toast('应用配置失败');
      return;
    }
    await this.sleep(6000);
    await this.loadAll();
    this.toast('已生效');
  }

  /** 断开一个客户端 */
  private async kickClient(radio: RadioItem, c: ClientItem): Promise<void> {
    this.busy = true;
    try {
      const r = await this.client.kickWifiClient(radio.ifname, c.mac, 0);
      if (r.success) {
        this.toast('已断开 ' + c.mac);
        await this.sleep(2000);
        await this.loadAll();
      } else {
        this.toast('断开失败: ' + (r.error || '未知错误'));
      }
    } finally {
      this.busy = false;
    }
  }

  /** 扫描周边 WiFi */
  private async doScan(radio: RadioItem): Promise<void> {
    if (radio.ifname.length === 0) {
      this.toast('该射频没有可用接口');
      return;
    }

    this.scanning = true;
    this.scanResult = [];
    this.scanFor = radio.bandLabel;
    this.scanHint = '';

    try {
      const r = await this.client.scanWifi(radio.ifname);
      if (!r.success || !r.data) {
        this.scanHint = '扫描失败: ' + (r.error || '未知错误');
        return;
      }

      const raw: IwinfoScanResult[] = r.data;
      if (raw.length === 0) {
        this.scanHint = '没扫到任何 AP。MT7981 在 HE160（跨 DFS 宽信道）模式下驱动会拒绝后台扫描，' +
          '把该射频带宽从 160MHz 降到 80MHz 通常就能扫到。';
        return;
      }

      const list: ScanItem[] = [];
      for (let i = 0; i < raw.length; i++) {
        const s: IwinfoScanResult = raw[i];
        const item: ScanItem = new ScanItem();
        item.ssid = s.ssid || '';
        item.bssid = s.bssid || ('ap' + i);
        item.channel = s.channel || 0;
        item.signal = s.signal || 0;
        list.push(item);
      }
      list.sort((a: ScanItem, b: ScanItem) => b.signal - a.signal);
      this.scanResult = list;
    } catch (e) {
      this.scanHint = '扫描异常: ' + JSON.stringify(e);
    } finally {
      this.scanning = false;
    }
  }

  // ==================== 工具 ====================

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  /** 信道下拉选项：auto + 可用信道 */
  private channelOptions(radio: RadioItem): SelectOption[] {
    const opts: SelectOption[] = [];
    const autoOpt: SelectOption = { value: 'auto' };
    opts.push(autoOpt);
    for (let i = 0; i < radio.channels.length; i++) {
      const o: SelectOption = { value: String(radio.channels[i]) };
      opts.push(o);
    }
    return opts;
  }

  /** 当前配置信道在选项里的下标 */
  private channelIndex(radio: RadioItem): number {
    if (radio.configChannel === 'auto' || radio.configChannel.length === 0) {
      return 0;
    }
    const want: number = parseInt(radio.configChannel) || 0;
    for (let i = 0; i < radio.channels.length; i++) {
      if (radio.channels[i] === want) {
        return i + 1;
      }
    }
    return 0;
  }

  /** 频宽下拉选项 */
  private htModeOptions(radio: RadioItem): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < radio.htModes.length; i++) {
      const o: SelectOption = { value: radio.htModes[i] };
      opts.push(o);
    }
    return opts;
  }

  /** 当前频宽在选项里的下标 */
  private htModeIndex(radio: RadioItem): number {
    for (let i = 0; i < radio.htModes.length; i++) {
      if (radio.htModes[i] === radio.configHtMode) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 射频关闭时拿不到 iwinfo.freqlist（没有 AP 接口），用频段标准信道兜底，
   * 这样用户可以在开启射频前先把信道设好。
   */
  private defaultChannelsFor(bandLabel: string): number[] {
    if (bandLabel === '2.4G') {
      return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
    }
    if (bandLabel === '5G') {
      return [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120,
              124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165];
    }
    return [];
  }

  /**
   * iwinfo 的 htmodes 有时是数组、有时是空格分隔的字符串，统一成数组。
   */
  private toStringArray(v: string[] | string | undefined): string[] {
    if (v === undefined || v === null) {
      return [];
    }
    if (Array.isArray(v)) {
      return v as string[];
    }
    const s: string = v as string;
    if (s.length === 0) {
      return [];
    }
    const parts: string[] = s.split(' ');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0) {
        out.push(p);
      }
    }
    return out;
  }

  private bandLabel(band: string): string {
    if (band === '2g') return '2.4G';
    if (band === '5g') return '5G';
    if (band === '6g') return '6G';
    if (band === '60g') return '60G';
    return band.length > 0 ? band : '未知频段';
  }

  private signalText(signal: number): string {
    if (signal === 0) return '信号 --';
    let level: string = '弱';
    if (signal > -50) level = '极佳';
    else if (signal > -60) level = '很好';
    else if (signal > -70) level = '一般';
    else if (signal > -80) level = '较弱';
    return '信号 ' + signal + ' dBm (' + level + ')';
  }

  private formatBytes(bytes: number): string {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }

  private formatDuration(sec: number): string {
    if (sec <= 0) return '--';
    const h: number = Math.floor(sec / 3600);
    const m: number = Math.floor((sec % 3600) / 60);
    const s: number = sec % 60;
    if (h > 0) return h + '小时' + m + '分';
    if (m > 0) return m + '分' + s + '秒';
    return s + '秒';
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2000 });
  }
}
