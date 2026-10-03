/**
 * 点光源特效演示页（HDS `hdsEffect`）—— 独立演示页，不属于现有业务页面。
 *
 * 页面本身只做两件事：铺深色背景 + 把 `PointLightDemo` 放进可滚动区域。
 * 真实项目里要用这个效果，直接在自己页面里 `PointLightDemo()`（或只抄它的
 * `.visualEffect(new hdsEffect.HdsEffectBuilder().pointLight({...}).buildEffect())`）即可。
 */

import { PointLightDemo } from '../components/PointLightDemo';

@Entry
@Component
struct PointLightDemoPage {
  build() {
    Column() {
      // 顶部标题（演示页自己的抬头，深色）
      Row() {
        Text('点光源特效')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffffff')
          .layoutWeight(1);
        Text('HDS hdsEffect.pointLight')
          .fontSize(12)
          .fontColor('#99ffffff');
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ bottom: 16 });

      Scroll() {
        PointLightDemo();
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    // 深色环境背景：点光源在这里才"有环境可照"
    .backgroundColor('#ff0b0b0d')
    .padding({ left: 16, right: 16, top: 24, bottom: 16 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }
}