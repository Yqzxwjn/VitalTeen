/**
 * 宏观数据集的加载与校验。
 *
 * 这个模块的核心职责不是「把 JSON 读进来」，而是**把关**：
 *
 * - 没有完整出处的数据不许进页面（`provenance` 缺任何一项即拒绝）
 * - 空数据集与「没有数据」等价，不许当成「全都达标」来画
 * - `rate` 口径的数值必须在 0–1 之间
 *
 * 前两条是合规与诚实问题，第三条是数据质量问题。第三条尤其值得说：
 * 把百分比写成 `85` 而不是 `0.85` 是这类数据最常见的录入错误，
 * 而 ECharts 会照画不误 —— 一张「达标率 8500%」的图在答辩现场是灾难。
 * 与其指望人眼在图上发现，不如让它在加载时就进不来。
 */

import type { MacroDataset, MetricRecord, Observation, Provenance } from './types'
import { SCHEMA_VERSION, STAGE_LABELS } from './types'

/** 默认数据文件位置。放在 `public/` 下，构建后原样拷贝进 `dist/`。 */
export const DEFAULT_DATASET_URL = 'data/macro-dataset.json'

/** 出处声明里每一项都必须有值，且给出中文名以便报错时能看懂。 */
const REQUIRED_PROVENANCE: ReadonlyArray<readonly [keyof Provenance, string]> = [
  ['title', '数据集名称'],
  ['publisher', '发布机构'],
  ['publishedYear', '发布年份'],
  ['url', '可核验链接'],
  ['license', '引用许可'],
  ['coverage', '覆盖范围'],
]

const KNOWN_STAGES = new Set<string>(STAGE_LABELS.map((item) => item.stage))

function majorOf(version: string): string {
  return version.split('.')[0] ?? ''
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function checkProvenance(raw: unknown, errors: string[]): void {
  if (!isPlainObject(raw)) {
    errors.push('缺少 provenance —— 没有出处的统计数据不允许展示')
    return
  }
  for (const [field, label] of REQUIRED_PROVENANCE) {
    const value = raw[field]
    if (value === undefined || value === null || value === '') {
      errors.push(`provenance 缺少「${label}」（字段 ${field}）`)
    }
  }
  const year = raw['publishedYear']
  if (typeof year === 'number' && (year < 1900 || year > 2100)) {
    errors.push(`provenance.publishedYear 不合理：${year}`)
  }
}

function checkMetric(raw: unknown, where: string, errors: string[]): void {
  if (!isPlainObject(raw)) {
    errors.push(`${where} 不是对象`)
    return
  }
  const code = raw['code']
  const name = raw['name']
  const value = raw['value']
  const kind = raw['kind']

  if (typeof code !== 'string' || code === '') errors.push(`${where} 缺少 code`)
  if (typeof name !== 'string' || name === '') errors.push(`${where} 缺少 name`)
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    errors.push(`${where} 的 value 不是有限数值`)
    return
  }
  if (kind !== 'rate' && kind !== 'mean' && kind !== 'index') {
    errors.push(`${where} 的 kind 非法：${String(kind)}`)
    return
  }
  if (kind === 'rate' && (value < 0 || value > 1)) {
    errors.push(
      `${where} 的 rate 口径取值应在 0–1 之间，实际为 ${value}。` +
        '若原始数据是百分数（如 85 表示 85%），请先除以 100。',
    )
  }
}

function checkObservation(raw: unknown, index: number, errors: string[]): void {
  const where = `observations[${index}]`
  if (!isPlainObject(raw)) {
    errors.push(`${where} 不是对象`)
    return
  }
  const stage = raw['stage']
  if (typeof stage !== 'string' || !KNOWN_STAGES.has(stage)) {
    errors.push(`${where} 的 stage 非法：${String(stage)}`)
  }
  const year = raw['year']
  if (typeof year !== 'number' || !Number.isInteger(year) || year < 1900 || year > 2100) {
    errors.push(`${where} 的 year 不合理：${String(year)}`)
  }
  const metrics = raw['metrics']
  if (!Array.isArray(metrics)) {
    errors.push(`${where} 的 metrics 应当是数组`)
    return
  }
  if (metrics.length === 0) {
    errors.push(`${where} 的 metrics 为空 —— 没有指标可画`)
  }
  metrics.forEach((metric, i) => checkMetric(metric, `${where}.metrics[${i}]`, errors))
}

