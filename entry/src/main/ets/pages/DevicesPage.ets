/**
 * 在线设备页面
 * 
 * 展示路由器的 DHCP 租约列表。
 */

import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { OpenWrtClient } from '../model/OpenWrtClient';
import { DeviceNotes } from '../model/DeviceNotes';
import { GlobalContext } from '../model/GlobalContext';
import type { DhcpLease } from '../model/OpenWrtModels';
import {
  C_PRIMARY, C_SUCCESS, C_DANGER, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_CARD_SOLID, C_FILL
} from '../common/Theme';
import { shouldShowErrorPage, shouldToast, notifyLoadFailed } from '../common/RefreshPolicy';
import type { LoadKind } from '../common/RefreshPolicy';
// 按压发光（HDS 点光源）：只追加 visualEffect + 按压状态，不改按钮原有样式
import { PressGlow } from '../common/PressGlow';

// 颜色统一走 Theme 里的资源（浅色/深色两套自动切换）
const COLOR_CARD_BG: ResourceColor = C_CARD;
const COLOR_SECONDARY: ResourceColor = C_TEXT_2;
const COLOR_TERTIARY: ResourceColor = C_TEXT_3;
const COLOR_PRIMARY: ResourceColor = C_PRIMARY;

@Component
export struct DevicesPage {
  private client!: OpenWrtClient;

  @State private devices: DhcpLease[] = [];
  /** 设备备注（本机 preferences；键是 MAC 小写）。改完换成新对象引用才会重绘 */
  @State private notes: Record<string, string> = {};
  /** 备注的读写（只存本机，不写路由器） */
  private notesStore: DeviceNotes = new DeviceNotes();
  /** 备注编辑框（每次编辑现建一个，绑当前这台设备） */
  private noteDialog: CustomDialogController | null = null;

  @State private isLoading: boolean = true;
  @State private isRefreshing: boolean = false;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  @State private activeCount: number = 0;
  /** 按压发光的按钮（'' = 没有；值是 MAC）：同屏只会按住一个 */
  @State private glowMac: string = '';

  aboutToAppear(): void {
    this.loadNotes();
    this.loadData();
  }

