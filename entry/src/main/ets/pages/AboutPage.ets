/**
 * 「关于」二级页面（从主页右上角的 ⓘ 进入）
 *
 * 三块内容：
 *   1. 版本信息（读 bundleManager，拿真实的 versionName / versionCode）
 *   2. 联系方式（GitHub 仓库 / Issues，点了用系统浏览器打开）
 *   3. 检查更新：调 GitHub Releases API，**只负责告诉用户有没有新版本**；
 *      要不要下载由用户点确认框决定 —— 确认后**跳系统浏览器**下载（App 自己不落盘、不安装）。
 *
 * 为什么不在 App 里下载/安装：
 *   · 需求就是这样：先问用户，确认后交给浏览器，省得 App 里堆安装包、也省得用户在两处找文件；
 *   · 鸿蒙普通应用本来也没有静默安装权限（`bundle.installer` 是系统 API + `INSTALL_BUNDLE` 权限），
 *     而且仓库里的 HAP 是**未签名**的 —— 真机得自己签名后再构建，模拟器才能直接装。
 */

import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { GlobalContext } from '../model/GlobalContext';
import { SpeedTestHistory } from '../model/SpeedTestHistory';
import {
  UpdateChecker, ReleaseInfo,
  REPO_URL, REPO_ISSUES_URL, REPO_RELEASES_URL
} from '../model/UpdateChecker';
import {
  C_PRIMARY, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_FILL,
  F_SECTION, F_BODY, F_CAPTION, F_TINY, R_CARD, SP_S, SP_M, SP_L, SP_XL, ICON_M, colorString
} from '../common/Theme';

@Component
export struct AboutPage {
  @State private appVersion: string = '--';
  @State private appVersionCode: number = 0;
  @State private bundleName: string = '--';

  /** 检查中 */
  @State private checking: boolean = false;
  /** 状态说明文字（已是最新 / 发现新版本 / 检查失败…） */
  @State private statusText: string = '';
  /** 有没有更新 */
  @State private hasUpdate: boolean = false;
  /** 最新版本信息 */
  @State private release: ReleaseInfo | null = null;
  @State private junkCount: number = 0;
  @State private cleaningJunk: boolean = false;

  private checker: UpdateChecker = new UpdateChecker();

  aboutToAppear(): void {
    this.loadAppInfo();
    this.loadJunkInfo();
  }

