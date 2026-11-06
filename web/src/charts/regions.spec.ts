/**
 * 行政区划名称归一化测试。
 *
 * 其中两条是**拿真实文件反向验证**，而不是只验函数本身：
 * 地图 GeoJSON 与示例数据集都在仓库里，测它们能不能真的对上。
 * 这类「两个文件之间的约定」最容易失守 —— 函数全绿，地图上却是空的。
 */

import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import type { MapGeoJson } from './regions'
import {
  REGION_ALIASES,
  isNonProvince,
  matchableRegions,
  normalizeGeoJsonNames,
  normalizeRegion,
  validateGeoJson,
} from './regions'

const GEOJSON_PATH = 'public/maps/china.geojson'
const EXAMPLE_DATA_PATH = 'public/data/macro-dataset.example.json'

function loadGeoJson(): MapGeoJson {
  return JSON.parse(readFileSync(GEOJSON_PATH, 'utf8')) as MapGeoJson
}

describe('normalizeRegion', () => {
  it('全称归一成简称', () => {
    expect(normalizeRegion('北京市')).toBe('北京')
    expect(normalizeRegion('广东省')).toBe('广东')
    expect(normalizeRegion('黑龙江省')).toBe('黑龙江')
  })

  it('五个自治区不能被「去掉后缀」处理', () => {
    // 全称里带民族名，机械去后缀会得到「广西壮族」「新疆维吾尔」「宁夏回族」
    // —— 都不是它们该有的简称，而地图上那些省就会永远没有数据
    expect(normalizeRegion('内蒙古自治区')).toBe('内蒙古')
    expect(normalizeRegion('广西壮族自治区')).toBe('广西')
    expect(normalizeRegion('西藏自治区')).toBe('西藏')
    expect(normalizeRegion('宁夏回族自治区')).toBe('宁夏')
    expect(normalizeRegion('新疆维吾尔自治区')).toBe('新疆')
  })

  it('特别行政区', () => {
    expect(normalizeRegion('香港特别行政区')).toBe('香港')
    expect(normalizeRegion('澳门特别行政区')).toBe('澳门')
  })

  it('简称原样返回（数据集两种写法都能用）', () => {
    expect(normalizeRegion('北京')).toBe('北京')
    expect(normalizeRegion('内蒙古')).toBe('内蒙古')
  })

  it('去掉首尾空白', () => {
    expect(normalizeRegion(' 北京市 ')).toBe('北京')
  })

  it('认不出的名称原样返回，不猜', () => {
    expect(normalizeRegion('某个不存在的地方')).toBe('某个不存在的地方')
  })
})

describe('isNonProvince', () => {
  it('境界线不是省份', () => {
    expect(isNonProvince('境界线')).toBe(true)
  })

  it('省份是省份', () => {
    expect(isNonProvince('北京')).toBe(false)
    expect(isNonProvince('北京市')).toBe(false)
  })
})

describe('normalizeGeoJsonNames', () => {
  it('改写 name 但不动几何与其他字段', () => {
    const geo: MapGeoJson = {
      type: 'FeatureCollection',
      features: [
        { type: 'Feature', properties: { name: '北京市', gb: '156110000' }, geometry: { x: 1 } },
      ],
    }
    const out = normalizeGeoJsonNames(geo)
    expect(out.features?.[0]?.properties?.['name']).toBe('北京')
    // 其它属性与几何必须原样保留 —— 只应改 name 一个字段
    expect(out.features?.[0]?.properties?.['gb']).toBe('156110000')
    expect(out.features?.[0]?.geometry).toEqual({ x: 1 })
  })

  it('不就地修改入参', () => {
    const geo: MapGeoJson = {
      type: 'FeatureCollection',
      features: [{ properties: { name: '上海市' } }],
    }
    normalizeGeoJsonNames(geo)
    expect(geo.features?.[0]?.properties?.['name']).toBe('上海市')
  })

  it('缺少 name 的要素原样保留', () => {
    const geo: MapGeoJson = { features: [{ properties: { foo: 1 } }] }
    expect(normalizeGeoJsonNames(geo).features?.[0]?.properties).toEqual({ foo: 1 })
  })

  it('没有 properties 的要素不崩', () => {
    const geo: MapGeoJson = { features: [{ type: 'Feature' }] }
    expect(() => normalizeGeoJsonNames(geo)).not.toThrow()
  })

  it('保留顶层除 features 外的字段（crs 等）', () => {
    const geo: MapGeoJson = { type: 'FeatureCollection', crs: { x: 1 }, features: [] }
    expect(normalizeGeoJsonNames(geo).crs).toEqual({ x: 1 })
  })
})

