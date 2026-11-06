import type { EChartsOption } from 'echarts'
import { describe, expect, it } from 'vitest'

import type { MacroDataset, MetricRecord, Observation, SchoolStage } from '@/data/types'
import { SCHEMA_VERSION } from '@/data/types'

import {
  availableMetrics,
  availableYears,
  buildDistribution,
  buildRegionHeatmap,
  buildRegionRanking,
  buildStageOverview,
  buildTrend,
  nationalValue,
  stageFromLabel,
} from './options'

function metric(
  code: string,
  value: number,
  opts: { kind?: MetricRecord['kind']; sampleSize?: number } = {},
): MetricRecord {
  const record: MetricRecord = {
    code,
    name: `指标${code}`,
    value,
    unit: opts.kind === 'rate' ? 'ratio' : '单位',
    kind: opts.kind ?? 'rate',
  }
  if (opts.sampleSize !== undefined) record.sampleSize = opts.sampleSize
  return record
}

function observation(
  stage: SchoolStage,
  year: number,
  metrics: MetricRecord[],
  region?: string,
): Observation {
  const obs: Observation = { stage, year, metrics }
  if (region !== undefined) obs.region = region
  return obs
}

function dataset(observations: Observation[]): MacroDataset {
  return {
    schemaVersion: SCHEMA_VERSION,
    provenance: {
      title: '测试数据集',
      publisher: '某机构',
      publishedYear: 2024,
      url: 'https://example.org',
      license: '测试',
      coverage: '测试',
    },
    observations,
  }
}

/**
 * ECharts 的 ``title`` 允许是单个对象或数组。构造器只产出单个对象，
 * 但类型上两者都可能，取值时要按这个前提处理 —— 用 ``as`` 断言绕过检查，
 * 下次类型真的变了就发现不了。
 */
function titleOf(option: EChartsOption): { text: string; subtext: string } {
  const raw = Array.isArray(option.title) ? option.title[0] : option.title
  return { text: String(raw?.text ?? ''), subtext: String(raw?.subtext ?? '') }
}

describe('可用指标与年份', () => {
  it('列出出现过的指标并去重', () => {
    const data = dataset([
      observation('junior', 2023, [metric('A', 0.5), metric('B', 1)]),
      observation('junior', 2024, [metric('A', 0.6)]),
    ])
    expect(availableMetrics(data).map((m) => m.code)).toEqual(['A', 'B'])
  })

  it('年份升序且去重', () => {
    const data = dataset([
      observation('junior', 2024, [metric('A', 0.5)]),
      observation('junior', 2022, [metric('A', 0.5)]),
      observation('junior', 2024, [metric('A', 0.5)]),
    ])
    expect(availableYears(data)).toEqual([2022, 2024])
  })
})

describe('nationalValue —— 不合成没有意义的数字', () => {
  it('有全国汇总行时直接采用，不标记为加权', () => {
    const result = nationalValue([
      { stage: 'junior', year: 2024, metric: metric('A', 0.6) },
      { stage: 'junior', year: 2024, region: '北京', metric: metric('A', 0.8, { sampleSize: 100 }) },
    ])
    expect(result).toEqual({ ok: true, value: 0.6, weighted: false })
  })

  it('只有分省数据且都带样本量时按样本量加权', () => {
    const result = nationalValue([
      { stage: 'junior', year: 2024, region: 'A省', metric: metric('X', 1.0, { sampleSize: 100 }) },
      { stage: 'junior', year: 2024, region: 'B省', metric: metric('X', 0.0, { sampleSize: 300 }) },
    ])
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.weighted).toBe(true)
      // 加权后应偏向样本量大的 B 省：0.25 而不是未加权的 0.5
      expect(result.value).toBeCloseTo(0.25, 10)
    }
  })

  it('只有分省数据且缺样本量时拒绝，并说明原因', () => {
    const result = nationalValue([
      { stage: 'junior', year: 2024, region: 'A省', metric: metric('X', 1.0) },
      { stage: 'junior', year: 2024, region: 'B省', metric: metric('X', 0.0) },
    ])
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.reason).toContain('未加权')
      expect(result.reason).toContain('样本量')
    }
  })

  it('全国汇总行重复时拒绝', () => {
    const result = nationalValue([
      { stage: 'junior', year: 2024, metric: metric('A', 0.6) },
      { stage: 'junior', year: 2024, metric: metric('A', 0.7) },
    ])
    expect(result.ok).toBe(false)
  })

  it('完全没有数据时拒绝', () => {
    expect(nationalValue([]).ok).toBe(false)
  })
})

