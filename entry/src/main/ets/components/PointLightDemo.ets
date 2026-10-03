/**
 * 点光源特效演示（HDS `hdsEffect`）
 *
 * 用法（把这一块放进任意页面即可，不影响原有 UI / import / 业务逻辑）：
 *   import { PointLightDemo } from '../components/PointLightDemo';
 *   ...
 *   PointLightDemo()
 *
 * 原理：`hdsEffect.HdsEffectBuilder().pointLight(...).buildEffect()` 造出一个 `VisualEffect`，
 * 交给组件的 `.visualEffect(...)`。光源会"打"在这个组件表面上：
 *   · 组件表面必须是**浅色**（这里用 #ffa0a0a0）；
 *   · 环境 / 父容器必须是**深色**（演示区用 #ff000000），否则看不出折射层次；
 *   · 支持 `.visualEffect()` 的组件：Button / Toggle / Row / Column / Image / Flex /
 *     Stack / Select / Menu / MenuItem（单个组件最多同时受 12 个光源照亮）。
 *
 * 光照类型 `PointLightIlluminatedType`：BORDER（只照边缘）/ CONTENT（只照内容）/
 * BORDER_CONTENT（边缘 + 内容，推荐，本演示默认）。
 * 可调参数 `PointLightOptions`：color / intensity（推荐 0~5）/ height（越小光斑越集中）/ bloom。
 *
 * ⚠️ 两个实测结论（模拟器 6.1.0.126 / x86_64）：
 *   1. `PointLightEffect.sourceType` 默认值是 `NONE`（= 不发光）。只写 options + illuminatedType
 *      是**不亮**的，必须显式给 `SOFT` 或 `BRIGHT`（本演示默认 SOFT）。
 *   2. 该模拟器**不支持点光源渲染**：参数会被完整解析（HDS_EFFECT 日志里能看到
 *      height / intensity / sourceType / position / illuminatedType 都 success），
 *      紧接着 `pointlight_model.cpp-Handle:48 PointLightUnsupportedHandler` ——
 *      渲染端没有对应实现，表面不会发生任何变化。要在支持 HDS 点光源的真机上才看得到光影。
 *      所以本演示里还打印了交互日志（`[PointLightDemo] ...`），模拟器上可以靠日志确认交互已触发。
 */

import { hdsEffect } from '@kit.UIDesignKit';

/** 浅色组件表面：点光源要有浅色表面才有"被照到"的折射感 */
const SURFACE: string = '#ffa0a0a0';
/** 演示区深色环境背景 */
const STAGE_BG: string = '#ff000000';
/** 深色底上的次级表面（控件槽 / 说明卡） */
const PANEL: string = '#1Affffff';
/** 深色底上的文字 */
const TEXT_ON_DARK: string = '#ffe8e8e8';
const TEXT_ON_DARK_DIM: string = '#99ffffff';
/** 浅色表面上的文字 */
const TEXT_ON_SURFACE: string = '#ff1a1a1a';
const TEXT_ON_SURFACE_DIM: string = '#cc1a1a1a';
/** 控件主色 */
const ACCENT: string = '#ff5b8ff9';
/** 光照过渡动画（需求：300ms + Smooth） */
const GLOW_ANIM: AnimateParam = { duration: 300, curve: Curve.Smooth };

/** 光照类型三档（顺序与 TYPE_VALUES 一致） */
const TYPE_LABELS: string[] = ['边框', '内容', '边框 + 内容'];
const TYPE_VALUES: hdsEffect.PointLightIlluminatedType[] = [
  hdsEffect.PointLightIlluminatedType.BORDER,
  hdsEffect.PointLightIlluminatedType.CONTENT,
  hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
];

/** 光源类型两档（⚠️ NONE = 不发光，别用） */
const SOURCE_LABELS: string[] = ['柔和 SOFT', '明亮 BRIGHT'];
const SOURCE_VALUES: hdsEffect.PointLightSourceType[] = [
  hdsEffect.PointLightSourceType.SOFT,
  hdsEffect.PointLightSourceType.BRIGHT
];

/** 光源颜色三档 */
const COLOR_LABELS: string[] = ['白光', '暖光', '冷光'];
const COLOR_VALUES: ResourceColor[] = [Color.White, '#ffffd9a0', '#ff9fd8ff'];

@Component
export struct PointLightDemo {
  /** 当前光照类型：默认「边框 + 内容」（光影层次最完整） */
  @State private typeIndex: number = 2;
  /** 当前光源类型：默认柔和 */
  @State private sourceIndex: number = 0;
  /** 当前光源颜色：默认白光 */
  @State private colorIndex: number = 0;
  /** 基础光照强度（0~5） */
  @State private intensity: number = 1.6;
  /** 光源高度（vp）：越小光斑越集中 */
  @State private lightHeight: number = 130;
  /** 交互一：按住按钮发光 */
  @State private pressingButton: boolean = false;
  /** 交互二：按住浅色卡片整块发光 */
  @State private pressingCard: boolean = false;
  /** 交互三：开关点亮（Toggle 自己就是被照亮的组件） */
  @State private glowing: boolean = false;

