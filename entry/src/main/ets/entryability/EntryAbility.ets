/**
 * EntryAbility — 应用入口
 * 
 * 职责：
 * 1. 初始化全局上下文（供 SessionStore 使用）
 * 2. 设置窗口属性
 * 3. 加载主页面 Index.ets
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { GlobalContext } from '../model/GlobalContext';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 保存全局上下文，供 SessionStore 等使用
    GlobalContext.getInstance().setContext(this.context);
    hilog.info(DOMAIN, 'OpenWrtApp', 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'OpenWrtApp', 'onWindowStageCreate');

    // 设置窗口布局
    windowStage.loadContent('pages/Index', (err) => {
      if (err) {
        hilog.error(DOMAIN, 'OpenWrtApp', '加载首页失败: %{public}s', JSON.stringify(err));
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
