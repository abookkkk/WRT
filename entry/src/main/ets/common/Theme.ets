/**
 * 视觉设计令牌
 *
 * 颜色全部走资源：`resources/base/element/color.json`（浅色）+
 * `resources/dark/element/color.json`（深色），由系统按当前色彩模式自动选一套。
 * 所以**不要在这里写死色值**，也不要再在页面里写 '#xxxxxx'，
 * 否则夜间模式下会出现白底黑字 / 看不清的色块。
 *
 * 当前色彩模式由 `model/ThemeSettings.ets` 控制：
 *   跟随系统（默认）/ 强制浅色 / 强制深色，对应 ApplicationContext.setColorMode()。
 * 系统模式切换时资源会重新解析，组件自动刷新，不需要手动重建。
 *
 * 注意：这里只导出普通常量。ArkUI 的 @Styles / @Extend 无法跨文件可靠导出，
 * 所以卡片的修饰属性在各页面内联书写（见 glassCard 注释里的标准写法）。
 */

import { common } from '@kit.AbilityKit';

// ===================== 颜色（资源引用，随浅色/深色自动切换） =====================

/** 主色 */
export const C_PRIMARY: Resource = $r('app.color.c_primary');
/** 主色深 */
export const C_PRIMARY_DEEP: Resource = $r('app.color.c_primary_deep');
/** 主色浅（用于浅底） */
export const C_PRIMARY_SOFT: Resource = $r('app.color.c_primary_soft');
/** 强调色（紫，用于渐变收尾） */
export const C_ACCENT: Resource = $r('app.color.c_accent');

/** 语义色 */
export const C_SUCCESS: Resource = $r('app.color.c_success');
export const C_SUCCESS_SOFT: Resource = $r('app.color.c_success_soft');
/** 成功色小胶囊底（半透明） */
export const C_SUCCESS_CHIP: Resource = $r('app.color.c_success_chip');
export const C_WARNING: Resource = $r('app.color.c_warning');
export const C_WARNING_SOFT: Resource = $r('app.color.c_warning_soft');
export const C_WARNING_CHIP: Resource = $r('app.color.c_warning_chip');
export const C_DANGER: Resource = $r('app.color.c_danger');
export const C_DANGER_SOFT: Resource = $r('app.color.c_danger_soft');
export const C_DANGER_CHIP: Resource = $r('app.color.c_danger_chip');

/** 文字三级 */
export const C_TEXT_1: Resource = $r('app.color.c_text_1');
export const C_TEXT_2: Resource = $r('app.color.c_text_2');
export const C_TEXT_3: Resource = $r('app.color.c_text_3');
export const C_TEXT_ON_PRIMARY: Resource = $r('app.color.c_text_on_primary');
export const C_TEXT_ON_PRIMARY_DIM: Resource = $r('app.color.c_text_on_primary_dim');

/** 卡片 / 背景 */
export const C_CARD: Resource = $r('app.color.c_card');
export const C_CARD_SOLID: Resource = $r('app.color.c_card_solid');
export const C_CARD_BORDER: Resource = $r('app.color.c_card_border');
export const C_DIVIDER: Resource = $r('app.color.c_divider');
export const C_FILL: Resource = $r('app.color.c_fill');

/** 页面渐变背景（浅色：上浅蓝 → 下灰白；深色：近黑蓝 → 深灰） */
export const C_BG_TOP: Resource = $r('app.color.c_bg_top');
export const C_BG_MID: Resource = $r('app.color.c_bg_mid');
export const C_BG_BOTTOM: Resource = $r('app.color.c_bg_bottom');

/** 底部标签栏底色（毛玻璃底下那层半透明色） */


/** 登录页顶部渐变（0~3 从上到下） */
export const C_LOGIN_GRAD_0: Resource = $r('app.color.c_login_grad_0');
export const C_LOGIN_GRAD_1: Resource = $r('app.color.c_login_grad_1');
export const C_LOGIN_GRAD_2: Resource = $r('app.color.c_login_grad_2');
export const C_LOGIN_GRAD_3: Resource = $r('app.color.c_login_grad_3');

/** 登录页 Logo 徽章底 */
export const C_BADGE: Resource = $r('app.color.c_badge');

// ===================== 颜色取值（给收不了 Resource 的地方用） =====================

/**
 * 把颜色资源解析成当前色彩模式下的 "#RRGGBB" 字符串。
 *
 * 为什么需要：Canvas 的 strokeStyle / fillStyle，以及 promptAction 弹窗按钮的 color，
 * 都只收字符串、收不了 Resource，只能运行时取色。走 resourceManager 取色会跟随
 * 浅色/深色自动变化，所以不要在那些地方写死色值。
 */
export function colorString(res: Resource, fallback: string): string {
  try {
    const ctx = getContext() as common.UIAbilityContext;
    const rid: number = res.id ?? 0;
    if (rid === 0) {
      return fallback;
    }
    const value: number = ctx.resourceManager.getColorSync(rid);
    const rgb: number = value & 0xFFFFFF;
    let hex: string = rgb.toString(16);
    while (hex.length < 6) {
      hex = '0' + hex;
    }
    return '#' + hex.toUpperCase();
  } catch (e) {
    return fallback;
  }
}

/** 同上，但返回 `rgba(r, g, b, alpha)`（Canvas 填充色需要带透明度） */
export function colorRgba(res: Resource, fallback: string, alpha: number): string {
  const hex: string = colorString(res, fallback);
  const r: number = parseInt(hex.substring(1, 3), 16);
  const g: number = parseInt(hex.substring(3, 5), 16);
  const b: number = parseInt(hex.substring(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

// ===================== 圆角 =====================

export const R_CARD: number = 20;
export const R_BTN: number = 22;
export const R_INPUT: number = 14;
export const R_CHIP: number = 11;

// ===================== 间距 =====================

export const SP_XS: number = 4;
export const SP_S: number = 8;
export const SP_M: number = 12;
export const SP_L: number = 16;
export const SP_XL: number = 20;
/** 悬浮标签栏占的高度：可滚动内容底部要留这么多，最后一行才不会被栏盖住（栏 62vp + 一点余量） */
export const TAB_BAR_SPACE: number = 74;

// ===================== 字号 =====================

export const F_HERO: number = 26;
export const F_TITLE: number = 22;
export const F_SECTION: number = 16;
export const F_BODY: number = 14;
export const F_CAPTION: number = 12;
export const F_TINY: number = 11;

// ===================== 图标尺寸 =====================

export const ICON_S: number = 16;
export const ICON_M: number = 20;
export const ICON_L: number = 24;
export const ICON_XL: number = 28;
