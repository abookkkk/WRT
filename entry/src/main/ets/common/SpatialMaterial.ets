/**
 * 沉浸光感（Spatial UI）材质层 —— 只使用在 SDK 里**已核实存在**的 HDS 接口
 *
 * 核实来源（DevEco 6.1.1 / API 24）：
 *   hms\ets\api\@hms.hds.hdsMaterial.d.ets
 *     · enum MaterialType : EXQUISITE = 0 / GENTLE = 1 / SMOOTH = 2（NONE 为默认值）
 *     · enum MaterialLevel: ADAPTIVE 为默认值
 *     · getSystemMaterialTypes(): Array<MaterialType>      ← 设备能力查询
 *   hms\ets\api\@hms.hds.hdsBaseComponent.d.ets
 *     · interface SystemMaterialParams { materialType?, materialLevel? }（line 1386）
 *     · HdsNavigationTitleBarStyle.systemMaterialEffect : SystemMaterialParams（line 1472 附近）
 *     · HdsTabsFloatingStyle.systemMaterialEffect        : SystemMaterialParams（line 5357 附近）
 *
 * ⚠️ 未核实项：`uiMaterial.ImmersiveMaterial` / `.systemMaterial(...)` 在**两个 SDK 里都查不到**，
 *    所以普通组件这一档也统一走 SystemMaterialParams（不要再按 ImmersiveMaterial 写）。
 *
 * 约束落地：
 *   约束 2 优先 ADAPTIVE          → params('adaptive', …) 就是 ADAPTIVE/ADAPTIVE
 *   约束 3 低端设备不强制 EXQUISITE → 先 getSystemMaterialTypes() 查，不支持就自动降级
 *   约束 5 亮色模式下 EXQUISITE 可能盖白叠层 → 亮色一律降到 GENTLE
 */

import { hdsMaterial } from '@kit.UIDesignKit';

/** 对外档位：用字符串表示，业务层不必到处 import HDS 枚举 */
export type MaterialTier = 'adaptive' | 'exquisite' | 'gentle' | 'smooth';

export class SpatialMaterial {
  /** 本次进程内缓存的能力查询结果（设备能力不会变，不必反复查） */
  private static cachedTypes: hdsMaterial.MaterialType[] | null = null;

  /**
   * 设备支持哪些材质档位。
   * 查询失败时**不假定高端**，回退到只声明 SMOOTH —— 宁可弱一点，也不要在低端机上翻车。
   */
  static supportedTypes(): hdsMaterial.MaterialType[] {
    if (SpatialMaterial.cachedTypes !== null) {
      return SpatialMaterial.cachedTypes;
    }
    let types: hdsMaterial.MaterialType[] = [];
    try {
      types = hdsMaterial.getSystemMaterialTypes();
      console.info('[SpatialMaterial] 设备支持的材质档位 = ' + JSON.stringify(types));
    } catch (e) {
      console.warn('[SpatialMaterial] 查询材质能力失败，按最低档处理: ' + JSON.stringify(e));
      types = [hdsMaterial.MaterialType.SMOOTH];
    }
    SpatialMaterial.cachedTypes = types;
    return types;
  }

  /** 设备是否支持 EXQUISITE（强）档 */
  static supportsExquisite(): boolean {
    return SpatialMaterial.supportedTypes().indexOf(hdsMaterial.MaterialType.EXQUISITE) >= 0;
  }

  /**
   * 档位 → 可直接塞进 `systemMaterialEffect` 的参数。
   *
   * @param tier      期望档位；默认 'adaptive'
   * @param isLight   当前是否亮色模式（约束 5：亮色下 EXQUISITE 可能覆盖白色叠层 → 降 GENTLE）
   */
  static params(tier: MaterialTier = 'adaptive', isLight: boolean = false): hdsMaterial.SystemMaterialParams {
    return {
      materialType: SpatialMaterial.resolveType(tier, isLight),
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
    };
  }

  /** 实际生效的材质类型（把设备能力与亮色约束都算进去） */
  private static resolveType(tier: MaterialTier, isLight: boolean): hdsMaterial.MaterialType {
    if (tier === 'smooth') {
      return hdsMaterial.MaterialType.SMOOTH;
    }
    if (tier === 'gentle') {
      return hdsMaterial.MaterialType.GENTLE;
    }
    if (tier === 'exquisite') {
      if (isLight) {
        // 约束 5：亮色下强档会压白叠层，降一档更耐看
        console.info('[SpatialMaterial] 亮色模式：EXQUISITE → GENTLE');
        return hdsMaterial.MaterialType.GENTLE;
      }
      if (!SpatialMaterial.supportsExquisite()) {
        // 约束 3：低端设备不支持强档
        console.info('[SpatialMaterial] 设备不支持 EXQUISITE → GENTLE');
        return hdsMaterial.MaterialType.GENTLE;
      }
      return hdsMaterial.MaterialType.EXQUISITE;
    }
    // 约束 2：默认自适应
    return hdsMaterial.MaterialType.ADAPTIVE;
  }

  /**
   * 同层渲染（API ≤ 23 常见）可能需要关闭沉浸光感：调用处按这个判定决定要不要传参数。
   * 本项目当前 targetSdkVersion = 24（见 AppScope/app.json5 与 build-profile.json5），默认可用；
   * 若以后要兼容更低版本，把这里换成运行时的同层渲染检测即可。
   */
  static shouldEnableImmersiveLight(compatibleSdkVersion: number): boolean {
    return compatibleSdkVersion > 23;
  }
}