describe('buildStageOverview', () => {
  const data = dataset([
    observation('junior', 2023, [metric('R', 0.5)]),
    observation('junior', 2024, [metric('R', 0.62)]),
    observation('senior', 2024, [metric('R', 0.55)]),
    observation('college', 2024, [metric('R', 0.48)]),
  ])

  it('取最新的一年', () => {
    const result = buildStageOverview(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(titleOf(result.option).text).toContain('2024')
    }
  })

  it('学段按标准顺序排列，而不是按字典序', () => {
    const result = buildStageOverview(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const axis = result.option.yAxis as { data: string[] }
      expect(axis.data).toEqual(['初中', '高中', '大学'])
    }
  })

  it('缺少的学段被记入副标题而不是补 0', () => {
    const result = buildStageOverview(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const { subtext } = titleOf(result.option)
      expect(subtext).toContain('缺少')
      expect(subtext).toContain('小学')
    }
  })

  it('样本量加权合成时在副标题里注明', () => {
    const regional = dataset([
      observation('junior', 2024, [metric('R', 0.9, { sampleSize: 10 })], 'A省'),
      observation('junior', 2024, [metric('R', 0.1, { sampleSize: 90 })], 'B省'),
    ])
    const result = buildStageOverview(regional, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(titleOf(result.option).subtext).toContain('加权')
    }
  })

  it('指标不存在时拒绝并说明', () => {
    const result = buildStageOverview(data, 'NOT_THERE')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('NOT_THERE')
  })

  it('全部学段都取不到值时拒绝，而不是画一张空图', () => {
    const onlyRegional = dataset([
      observation('junior', 2024, [metric('R', 0.5)], 'A省'),
      observation('junior', 2024, [metric('R', 0.6)], 'B省'),
    ])
    expect(buildStageOverview(onlyRegional, 'R').ok).toBe(false)
  })
})

