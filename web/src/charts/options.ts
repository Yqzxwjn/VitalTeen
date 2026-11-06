/**
 * 图表配置构造。
 *
 * **纯函数，不碰 DOM，不碰 ECharts 实例。** 这样测试可以在 jsdom 里秒跑，
 * 而真正的逻辑 —— 数据筛选、聚合、排序、空值处理 —— 全在这里。
 * ECharts 的渲染只是末尾一步，渲染错了肉眼能看出来，而聚合错了画出来很像对的。
 *
 * 每个构造器返回 :type:`ChartResult` 而不是直接返回 option：
 * 「这个指标没有数据」是一个**要显示的结论**，不是一个异常，也不是一张空图。
 * 用 `null` 表达会让调用方容易忘记处理。
 */

import type { EChartsOption } from 'echarts'

import type { MacroDataset, MetricRecord, Observation, SchoolStage } from '@/data/types'
import { STAGE_LABELS } from '@/data/types'
import { CHINA_MAP_NAME, normalizeRegion } from './regions'

export type ChartResult =
  | { ok: true; option: EChartsOption; height?: number }
  | { ok: false; reason: string }

/**
 * ``height`` 是**布局**信息，不放进 ``EChartsOption``。
 *
 * 曾经把它当作一个自定义键塞进 option 里、再用 ``as`` 断言绕过类型检查 ——
 * 类型是过了，但 ECharts 对不认识的键**静默忽略**，那个高度从未生效。
 * 用断言盖住问题比报错更糟：报错会逼你面对，断言只是让你以为没事。
 */

/** 打平后的一条观测。 */
interface Sample {
  stage: SchoolStage
  year: number
  region?: string
  metric: MetricRecord
}

const STAGE_ORDER: readonly string[] = STAGE_LABELS.map((item) => item.stage)
const STAGE_NAME = new Map(STAGE_LABELS.map((item) => [item.stage, item.label]))

/** 学段标识 → 显示名。下钻标签与图注都要用，因此对外导出，避免各写一份映射。 */
export function stageLabel(stage: SchoolStage): string {
  return STAGE_NAME.get(stage) ?? stage
}

/**
 * 找出重复记录，返回人类可读的描述。
 *
 * 键是「学段 + 年份 + 地区」：分省数据里同一个 (学段, 年份) 本来就有多个地区，
 * 那是正常的；**同一个地区出现两条**才是重复。
 */