/**
 * 校验原始数据。返回错误列表，空数组表示通过。
 *
 * **不抛异常**：调用方需要拿到全部问题一次性展示给填数据的人，
 * 一条一条地报错会让人来回改很多轮。
 */
export function validate(raw: unknown): string[] {
  const errors: string[] = []

  if (!isPlainObject(raw)) {
    return ['顶层应当是一个对象']
  }

  const version = raw['schemaVersion']
  if (typeof version !== 'string' || version === '') {
    errors.push('缺少 schemaVersion')
  } else if (majorOf(version) !== majorOf(SCHEMA_VERSION)) {
    errors.push(
      `数据格式版本不兼容：文件为 ${version}，当前支持 ${SCHEMA_VERSION}。` +
        '大版本不同意味着字段语义可能已变，不做兼容猜测。',
    )
  }

  checkProvenance(raw['provenance'], errors)

  const observations = raw['observations']
  if (!Array.isArray(observations)) {
    errors.push('observations 应当是数组')
    return errors
  }
  if (observations.length === 0) {
    errors.push(
      'observations 为空 —— 空数据集与「数据未接入」没有区别，' +
        '与其放一个空文件，不如不放文件，让页面如实说明。',
    )
  }
  observations.forEach((item, index) => checkObservation(item, index, errors))

  return errors
}

/** 缺数据时给出的可操作提示。这段文字会直接显示在页面上。 */
export const MISSING_DATA_HINT = [
  `请把宏观数据集放到 public/${DEFAULT_DATASET_URL}。`,
  '文件需要包含 schemaVersion、provenance（数据集名称、发布机构、发布年份、',
  '可核验链接、引用许可、覆盖范围）与 observations 三个部分。',
  '',
  '出处信息是必填的：本页面展示的是外部统计数据，不是本平台产生的结果。',
  '一个无法溯源的数字在答辩现场经不起一句「这个数据哪来的」。',
].join('\n')

/** 从已解析的对象构造结果。 */
export function fromRaw(raw: unknown, url = DEFAULT_DATASET_URL): LoadResultShape {
  const errors = validate(raw)
  if (errors.length > 0) {
    return { status: 'invalid', path: url, errors }
  }
  return { status: 'ok', dataset: raw as MacroDataset }
}

type LoadResultShape =
  | { status: 'ok'; dataset: MacroDataset }
  | { status: 'invalid'; path: string; errors: string[] }

/**
 * 从 URL 加载数据集。
 *
 * 文件不存在（404）与文件不合法被区分对待：前者是「还没接入数据」，
 * 后者是「接进来的数据有问题」。这两种情况对使用者要说不同的话。
 */
export async function loadFrom(
  url: string = DEFAULT_DATASET_URL,
  fetchImpl: typeof fetch = fetch,
): Promise<import('./types').LoadResult> {
  let response: Response
  try {
    response = await fetchImpl(url, { cache: 'no-cache' })
  } catch (error) {
    return {
      status: 'invalid',
      path: url,
      errors: [`读取数据文件失败：${error instanceof Error ? error.message : String(error)}`],
    }
  }

  if (response.status === 404) {
    return { status: 'missing', path: url, hint: MISSING_DATA_HINT }
  }
  if (!response.ok) {
    return { status: 'invalid', path: url, errors: [`数据文件返回 HTTP ${response.status}`] }
  }

  let raw: unknown
  try {
    raw = await response.json()
  } catch (error) {
    return {
      status: 'invalid',
      path: url,
      errors: [`数据文件不是合法 JSON：${error instanceof Error ? error.message : String(error)}`],
    }
  }

  return fromRaw(raw, url)
}

export type { MetricRecord, Observation, Provenance }
