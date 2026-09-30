/**
 * 无线（WiFi）管理页 —— 多 SSID + 出口映射
 *
 * 数据源分三层，缺一不可：
 *   1. **配置态（权威）**：`uci.get wireless`
 *      → 全部 wifi-device 与 wifi-iface。**射频被禁用时运行时接口是空的，但配置里的
 *        SSID 还在**（本机实测：radio0 disabled=1，配置里 default_radio0 仍在），
 *        所以"一个射频上有几个 SSID"必须以 uci 为准，不能用 getWirelessDevices 的 interfaces[]。
 *   2. **运行时**：`luci-rpc.getWirelessDevices` → 每个 AP 的 ifname、射频 iwinfo（信道/功率/模式）
 *   3. **出口**：`uci network`（子网）+ `uci firewall`（zone）+ Clash API `/rules`、`/proxies`
 *      → SSID → network → 子网 → SRC-IP-CIDR 命中的策略组 → 该组当前节点
 *
 * 写入链路（实测可用，且不会断开已连客户端）：
 *   uci set/delete/add wireless.<section>.<option> → uci commit wireless → rc.init network reload
 *
 * 断开客户端用 hostapd.<ifname>.del_client；取客户端必须用 iwinfo.assoclist（ACL 放行）。
 *
 * ⚠️ 实测限制：`file.write` 被 ACL 拒绝（连 /tmp 都不行），OpenClash 自定义规则文件也读不出来，
 * 所以**App 没法自动写"按源 IP 分流"的 Clash 规则**。本页负责把 SSID 管起来、把出口映射显示出来
 * 并给出告警；分流规则本身仍要在 LuCI / OpenClash 里配置。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type {
  WirelessRadio,
  WirelessIface,
  IwinfoData,
  WifiClient,
  IwinfoScanResult,
  WifiConfig,
  WifiDeviceCfg,
  WifiIfaceCfg,
  NetworkCfg,
  ClashRule,
  ClashGroup,
  OpenClashSettings
} from '../model/OpenWrtModels';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_DANGER, C_TEXT_1, C_TEXT_2, C_TEXT_3, C_CARD, C_FILL,
  colorString
} from '../common/Theme';

/** 页面用的客户端条目 */
class ClientItem {
  mac: string = '';
  signal: number = 0;
  rxBytes: number = 0;
  txBytes: number = 0;
  onlineSec: number = 0;
}

/** 页面用的一个 SSID（一个 wifi-iface：配置态 + 运行时拼起来） */
class ApItem {
  section: string = '';
  radio: string = '';
  ssid: string = '';
  password: string = '';
  encryption: string = '';
  network: string = '';
  hidden: boolean = false;
  /** uci 里的 disabled：这个 SSID 被单独禁用 */
  disabled: boolean = false;
  /** 运行时接口名，空表示当前没生效 */
  ifname: string = '';
  /** 运行时该 BSS 是否存在（射频开着 + 这个 AP 启用） */
  live: boolean = false;
  /** 绑定的 network 对应的子网（如 192.168.2.0/24），读不到为空 */
  netSubnet: string = '';
  /** 是否已用了独立子网（network != lan） */
  dedicated: boolean = false;
  clients: ClientItem[] = [];
}

/** 页面用的一个射频 */
class RadioItem {
  radioName: string = '';
  bandLabel: string = '';
  enabled: boolean = false;
  configChannel: string = '';
  configHtMode: string = '';
  configTxPower: string = '';
  country: string = '';
  liveChannel: number = 0;
  txpowerDbm: number = 0;
  hwmodes: string = '';
  channels: number[] = [];
  htModes: string[] = [];
  txPowers: number[] = [];
  aps: ApItem[] = [];
}

