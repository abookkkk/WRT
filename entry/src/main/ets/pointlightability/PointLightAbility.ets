/**
 * 点光源演示 Ability —— 只为运行 `pages/PointLightDemoPage` 而存在。
 *
 * 为什么单独做一个 Ability：这样演示代码完全不碰现有业务（EntryAbility / Index /
 * HomePage 一行都不改），既能在模拟器上直接起：
 *   hdc shell aa start -a PointLightAbility -b com.abookkkk.wrt
 * 也能在 DevEco 的「运行配置」里选这个 Ability 跑。不需要了直接删掉本文件 +
 * module.json5 里那条 ability + main_pages.json 里那行即可。
 */

import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

export default class PointLightAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/PointLightDemoPage', (err) => {
      // ⚠️ 注意判空方式：成功时回调也会给一个 `{ code: 0 }` 的对象，
      // 直接 `if (err)` 会把成功当失败打日志（实测踩过）
      if (err && err.code) {
        hilog.error(DOMAIN, 'PointLightDemo', '加载演示页失败: %{public}s', JSON.stringify(err));
        return;
      }
      // 全屏 + 透明系统栏：演示页想要"整块深色"的观感（与主 App 的做法一致，
      // 时序也一样 —— 必须等 loadContent 回调里再设，否则抛 1300002）
      try {
        const win: window.Window = windowStage.getMainWindowSync();
        win.setWindowLayoutFullScreen(true);
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#E5FFFFFF',
          navigationBarContentColor: '#E5FFFFFF'
        });
      } catch (e) {
        hilog.error(DOMAIN, 'PointLightDemo', '窗口配置失败: %{public}s', JSON.stringify(e));
      }
      hilog.info(DOMAIN, 'PointLightDemo', '点光源演示页已加载');
    });
  }
}