  /** 按住时额外叠加的强度：光斑更亮，松手回落 */
  private static readonly PRESS_BOOST: number = 2.2;

  /**
   * 造一个点光源效果。
   *
   * @param extra 临时叠加的强度（按压 / 开关时用）。状态一变就重新 build 出新的
   *              `VisualEffect`，配合组件上的 `.animation(GLOW_ANIM)` 做 300ms 平滑过渡。
   */
  private pointLight(extra: number = 0): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        // ⚠️ 默认 NONE = 不发光，必须显式指定光源类型
        sourceType: SOURCE_VALUES[this.sourceIndex],
        // 需求约束 4：用 BORDER_CONTENT 拿到最完整的光影层次（默认档）
        illuminatedType: TYPE_VALUES[this.typeIndex],
        options: {
          color: COLOR_VALUES[this.colorIndex],
          intensity: this.intensity + extra,
          height: this.lightHeight
        }
      })
      .buildEffect();
  }

  /** 按压时用的实际强度（也用来打日志，模拟器上靠日志确认交互触发） */
  private pressIntensity(base: number): number {
    return base + PointLightDemo.PRESS_BOOST;
  }

  /** 光照类型切换器（需求：边框 / 内容 / 边框 + 内容） */
  @Builder
  typeSwitcher() {
    Column() {
      Text('光照类型（PointLightIlluminatedType）')
        .fontSize(13)
        .fontColor(TEXT_ON_DARK_DIM)
        .width('100%')
        .margin({ bottom: 8 });

      Row() {
        ForEach(TYPE_LABELS, (label: string, index: number) => {
          Button(label)
            .height(36)
            .layoutWeight(1)
            .type(ButtonType.Capsule)
            .fontSize(13)
            .fontColor(this.typeIndex === index ? Color.White : TEXT_ON_DARK)
            .backgroundColor(this.typeIndex === index ? ACCENT : PANEL)
            .margin({ left: index === 0 ? 0 : 6, right: index === TYPE_LABELS.length - 1 ? 0 : 6 })
            .onClick(() => {
              this.typeIndex = index;
              console.info(`[PointLightDemo] 光照类型 → ${TYPE_LABELS[index]}`);
            });
        }, (label: string) => label);
      }
      .width('100%');
    }
    .width('100%')
    .padding(14)
    .backgroundColor(PANEL)
    .borderRadius(16);
  }

  /** 光源类型 + 颜色（都是 PointLightEffect / PointLightOptions 上的可选项） */
  @Builder
  sourcePicker() {
    Column() {
      Text('光源类型 sourceType（不写默认 NONE = 不发光）')
        .fontSize(13)
        .fontColor(TEXT_ON_DARK_DIM)
        .width('100%')
        .margin({ bottom: 8 });

      Row() {
        ForEach(SOURCE_LABELS, (label: string, index: number) => {
          Button(label)
            .height(34)
            .layoutWeight(1)
            .type(ButtonType.Capsule)
            .fontSize(13)
            .fontColor(this.sourceIndex === index ? Color.White : TEXT_ON_DARK)
            .backgroundColor(this.sourceIndex === index ? ACCENT : PANEL)
            .margin({ left: index === 0 ? 0 : 6, right: index === SOURCE_LABELS.length - 1 ? 0 : 6 })
            .onClick(() => {
              this.sourceIndex = index;
              console.info(`[PointLightDemo] 光源类型 → ${SOURCE_LABELS[index]}`);
            });
        }, (label: string) => label);
      }
      .width('100%');

      Text('光源颜色 color')
        .fontSize(13)
        .fontColor(TEXT_ON_DARK_DIM)
        .width('100%')
        .margin({ top: 12, bottom: 8 });

      Row() {
        ForEach(COLOR_LABELS, (label: string, index: number) => {
          Row() {
            Column()
              .width(14)
              .height(14)
              .borderRadius(7)
              .backgroundColor(COLOR_VALUES[index])
              .border({ width: 1, color: '#66ffffff' });
            Text(label)
              .fontSize(13)
              .fontColor(this.colorIndex === index ? Color.White : TEXT_ON_DARK)
              .margin({ left: 6 });
          }
          .layoutWeight(1)
          .height(34)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.colorIndex === index ? '#33ffffff' : '#0Affffff')
          .borderRadius(17)
          .margin({ left: index === 0 ? 0 : 6, right: index === COLOR_LABELS.length - 1 ? 0 : 6 })
          .onClick(() => {
            this.colorIndex = index;
            console.info(`[PointLightDemo] 光源颜色 → ${COLOR_LABELS[index]}`);
          });
        }, (label: string) => label);
      }
      .width('100%');
    }
    .width('100%')
    .padding(14)
    .backgroundColor(PANEL)
    .borderRadius(16)
    .margin({ top: 12 });
  }

  /** 参数调节（强度 / 高度） */
  @Builder
  paramSliders() {
    Column() {
      Row() {
        Text('光照强度 intensity')
          .fontSize(13)
          .fontColor(TEXT_ON_DARK)
          .layoutWeight(1);
        Text(this.intensity.toFixed(1))
          .fontSize(13)
          .fontColor(ACCENT);
      }
      .width('100%');

      Slider({
        value: this.intensity,
        min: 0,
        max: 5,
        step: 0.1,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor(ACCENT)
        .trackColor('#33ffffff')
        .onChange((value: number) => {
          this.intensity = value;
        });

      Row() {
        Text('光源高度 height')
          .fontSize(13)
          .fontColor(TEXT_ON_DARK)
          .layoutWeight(1);
        Text(String(Math.round(this.lightHeight)) + ' vp')
          .fontSize(13)
          .fontColor(ACCENT);
      }
      .width('100%')
      .margin({ top: 6 });

      Slider({
        value: this.lightHeight,
        min: 40,
        max: 300,
        step: 10,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor(ACCENT)
        .trackColor('#33ffffff')
        .onChange((value: number) => {
          this.lightHeight = value;
        });

      Text('高度越小，光斑越集中；越大，照亮范围越广')
        .fontSize(12)
        .fontColor(TEXT_ON_DARK_DIM)
        .width('100%')
        .margin({ top: 2 });
    }
    .width('100%')
    .padding(14)
    .backgroundColor(PANEL)
    .borderRadius(16)
    .margin({ top: 12 });
  }

  build() {
    Column() {
      // ==================== 演示舞台（深色环境 + 浅色组件） ====================
      Column() {
        Text('演示舞台：深色环境 + 浅色组件')
          .fontSize(12)
          .fontColor(TEXT_ON_DARK_DIM)
          .width('100%')
          .margin({ bottom: 14 });

        // ---- 交互一：按住按钮发光 ----
        Button('按住我 → 发光')
          .width('100%')
          .height(56)
          .type(ButtonType.Capsule)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_ON_SURFACE)
          .backgroundColor(SURFACE)
          .visualEffect(this.pointLight(this.pressingButton ? PointLightDemo.PRESS_BOOST : 0))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.pressingButton = true;
              console.info(`[PointLightDemo] 按钮按住：intensity ${this.intensity.toFixed(1)} → ${this.pressIntensity(this.intensity).toFixed(1)}`);
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressingButton = false;
              console.info(`[PointLightDemo] 按钮松开：intensity 回到 ${this.intensity.toFixed(1)}`);
            }
          })
          .animation(GLOW_ANIM);

        // ---- 交互二：按住浅色卡片整块发光 ----
        Row() {
          Column() {
            Text('浅色卡片')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_ON_SURFACE);
            Text('按住整块卡片，边缘 + 内容一起被照亮')
              .fontSize(12)
              .fontColor(TEXT_ON_SURFACE_DIM)
              .margin({ top: 4 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          Text(this.pressingCard ? '照亮中' : '按住')
            .fontSize(12)
            .fontColor(TEXT_ON_SURFACE);
        }
        .width('100%')
        .height(88)
        .padding({ left: 18, right: 18 })
        .backgroundColor(SURFACE)
        .borderRadius(20)
        .margin({ top: 14 })
        .visualEffect(this.pointLight(this.pressingCard ? PointLightDemo.PRESS_BOOST : 0))
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.pressingCard = true;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressingCard = false;
          }
        })
        .animation(GLOW_ANIM);

        // ---- 交互三：开关点亮（Toggle 自己就是被照亮的组件） ----
        Row() {
          Column() {
            Text('开关点亮')
              .fontSize(15)
              .fontColor(TEXT_ON_DARK);
            Text('打开开关，Toggle 表面常亮')
              .fontSize(12)
              .fontColor(TEXT_ON_DARK_DIM)
              .margin({ top: 2 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          Toggle({ type: ToggleType.Switch, isOn: this.glowing })
            .width(64)
            .height(36)
            .padding(3)
            .backgroundColor(SURFACE)
            .borderRadius(18)
            .selectedColor(ACCENT)
            .visualEffect(this.pointLight(this.glowing ? 1.2 : 0))
            .onChange((isOn: boolean) => {
              this.glowing = isOn;
              console.info(`[PointLightDemo] 开关点亮 → ${isOn}`);
            })
            .animation(GLOW_ANIM);
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(PANEL)
        .borderRadius(16)
        .margin({ top: 14 });
      }
      .width('100%')
      .padding(18)
      .backgroundColor(STAGE_BG)
      .borderRadius(24);

      // ==================== 控制区（深色，本身不参与光照） ====================
      this.typeSwitcher();
      this.sourcePicker();
      this.paramSliders();

      Text('提示：点光源必须要「浅色组件表面 + 深色环境背景」才看得见；单个组件最多同时受 12 个光源照亮。\n' +
        '模拟器（x86_64）实测不支持点光源渲染：日志里会出现 PointLightUnsupportedHandler，表面不会有变化，需在真机上查看。')
        .fontSize(12)
        .fontColor(TEXT_ON_DARK_DIM)
        .width('100%')
        .margin({ top: 14, bottom: 8 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}