/** 出口映射表的一行 */
class MapRow {
  ssid: string = '';
  where: string = '';
  network: string = '';
  zone: string = '';
  subnet: string = '';
  exitGroup: string = '';
  exitNode: string = '';
  defaultGroup: string = '';
  defaultNode: string = '';
  warn: string = '';
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
  @State private mapping: MapRow[] = [];
  @State private mappingNote: string = '';
  @State private networkNames: string[] = [];
  /** lan zone 的段名与它当前的 network 列表（建/删子网时要基于原列表做数组 set） */
  @State private lanZoneSection: string = '';
  @State private lanZoneNetworks: string[] = [];
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
            // ===== 顶部 =====
            Row() {
              Text('无线网络').fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1);
              Button('刷新')
                .fontSize(14).height(32).type(ButtonType.Capsule)
                .enabled(!this.busy)
                .onClick(() => this.loadAll());
            }
            .width('100%').margin({ bottom: 12 });

            // ===== 出口映射 =====
            this.mappingCard();

            // ===== 每个射频一张卡（卡内含该射频下所有 SSID） =====
            ForEach(this.radios, (radio: RadioItem) => {
              this.radioCard(radio);
            }, (radio: RadioItem) => radio.radioName + '#' + this.dataVersion)

            // ===== 扫描结果 =====
            if (this.scanResult.length > 0 || this.scanHint.length > 0) {
              Column() {
                Text('周边 WiFi（' + this.scanFor + '）')
                  .fontSize(15).fontWeight(FontWeight.Bold).width('100%').margin({ bottom: 8 });

                if (this.scanHint.length > 0) {
                  Text(this.scanHint)
                    .fontSize(12).fontColor(C_WARNING).width('100%').lineHeight(18);
                }

                ForEach(this.scanResult, (s: ScanItem) => {
                  Row() {
                    Text(s.ssid.length > 0 ? s.ssid : '(隐藏网络)')
                      .fontSize(13).layoutWeight(1).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis });
                    Text('信道 ' + s.channel).fontSize(12).fontColor(C_TEXT_2).margin({ right: 10 });
                    Text(String(s.signal) + ' dBm')
                      .fontSize(12)
                      .fontColor(s.signal > -60 ? C_SUCCESS : (s.signal > -75 ? C_WARNING : C_TEXT_3));
                  }
                  .width('100%').padding({ top: 6, bottom: 6 })
                }, (s: ScanItem) => s.bssid);
              }
              .width('100%').padding(16)
              .backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM)
              .margin({ bottom: 12 });
            }

            // ===== 说明 =====
            Column() {
              Text('说明').fontSize(15).fontWeight(FontWeight.Bold).width('100%').margin({ bottom: 8 });
              Text('· SSID 列表来自路由器的 uci 配置，射频关闭时也能看到并编辑')
                .fontSize(12).fontColor(C_TEXT_3).margin({ bottom: 4 });
              Text('· 保存走 uci commit + rc.init network reload，实测不会断开已有连接')
                .fontSize(12).fontColor(C_TEXT_3).margin({ bottom: 4 });
              Text('· 新增/删除 SSID 会改配置并重载无线，操作前请确认')
                .fontSize(12).fontColor(C_TEXT_3).margin({ bottom: 4 });
              Text('· 出口看 Clash 的 SRC-IP-CIDR 规则；没有该规则的 SSID 会跟默认策略组')
                .fontSize(12).fontColor(C_TEXT_3).margin({ bottom: 4 });
              Text('· 分流规则要在 OpenClash / LuCI 里配：App 只能读规则，写不了（file.write 被 ACL 拒绝）')
                .fontSize(12).fontColor(C_TEXT_3).margin({ bottom: 4 });
              Text('· 断开设备用 hostapd.<接口>.del_client，不拉黑，客户端可立即重连')
                .fontSize(12).fontColor(C_TEXT_3);
            }
            .width('100%').padding(16)
            .backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM);
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

  // ==================== 出口映射卡片 ====================

  @Builder
  mappingCard() {
    Column() {
      Row() {
        Text('出口映射').fontSize(16).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1).layoutWeight(1);
        Text('SSID → 网络 → 策略组').fontSize(12).fontColor(C_TEXT_3);
      }
      .width('100%').margin({ bottom: 10 });

      if (this.mappingNote.length > 0) {
        Text(this.mappingNote)
          .fontSize(12).fontColor(C_WARNING).width('100%').lineHeight(17).margin({ bottom: 8 });
      }

      if (this.mapping.length === 0) {
        Text('没有可用的 SSID')
          .fontSize(13).fontColor(C_TEXT_3).width('100%');
      }

      ForEach(this.mapping, (row: MapRow) => {
        Column() {
          Row() {
            Column() {
              Text(row.ssid.length > 0 ? row.ssid : '(未命名 SSID)')
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(C_TEXT_1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(row.where + ' · ' + (row.network.length > 0 ? row.network : '未绑定') +
                   (row.zone.length > 0 ? ' · zone ' + row.zone : '') +
                   (row.subnet.length > 0 ? ' · ' + row.subnet : ''))
                .fontSize(11).fontColor(C_TEXT_3).margin({ top: 3 })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);

            Column() {
              if (row.exitGroup.length > 0) {
                Text(row.exitGroup)
                  .fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_SUCCESS)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(row.exitNode.length > 0 ? row.exitNode : '(未选节点)')
                  .fontSize(11).fontColor(C_TEXT_2).margin({ top: 3 }).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              } else {
                Text('未单独分流')
                  .fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_WARNING);
                Text('跟默认：' + (row.defaultGroup.length > 0 ? row.defaultGroup : '—') +
                     (row.defaultNode.length > 0 ? ' → ' + row.defaultNode : ''))
                  .fontSize(11).fontColor(C_TEXT_2).margin({ top: 3 }).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
            }
            .alignItems(HorizontalAlign.End).layoutWeight(1);
          }
          .width('100%').alignItems(VerticalAlign.Top);

          if (row.warn.length > 0) {
            Text(row.warn)
              .fontSize(11).fontColor(C_WARNING).width('100%').margin({ top: 4 }).lineHeight(16);
          }
        }
        .width('100%')
        .padding({ top: 9, bottom: 9 })
      }, (row: MapRow) => row.ssid + '|' + row.network + '#' + this.dataVersion)

      Text('同一子网下的多个 SSID 没法按 SSID 分流：要让某路 WiFi 走独立住宅 IP，' +
           '需要给它单独的 network 子网，并在 OpenClash 里加一条 SRC-IP-CIDR 规则指向对应策略组。')
        .fontSize(11).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ top: 10 });
    }
    .width('100%').padding(16)
    .backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 12 });
  }

  // ==================== 射频卡片 ====================

  @Builder
  radioCard(radio: RadioItem) {
    Column() {
      // --- 标题：频段 + 开关 ---
      Row() {
        Text(radio.enabled ? '📶' : '📴').fontSize(20).margin({ right: 8 });
        Text(radio.bandLabel).fontSize(17).fontWeight(FontWeight.Bold);
        Text(radio.radioName + (radio.country.length > 0 ? ' · ' + radio.country : ''))
          .fontSize(12).fontColor(C_TEXT_3).margin({ left: 8 });
        Blank();
        Text(radio.enabled ? '已开启' : '已关闭')
          .fontSize(12).fontColor(Color.White)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(radio.enabled ? C_SUCCESS : C_TEXT_3)
          .borderRadius(9)
          .margin({ right: 8 });
        Toggle({ type: ToggleType.Switch, isOn: radio.enabled })
          .enabled(!this.busy)
          .onChange((v: boolean) => this.toggleRadio(radio, v));
      }
      .width('100%').margin({ bottom: 12 });

      // --- 运行时状态 ---
      this.infoLine('当前信道', radio.liveChannel > 0 ? String(radio.liveChannel) : '--');
      this.infoLine('发射功率', radio.txpowerDbm > 0 ? (radio.txpowerDbm + ' dBm') : '--');
      this.infoLine('支持模式', radio.hwmodes.length > 0 ? radio.hwmodes : '--');
      this.infoLine('SSID 数量', String(radio.aps.length) + ' 个');

      Divider().margin({ top: 8, bottom: 12 });

      // --- 信道 ---
      Row() {
        Text('信道').fontSize(14).fontColor(C_TEXT_2).layoutWeight(1);
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

      // --- 频宽 ---
      Row() {
        Text('频宽').fontSize(14).fontColor(C_TEXT_2).layoutWeight(1);
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

      // --- 发射功率 ---
      Row() {
        Text('发射功率').fontSize(14).fontColor(C_TEXT_2).layoutWeight(1);
        Select(this.txPowerOptions(radio))
          .selected(this.txPowerIndex(radio))
          .value(radio.configTxPower.length > 0 ? (radio.configTxPower + ' dBm') : '自动')
          .font({ size: 14 })
          .enabled(!this.busy)
          .onSelect((index: number, value?: string) => {
            if (value !== undefined) {
              radio.configTxPower = value;
            }
          });
      }
      .width('100%').margin({ bottom: 8 });

      if (radio.configHtMode.indexOf('160') >= 0) {
        Text('⚠️ 160MHz 会占用跨 DFS 的宽信道，MT7981 驱动会拒绝后台扫描（信道扫描会扫不到东西）')
          .fontSize(11).fontColor(C_WARNING).width('100%')
          .lineHeight(16).margin({ top: 4 });
      }

      Button(this.busy ? '正在应用...' : '保存射频设置（信道 / 频宽 / 功率）')
        .width('100%').height(38).type(ButtonType.Capsule)
        .backgroundColor(C_PRIMARY)
        .fontSize(14)
        .enabled(!this.busy)
        .margin({ top: 10 })
        .onClick(() => this.saveRadio(radio));

      Divider().margin({ top: 14, bottom: 12 });

      // --- 该射频下的所有 SSID ---
      Row() {
        Text('SSID（' + String(radio.aps.length) + '）')
          .fontSize(15).fontWeight(FontWeight.Bold).layoutWeight(1);
        Button('+ 新增 SSID')
          .fontSize(12).height(30).type(ButtonType.Capsule)
          .backgroundColor(C_PRIMARY)
          .enabled(!this.busy)
          .onClick(() => this.confirmAddSsid(radio));
      }
      .width('100%').margin({ bottom: 10 });

      ForEach(radio.aps, (ap: ApItem) => {
        this.apBlock(radio, ap);
      }, (ap: ApItem) => ap.section + '#' + this.dataVersion)

      Button(this.scanning ? '扫描中...' : ('扫描 ' + radio.bandLabel + ' 周边 WiFi'))
        .width('100%').height(36).type(ButtonType.Capsule)
        .backgroundColor(C_WARNING)
        .margin({ top: 12 })
        .enabled(!this.busy && !this.scanning)
        .onClick(() => this.doScan(radio));
    }
    .width('100%').padding(16)
    .backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 12 });
  }

  // ==================== 单个 SSID 区块 ====================

  @Builder
  apBlock(radio: RadioItem, ap: ApItem) {
    Column() {
      // --- 标题行：SSID + 启用开关 ---
      Row() {
        Column() {
          Text(ap.ssid.length > 0 ? ap.ssid : '(未命名 SSID)')
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(ap.section + ' · ' + (ap.encryption.length > 0 ? ap.encryption : '未设加密') +
               (ap.live ? (' · ' + ap.ifname) : ' · 未生效'))
            .fontSize(11).fontColor(C_TEXT_3).margin({ top: 3 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1);

        Text(ap.disabled ? '已禁用' : '已启用')
          .fontSize(11).fontColor(ap.disabled ? C_TEXT_3 : C_SUCCESS)
          .margin({ right: 6 });
        Toggle({ type: ToggleType.Switch, isOn: !ap.disabled })
          .enabled(!this.busy)
          .onChange((v: boolean) => this.toggleAp(ap, v));
      }
      .width('100%').margin({ bottom: 8 });

      if (!ap.live) {
        Text(radio.enabled ? '该 SSID 已被单独禁用，打开上面的开关即可启用'
                           : '所属射频已关闭，打开射频开关后这个 SSID 才会生效')
          .fontSize(11).fontColor(C_TEXT_3).width('100%').margin({ bottom: 8 });
      }

      // --- SSID ---
      Text('WiFi 名称 (SSID)').fontSize(13).fontColor(C_TEXT_2).width('100%');
      TextInput({ text: ap.ssid, placeholder: '输入 SSID' })
        .width('100%').margin({ top: 4, bottom: 10 })
        .fontSize(14)
        .onChange((v: string) => { ap.ssid = v.trim(); });

      // --- 密码 ---
      Text('WiFi 密码').fontSize(13).fontColor(C_TEXT_2).width('100%');
      TextInput({ text: ap.password, placeholder: '输入密码（留空=开放网络，至少 8 位）' })
        .type(InputType.Password)
        .showPasswordIcon(false)
        .width('100%').margin({ top: 4, bottom: 10 })
        .fontSize(14)
        .onChange((v: string) => { ap.password = v; });

      // --- 绑定网络 ---
      Row() {
        Column() {
          Text('绑定网络 (network)').fontSize(13).fontColor(C_TEXT_2);
          Text('决定这个 SSID 走哪个子网与防火墙区域')
            .fontSize(11).fontColor(C_TEXT_3).margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1);
        Select(this.networkOptions())
          .selected(this.networkIndex(ap))
          .value(ap.network.length > 0 ? ap.network : '未绑定')
          .font({ size: 14 })
          .enabled(!this.busy)
          .onSelect((index: number, value?: string) => {
            if (value !== undefined) {
              ap.network = value;
            }
          });
      }
      .width('100%').margin({ top: 2, bottom: 10 });

      // --- 出口子网（建/删独立网段，给"一 WiFi 一住宅 IP"打底）---
      Column() {
        Row() {
          Column() {
            Text(ap.dedicated ? '独立子网' : '与 lan 共用子网')
              .fontSize(13).fontColor(C_TEXT_2);
            Text((ap.network.length > 0 ? ap.network : '未绑定') +
                 (ap.netSubnet.length > 0 ? ' · ' + ap.netSubnet : ''))
              .fontSize(11).fontColor(C_TEXT_3).margin({ top: 2 });
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1);

          Button(ap.dedicated ? '退回 lan' : '建独立子网')
            .fontSize(12).height(30).type(ButtonType.Capsule)
            .backgroundColor(ap.dedicated ? C_DANGER : C_PRIMARY)
            .enabled(!this.busy && this.lanZoneSection.length > 0)
            .onClick(() => {
              if (ap.dedicated) {
                this.confirmDeleteSubnet(ap);
              } else {
                this.confirmCreateSubnet(ap);
              }
            });
        }
        .width('100%');

        Text(ap.dedicated
          ? '该 SSID 已是独立网段：在 OpenClash / LuCI 里为 ' + ap.netSubnet +
            ' 加一条 SRC-IP-CIDR 规则指向专用策略组，它就从那条住宅 IP 出去'
          : '建独立子网会新建桥 + 静态接口 + DHCP，把该 SSID 换到 192.168.x.0/24 新网段（客户端需重连）')
          .fontSize(11).fontColor(C_TEXT_3).width('100%').margin({ top: 4 }).lineHeight(16);
      }
      .width('100%').margin({ top: 2, bottom: 10 })

      // --- 隐藏 SSID ---
      Row() {
        Column() {
          Text('隐藏 WiFi 名称').fontSize(14);
          Text('隐藏后新设备需要手动输入名称才能连接')
            .fontSize(11).fontColor(C_TEXT_3).margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: ap.hidden })
          .enabled(!this.busy)
          .onChange((v: boolean) => { ap.hidden = v; });
      }
      .width('100%').margin({ bottom: 10 });

      // --- 操作按钮 ---
      Row() {
        Button(this.busy ? '正在应用...' : '保存并应用')
          .layoutWeight(1).height(38).type(ButtonType.Capsule)
          .backgroundColor(C_PRIMARY).fontSize(14)
          .enabled(!this.busy)
          .onClick(() => this.applyApEdits(ap));
        Button('删除')
          .width(76).height(38).type(ButtonType.Capsule)
          .backgroundColor(C_DANGER).fontSize(14)
          .margin({ left: 8 })
          .enabled(!this.busy)
          .onClick(() => this.confirmDeleteSsid(ap));
      }
      .width('100%').margin({ bottom: 4 });

      // --- 已连接客户端 ---
      if (ap.clients.length > 0) {
        Text('已连接设备（' + String(ap.clients.length) + '）')
          .fontSize(13).fontWeight(FontWeight.Bold)
          .width('100%').margin({ top: 12, bottom: 4 });

        ForEach(ap.clients, (c: ClientItem) => {
          Row() {
            Column() {
              Text(c.mac).fontSize(13).fontWeight(FontWeight.Medium);
              Text(this.signalText(c.signal) + '   ↓' + this.formatBytes(c.rxBytes) +
                   '  ↑' + this.formatBytes(c.txBytes) + '   在线 ' + this.formatDuration(c.onlineSec))
                .fontSize(11).fontColor(C_TEXT_3).margin({ top: 3 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);

            Button('断开')
              .fontSize(12).height(30).type(ButtonType.Capsule)
              .backgroundColor(C_DANGER)
              .enabled(!this.busy)
              .onClick(() => this.kickClient(ap, c));
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
        }, (c: ClientItem) => c.mac + '#' + this.dataVersion);
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(C_FILL)
    .borderRadius(14)
    .margin({ bottom: 10 });
  }

  /**
   * 键值对行。
   * 注意：传进来的是**纯展示、随条目一起重建**的值，且调用方在 ForEach 内、
   * key 里带了 dataVersion，所以不会有 @Builder 值传递不刷新的问题。
   */
  @Builder
  infoLine(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor(C_TEXT_2);
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
      // 1) 配置态：射频 + 全部 SSID（权威数据源）
      const cfg: WifiConfig = await this.client.getWifiConfig();
      if (cfg.devices.length === 0) {
        this.hasError = true;
        this.errorMsg = '读取无线配置失败（uci wireless 读不到 wifi-device）';
        return;
      }

      // 2) 运行时：射频 iwinfo、每个 AP 的 ifname
      const rtResp = await this.client.getWirelessDevices();
      const runtime: Record<string, WirelessRadio> =
        (rtResp.success && rtResp.data) ? rtResp.data : {};

      // 3) 出口映射素材：network 子网 / zone / Clash 规则与策略组
      const netCfgs: NetworkCfg[] = await this.client.getNetworkConfigs();
      const zones: Record<string, string> = await this.client.getNetworkZones();
      const netSubnet: Record<string, string> = {};
      const netNames: string[] = [];
      for (let i = 0; i < netCfgs.length; i++) {
        netSubnet[netCfgs[i].name] = netCfgs[i].subnet;
        if (netCfgs[i].name !== 'loopback') {
          netNames.push(netCfgs[i].name);
        }
      }
      this.networkNames = netNames;

      // lan zone（建独立子网时要往它的 network 列表里追加；只能数组 set，不能 add_list）
      this.lanZoneSection = await this.client.findLanZoneSection();
      this.lanZoneNetworks = await this.client.getLanZoneNetworks(this.lanZoneSection);

      let rules: ClashRule[] = [];
      let groups: ClashGroup[] = [];
      let clashNote: string = '';
      const oc: OpenClashSettings | null = await this.client.getOpenClashSettings();
      if (oc === null) {
        clashNote = '读不到 OpenClash 配置：下面显示的是 SSID 与网络归属，出口一列不可信';
      } else if (!oc.enabled) {
        clashNote = 'OpenClash 总开关是关闭的，所有 SSID 都按默认路由直出';
      } else {
        const base: string = `http://${this.client.getHost()}:${oc.apiPort}`;
        rules = await this.client.getClashRules(base, oc.apiSecret);
        groups = await this.client.getClashGroups(base, oc.apiSecret);
        if (rules.length === 0) {
          clashNote = '读不到 Clash 规则（OpenClash 可能没在运行），出口一列仅供参考';
        } else if (this.countSourceRules(rules) === 0) {
          clashNote = '当前没有任何 SRC-IP-CIDR 规则：所有 SSID 都会共用默认策略组的出口';
        }
      }

      // 4) 组装射频 + SSID
      const items: RadioItem[] = [];
      for (let d = 0; d < cfg.devices.length; d++) {
        const dev: WifiDeviceCfg = cfg.devices[d];
        const item: RadioItem = new RadioItem();
        item.radioName = dev.section;
        item.bandLabel = this.bandLabel(dev.band);
        item.enabled = !dev.disabled;
        item.configChannel = dev.channel.length > 0 ? dev.channel : 'auto';
        item.configHtMode = dev.htmode;
        item.configTxPower = dev.txpower;
        item.country = dev.country;

        const radioRt: WirelessRadio | undefined = runtime[dev.section];
        if (radioRt && radioRt.iwinfo) {
          const live: IwinfoData = radioRt.iwinfo;
          item.liveChannel = live.channel || 0;
          item.txpowerDbm = live.txpower || 0;
          item.hwmodes = live.hwmodes_text || '';
          item.htModes = this.toStringArray(live.htmodes);
        }

        // 该射频下的所有 SSID（配置态，含射频被禁用时的）
        const aps: ApItem[] = [];
        for (let a = 0; a < cfg.ifaces.length; a++) {
          const ic: WifiIfaceCfg = cfg.ifaces[a];
          if (ic.radio !== dev.section) {
            continue;
          }
          const ap: ApItem = new ApItem();
          ap.section = ic.section;
          ap.radio = ic.radio;
          ap.ssid = ic.ssid;
          ap.password = ic.key;
          ap.encryption = ic.encryption;
          ap.network = ic.network;
          ap.netSubnet = netSubnet[ic.network] || '';
          ap.dedicated = ic.network.length > 0 && ic.network !== 'lan';
          ap.hidden = ic.hidden;
          ap.disabled = ic.disabled;

          if (radioRt) {
            const ifaces: WirelessIface[] = radioRt.interfaces || [];
            for (let k = 0; k < ifaces.length; k++) {
              if ((ifaces[k].section || '') === ic.section) {
                ap.ifname = ifaces[k].ifname || '';
                ap.live = ap.ifname.length > 0;
              }
            }
          }

          if (ap.live) {
            const cr = await this.client.getWifiClients(ap.ifname);
            if (cr.success && cr.data) {
              ap.clients = this.toClientItems(cr.data);
            }
          }
          aps.push(ap);
        }
        item.aps = aps;

        // 信道 / 功率候选：拿该射频下第一个生效的 AP 接口去查
        let probeIface: string = '';
        for (let i = 0; i < aps.length; i++) {
          if (aps[i].ifname.length > 0) {
            probeIface = aps[i].ifname;
          }
        }
        if (probeIface.length > 0) {
          const fr = await this.client.getWifiChannels(probeIface);
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
          item.txPowers = await this.client.getTxPowerList(probeIface);
        }
        if (item.channels.length === 0) {
          item.channels = this.defaultChannelsFor(item.bandLabel);
        }
        items.push(item);
      }

      // 5) 组装出口映射
      let defGroup: string = '';
      for (let i = 0; i < rules.length; i++) {
        if (rules[i].type === 'MATCH') {
          defGroup = rules[i].proxy;
        }
      }
      const rows: MapRow[] = [];
      for (let r = 0; r < items.length; r++) {
        const radio: RadioItem = items[r];
        for (let a = 0; a < radio.aps.length; a++) {
          const ap: ApItem = radio.aps[a];
          const row: MapRow = new MapRow();
          row.ssid = ap.ssid;
          row.where = radio.bandLabel + ' · ' + ap.radio;
          row.network = ap.network;
          row.zone = zones[ap.network] || '';
          row.subnet = netSubnet[ap.network] || '';
          row.exitGroup = this.matchSourceGroup(rules, row.subnet);
          row.exitNode = this.groupNow(groups, row.exitGroup);
          row.defaultGroup = defGroup;
          row.defaultNode = this.groupNow(groups, defGroup);
          row.warn = this.mappingWarn(items, ap, row);
          rows.push(row);
        }
      }

      this.radios = items;
      this.mapping = rows;
      this.mappingNote = clashNote;
      this.dataVersion = this.dataVersion + 1;
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '加载异常: ' + JSON.stringify(e);
    } finally {
      this.isLoading = false;
    }
  }

  /** SRC-IP-CIDR 规则条数 */
  private countSourceRules(rules: ClashRule[]): number {
    let n: number = 0;
    for (let i = 0; i < rules.length; i++) {
      if (rules[i].type === 'SRC-IP-CIDR') {
        n = n + 1;
      }
    }
    return n;
  }

  /**
   * 找出按源子网分流的策略组。
   * 只看 SRC-IP-CIDR —— 目的地址的 IP-CIDR / 域名规则跟"这个 SSID 从哪出去"无关。
   */
  private matchSourceGroup(rules: ClashRule[], subnet: string): string {
    if (subnet.length === 0) {
      return '';
    }
    const subnetIp: string = subnet.split('/')[0];
    for (let i = 0; i < rules.length; i++) {
      const rule: ClashRule = rules[i];
      if (rule.type !== 'SRC-IP-CIDR') {
        continue;
      }
      if (rule.payload === subnet || rule.payload.split('/')[0] === subnetIp) {
        return rule.proxy;
      }
    }
    return '';
  }

  /** 策略组当前选中的节点 */
  private groupNow(groups: ClashGroup[], group: string): string {
    if (group.length === 0) {
      return '';
    }
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].name === group) {
        return groups[i].now;
      }
    }
    return '';
  }

  /** 生成这一行的告警文案 */
  private mappingWarn(items: RadioItem[], ap: ApItem, row: MapRow): string {
    const parts: string[] = [];
    if (row.subnet.length === 0) {
      parts.push('绑定的 network「' + ap.network + '」读不到子网，无法判断分流');
    } else if (row.exitGroup.length === 0) {
      parts.push('该子网没有 SRC-IP-CIDR 规则，会跟默认出口');
    }
    const share: string[] = [];
    for (let r = 0; r < items.length; r++) {
      for (let a = 0; a < items[r].aps.length; a++) {
        const other: ApItem = items[r].aps[a];
        if (other.section !== ap.section && other.network === ap.network) {
          share.push(other.ssid.length > 0 ? other.ssid : other.section);
        }
      }
    }
    if (share.length > 0) {
      parts.push('与「' + share.join('、') + '」共用同一 network，没法按 SSID 分开出口');
    }
    return parts.join('；');
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

  /** 单独启用/禁用一个 SSID */
  private async toggleAp(ap: ApItem, on: boolean): Promise<void> {
    ap.disabled = !on;
    this.busy = true;
    try {
      const ok: boolean = await this.client.setWifiOption(ap.section, 'disabled', on ? '0' : '1');
      if (!ok) {
        this.toast('写入配置失败');
        return;
      }
      await this.applyChanges(on ? '正在启用该 SSID...' : '正在禁用该 SSID...');
    } finally {
      this.busy = false;
    }
  }

  /** 保存该射频的信道 / 频宽 / 发射功率 */
  private async saveRadio(radio: RadioItem): Promise<void> {
    this.busy = true;
    try {
      let ok: boolean = true;
      if (radio.configChannel.length > 0) {
        ok = await this.client.setWifiOption(radio.radioName, 'channel', radio.configChannel);
      }
      if (ok && radio.configHtMode.length > 0) {
        ok = await this.client.setWifiOption(radio.radioName, 'htmode', radio.configHtMode);
      }
      if (ok) {
        if (radio.configTxPower.length > 0) {
          ok = await this.client.setWifiOption(radio.radioName, 'txpower', radio.configTxPower);
        } else {
          // 选「自动」就把这项删掉，回到驱动/国家默认
          ok = await this.client.deleteWifiOption(radio.radioName, 'txpower');
        }
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

  /** 保存一个 SSID 的名称 / 密码 / 隐藏 / 绑定网络 */
  private async applyApEdits(ap: ApItem): Promise<void> {
    if (ap.ssid.length === 0) {
      this.toast('WiFi 名称不能为空');
      return;
    }
    if (ap.password.length > 0 && ap.password.length < 8) {
      this.toast('WPA 密码至少 8 位');
      return;
    }
    if (ap.network.length === 0) {
      this.toast('请选择绑定的网络');
      return;
    }

    this.busy = true;
    try {
      let ok: boolean = await this.client.setWifiOption(ap.section, 'ssid', ap.ssid);
      if (ok) {
        ok = await this.client.setWifiOption(ap.section, 'hidden', ap.hidden ? '1' : '0');
      }
      if (ok) {
        ok = await this.client.setWifiOption(ap.section, 'network', ap.network);
      }
      if (ok) {
        // 密码留空 = 开放网络：要显式把 encryption 也改掉，否则旧密码会一直留着
        if (ap.password.length > 0) {
          ok = await this.client.setWifiOption(ap.section, 'key', ap.password);
          if (ok) {
            ok = await this.client.setWifiOption(ap.section, 'encryption', 'psk2');
          }
        } else {
          ok = await this.client.setWifiOption(ap.section, 'encryption', 'none');
        }
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

  /** 新增 SSID 前的确认框（会改配置并重载无线） */
  private confirmAddSsid(radio: RadioItem): void {
    let base: string = 'OpenWrt';
    let key: string = '';
    let network: string = this.networkNames.length > 0 ? this.networkNames[0] : 'lan';
    if (radio.aps.length > 0) {
      const first: ApItem = radio.aps[0];
      if (first.ssid.length > 0) {
        base = first.ssid;
      }
      key = first.password;
      if (first.network.length > 0) {
        network = first.network;
      }
    }
    const newSsid: string = base + '-' + String(radio.aps.length + 1);
    const netHint: string = key.length > 0
      ? '名称「' + newSsid + '」，密码沿用该射频第一个 SSID 的密码，绑定 ' + network + '。'
      : '名称「' + newSsid + '」，无密码（开放网络），绑定 ' + network + '。';

    promptAction.showDialog({
      title: '新增 SSID',
      message: netHint + '\n\n新增后会立即提交配置并重载无线（几秒）。' +
               '要让它走独立出口，还需要在 OpenClash 里为它的子网加一条 SRC-IP-CIDR 规则。',
      buttons: [
        { text: '取消', color: colorString(C_TEXT_2, '#666666') },
        { text: '新增', color: colorString(C_PRIMARY, '#0A59F7') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.addSsid(radio, newSsid, key, network);
      }
    });
  }

  private async addSsid(radio: RadioItem, ssid: string, key: string, network: string): Promise<void> {
    this.busy = true;
    promptAction.showToast({ message: '正在新增 SSID...', duration: 2000 });
    try {
      const section: string = await this.client.addWifiIface(radio.radioName, ssid, key, network, false);
      if (section.length === 0) {
        this.toast('新增失败（写配置被拒或段名没拿到）');
        return;
      }
      await this.applyChanges('正在应用，无线会重载几秒...');
    } finally {
      this.busy = false;
    }
  }

  /** 删除 SSID 前的确认框 */
  private confirmDeleteSsid(ap: ApItem): void {
    promptAction.showDialog({
      title: '删除 SSID',
      message: '确定删除「' + (ap.ssid.length > 0 ? ap.ssid : ap.section) + '」吗？\n' +
               '会从无线配置里移除这个 wifi-iface 并重载无线，连在它上面的设备会掉线。',
      buttons: [
        { text: '取消', color: colorString(C_TEXT_2, '#666666') },
        { text: '删除', color: colorString(C_DANGER, '#F53F3F') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.deleteSsid(ap);
      }
    });
  }

  private async deleteSsid(ap: ApItem): Promise<void> {
    this.busy = true;
    try {
      const ok: boolean = await this.client.deleteWifiIface(ap.section);
      if (!ok) {
        this.toast('删除失败');
        return;
      }
      await this.applyChanges('正在删除并重载无线...');
    } finally {
      this.busy = false;
    }
  }

  /** 建独立子网前的确认（新建桥/接口/DHCP + 追加进 lan zone + 重绑该 SSID） */
  private async confirmCreateSubnet(ap: ApItem): Promise<void> {
    const prefix: string = await this.client.findFreeSubnetPrefix();
    if (prefix.length === 0) {
      this.toast('找不到空闲网段（192.168.3~249 都被占用了）');
      return;
    }
    const netName: string = 'air' + prefix.split('.')[2];
    promptAction.showDialog({
      title: '建立独立子网',
      message: '让「' + (ap.ssid.length > 0 ? ap.ssid : ap.section) + '」使用独立网段：\n' +
               '  新网段 ' + prefix + '.0/24（网关 ' + prefix + '.1）\n' +
               '  新建桥 br-' + netName + '、静态接口 ' + netName + ' 与对应 DHCP\n' +
               '  把 ' + netName + ' 加进 lan 防火墙区域（保持被 OpenClash 接管）\n' +
               '  该 SSID 从当前 network 改绑到 ' + netName + '\n\n' +
               '客户端会重连。之后还要在 OpenClash / LuCI 里为 ' + prefix + '.0/24 加一条 ' +
               'SRC-IP-CIDR 规则指向专用策略组（这条 App 写不了）。',
      buttons: [
        { text: '取消', color: colorString(C_TEXT_2, '#666666') },
        { text: '建立', color: colorString(C_PRIMARY, '#0A59F7') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.createSubnet(ap, netName, prefix);
      }
    });
  }

  private async createSubnet(ap: ApItem, netName: string, prefix: string): Promise<void> {
    this.busy = true;
    this.toast('正在建立独立子网...');
    try {
      const created: string = await this.client.createSubnetForSsid(
        ap.section, netName, prefix, this.lanZoneSection, this.lanZoneNetworks
      );
      if (created.length === 0) {
        this.toast('建立失败（未提交的改动已回滚）');
        return;
      }
      await this.reloadNetworkStack();
      this.toast('已建立 ' + created + '（' + prefix + '.0/24）');
    } finally {
      this.busy = false;
    }
  }

  /** 删除独立子网前的确认 */
  private confirmDeleteSubnet(ap: ApItem): void {
    promptAction.showDialog({
      title: '退回 lan',
      message: '删除「' + (ap.ssid.length > 0 ? ap.ssid : ap.section) + '」的独立子网 ' + ap.network + '：\n' +
               '  从 lan 防火墙区域移除该网络\n' +
               '  删除它的桥 / 静态接口 / DHCP 段\n' +
               '  该 SSID 绑回 lan\n\n' +
               '客户端会重连。',
      buttons: [
        { text: '取消', color: colorString(C_TEXT_2, '#666666') },
        { text: '删除', color: colorString(C_DANGER, '#F53F3F') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.deleteSubnet(ap);
      }
    });
  }

  private async deleteSubnet(ap: ApItem): Promise<void> {
    this.busy = true;
    this.toast('正在删除子网...');
    try {
      const ok: boolean = await this.client.deleteSubnetForSsid(
        ap.section, ap.network, this.lanZoneSection, this.lanZoneNetworks
      );
      if (!ok) {
        this.toast('删除失败');
        return;
      }
      await this.reloadNetworkStack();
      this.toast('已退回 lan');
    } finally {
      this.busy = false;
    }
  }

  /**
   * 新子网生效要两步：reload netifd（加接口/桥）+ reload dnsmasq（新 DHCP 作用域），
   * 然后重新加载页面数据。不能用 reload_config —— 那是脚本，file.exec 不在白名单。
   */
  private async reloadNetworkStack(): Promise<void> {
    await this.client.applyWifi();
    await this.client.reloadService('dnsmasq');
    await this.sleep(6000);
    await this.loadAll();
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
  private async kickClient(ap: ApItem, c: ClientItem): Promise<void> {
    if (ap.ifname.length === 0) {
      this.toast('该 SSID 当前没有可用接口');
      return;
    }
    this.busy = true;
    try {
      const r = await this.client.kickWifiClient(ap.ifname, c.mac, 0);
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
    let ifname: string = '';
    for (let i = 0; i < radio.aps.length; i++) {
      if (radio.aps[i].ifname.length > 0) {
        ifname = radio.aps[i].ifname;
      }
    }
    if (ifname.length === 0) {
      this.toast('该射频没有可用接口（先把它打开）');
      return;
    }

    this.scanning = true;
    this.scanResult = [];
    this.scanFor = radio.bandLabel;
    this.scanHint = '';

    try {
      const r = await this.client.scanWifi(ifname);
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

  private htModeOptions(radio: RadioItem): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < radio.htModes.length; i++) {
      const o: SelectOption = { value: radio.htModes[i] };
      opts.push(o);
    }
    return opts;
  }

  private htModeIndex(radio: RadioItem): number {
    for (let i = 0; i < radio.htModes.length; i++) {
      if (radio.htModes[i] === radio.configHtMode) {
        return i;
      }
    }
    return -1;
  }

  /** 发射功率下拉：自动 + 支持档位 */
  private txPowerOptions(radio: RadioItem): SelectOption[] {
    const opts: SelectOption[] = [];
    const autoOpt: SelectOption = { value: '' };
    opts.push(autoOpt);
    for (let i = 0; i < radio.txPowers.length; i++) {
      const o: SelectOption = { value: String(radio.txPowers[i]) };
      opts.push(o);
    }
    return opts;
  }

  private txPowerIndex(radio: RadioItem): number {
    if (radio.configTxPower.length === 0) {
      return 0;
    }
    const want: number = parseInt(radio.configTxPower) || 0;
    for (let i = 0; i < radio.txPowers.length; i++) {
      if (radio.txPowers[i] === want) {
        return i + 1;
      }
    }
    return 0;
  }

  /** 绑定网络下拉 */
  private networkOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.networkNames.length; i++) {
      const o: SelectOption = { value: this.networkNames[i] };
      opts.push(o);
    }
    return opts;
  }

  private networkIndex(ap: ApItem): number {
    for (let i = 0; i < this.networkNames.length; i++) {
      if (this.networkNames[i] === ap.network) {
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

  /** iwinfo 的 htmodes 有时是数组、有时是空格分隔的字符串，统一成数组 */
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