/**
 * 外观（主题模式）设置：跟随系统 / 强制浅色 / 强制深色
 *
 * 实现要点：
 *   1. 应用侧用 `ApplicationContext.setColorMode()` 控制，`COLOR_MODE_NOT_SET` 即跟随系统；
 *   2. 颜色本身都在 `resources/base|dark/element/color.json` 里，setColorMode 之后
 *      系统会按新色彩模式重新解析资源，界面自动刷新，不需要手动重建组件；
 *   3. 沉浸式布局下状态栏/导航栏的文字图标颜色**不会**自动跟着应用模式走
 *      （它跟的是系统模式），强制深色时必须主动把系统栏内容色改成浅色，
 *      否则黑色图标压在深色背景上会看不见。
 */

import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/** 外观模式：跟随系统 / 浅色 / 深色 */
export type AppearanceMode = 'system' | 'light' | 'dark';

const STORE_NAME: string = 'openwrt_settings';
const KEY_MODE: string = 'appearance_mode';

export class ThemeSettings {
  /** 同步读取已保存的外观模式（读不到或出错都退回跟随系统） */
  static load(context: common.Context): AppearanceMode {
    try {
      const pref: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
      const value: string = String(pref.getSync(KEY_MODE, 'system'));
      if (value === 'light') {
        return 'light';
      }
      if (value === 'dark') {
        return 'dark';
      }
      return 'system';
    } catch (e) {
      console.warn('[ThemeSettings] 读取外观设置失败: ' + JSON.stringify(e));
      return 'system';
    }
  }

  /** 保存（异步刷盘，失败只记日志，不影响本次切换） */
  static save(context: common.Context, mode: AppearanceMode): void {
    try {
      const pref: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
      pref.putSync(KEY_MODE, mode);
      pref.flush();
      console.info('[ThemeSettings] 外观模式已保存: ' + mode);
    } catch (e) {
      console.error('[ThemeSettings] 保存外观设置失败: ' + JSON.stringify(e));
    }
  }

  /** 应用外观模式：设置色彩模式 + 同步系统栏图标颜色 */
  static apply(context: common.Context, mode: AppearanceMode): void {
    try {
      context.getApplicationContext().setColorMode(ThemeSettings.toColorMode(mode));
      console.info('[ThemeSettings] 已应用外观模式: ' + mode);
    } catch (e) {
      console.error('[ThemeSettings] setColorMode 失败: ' + JSON.stringify(e));
    }
    ThemeSettings.refreshSystemBar(context, mode);
  }

  /**
   * 当前实际是不是深色。
   *
   * 强制模式直接按参数判断（避免 setColorMode 还没生效时读错）；
   * 跟随系统时用一个取巧但可靠的办法：拿背景色资源的**实际解析结果**反推，
   * 浅色背景 #EAF1FF 很亮、深色背景 #10141C 很暗，按亮度判断即可。
   * （resourceManager 的 Configuration 类型上没有暴露 colorMode，所以不查配置。）
   */
  static isDark(context: common.Context, mode: AppearanceMode): boolean {
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    try {
      const rid: number = $r('app.color.c_bg_top').id ?? 0;
      if (rid === 0) {
        return false;
      }
      const value: number = context.resourceManager.getColorSync(rid);
      const r: number = (value >> 16) & 0xFF;
      const g: number = (value >> 8) & 0xFF;
      const b: number = value & 0xFF;
      return (r * 0.299 + g * 0.587 + b * 0.114) < 128;
    } catch (e) {
      return false;
    }
  }

  /**
   * 只同步系统栏图标颜色，不动色彩模式。
   * 系统深浅色变化（onConfigurationUpdate）时调用，避免和 setColorMode 互相触发。
   */
  static refreshSystemBar(context: common.Context, mode: AppearanceMode): void {
    const contentColor: string = ThemeSettings.isDark(context, mode) ? '#E5FFFFFF' : '#E5000000';
    window.getLastWindow(context).then((win: window.Window) => {
      win.setWindowSystemBarProperties({
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
    }).catch((err: Object) => {
      console.warn('[ThemeSettings] 设置系统栏配色失败: ' + JSON.stringify(err));
    });
  }

  private static toColorMode(mode: AppearanceMode): ConfigurationConstant.ColorMode {
    if (mode === 'dark') {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (mode === 'light') {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }
}