describe('buildTrend', () => {
  it('只有一年时拒绝，并说明趋势至少需要两年', () => {
    const data = dataset([observation('junior', 2024, [metric('R', 0.5)])])
    const result = buildTrend(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('两年')
  })

  it('某学段缺失的年份留空，不做插值', () => {
    // 年份轴来自**数据集里出现过的全部年份**，而不是某个学段自己的年份。
    // 因此「缺口」只在别的学段提供了那一年时才显现 —— 初中的 2021 之所以
    // 会是一个断点，是因为高中在 2021 有数据。这条语义不显然，
    // 写在这里以免下次有人把它当成 bug。
    const data = dataset([
      observation('junior', 2020, [metric('R', 0.5)]),
      observation('junior', 2022, [metric('R', 0.7)]),
      observation('senior', 2021, [metric('R', 0.6)]),
    ])
    const result = buildTrend(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as {
        name: string
        data: (number | null)[]
        connectNulls?: boolean
      }[]
      const junior = series.find((s) => s.name === '初中')
      expect(junior?.data).toEqual([0.5, null, 0.7])
      // connectNulls 必须关闭：把两点直连会让人以为中间是插值出来的
      expect(junior?.connectNulls).toBe(false)
    }
  })

  it('按学段分系列', () => {
    const data = dataset([
      observation('junior', 2020, [metric('R', 0.5)]),
      observation('junior', 2021, [metric('R', 0.6)]),
      observation('senior', 2020, [metric('R', 0.4)]),
      observation('senior', 2021, [metric('R', 0.45)]),
    ])
    const result = buildTrend(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { name: string }[]
      expect(series.map((s) => s.name)).toEqual(['初中', '高中'])
    }
  })

  it('全空的学段被跳过并记入副标题', () => {
    const data = dataset([
      observation('junior', 2020, [metric('R', 0.5)]),
      observation('junior', 2021, [metric('R', 0.6)]),
      // 高中两年都只有分省数据且缺样本量 → 合成不出来
      observation('senior', 2020, [metric('R', 0.4)], 'A省'),
      observation('senior', 2021, [metric('R', 0.45)], 'B省'),
    ])
    const result = buildTrend(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { name: string }[]
      expect(series.map((s) => s.name)).toEqual(['初中'])
      expect(titleOf(result.option).subtext).toContain('高中')
    }
  })
})

describe('stageFromLabel —— 点击返回的是显示名，内部用的是标识', () => {
  it('把显示名映射回学段标识', () => {
    expect(stageFromLabel('初中')).toBe('junior')
    expect(stageFromLabel('小学一、二年级')).toBe('primary-1-2')
  })

  it('认不出的名字返回 null，而不是猜一个', () => {
    expect(stageFromLabel('幼儿园')).toBeNull()
    expect(stageFromLabel('')).toBeNull()
  })
})

describe('buildTrend 的下钻过滤', () => {
  const data = dataset([
    observation('junior', 2020, [metric('R', 0.5)]),
    observation('junior', 2021, [metric('R', 0.6)]),
    observation('senior', 2020, [metric('R', 0.4)]),
    observation('senior', 2021, [metric('R', 0.45)]),
    // 北京必须有两年以上数据：趋势至少需要两年，
    // 只给一年的话这条测试断言的其实是「数据不足时的拒绝行为」，
    // 而不是它想验证的「按学段分系列」。
    observation('junior', 2021, [metric('R', 0.9)], '北京'),
    observation('junior', 2022, [metric('R', 0.92)], '北京'),
    observation('senior', 2021, [metric('R', 0.8)], '北京'),
    observation('senior', 2022, [metric('R', 0.83)], '北京'),
  ])

  it('限定学段后只剩一条线', () => {
    const result = buildTrend(data, 'R', { kind: 'stage', stage: 'junior' })
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { name: string }[]
      expect(series.map((s) => s.name)).toEqual(['初中'])
      expect(titleOf(result.option).text).toContain('初中')
    }
  })

  it('限定地区后是该地区各学段的若干条线，而不是跨学段平均成一条', () => {
    // 跨学段求平均需要一套加权规则，而那种平均本身没有意义
    const result = buildTrend(data, 'R', { kind: 'region', region: '北京' })
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { name: string; data: (number | null)[] }[]
      expect(series.map((s) => s.name)).toEqual(['初中', '高中'])
      expect(titleOf(result.option).text).toContain('北京')
    }
  })

  it('下钻到某个省时，单条记录直接取值，不要求样本量', () => {
    // 曾经的实现无论什么情况都走 nationalValue（职责是「从分省值合成全国值」），
    // 于是要求每条记录带样本量才能加权 —— 而省份自己的记录本来就不该背这个要求。
    // 后果是**下钻到任何一个省都画不出趋势图**，而报错信息还指向「缺少样本量」，
    // 让人以为是数据问题。
    const data = dataset([
      observation('junior', 2021, [metric('R', 0.9)], '北京'),
      observation('junior', 2022, [metric('R', 0.92)], '北京'),
    ])
    const result = buildTrend(data, 'R', { kind: 'region', region: '北京' })
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { data: (number | null)[] }[]
      expect(series[0]?.data).toEqual([0.9, 0.92])
    }
  })

  it('同一地区同一学段同一年出现多条记录时拒绝，而不是随便取一条', () => {
    const data = dataset([
      observation('junior', 2021, [metric('R', 0.9)], '北京'),
      observation('junior', 2021, [metric('R', 0.5)], '北京'),
      observation('junior', 2022, [metric('R', 0.92)], '北京'),
    ])
    const result = buildTrend(data, 'R', { kind: 'region', region: '北京' })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('重复')
  })

  it('限定范围内没有数据时说明是哪个范围没有', () => {
    const result = buildTrend(data, 'R', { kind: 'region', region: '不存在的省' })
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.reason).toContain('不存在的省')
    }
  })

  it('不过滤时行为不变', () => {
    const filtered = buildTrend(data, 'R')
    expect(filtered.ok).toBe(true)
    if (filtered.ok) {
      const series = filtered.option.series as { name: string }[]
      expect(series.map((s) => s.name)).toEqual(['初中', '高中'])
      expect(titleOf(filtered.option).text).toBe('年度趋势')
    }
  })
})

