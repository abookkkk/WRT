/**
 * 按压发光（HDS 点光源 `hdsEffect.pointLight`）—— 给**现有**组件追加"按下时表面被照亮"的效果。
 *
 * 设计原则（对应需求约束）：只**追加** `.visualEffect()` + 一个按压状态 + `.animation()`，
 * 不改组件原有的颜色 / 尺寸 / 圆角 / 阴影 / 布局，也不碰任何业务逻辑。
 *
 * 用法（三步）：
 *   import { PressGlow } from '../common/PressGlow';
 *
 *   @State private cardPressed: boolean = false;                 // 1) 一个按压状态
 *   ...
 *   Column() { ... }
 *     .visualEffect(PressGlow.effect(this.cardPressed))           // 2) 光照
 *     .onTouch((e: TouchEvent) => PressGlow.track(e, (p: boolean) => { this.cardPressed = p; }))
 *     .animation(PressGlow.ANIM)                                  // 3) 300ms 平滑过渡
 *
 * ⚠️ 三条实测结论（模拟器 6.1.0.126 / x86_64）：
 *   1. `sourceType` 默认是 `NONE`（= 不发光），必须显式给 `SOFT` / `BRIGHT` —— 这里给 `SOFT`；
 *   2. 点光源要"浅色组件表面 + 深色环境背景"才看得见：卡片在**浅色模式**下最明显，
 *      深色模式下卡片本身是深色半透明的，光感会弱很多（这是组件原有配色，按约束不去改）；
 *   3. 该模拟器**不支持点光源渲染**（日志里是 `PointLightUnsupportedHandler`），表面不会变化，
 *      光影要在支持 HDS 点光源的真机上才看得到；这里不改变任何原有外观，所以模拟器上
 *      观感与改动前完全一致。
 *
 * 不想要这个效果时：把 `PressGlow.enabled` 置成 `false` 即可（一行，所有调用点一起失效）。
 */

import { hdsEffect } from '@kit.UIDesignKit';

/** 按压时的光照强度（0~5，越大越亮） */
const PRESSED_INTENSITY: number = 3.0;
/** 光源高度（vp）：越小光斑越集中 */
const LIGHT_HEIGHT: number = 120;

export class PressGlow {
  /** 总开关：置 false 后所有调用点都退化成"没有光照"，业务不受影响 */
  static enabled: boolean = true;

  /** 光照过渡动画（需求：300ms + Curve.Smooth） */
  static readonly ANIM: AnimateParam = { duration: 300, curve: Curve.Smooth };

  /**
   * 按压状态 → `VisualEffect`。
   *
   * @param pressed   当前是否被按住
   * @param intensity 按住时的强度（默认 3.0）
   */
  static effect(pressed: boolean, intensity: number = PRESSED_INTENSITY): VisualEffect {
    if (!PressGlow.enabled) {
      // 关掉时返回一个"无光源"效果：组件外观与改动前完全一致
      return new hdsEffect.HdsEffectBuilder()
        .pointLight({ sourceType: hdsEffect.PointLightSourceType.NONE })
        .buildEffect();
    }
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        // ⚠️ 默认 NONE = 不发光，必须显式指定
        sourceType: hdsEffect.PointLightSourceType.SOFT,
        // 需求约束：用 BORDER_CONTENT 拿到最完整的光影层次（边缘 + 内容）
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
        options: {
          color: Color.White,
          intensity: pressed ? intensity : 0,
          height: LIGHT_HEIGHT
        }
      })
      .buildEffect();
  }

  /**
   * 统一的按压跟踪：Down → true，Up / Cancel → false。
   * 各页面不用各写一遍 TouchType 判断（也保证不会漏掉 Cancel 导致"一直亮着"）。
   */
  static track(event: TouchEvent, setPressed: (pressed: boolean) => void): void {
    if (event.type === TouchType.Down) {
      setPressed(true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      setPressed(false);
    }
  }
}