  build() {
    Scroll() {
      Column() {
        // ===== 应用信息 =====
        Column() {
          Row() {
            Image($r('app.media.layered_image'))
              .width(56).height(56).borderRadius(14);
            Column() {
              Text('OpenWrt 管理')
                .fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
              Text('版本 ' + this.appVersion + '（' + String(this.appVersionCode) + '）')
                .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 3 });
              Text(this.bundleName)
                .fontSize(F_TINY).fontColor(C_TEXT_3)
                .fontFamily('monospace').margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: SP_M });
          }
          .width('100%').alignItems(VerticalAlign.Center);

          Text('用 HarmonyOS（ArkTS + ArkUI）写的 OpenWrt 路由器管理客户端，直接调路由器自带的 ubus JSON-RPC，不需要装 luci-mod-rpc。')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ top: SP_M });
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 清理垃圾 =====
        Column() {
          Row() {
            Column() {
              Text('清理垃圾').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
              Text(this.junkCount > 0
                ? ('测速缓存 · ' + String(this.junkCount) + ' 条记录')
                : '暂时没有可清理的缓存')
                .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 4 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            Button(this.cleaningJunk ? '清理中…' : '清理垃圾')
              .fontSize(F_CAPTION).height(32).type(ButtonType.Capsule)
              .backgroundColor(this.junkCount > 0 ? C_PRIMARY : C_FILL)
              .fontColor(this.junkCount > 0 ? Color.White : C_TEXT_3)
              .enabled(!this.cleaningJunk && this.junkCount > 0)
              .onClick(() => this.confirmCleanJunk());
          }
          .width('100%').alignItems(VerticalAlign.Center);
          Text('只清理本应用生成的测速缓存，不会删除登录信息、设备备注或路由器数据。')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ top: SP_M });
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 联系方式 =====
        Column() {
          Text('联系方式').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
            .width('100%').margin({ bottom: SP_S });

          this.linkRow('GitHub', '@abookkkk', REPO_URL);
          this.linkRow('项目仓库', 'abookkkk/WRT', REPO_URL);
          this.linkRow('问题反馈', 'Issues · 提 bug / 建议', REPO_ISSUES_URL);
          this.linkRow('版本发布', 'Releases · 历史版本与更新日志', REPO_RELEASES_URL);
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 检查更新 =====
        Column() {
          Row() {
            Column() {
              Text('检查更新').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
              Text('从 GitHub Releases 取最新版本')
                .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 3 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);

            Button(this.checking ? '检查中…' : '检查更新')
              .fontSize(F_CAPTION).height(32).type(ButtonType.Capsule)
              .backgroundColor(C_PRIMARY)
              .enabled(!this.checking)
              .onClick(() => this.checkUpdate());
          }
          .width('100%').alignItems(VerticalAlign.Center);

          if (this.statusText.length > 0) {
            Text(this.statusText)
              .fontSize(F_CAPTION)
              .fontColor(this.hasUpdate ? C_WARNING : C_TEXT_2)
              .width('100%').lineHeight(18).margin({ top: SP_M });
          }

          // 有新版：显示最新版本 + 更新日志，下载交给浏览器
          if (this.release !== null && this.hasUpdate) {
            Text('最新版本 ' + this.release.tag + (this.release.hapSize > 0 ? (' · ' + this.formatSize(this.release.hapSize)) : ''))
              .fontSize(F_CAPTION).fontColor(C_TEXT_2).width('100%').margin({ top: SP_M });
            if (this.release.notes.length > 0) {
              Text(this.release.notes)
                .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16)
                .maxLines(12).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: SP_S });
            }
            Row() {
              Button('去浏览器下载')
                .fontSize(F_CAPTION).height(32).type(ButtonType.Capsule)
                .backgroundColor(C_PRIMARY)
                .onClick(() => this.downloadInBrowser());
              Button('打开发布页')
                .fontSize(F_CAPTION).height(32).type(ButtonType.Capsule)
                .backgroundColor(C_FILL).fontColor(C_TEXT_2)
                .margin({ left: SP_S })
                .onClick(() => this.openUrl(REPO_RELEASES_URL));
            }
            .width('100%').margin({ top: SP_M });
          } else {
            // 没查出更新（或检查失败）时，给一条手动通道
            Button('打开发布页手动看看')
              .fontSize(F_CAPTION).height(30).type(ButtonType.Capsule)
              .backgroundColor(C_FILL).fontColor(C_TEXT_2)
              .margin({ top: SP_M })
              .onClick(() => this.openUrl(REPO_RELEASES_URL));
          }
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 说明 =====
        Column() {
          Text('说明').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
            .width('100%').margin({ bottom: SP_S });
          Text('· 检查更新用的是 GitHub 公开 API（不需要 token）；被限流时会退到 releases.atom 拿版本号，界面会说明')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· **不会自动下载**：确认后由系统浏览器下载，装不装、什么时候装都由你决定')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· Releases 里的 HAP 是未签名的：**模拟器可以直接装**，真机要用 DevEco 配置自动签名后重新构建才装得上')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· 鸿蒙普通应用没有静默安装权限（bundle.installer 是系统 API），所以由你手动安装')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16);
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM);
      }
      .width('100%').padding(SP_L)
    }
    .width('100%').height('100%')
    .edgeEffect(EdgeEffect.Spring);
  }

  /** 一行「标题 / 副标题 —— 右箭头」，点了用系统浏览器打开 */
  @Builder
  linkRow(title: string, subtitle: string, url: string) {
    Row() {
      Column() {
        Text(title).fontSize(F_BODY).fontColor(C_TEXT_1);
        Text(subtitle).fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 2 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1);

      SymbolGlyph($r('sys.symbol.arrow_up_right'))
        .fontSize(ICON_M)
        .fontColor([C_TEXT_3])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE);
    }
    .width('100%')
    .padding({ top: SP_M, bottom: SP_M })
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.openUrl(url));
  }

  // ==================== 逻辑 ====================

  private loadAppInfo(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
      this.appVersionCode = info.versionCode;
      this.bundleName = info.name;
    } catch (e) {
      console.error('[About] 读版本信息失败: ' + JSON.stringify(e));
    }
  }

  private async loadJunkInfo(): Promise<void> {
    try {
      const context: common.Context | null = GlobalContext.getInstance().getContext();
      if (context === null) return;
      const history: SpeedTestHistory = new SpeedTestHistory();
      await history.init(context);
      this.junkCount = history.snapshot().length;
    } catch (e) {
      console.warn('[About] 读取可清理缓存失败: ' + JSON.stringify(e));
    }
  }

  private async confirmCleanJunk(): Promise<void> {
    const result = await promptAction.showDialog({
      title: '清理垃圾',
      message: '将清除本机保存的测速历史记录，共 ' + String(this.junkCount) + ' 条。登录信息和设备备注不会受影响。',
      buttons: [
        { text: '取消', color: colorString(C_TEXT_2, '#666666') },
        { text: '清理', color: colorString(C_PRIMARY, '#0A59F7') }
      ]
    });
    if (result.index !== 1) return;
    this.cleaningJunk = true;
    try {
      const context: common.Context | null = GlobalContext.getInstance().getContext();
      if (context === null) return;
      const history: SpeedTestHistory = new SpeedTestHistory();
      await history.init(context);
      const ok: boolean = await history.clearAll();
      if (ok) {
        this.junkCount = 0;
        promptAction.showToast({ message: '垃圾清理完成', duration: 1600 });
      } else {
        promptAction.showToast({ message: '清理失败，请稍后重试', duration: 1800 });
      }
    } catch (e) {
      promptAction.showToast({ message: '清理失败，请稍后重试', duration: 1800 });
      console.error('[About] 清理垃圾失败: ' + JSON.stringify(e));
    } finally {
      this.cleaningJunk = false;
    }
  }

  /** 检查更新：只比对版本 + 问用户，绝不自动下载 */
  private async checkUpdate(): Promise<void> {
    this.checking = true;
    this.statusText = '正在检查…';
    this.hasUpdate = false;
    this.release = null;

    try {
      const ri: ReleaseInfo | null = await this.checker.fetchLatest();
      if (ri === null) {
        this.statusText = this.checker.lastError.length > 0
          ? ('检查失败：' + this.checker.lastError + '（releases.atom 兜底也没成功）')
          : '检查失败：拉不到 release（没网 / 被限流 / 仓库还没发过 release）';
        return;
      }
      const cmp: number = UpdateChecker.compareVersion(ri.version, this.appVersion);
      this.release = ri;
      if (cmp <= 0) {
        this.statusText = '已是最新版本（远端 ' + ri.tag + '）';
        return;
      }
      this.hasUpdate = true;
      this.statusText = '发现新版本 ' + ri.tag + '（当前 ' + this.appVersion + '）'
        + (ri.viaAtom ? '［API 限流，版本号来自 releases.atom］' : '');
      await this.askDownload(ri);
    } catch (e) {
      this.statusText = '检查异常: ' + JSON.stringify(e);
    } finally {
      this.checking = false;
    }
  }

  /** 先问用户要不要下载；点「去浏览器下载」才跳浏览器 */
  private async askDownload(ri: ReleaseInfo): Promise<void> {
    try {
      const res = await promptAction.showDialog({
        title: '发现新版本 ' + ri.tag,
        message: '当前版本 ' + this.appVersion + '。\n\n要去浏览器下载新版安装包吗？\n（本应用不保存安装包，也不自动安装）',
        buttons: [
          { text: '稍后', color: colorString(C_TEXT_2, '#666666') },
          { text: '去浏览器下载', color: colorString(C_PRIMARY, '#0A59F7') }
        ]
      });
      if (res.index === 1) {
        this.downloadInBrowser();
      }
    } catch (e) {
      console.error('[About] 弹确认框失败: ' + JSON.stringify(e));
    }
  }

  /** 跳系统浏览器下载：优先直接开安装包地址，退而求其次开 release 页面 */
  private downloadInBrowser(): void {
    const ri: ReleaseInfo | null = this.release;
    if (ri === null) {
      this.openUrl(REPO_RELEASES_URL);
      return;
    }
    this.openUrl(ri.hapUrl.length > 0 ? ri.hapUrl : ri.pageUrl);
  }

  private async openUrl(url: string): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      await ctx.startAbility(want);
    } catch (e) {
      promptAction.showToast({ message: '打不开链接: ' + JSON.stringify(e), duration: 2500 });
      console.error('[About] 打开链接失败: ' + JSON.stringify(e));
    }
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) {
      return String(bytes) + ' B';
    }
    if (bytes < 1048576) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return (bytes / 1048576).toFixed(2) + ' MB';
  }
}
