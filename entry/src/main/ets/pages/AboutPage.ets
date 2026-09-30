/**
 * 「关于」二级页面（从主页右上角的 ⓘ 进入）
 *
 * 三块内容：
 *   1. 版本信息（读 bundleManager，拿真实的 versionName / versionCode）
 *   2. 联系方式（GitHub 仓库 / Issues，点了用系统浏览器打开）
 *   3. 检查更新：调 GitHub Releases API；**发现新版本会自动下载** HAP 到应用目录，
 *      再提供「另存为」用系统文件选择器导出（方便用 hdc / 文件管理安装）。
 *
 * ⚠️ 不能自动安装：普通应用没有静默安装权限（`bundle.installer` 是系统 API + `INSTALL_BUNDLE` 权限），
 * 而且仓库里的 HAP 是**未签名**的 —— 真机得自己签名后才装得上，模拟器可以直接装。
 * 页面里把这两条都写明了，不糊弄用户。
 */

import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import {
  UpdateChecker, ReleaseInfo,
  REPO_URL, REPO_ISSUES_URL, REPO_RELEASES_URL
} from '../model/UpdateChecker';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_FILL, C_DIVIDER,
  F_SECTION, F_BODY, F_CAPTION, F_TINY, R_CARD, SP_S, SP_M, SP_L, SP_XL, ICON_M
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

  /** 下载中 / 进度 0~1 / 下载好的本地路径 */
  @State private downloading: boolean = false;
  @State private progress: number = 0;
  @State private savedPath: string = '';
  @State private saving: boolean = false;

  private checker: UpdateChecker = new UpdateChecker();

  aboutToAppear(): void {
    this.loadAppInfo();
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
              .enabled(!this.checking && !this.downloading)
              .onClick(() => this.checkUpdate());
          }
          .width('100%').alignItems(VerticalAlign.Center);

          if (this.statusText.length > 0) {
            Text(this.statusText)
              .fontSize(F_CAPTION)
              .fontColor(this.hasUpdate ? C_WARNING : C_TEXT_2)
              .width('100%').lineHeight(18).margin({ top: SP_M });
          }

          // 没检查出更新（或检查失败）时，给一条手动通道
          if (!this.hasUpdate && !this.downloading && this.savedPath.length === 0) {
            Button('打开发布页手动看看')
              .fontSize(F_CAPTION).height(30).type(ButtonType.Capsule)
              .backgroundColor(C_FILL).fontColor(C_TEXT_2)
              .margin({ top: SP_M })
              .onClick(() => this.openUrl(REPO_RELEASES_URL));
          }

          // 有新版：显示版本号 + 更新日志 + 下载进度
          if (this.release !== null && this.hasUpdate && !this.downloading && this.savedPath.length === 0) {
            Text('最新版本 ' + this.release.tag + (this.release.hapSize > 0 ? (' · ' + this.formatSize(this.release.hapSize)) : ''))
              .fontSize(F_CAPTION).fontColor(C_TEXT_2).width('100%').margin({ top: SP_M });
            if (this.release.notes.length > 0) {
              Text(this.release.notes)
                .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16)
                .maxLines(12).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: SP_S });
            }
          }

          if (this.downloading) {
            Text('正在下载更新包… ' + Math.round(this.progress * 100) + '%')
              .fontSize(F_CAPTION).fontColor(C_TEXT_2).width('100%').margin({ top: SP_M });
            Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
              .width('100%').height(8).borderRadius(4)
              .color(C_PRIMARY).margin({ top: SP_S });
          }

          if (this.savedPath.length > 0) {
            Text('已下载到应用目录')
              .fontSize(F_CAPTION).fontColor(C_SUCCESS).width('100%').margin({ top: SP_M });
            Text(this.savedPath)
              .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%')
              .fontFamily('monospace').lineHeight(15).margin({ top: 2 });
            Row() {
              Button(this.saving ? '导出中…' : '另存为…')
                .fontSize(F_CAPTION).height(32).type(ButtonType.Capsule)
                .backgroundColor(C_PRIMARY)
                .enabled(!this.saving)
                .onClick(() => this.exportHap());
              Button('打开发布页')
                .fontSize(F_CAPTION).height(32).type(ButtonType.Capsule)
                .backgroundColor(C_FILL).fontColor(C_TEXT_2)
                .margin({ left: SP_S })
                .onClick(() => this.openUrl(REPO_RELEASES_URL));
            }
            .width('100%').margin({ top: SP_M });
          }
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 说明 =====
        Column() {
          Text('说明').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
            .width('100%').margin({ bottom: SP_S });
          Text('· 更新包来自 GitHub 上你这个仓库的 Releases，检查更新用的是公开 API（不需要 token）')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· Releases 里的 HAP 是未签名的：**模拟器可以直接装**，真机要用 DevEco 配置自动签名后重新构建才装得上')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· 鸿蒙普通应用没有静默安装权限（bundle.installer 是系统 API），所以只能下到本机再导出安装')
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

  /** 检查更新：有新版本就自动开始下载（用户要的就是这个） */
  private async checkUpdate(): Promise<void> {
    this.checking = true;
    this.statusText = '正在检查…';
    this.hasUpdate = false;
    this.release = null;
    this.savedPath = '';
    this.progress = 0;

    try {
      const ri: ReleaseInfo | null = await this.checker.fetchLatest();
      if (ri === null) {
        this.statusText = this.checker.lastError.length > 0
          ? ('检查失败：' + this.checker.lastError)
          : '检查失败：拉不到 release（没网 / 被限流 / 仓库还没发过 release）';
        return;
      }
      const cmp: number = UpdateChecker.compareVersion(ri.version, this.appVersion);
      if (cmp <= 0) {
        this.statusText = '已是最新版本（远端 ' + ri.tag + '）';
        this.release = ri;
        return;
      }
      this.release = ri;
      this.hasUpdate = true;
      this.statusText = '发现新版本 ' + ri.tag + '（当前 ' + this.appVersion + '），开始自动下载…';
      await this.startDownload(ri);
    } catch (e) {
      this.statusText = '检查异常: ' + JSON.stringify(e);
    } finally {
      this.checking = false;
    }
  }

  private async startDownload(ri: ReleaseInfo): Promise<void> {
    const ctx: common.Context | null = this.getCtx();
    if (ctx === null) {
      this.statusText = '拿不到应用上下文，无法下载';
      return;
    }
    this.downloading = true;
    this.progress = 0;
    try {
      const dir: string = ctx.filesDir + '/updates';
      const path: string = await this.checker.downloadHap(ri, dir, (received: number, total: number) => {
        this.progress = total > 0 ? Math.min(1, received / total) : 0;
      });
      if (path.length > 0) {
        this.savedPath = path;
        this.statusText = '新版本 ' + ri.tag + ' 已下载完成';
      } else {
        this.statusText = '下载失败（可以点「打开发布页」手动下载）';
      }
    } catch (e) {
      this.statusText = '下载异常: ' + JSON.stringify(e);
    } finally {
      this.downloading = false;
    }
  }

  /** 用系统文件选择器导出（保存到「下载」等位置，方便 hdc / 文件管理安装） */
  private async exportHap(): Promise<void> {
    if (this.savedPath.length === 0) {
      return;
    }
    this.saving = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const opt: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opt.newFileNames = [this.hapFileName()];
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await p.save(opt);
      if (uris.length === 0) {
        return;
      }
      fs.copyFileSync(this.savedPath, uris[0]);
      promptAction.showToast({ message: '已导出，去「文件管理」里安装吧', duration: 2500 });
    } catch (e) {
      promptAction.showToast({ message: '导出失败: ' + JSON.stringify(e), duration: 2500 });
      console.error('[About] 导出失败: ' + JSON.stringify(e));
    } finally {
      this.saving = false;
    }
  }

  private hapFileName(): string {
    const idx: number = this.savedPath.lastIndexOf('/');
    return idx >= 0 ? this.savedPath.substring(idx + 1) : this.savedPath;
  }

  private getCtx(): common.Context | null {
    try {
      return getContext(this) as common.Context;
    } catch (e) {
      console.error('[About] 取 context 失败: ' + JSON.stringify(e));
      return null;
    }
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