/**
 * EntryAbility — 应用入口
 * 
 * 职责：
 * 1. 初始化全局上下文（供 SessionStore 使用）
 * 2. 设置窗口属性
 * 3. 加载主页面 Index.ets
 */

import { AbilityConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { GlobalContext } from '../model/GlobalContext';
import { ThemeSettings, AppearanceMode } from '../model/ThemeSettings';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 保存全局上下文，供 SessionStore 等使用
    GlobalContext.getInstance().setContext(this.context);
    // 应用上次选择的外观模式（跟随系统 / 浅色 / 深色）。
    // 必须赶在加载页面之前设好，否则会先按系统模式渲染一帧再跳成用户选的那套。
    const mode: AppearanceMode = ThemeSettings.load(this.context);
    ThemeSettings.apply(this.context, mode);
    hilog.info(DOMAIN, 'OpenWrtApp', 'EntryAbility onCreate, appearance=%{public}s', mode);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色变化时回调。跟随系统模式下状态栏/导航栏的图标颜色要重新同步
    // （这里只改系统栏配色、不再调 setColorMode，避免和系统配置回调互相触发）。
    const mode: AppearanceMode = ThemeSettings.load(this.context);
    ThemeSettings.refreshSystemBar(this.context, mode);
    hilog.info(DOMAIN, 'OpenWrtApp', 'onConfigurationUpdate, appearance=%{public}s', mode);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'onWindowStageCreate');

    // ⚠️ 全屏布局 + 系统栏配置必须等**内容加载完**再做（实测时序很关键）：
    // 在 onCreate 里、或 loadContent 之前调用，两个 set 都会抛 1300002（窗口状态异常），
    // 全屏就不生效 —— 页面内容仍被安全区挡在状态栏之外，看起来「改了跟没改一样」。
    windowStage.loadContent('pages/Index', (err) => {
      if (err) {
        hilog.error(DOMAIN, 'OpenWrtApp', '加载首页失败: %{public}s', JSON.stringify(err));
      }
      try {
        ThemeSettings.setupWindow(windowStage.getMainWindowSync(), this.context, ThemeSettings.load(this.context));
        hilog.info(DOMAIN, 'OpenWrtApp', '已应用全屏布局 + 系统栏配色');
      } catch (e) {
        hilog.error(DOMAIN, 'OpenWrtApp', '应用窗口配置失败: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'onBackground');
  }
}