function findDuplicates(samples: Sample[]): string[] {
  const counts = new Map<string, number>()
  for (const sample of samples) {
    const scope = sample.region === undefined ? '全国' : sample.region
    const key = `${stageLabel(sample.stage)} ${sample.year} 年（${scope}）`
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  return [...counts].filter(([, count]) => count > 1).map(([key]) => key)
}

const MAX_REPORTED_DUPLICATES = 3

/**
 * 有重复记录就拒绝绘图。
 *
 * **必须把「数据缺失」与「数据有错」分开。** 两者在图上都是缺口，长得一模一样 ——
 * 曾经重复记录被静默转成一个断点，用户看到的是一条有洞的线，
 * 而洞的原因（数据重复）完全不可见。
 *
 * 缺失是覆盖问题（那条线本来就该断），重复是数据错误（那条线不该存在两条）。
 * 后者要修数据，不是画图时能绕过去的。
 */
function rejectDuplicates(samples: Sample[], label: string): ChartResult | null {
  const duplicates = findDuplicates(samples)
  if (duplicates.length === 0) return null

  const shown = duplicates.slice(0, MAX_REPORTED_DUPLICATES)
  const more = duplicates.length > shown.length ? ` 等 ${duplicates.length} 处` : ''
  return {
    ok: false,
    reason:
      `${label}存在重复记录（同一学段、年份、地区出现多条）：${shown.join('、')}${more}。` +
      '这是数据错误而不是缺失 —— 图上的缺口会被误读成「那年没测」，' +
      '所以这里直接拒绝绘图，请先修正数据。',
  }
}

function flatten(dataset: MacroDataset, code?: string): Sample[] {
  const out: Sample[] = []
  for (const observation of dataset.observations) {
    for (const metric of observation.metrics) {
      if (code !== undefined && metric.code !== code) continue
      // exactOptionalPropertyTypes 下不能显式赋 undefined，只能按存在与否构造
      const sample: Sample = { stage: observation.stage, year: observation.year, metric }
      if (observation.region !== undefined) sample.region = observation.region
      out.push(sample)
    }
  }
  return out
}

/** 数据集里出现过的全部指标，按代码去重，保留首次出现的名称。 */
export function availableMetrics(dataset: MacroDataset): { code: string; name: string }[] {
  const seen = new Map<string, string>()
  for (const observation of dataset.observations) {
    for (const metric of observation.metrics) {
      if (!seen.has(metric.code)) seen.set(metric.code, metric.name)
    }
  }
  return [...seen].map(([code, name]) => ({ code, name }))
}

/** 数据集里出现过的年份，升序。 */
export function availableYears(dataset: MacroDataset): number[] {
  return [...new Set(dataset.observations.map((o) => o.year))].sort((a, b) => a - b)
}

/** 下钻过滤：把视图限定到某个学段或某个地区。 */
export type TrendFilter =
  | { kind: 'stage'; stage: SchoolStage }
  | { kind: 'region'; region: string }

/**
 * 从显示名反查学段。
 *
 * 图表点击拿到的是轴上的类目名（「初中」），而内部标识是 `junior`。
 * 这层映射必须有，否则下钻要把展示文本当键用 —— 那会在改文案时静默失效。
 */
export function stageFromLabel(label: string): SchoolStage | null {
  for (const item of STAGE_LABELS) {
    if (item.label === label) return item.stage
  }
  return null
}

function matchesFilter(sample: Sample, filter: TrendFilter | undefined): boolean {
  if (filter === undefined) return true
  return filter.kind === 'stage' ? sample.stage === filter.stage : sample.region === filter.region
}

function describeFilter(filter: TrendFilter): string {
  return filter.kind === 'stage' ? stageLabel(filter.stage) : filter.region
}

/**
 * 把一组分省观测合成一个全国值。
 *
 * **不做未加权的省份平均。** 各省的抽测样本量差异很大，直接平均等于假设
 * 「北京和西藏权重相同」，得出的数字没有意义 —— 而它在图上看起来和真值一样。
 *
 * 优先用数据里已有的全国汇总行；没有时，只有在**每一行都带样本量**的前提下
 * 才按样本量加权，并在图上注明。两条都不满足就拒绝，并说清缺什么。
 */
export function nationalValue(
  samples: Sample[],
): { ok: true; value: number; weighted: boolean } | { ok: false; reason: string } {
  const nationwide = samples.filter((s) => s.region === undefined)
  if (nationwide.length > 1) {
    return { ok: false, reason: '同一学段与年份出现了多条全国汇总记录，数据存在重复' }
  }

  const only = nationwide.at(0)
  if (only !== undefined) {
    return { ok: true, value: only.metric.value, weighted: false }
  }

  if (samples.length === 0) return { ok: false, reason: '没有数据' }

  const allSized = samples.every((s) => typeof s.metric.sampleSize === 'number' && s.metric.sampleSize > 0)
  if (!allSized) {
    return {
      ok: false,
      reason:
        '该指标只有分省数据，且缺少样本量，无法合成全国值。' +
        '未加权的省份平均会得出一个没有意义的数字，因此不做这种合成。',
    }
  }

  let weightedSum = 0
  let totalWeight = 0
  for (const sample of samples) {
    const weight = sample.metric.sampleSize ?? 0
    weightedSum += sample.metric.value * weight
    totalWeight += weight
  }
  return totalWeight > 0
    ? { ok: true, value: weightedSum / totalWeight, weighted: true }
    : { ok: false, reason: '样本量合计为 0' }
}

/**
 * 一组样本的代表值。
 *
 * **区分「取一个实体的值」与「把多个实体合成一个值」** —— 这两件事用同一套规则
 * 处理会出问题。
 *
 * 视图已经限定到某个地区时，一组里应当只有一条记录，它的值就是答案。
 * 曾经这里无论什么情况都走 :func:`nationalValue`，而那个函数的职责是
 * 「从分省值合成全国值」，所以它要求每条记录带样本量才能加权 ——
 * 于是**下钻到任何一个省都画不出趋势图**，因为省份自己的记录本来就不带全国口径的
 * 样本量要求。
 */
function resolveValue(
  samples: Sample[],
  scopedToRegion: boolean,
): { ok: true; value: number } | { ok: false; reason: string } {
  if (!scopedToRegion) return nationalValue(samples)

  if (samples.length === 1) {
    const only = samples[0]
    return only === undefined
      ? { ok: false, reason: '没有数据' }
      : { ok: true, value: only.metric.value }
  }
  return {
    ok: false,
    reason: `同一学段与年份有 ${samples.length} 条记录，数据存在重复`,
  }
}

/** 学段概览：最新一年里各学段的该指标对比。 */
export function buildStageOverview(dataset: MacroDataset, code: string): ChartResult {
  const all = flatten(dataset, code)
  if (all.length === 0) {
    return { ok: false, reason: `数据集里没有指标 ${code}` }
  }
  const duplicateFailure = rejectDuplicates(all, `指标 ${code} 的`)
  if (duplicateFailure !== null) return duplicateFailure

  const latestYear = Math.max(...all.map((s) => s.year))
  const ofYear = all.filter((s) => s.year === latestYear)

  const missing: string[] = []
  const weighted: string[] = []
  const rows: { label: string; value: number }[] = []

  for (const stage of STAGE_ORDER) {
    const group = ofYear.filter((s) => s.stage === stage)
    if (group.length === 0) {
      missing.push(stageLabel(stage as SchoolStage))
      continue
    }
    const national = nationalValue(group)
    if (!national.ok) {
      missing.push(`${stageLabel(stage as SchoolStage)}（${national.reason}）`)
      continue
    }
    if (national.weighted) weighted.push(stageLabel(stage as SchoolStage))
    rows.push({ label: stageLabel(stage as SchoolStage), value: national.value })
  }

  if (rows.length === 0) {
    return { ok: false, reason: `${latestYear} 年没有可用的学段数据：${missing.join('；')}` }
  }

  const notes: string[] = []
  if (weighted.length > 0) notes.push(`${weighted.join('、')} 按样本量加权合成`)
  if (missing.length > 0) notes.push(`缺少：${missing.join('、')}`)

  return {
    ok: true,
    option: {
      title: {
        text: `${latestYear} 年各学段对比`,
        subtext: notes.join('；'),
        left: 0,
        textStyle: { fontSize: 14 },
        subtextStyle: { fontSize: 11, color: '#8b949e' },
      },
      grid: { left: 100, right: 60, top: 60, bottom: 24 },
      tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' } },
      xAxis: { type: 'value', axisLabel: { formatter: (v: number) => v.toFixed(2) } },
      yAxis: {
        type: 'category',
        inverse: true,
        data: rows.map((r) => r.label),
      },
      series: [
        {
          type: 'bar',
          data: rows.map((r) => r.value),
          label: { show: true, position: 'right', formatter: '{c}' },
          itemStyle: { color: '#4cc2ff' },
        },
      ],
    },
  }
}

/**
 * 年度趋势：某指标逐年变化，按学段分系列。
 *
 * **年份轴取自当前范围内出现过的全部年份。** 不加 ``filter`` 时是「数据集里
 * 出现过的年份」，下钻时是「该范围内出现过的年份」。两种情况语义一致：
 * 轴上的每一年都至少有一条线有值，不会被空白年份撑开。
 *
 * 由此推出一个不显然的后果：**一个学段的「缺口」只在同一范围内别的学段提供了
 * 那一年时才显现**。若某年该范围整体没有数据，那一年不会出现在轴上 ——
 * 那不是缺口，是没覆盖。测试里有一条专门锁住它。
 */
export function buildTrend(
  dataset: MacroDataset,
  code: string,
  filter?: TrendFilter,
): ChartResult {
  const all = flatten(dataset, code).filter((sample) => matchesFilter(sample, filter))
  if (all.length === 0) {
    return {
      ok: false,
      reason:
        filter === undefined
          ? `数据集里没有指标 ${code}`
          : `指标 ${code} 在「${describeFilter(filter)}」范围内没有数据`,
    }
  }
  const duplicateFailure = rejectDuplicates(all, `指标 ${code} 的`)
  if (duplicateFailure !== null) return duplicateFailure

  const years = [...new Set(all.map((s) => s.year))].sort((a, b) => a - b)
  if (years.length < 2) {
    return {
      ok: false,
      reason: `${years.length} 个年份的数据画不出趋势 —— 趋势至少需要两年。`,
    }
  }

  const series: { name: string; data: (number | null)[] }[] = []
  const skipped: string[] = []
  // 限定到地区时，每个分组指向一个具体实体，取值规则与「合成全国值」不同
  const scopedToRegion = filter?.kind === 'region'

  for (const stage of STAGE_ORDER) {
    const forStage = all.filter((s) => s.stage === stage)
    if (forStage.length === 0) continue

    const data = years.map((year) => {
      const group = forStage.filter((s) => s.year === year)
      if (group.length === 0) return null // 该年无数据：留空，不插值也不填 0
      const resolved = resolveValue(group, scopedToRegion)
      return resolved.ok ? resolved.value : null
    })

    if (data.every((v) => v === null)) {
      skipped.push(stageLabel(stage as SchoolStage))
      continue
    }
    series.push({ name: stageLabel(stage as SchoolStage), data })
  }

  if (series.length === 0) {
    return { ok: false, reason: '所有学段都因缺少数据或样本量而无法合成趋势值' }
  }

  return {
    ok: true,
    option: {
      title: {
        text: filter === undefined ? '年度趋势' : `年度趋势 · ${describeFilter(filter)}`,
        subtext: skipped.length > 0 ? `已跳过（无可用数据）：${skipped.join('、')}` : '',
        left: 0,
        textStyle: { fontSize: 14 },
        subtextStyle: { fontSize: 11, color: '#8b949e' },
      },
      grid: { left: 56, right: 24, top: 60, bottom: 40 },
      tooltip: { trigger: 'axis' },
      legend: { bottom: 0, textStyle: { color: '#8b949e' } },
      // connectNulls 保持关闭：缺哪一年就断在哪一年，
      // 把两点直连会让人以为中间年份是插值出来的
      xAxis: { type: 'category', data: years.map(String), boundaryGap: false },
      yAxis: { type: 'value' },
      series: series.map((s) => ({ ...s, type: 'line' as const, connectNulls: false })),
    },
  }
}

/** 地区分布：某一年的各省排序。用横向柱而非地图，避免额外的 GeoJSON 依赖。 */
export function buildRegionRanking(
  dataset: MacroDataset,
  code: string,
  year?: number,
): ChartResult {
  const all = flatten(dataset, code).filter((s) => s.region !== undefined)
  if (all.length === 0) {
    return {
      ok: false,
      reason: `指标 ${code} 没有分省数据。若只有全国汇总，请用学段概览视图。`,
    }
  }
  const duplicateFailure = rejectDuplicates(all, `指标 ${code} 的`)
  if (duplicateFailure !== null) return duplicateFailure

  const targetYear = year ?? Math.max(...all.map((s) => s.year))
  const rows = all
    .filter((s) => s.year === targetYear)
    .map((s) => ({ label: s.region ?? '未标注', value: s.metric.value }))
    .sort((a, b) => b.value - a.value)

  if (rows.length === 0) {
    return { ok: false, reason: `${targetYear} 年没有分省数据` }
  }

  // 省份多时容器要够高，否则标签会挤成一团
  const height = Math.max(240, rows.length * 22 + 80)
  return {
    ok: true,
    height,
    option: {
      title: { text: `${targetYear} 年分省对比`, left: 0, textStyle: { fontSize: 14 } },
      grid: { left: 80, right: 60, top: 44, bottom: 24 },
      tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' } },
      xAxis: { type: 'value' },
      yAxis: {
        type: 'category',
        inverse: true,
        data: rows.map((r) => r.label),
        axisLabel: { fontSize: 11 },
      },
      series: [
        {
          type: 'bar',
          data: rows.map((r) => r.value),
          label: { show: true, position: 'right', fontSize: 10, formatter: '{c}' },
          itemStyle: { color: '#3fb950' },
        },
      ],
    },
  }
}

/**
 * 地图热力图：某一年各省份的指标分布。
 *
 * 与分省排名看的是同一份数据，但回答的问题不同：**排名看「谁高谁低」，
 * 地图看「高低在地理上怎么连片」** —— 沿海与内陆有没有分界、是连片还是零散，
 * 这些在柱状图里看不出来。
 *
 * **前置条件：地图必须已经用 :func:`~@/data/mapLoader.registerChinaMap` 注册过。**
 * 未注册时 ECharts 会画一张空白地图**且不报错** —— 所以这个前置条件不能靠
 * 「应该注册了」来保证，得由 App 层在渲染前确认（地图数据是异步加载的）。
 *
 * 省名会先过 :func:`normalizeRegion`：地图要素是「北京市」、数据里常是「北京」，
 * 不对齐的省份会是灰的，同样不报错。
 */
export function buildRegionHeatmap(
  dataset: MacroDataset,
  code: string,
  year?: number,
): ChartResult {
  const all = flatten(dataset, code)
  const regional = all.filter((s) => s.region !== undefined)
  if (regional.length === 0) {
    return {
      ok: false,
      reason: `指标 ${code} 没有分省数据，画不出地图。地图看的是省际分布，需要分省值。`,
    }
  }
  const duplicateFailure = rejectDuplicates(regional, `指标 ${code} 的`)
  if (duplicateFailure !== null) return duplicateFailure

  const targetYear = year ?? Math.max(...regional.map((s) => s.year))
  const ofYear = regional.filter((s) => s.year === targetYear)
  if (ofYear.length === 0) {
    return { ok: false, reason: `${targetYear} 年没有分省数据` }
  }

  const values = ofYear.map((s) => s.metric.value)
  const min = Math.min(...values)
  const max = Math.max(...values)

  // 所有省份一个值：色阶没有跨度，整张图一个颜色，看不出任何东西
  if (min === max) {
    return {
      ok: false,
      reason:
        `${targetYear} 年所有地区的 ${code} 取值完全相同（${min}），` +
        '地图上会是一片同色的色块，看不出分布。' +
        '这通常意味着数据把全国汇总值填进了每一行分省记录。',
    }
  }

  const kind = ofYear[0]?.metric.kind
  const scaleNote = kind === 'rate' ? '达标率（0–1）' : (ofYear[0]?.metric.unit ?? '')

  return {
    ok: true,
    // 地图比柱状图占地方，给它更高的容器
    height: 520,
    option: {
      title: {
        text: `${targetYear} 年分省分布`,
        subtext: `${scaleNote}；没有颜色的省份表示数据集中缺该地区`,
        left: 0,
        textStyle: { fontSize: 14 },
        subtextStyle: { fontSize: 11, color: '#8b949e' },
      },
      tooltip: {
        trigger: 'item',
        formatter: '{b}<br/>{c}',
      },
      visualMap: {
        min,
        max,
        left: 8,
        bottom: 8,
        text: ['高', '低'],
        calculable: true,
        inRange: { color: ['#17324d', '#1f6feb', '#4cc2ff', '#a5e9ff'] },
        textStyle: { color: '#8b949e', fontSize: 11 },
      },
      series: [
        {
          type: 'map',
          map: CHINA_MAP_NAME,
          roam: false,
          label: { show: false },
          emphasis: {
            label: { show: true, fontSize: 11, color: '#0d1117' },
            itemStyle: { areaColor: '#d29922' },
          },
          // 底色比背景稍亮：既区别于「有数据但值低」，也不至于看不见省界
          itemStyle: { areaColor: '#161b22', borderColor: '#2a323d', borderWidth: 0.6 },
          data: ofYear.map((s) => ({
            name: normalizeRegion(s.region ?? ''),
            value: s.metric.value,
          })),
        },
      ],
    },
  }
}

/**
 * 指标分布：某一年的**分省值**分布。
 *
 * 用途与分省排名不同：排名看的是「谁高谁低」，分布看的是「差距有多大」。
 * 一个达标率 0.62 的全国均值背后，可能是各省都在 0.60–0.64 之间，
 * 也可能是从 0.40 到 0.85 一字排开 —— 这两种情况意味着完全不同的政策含义。
 *
 * **不按样本量加权**：这里每一根柱子代表一个省份，是有意为之。
 * 加权会把样本量大的省份放大成「多个省」，那就不再是「省际差异」了。
 * 因此图注里会写明「每省一票」。
 *
 * 全国值**以高亮所在区间的方式标出，而不是画参考线**：直方图的横轴是分箱而非
 * 连续数值，一条线只能落在箱子边界上，位置本身就是近似的。高亮 + 图注给出确切
 * 数值，比一条位置含混的线诚实。
 */
export function buildDistribution(
  dataset: MacroDataset,
  code: string,
  year?: number,
): ChartResult {
  // 保留全体样本：分省值用来分箱，而全国汇总值要从包含全国行的全体里找
  const all = flatten(dataset, code)
  const regional = all.filter((s) => s.region !== undefined)
  if (regional.length === 0) {
    return {
      ok: false,
      reason: `指标 ${code} 没有分省数据，画不出分布。分布图看的是省际差异，需要分省值。`,
    }
  }
  // 重复记录会让同一根柱子被数两次，直方图的形状直接失真
  const duplicateFailure = rejectDuplicates(regional, `指标 ${code} 的`)
  if (duplicateFailure !== null) return duplicateFailure

  const targetYear = year ?? Math.max(...regional.map((s) => s.year))
  const ofYear = regional.filter((s) => s.year === targetYear)
  if (ofYear.length === 0) {
    return { ok: false, reason: `${targetYear} 年没有分省数据` }
  }

  const values = ofYear.map((s) => s.metric.value)
  const min = Math.min(...values)
  const max = Math.max(...values)

  if (min === max) {
    // 所有省一个值 —— 这通常意味着数据把全国汇总填进了每一行，
    // 而不是各省真的完全一致。说出来比画一根柱子有用。
    return {
      ok: false,
      reason:
        `${targetYear} 年所有地区的 ${code} 取值完全相同（${min}），分布图没有信息量。` +
        '这通常意味着数据把全国汇总值填进了每一行分省记录，而不是各省真的相同。',
    }
  }

  // 分箱数随省份数量走，但控制在 4–10 之间：
  // 太少看不出形状，太多则大部分箱子是空的，反而更难读
  const binCount = Math.min(10, Math.max(4, Math.round(Math.sqrt(ofYear.length))))
  const width = (max - min) / binCount
  const counts = new Array<number>(binCount).fill(0)
  for (const value of values) {
    const index = Math.min(binCount - 1, Math.floor((value - min) / width))
    counts[index] = (counts[index] ?? 0) + 1
  }

  const labels = counts.map((_, index) => {
    const low = min + index * width
    return `${low.toFixed(2)}–${(low + width).toFixed(2)}`
  })

  // 全国汇总值必须从**包含全国行的全体样本**里找。
  // ofYear 是从 regional 派生的，而 regional 已经筛掉了全国行 —— 在那里找
  // 按构造就不可能找到，图注会一直说「没有全国汇总值」，哪怕数据里明明有。
  const national = nationalValue(
    all.filter((s) => s.year === targetYear && s.region === undefined),
  )
  const nationalBin = national.ok
    ? Math.min(binCount - 1, Math.floor((national.value - min) / width))
    : -1

  const notes = [`共 ${ofYear.length} 个地区，每省一票（未按样本量加权）`]
  if (national.ok) {
    notes.push(`全国值 ${national.value.toFixed(2)} 落在第 ${nationalBin + 1} 个区间（已高亮）`)
  } else {
    notes.push('数据集中没有全国汇总值，无法标出全国所在位置')
  }

  return {
    ok: true,
    option: {
      title: {
        text: `${targetYear} 年分省分布`,
        subtext: notes.join('；'),
        left: 0,
        textStyle: { fontSize: 14 },
        subtextStyle: { fontSize: 11, color: '#8b949e' },
      },
      grid: { left: 56, right: 24, top: 64, bottom: 56 },
      tooltip: {
        trigger: 'axis',
        axisPointer: { type: 'shadow' },
        formatter: '{b}<br/>{c} 个地区',
      },
      xAxis: {
        type: 'category',
        data: labels,
        axisLabel: { fontSize: 10, rotate: 30 },
      },
      yAxis: { type: 'value', name: '地区数', nameTextStyle: { fontSize: 11 } },
      series: [
        {
          type: 'bar',
          // 逐项配色：全国值所在的区间换一个颜色。系列级 itemStyle 会被逐项覆盖，
          // 因此这里不再写系列级的默认色。
          data: counts.map((count, index) => ({
            value: count,
            itemStyle: { color: index === nationalBin ? '#d29922' : '#4cc2ff' },
          })),
          label: { show: true, position: 'top', fontSize: 10 },
        },
      ],
    },
  }
}

export type { Observation }