describe('buildDistribution', () => {
  function regional(values: [string, number][]): MacroDataset {
    return dataset(
      values.map(([region, value]) => observation('junior', 2024, [metric('R', value)], region)),
    )
  }

  it('把省份值分箱', () => {
    const data = regional([
      ['A省', 0.1],
      ['B省', 0.15],
      ['C省', 0.5],
      ['D省', 0.9],
      ['E省', 0.95],
    ])
    const result = buildDistribution(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      // 逐项数据现在是 {value, itemStyle} 对象（为了给全国值所在的区间换色），
      // 不再是裸数字 —— 对对象求和会得到 NaN，而不是报错
      const series = result.option.series as { data: { value: number }[] }[]
      const bars = series[0]?.data ?? []
      expect(bars.reduce((sum, bar) => sum + bar.value, 0)).toBe(5)
    }
  })

  it('图注写明「每省一票」—— 分布图刻意不按样本量加权', () => {
    const data = regional([
      ['A省', 0.1],
      ['B省', 0.9],
    ])
    const result = buildDistribution(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(titleOf(result.option).subtext).toContain('每省一票')
    }
  })

  it('全国值存在时高亮它所在的区间，并在图注里给出确切数值', () => {
    // 直方图的横轴是分箱，画不了精确位置的参考线；高亮 + 图注数值是能做到的
    // 最诚实的表达。曾经这里只把全国值算出来写进图注，却没真的标在图上 ——
    // 类型检查不会发现，因为那个变量确实"被用到了"。
    const data = dataset([
      observation('junior', 2024, [metric('R', 0.62)]),
      observation('junior', 2024, [metric('R', 0.1)], 'A省'),
      observation('junior', 2024, [metric('R', 0.3)], 'B省'),
      observation('junior', 2024, [metric('R', 0.8)], 'C省'),
      observation('junior', 2024, [metric('R', 0.95)], 'D省'),
    ])
    const result = buildDistribution(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as {
        data: { value: number; itemStyle: { color: string } }[]
      }[]
      const bars = series[0]?.data ?? []
      const highlighted = bars.filter((bar) => bar.itemStyle.color !== '#4cc2ff')
      expect(highlighted).toHaveLength(1)
      expect(titleOf(result.option).subtext).toContain('全国值 0.62')
    }
  })

  it('没有全国汇总值时不在图上做任何标记', () => {
    const data = regional([
      ['A省', 0.1],
      ['B省', 0.9],
    ])
    const result = buildDistribution(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { data: { itemStyle: { color: string } }[] }[]
      const bars = series[0]?.data ?? []
      expect(bars.every((bar) => bar.itemStyle.color === '#4cc2ff')).toBe(true)
      expect(titleOf(result.option).subtext).toContain('没有全国汇总值')
    }
  })

  it('没有分省数据时拒绝，并说明分布图需要分省值', () => {
    const data = dataset([observation('junior', 2024, [metric('R', 0.5)])])
    const result = buildDistribution(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('分省')
  })

  it('所有省份取值相同时拒绝，并指出这通常是数据填错了', () => {
    const data = regional([
      ['A省', 0.62],
      ['B省', 0.62],
      ['C省', 0.62],
    ])
    const result = buildDistribution(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.reason).toContain('完全相同')
      expect(result.reason).toContain('全国汇总')
    }
  })

  it('指定年份没有分省数据时拒绝', () => {
    const data = regional([['A省', 0.1]])
    const result = buildDistribution(data, 'R', 2019)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('2019')
  })
})

