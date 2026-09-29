/**
 * 视觉设计令牌
 *
 * 统一颜色 / 圆角 / 间距 / 字号，让所有页面视觉一致。
 * 颜色取 HarmonyOS 系统设计语言的蓝主色调，配合玻璃拟态卡片。
 *
 * 注意：这里只导出普通常量。ArkUI 的 @Styles / @Extend 无法跨文件可靠导出，
 * 所以卡片的修饰属性在各页面内联书写（见 glassCard 注释里的标准写法）。
 */

// ===================== 颜色 =====================

/** 主色（系统蓝） */
export const C_PRIMARY: string = '#0A59F7';
/** 主色深 */
export const C_PRIMARY_DEEP: string = '#0A3FBF';
/** 主色浅（用于浅底） */
export const C_PRIMARY_SOFT: string = '#E8F0FE';
/** 强调色（紫，用于渐变收尾） */
export const C_ACCENT: string = '#6A4DFF';

/** 语义色 */
export const C_SUCCESS: string = '#1DB954';
export const C_SUCCESS_SOFT: string = '#E6F7ED';
export const C_WARNING: string = '#FF9500';
export const C_WARNING_SOFT: string = '#FFF4E5';
export const C_DANGER: string = '#F53F3F';
export const C_DANGER_SOFT: string = '#FFECEC';

/** 文字三级 */
export const C_TEXT_1: string = '#181818';
export const C_TEXT_2: string = '#6B6B6B';
export const C_TEXT_3: string = '#9C9C9C';
export const C_TEXT_ON_PRIMARY: string = '#FFFFFF';

/** 卡片 / 背景 */
export const C_CARD: string = '#F2FFFFFF';
export const C_CARD_SOLID: string = '#FFFFFF';
export const C_CARD_BORDER: string = '#1F0A59F7';
export const C_DIVIDER: string = '#14000000';
export const C_FILL: string = '#0D000000';

/** 页面渐变背景（上浅蓝 → 下灰白） */
export const C_BG_TOP: string = '#EAF1FF';
export const C_BG_MID: string = '#F4F6FA';
export const C_BG_BOTTOM: string = '#F5F6F8';

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
