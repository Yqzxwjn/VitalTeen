/**
 * 示例数据集的自检。
 *
 * 示例数据的唯一用途是**让人在真实数据接入之前能看到界面**。它一旦不合法，
 * 复制过去的人会直接撞上「数据文件有问题」的报错 —— 那比不提供示例更糟，
 * 因为它会让人以为工具本身坏了，而不是示例文件坏了。
 *
 * 所以这组测试守的是一个承诺：**复制过去一定能用。**
 */

import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import type { MacroDataset } from './types'
import { SCHEMA_VERSION } from './types'
import { validate } from './loader'
import { normalizeRegion } from '@/charts/regions'

const EXAMPLE_PATH = 'public/data/macro-dataset.example.json'

function loadExample(): MacroDataset {
  return JSON.parse(readFileSync(EXAMPLE_PATH, 'utf8')) as MacroDataset
}

describe('示例数据集', () => {
  it('能通过加载器的校验', () => {
    expect(validate(loadExample())).toEqual([])
  })

  it('格式版本与当前契约一致', () => {
    expect(loadExample().schemaVersion).toBe(SCHEMA_VERSION)
  })

  it('出处声明里明确写着它是示例数据', () => {
    // 这是它**不会被误当成真实统计数据**的唯一保障。
    // 页面顶部会原样显示这段出处声明，所以只要它还写着「示例」与「禁止」，
    // 就没有人会把它带进答辩材料。
    const { provenance } = loadExample()
    expect(provenance.title).toContain('示例')
    expect(provenance.publisher).toContain('不含任何真实统计')
    expect(provenance.license).toContain('禁止')
  })

  it('覆盖到五个视图都画得出来所需的维度', () => {
    // 少任何一项，某个视图就会显示「无法绘制」，预览也就失去了意义：
    // 趋势图至少需要两年；分布图与地图至少需要两个地区、且取值不能完全相同。
    const { observations } = loadExample()

    const years = new Set(observations.map((o) => o.year))
    expect(years.size).toBeGreaterThanOrEqual(2)

    const regional = observations.filter((o) => o.region !== undefined)
    const regions = new Set(regional.map((o) => o.region))
    expect(regions.size).toBeGreaterThanOrEqual(2)

    const values = regional.map((o) => o.metrics[0]?.value ?? 0)
    expect(new Set(values).size).toBeGreaterThan(1)

    const stages = new Set(observations.map((o) => o.stage))
    expect(stages.size).toBeGreaterThanOrEqual(2)

    const codes = new Set(observations.flatMap((o) => o.metrics.map((m) => m.code)))
    expect(codes.size).toBeGreaterThanOrEqual(2)
  })

  it('覆盖地图上的每一个省级要素', () => {
    // **这条是刻意严格到「全部」的。** 示例数据的用途是「让人看清界面」，
    // 而地图上只亮几个省、其余全是灰的，看起来像坏了 —— 达不到那个用途。
    // 曾经这份数据只有 6 个省，地图预览就是这个效果。
    //
    // 断言的是「数据覆盖了地图的全部省份」，而不是反过来 —— 反方向
    // 由 regions.spec.ts 保证（数据里的每个地区都能在地图上找到）。
    const geo = JSON.parse(readFileSync('public/maps/china.geojson', 'utf8')) as {
      features: { properties?: { name?: string } }[]
    }
    const mapProvinces = new Set(
      geo.features
        .map((f) => f.properties?.name)
        .filter((n): n is string => typeof n === 'string' && n !== '境界线')
        .map((n) => normalizeRegion(n)),
    )
    const dataProvinces = new Set(
      loadExample()
        .observations.map((o) => o.region)
        .filter((r): r is string => typeof r === 'string')
        .map((r) => normalizeRegion(r)),
    )

    const uncovered = [...mapProvinces].filter((p) => !dataProvinces.has(p))
    expect(uncovered).toEqual([])
  })

  it('每个省都有两年数据，这样点进任何一个省都画得出趋势', () => {
    // 只给一年的话，下钻到那个省会显示「趋势至少需要两年」——
    // 那不是 bug，但预览时看起来像功能没做完
    const byRegion = new Map<string, Set<number>>()
    for (const o of loadExample().observations) {
      if (typeof o.region !== 'string') continue
      const years = byRegion.get(o.region) ?? new Set<number>()
      years.add(o.year)
      byRegion.set(o.region, years)
    }
    const singleYear = [...byRegion].filter(([, years]) => years.size < 2).map(([name]) => name)
    expect(singleYear).toEqual([])
  })

  it('不会覆盖默认加载的文件名', () => {
    // 默认加载的是 macro-dataset.json；示例文件叫 .example.json，
    // 因此**默认状态下页面仍然显示「数据未接入」** —— 那是有意的。
    expect(EXAMPLE_PATH.endsWith('macro-dataset.example.json')).toBe(true)
  })
})