describe('matchableRegions', () => {
  it('排除非省级要素', () => {
    const geo: MapGeoJson = {
      features: [
        { properties: { name: '北京市' } },
        { properties: { name: '境界线' } },
        { properties: { name: '广东省' } },
      ],
    }
    expect(matchableRegions(geo)).toEqual(['北京', '广东'])
  })

  it('去重且保持出现顺序', () => {
    const geo: MapGeoJson = {
      features: [
        { properties: { name: '北京' } },
        { properties: { name: '北京市' } },
        { properties: { name: '广东' } },
      ],
    }
    expect(matchableRegions(geo)).toEqual(['北京', '广东'])
  })
})

describe('validateGeoJson', () => {
  it('合法的可通过', () => {
    const geo: MapGeoJson = { type: 'FeatureCollection', features: [{ properties: { name: '北京市' } }] }
    expect(validateGeoJson(geo)).toEqual([])
  })

  it('顶层不是对象时拒绝', () => {
    expect(validateGeoJson([])).toEqual(['顶层应当是一个对象'])
  })

  it('type 不对时拒绝', () => {
    const errors = validateGeoJson({ type: 'Feature', features: [] })
    expect(errors.some((e) => e.includes('FeatureCollection'))).toBe(true)
  })

  it('features 为空时拒绝，并说明空地图与没有地图没有区别', () => {
    const errors = validateGeoJson({ type: 'FeatureCollection', features: [] })
    expect(errors.some((e) => e.includes('空地图'))).toBe(true)
  })

  it('要素缺 name 时指出数量', () => {
    const errors = validateGeoJson({
      type: 'FeatureCollection',
      features: [{ properties: { name: '北京市' } }, { properties: {} }],
    })
    expect(errors.some((e) => e.includes('1 个要素缺少'))).toBe(true)
  })
})

// --------------------------------------------------------------------------
// 拿真实文件反向验证：函数全绿但地图空白，才是真正要防的情形
// --------------------------------------------------------------------------

describe('对照表与真实地图的一致性', () => {
  it('地图里每一个省级要素都有对照条目', () => {
    // 少一条，那个省在地图上就永远是灰的，而且不报错。
    // 手工抄 34 个名字，抄错一个的概率并不低。
    const geo = loadGeoJson()
    const rawNames = (geo.features ?? [])
      .map((f) => f.properties?.['name'])
      .filter((n): n is string => typeof n === 'string' && !isNonProvince(n))

    expect(rawNames).toHaveLength(34)
    const missing = rawNames.filter((n) => REGION_ALIASES[n] === undefined)
    expect(missing).toEqual([])
  })

  it('归一化后没有重名（重名会让两个省抢同一份数据）', () => {
    const regions = matchableRegions(loadGeoJson())
    expect(new Set(regions).size).toBe(regions.length)
    expect(regions).toHaveLength(34)
  })

  it('境界线不参与匹配，但也没有被删掉', () => {
    const geo = loadGeoJson()
    const total = geo.features?.length ?? 0
    const provinces = matchableRegions(geo).length
    // 34 个省 + 若干境界线要素。境界线必须保留 ——
    // 中国地图上南海诸岛与九段线是必须出现的，删掉是合规问题
    expect(total).toBeGreaterThan(provinces)
    expect(provinces).toBe(34)
  })

  it('示例数据集里的每个地区都能在地图上找到', () => {
    // 这是端到端的匹配检查：数据侧的简称 → 归一化 → 地图侧的名称。
    // 这条过了，才说明地图真的会亮起来，而不是一片灰。
    const regions = new Set(matchableRegions(loadGeoJson()))
    const data = JSON.parse(readFileSync(EXAMPLE_DATA_PATH, 'utf8')) as {
      observations: { region?: string }[]
    }
    const used = new Set(
      data.observations.map((o) => o.region).filter((r): r is string => typeof r === 'string'),
    )

    expect(used.size).toBeGreaterThan(0)
    const unmatched = [...used].filter((name) => !regions.has(normalizeRegion(name)))
    expect(unmatched).toEqual([])
  })

  it('真实地图文件本身通过校验', () => {
    expect(validateGeoJson(loadGeoJson())).toEqual([])
  })
})