describe('buildRegionHeatmap', () => {
  function regional(values: [string, number][], year = 2024): MacroDataset {
    return dataset(
      values.map(([region, value]) => observation('junior', year, [metric('R', value)], region)),
    )
  }

  it('把数据按省名喂给地图系列', () => {
    const data = regional([
      ['北京', 0.7],
      ['广东', 0.6],
    ])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { type: string; map: string; data: unknown[] }[]
      expect(series[0]?.type).toBe('map')
      expect(series[0]?.map).toBe('china')
      expect(series[0]?.data).toEqual([
        { name: '北京', value: 0.7 },
        { name: '广东', value: 0.6 },
      ])
    }
  })

  it('省份名称先归一化 —— 否则地图上那些省是灰的且不报错', () => {
    // 数据里可能写全称（从别的报告抄来的），而地图要素注册后是简称
    const data = regional([
      ['北京市', 0.7],
      ['广东省', 0.6],
      ['内蒙古自治区', 0.5],
    ])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const series = result.option.series as { data: { name: string }[] }[]
      expect(series[0]?.data.map((d) => d.name)).toEqual(['北京', '广东', '内蒙古'])
    }
  })

  it('色阶范围取自数据本身', () => {
    const data = regional([
      ['北京', 0.7],
      ['甘肃', 0.45],
    ])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const visualMap = result.option.visualMap as { min: number; max: number }
      expect(visualMap.min).toBeCloseTo(0.45, 10)
      expect(visualMap.max).toBeCloseTo(0.7, 10)
    }
  })

  it('默认取最新年份，也可指定', () => {
    const data = dataset([
      observation('junior', 2020, [metric('R', 0.2)], '北京'),
      observation('junior', 2020, [metric('R', 0.8)], '广东'),
      observation('junior', 2024, [metric('R', 0.6)], '北京'),
      observation('junior', 2024, [metric('R', 0.5)], '广东'),
    ])
    const latest = buildRegionHeatmap(data, 'R')
    expect(latest.ok).toBe(true)
    if (latest.ok) {
      expect(titleOf(latest.option).text).toContain('2024')
    }

    const older = buildRegionHeatmap(data, 'R', 2020)
    expect(older.ok).toBe(true)
    if (older.ok) {
      const series = older.option.series as { data: { value: number }[] }[]
      expect(series[0]?.data[0]?.value).toBeCloseTo(0.2, 10)
    }
  })

  it('没有分省数据时拒绝，并说明地图需要分省值', () => {
    const data = dataset([observation('junior', 2024, [metric('R', 0.5)])])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('省际分布')
  })

  it('所有省份取值相同时拒绝 —— 一片同色看不出分布', () => {
    const data = regional([
      ['北京', 0.62],
      ['广东', 0.62],
    ])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.reason).toContain('一片同色')
      expect(result.reason).toContain('全国汇总')
    }
  })

  it('重复记录同样拒绝（与其它视图一致）', () => {
    const data = dataset([
      observation('junior', 2024, [metric('R', 0.2)], '北京'),
      observation('junior', 2024, [metric('R', 0.8)], '北京'),
    ])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('重复')
  })

  it('容器比柱状图高（地图占地方）', () => {
    const data = regional([
      ['北京', 0.7],
      ['广东', 0.6],
    ])
    const result = buildRegionHeatmap(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.height).toBeGreaterThan(360)
  })
})

describe('buildRegionRanking', () => {
  it('按数值降序排列', () => {
    const data = dataset([
      observation('junior', 2024, [metric('R', 0.3)], 'A省'),
      observation('junior', 2024, [metric('R', 0.9)], 'B省'),
      observation('junior', 2024, [metric('R', 0.6)], 'C省'),
    ])
    const result = buildRegionRanking(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      const axis = result.option.yAxis as { data: string[] }
      expect(axis.data).toEqual(['B省', 'C省', 'A省'])
    }
  })

  it('默认取最新年份', () => {
    const data = dataset([
      observation('junior', 2020, [metric('R', 0.3)], 'A省'),
      observation('junior', 2024, [metric('R', 0.9)], 'B省'),
    ])
    const result = buildRegionRanking(data, 'R')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(titleOf(result.option).text).toContain('2024')
      const axis = result.option.yAxis as { data: string[] }
      expect(axis.data).toEqual(['B省'])
    }
  })

  it('可以指定年份', () => {
    const data = dataset([
      observation('junior', 2020, [metric('R', 0.3)], 'A省'),
      observation('junior', 2024, [metric('R', 0.9)], 'B省'),
    ])
    const result = buildRegionRanking(data, 'R', 2020)
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(titleOf(result.option).text).toContain('2020')
    }
  })

  it('没有分省数据时拒绝，并指路到学段概览', () => {
    const data = dataset([observation('junior', 2024, [metric('R', 0.5)])])
    const result = buildRegionRanking(data, 'R')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('学段概览')
  })

  it('指定年份没有数据时拒绝', () => {
    const data = dataset([observation('junior', 2024, [metric('R', 0.5)], 'A省')])
    const result = buildRegionRanking(data, 'R', 2019)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason).toContain('2019')
  })
})