  build() {
    Stack() {
      if (!this.isLoading && !this.hasError) {
        Column() {
          // 统计头部
          Row() {
            Text(`${this.activeCount} 台在线`)
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(COLOR_PRIMARY);
            Text(`共 ${this.devices.length} 个租约`).fontSize(12).fontColor(COLOR_SECONDARY).margin({ left: 8 });
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 });

          // 下拉刷新用 Refresh 组件 —— 这是全 App 唯一的刷新手势（规范见 common/RefreshPolicy.ets）。
          // 千万不要用 List 的 onReachStart —— 它在列表初次渲染（本来就在顶部）时就会触发，
          // 加载完数据又引起重渲染，于是再次触发，形成无限刷新循环。
          Refresh({ refreshing: this.isRefreshing }) {
            List() {
              ForEach(this.devices, (device: DhcpLease) => {
                ListItem() {
                  // 设备卡片（不拆分 @Builder，全内联）
                  Column() {
                    Row() {
                      // 用文本代替 Circle 头像
                      Text(this.getInitial(device.hostname))
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(Color.White)
                        .textAlign(TextAlign.Center)
                        .width(40).height(40)
                        .backgroundColor(this.getDeviceColor(device.hostname))
                        .borderRadius(20)
                        .margin({ right: 12 });

                      Column() {
                        Text(device.hostname || '(未命名设备)')
                          .fontSize(15).fontWeight(FontWeight.Bold)
                          .lineHeight(20).maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis });
                        Text(device.mac)
                          .fontSize(13).fontColor(COLOR_SECONDARY)
                          .fontFamily('monospace').margin({ top: 2 });
                        // 备注（本机存的，hostname 为空时尤其管用）
                        if (this.noteOf(device.mac).length > 0) {
                          Text('备注：' + this.noteOf(device.mac))
                            .fontSize(12).fontColor(COLOR_PRIMARY)
                            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                            .margin({ top: 2 });
                        }
                      }
                      .layoutWeight(1)
                      // Column 的 alignItems 默认是 Center，不写的话主机名/MAC 会居中
                      .alignItems(HorizontalAlign.Start);

                      // 状态指示灯用文本替代
                      Text(this.isLeaseActive(device) ? '●' : '○')
                        .fontSize(14)
                        .fontColor(this.isLeaseActive(device) ? C_SUCCESS : C_TEXT_3);
                    }
                    .width('100%').margin({ bottom: 8 });

                    Row() {
                      Text(device.ip).fontSize(14).fontWeight(FontWeight.Medium).fontFamily('monospace');
                      Text(this.formatExpiry(device.end))
                        .fontSize(12)
                        .fontColor(this.isLeaseActive(device) ? COLOR_SECONDARY : C_DANGER)
                        .layoutWeight(1).textAlign(TextAlign.End).margin({ left: 8 });
                      // 备注入口：弹一个带输入框的对话框
                      Button(this.noteOf(device.mac).length > 0 ? '改备注' : '备注')
                        .fontSize(11).height(26).type(ButtonType.Capsule)
                        .backgroundColor(C_FILL).fontColor(COLOR_PRIMARY)
                        .margin({ left: 10 })
                        // 按住时按钮表面点光源亮起（原有底色 / 尺寸没动）
                        .visualEffect(PressGlow.effect(this.glowMac === device.mac))
                        .onTouch((event: TouchEvent) => {
                          PressGlow.track(event, (pressed: boolean) => {
                            this.glowMac = pressed ? device.mac : '';
                          });
                        })
                        .animation(PressGlow.ANIM)
                        .onClick(() => this.openNoteDialog(device));
                    }
                    .width('100%').alignItems(VerticalAlign.Center);
                  }
                  .width('100%').padding(16).backgroundColor(COLOR_CARD_BG)
                  .borderRadius(18).shadow(ShadowStyle.OUTER_DEFAULT_SM)
                  .margin({ bottom: 10 });
                }
              }, (device: DhcpLease, index?: number) => {
                // key 里带上备注：备注改了才会重建这张卡（ArkUI 会复用条目节点，不换 key 不刷新）
                return device.mac + device.ip + '#' + this.noteOf(device.mac);
              });
            }
            .width('100%')
            .height('100%')
            // 左右留白放在 List 的 padding 上。
            // 不能给卡片写 width('100%') + margin({left,right})：width 已经是父容器全宽，
            // 再加左右 margin 会让卡片向右溢出屏幕，右边的内容（状态点、到期时间）被裁掉。
            .padding({ left: 16, right: 16 })
            .edgeEffect(EdgeEffect.Spring);
          }
          .layoutWeight(1)
          .width('100%')
          .onRefreshing(() => this.onPullRefresh());
        }
        .width('100%').height('100%');
      }

      // 空状态是盖在列表上面的一层：不能吞掉触摸事件，
      // 否则租约为 0 时下拉刷新会被这层挡住（HitTestMode.None 让手势透到下面的 Refresh）
      if (!this.isLoading && !this.hasError && this.devices.length === 0) {
        Column() {
          Text('📡').fontSize(48);
          Text('未找到 DHCP 租约').fontSize(16).fontColor(COLOR_SECONDARY).margin({ top: 12 });
          Text('请确保路由器开启了 DHCP 服务器').fontSize(13).fontColor(COLOR_TERTIARY).margin({ top: 4 });
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None);
      }

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }
      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(14).margin({ top: 12 });
          Button('重试').type(ButtonType.Capsule).margin({ top: 16 })
            .onClick(() => this.loadData());
        }
      }
    }
    .width('100%').height('100%')
  }

  // ==================== 设备备注（只存本机） ====================

  /** 读本机备注。异步读完换成新对象，触发列表重绘 */
  private async loadNotes(): Promise<void> {
    try {
      const ctx: common.Context | null = GlobalContext.getInstance().getContext();
      if (!ctx) {
        return;
      }
      await this.notesStore.init(ctx);
      this.notes = this.notesStore.snapshot();
    } catch (e) {
      console.warn('[Devices] 读取设备备注失败: ' + JSON.stringify(e));
    }
  }

  /** 一台设备的备注，没设过是空串 */
  private noteOf(mac: string): string {
    const v: string | undefined = this.notes[mac.toLowerCase()];
    return v === undefined ? '' : v;
  }

  /** 弹出备注编辑框（每台设备现建一个 controller，绑上它的名字 / IP / MAC） */
  private openNoteDialog(device: DhcpLease): void {
    const mac: string = device.mac.toLowerCase();
    this.noteDialog = new CustomDialogController({
      builder: DeviceNoteDialog({
        deviceName: device.hostname.length > 0 ? device.hostname : '(未命名设备)',
        deviceInfo: device.ip + ' · ' + device.mac,
        initialNote: this.noteOf(mac),
        onSave: (note: string) => {
          this.saveNote(mac, note);
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.noteDialog.open();
  }

  /** 存备注（空串 = 清除） */
  private async saveNote(mac: string, note: string): Promise<void> {
    const ok: boolean = await this.notesStore.set(mac, note);
    this.notes = this.notesStore.snapshot();
    promptAction.showToast({
      message: ok ? (note.trim().length > 0 ? '备注已保存' : '备注已清除') : '备注保存失败',
      duration: 1500
    });
  }

  // ==================== 数据加载 ====================

  /**
   * 加载 DHCP 租约 —— 本页唯一的取数入口（刷新规范见 common/RefreshPolicy.ets）。
   * kind 决定 Loading 与失败反馈：'first' 首屏 / 'pull' 下拉刷新。
   */
  private async loadData(kind: LoadKind = 'first'): Promise<void> {
    if (kind === 'first') {
      this.isLoading = true;
    }

    try {
      if (!this.client.isLoggedIn()) {
        this.failLoad('未登录', kind);
        return;
      }

      const result = await this.client.getDhcpLeases();
      if (result.success && result.data) {
        this.devices = result.data;
        const now: number = Math.floor(Date.now() / 1000);
        this.activeCount = result.data.filter((d: DhcpLease) => d.end > now).length;
        // 成功就清掉错误页：停在错误页时，一次下拉刷新也能把它救回来
        this.hasError = false;
      } else {
        this.failLoad(result.error || '获取租约数据失败', kind);
      }
    } catch (e) {
      this.failLoad('请求异常: ' + JSON.stringify(e), kind);
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
    }
  }

  /**
   * 统一的失败处理，三档反馈（规范见 common/RefreshPolicy.ets）：
   * 首屏失败 → 错误页；下拉刷新失败 → 保留已有数据 + 提示；静默刷新失败 → 只写日志。
   */
  private failLoad(msg: string, kind: LoadKind): void {
    console.error('[Devices] ' + msg);
    if (shouldShowErrorPage(kind)) {
      this.hasError = true;
      this.errorMsg = msg;
    } else if (shouldToast(kind)) {
      notifyLoadFailed(msg);
    }
  }

  /** 下拉刷新的统一入口：挂给 Refresh 的 onRefreshing */
  private onPullRefresh(): void {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    this.loadData('pull');
  }

  private isLeaseActive(device: DhcpLease): boolean {
    const now: number = Math.floor(Date.now() / 1000);
    return device.end > now;
  }

  private formatExpiry(endTimestamp: number): string {
    const now: number = Math.floor(Date.now() / 1000);
    const remaining: number = endTimestamp - now;
    if (remaining <= 0) return '已过期';
    const hours: number = Math.floor(remaining / 3600);
    const mins: number = Math.floor((remaining % 3600) / 60);
    if (hours > 24) return `${Math.floor(hours / 24)}天后过期`;
    if (hours > 0) return `${hours}小时${mins}分后过期`;
    return `${mins}分后过期`;
  }

  private getInitial(hostname: string): string {
    if (!hostname) return '?';
    return hostname.charAt(0).toUpperCase();
  }

  private getDeviceColor(hostname: string): ResourceColor {
    const colors: ResourceColor[] = ['#4A90D9', '#7B61FF', '#E8725A', '#50B87A', '#D9A845', '#5AB0D9', '#D96BA5', '#6BC9B0'];
    if (!hostname) return colors[0];
    let hash: number = 0;
    for (let i = 0; i < hostname.length; i++) {
      hash = hostname.charCodeAt(i) + ((hash << 5) - hash);
    }
    const idx: number = Math.abs(hash) % colors.length;
    return colors[idx];
  }
}

/**
 * 备注编辑对话框。
 *
 * 为什么用对话框而不是卡片内联编辑：在线设备是二级页面，列表在滚动容器里，
 * 内联输入框会被键盘顶来顶去；系统的对话框会自动避让键盘。
 * 只在 DevicesPage 里用，所以直接放同一个文件。
 */
@CustomDialog
struct DeviceNoteDialog {
  controller?: CustomDialogController;
  deviceName: string = '';
  deviceInfo: string = '';
  initialNote: string = '';
  onSave: (note: string) => void = () => {};

  @State private text: string = '';

  aboutToAppear(): void {
    this.text = this.initialNote;
  }

  build() {
    Column() {
      Text('设备备注')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1).width('100%');
      Text(this.deviceName)
        .fontSize(14).fontColor(C_TEXT_2).width('100%').margin({ top: 6 })
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
      Text(this.deviceInfo)
        .fontSize(12).fontColor(C_TEXT_3).width('100%').margin({ top: 2 })
        .fontFamily('monospace');

      TextInput({ text: this.text, placeholder: '如：客厅电视（留空 = 清除备注）' })
        .width('100%')
        .fontSize(14)
        .margin({ top: 14 })
        .onChange((v: string) => { this.text = v; });

      Row() {
        Button('取消')
          .fontSize(14).height(36).type(ButtonType.Capsule)
          .backgroundColor(C_FILL).fontColor(C_TEXT_2)
          .layoutWeight(1)
          .onClick(() => { this.controller?.close(); });
        Button('保存')
          .fontSize(14).height(36).type(ButtonType.Capsule)
          .backgroundColor(C_PRIMARY).fontColor(Color.White)
          .layoutWeight(1).margin({ left: 10 })
          .onClick(() => {
            this.onSave(this.text);
            this.controller?.close();
          });
      }
      .width('100%').margin({ top: 16 });
    }
    .width('100%')
    .padding(20)
    .backgroundColor(C_CARD_SOLID)
    .borderRadius(20);
  }
}
