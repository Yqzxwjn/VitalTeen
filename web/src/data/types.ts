/**
 * 宏观体质数据的数据契约。
 *
 * ## 为什么每个数据集都必须自带出处
 *
 * 大屏要展示的是**全国青少年体质统计**，那些数字不来自本仓库，也不由我们产生。
 * 一个不知道出处的统计数字，在答辩现场被问一句「这个数据哪来的」就完了 ——
 * 而「数据来源合规」本身就是评分表里技术实现与规范那一项的考量。
 *
 * 因此这里的类型把出处做成**必填**：缺了任何一项，数据集会被加载器拒绝，
 * 页面会明说「数据未接入」，而不是画一张看起来很像那么回事的图。
 *
 * 这跟领域层的阈值治理是同一套思路 —— `shared/thresholds/` 里每个阈值带
 * `source_type`，这里每个数据集带 `provenance`。**不知道就说不知道。**
 */

/** 学段。与《国家学生体质健康标准》的分组口径一致。 */
export type SchoolStage =
  | 'primary-1-2' // 小学一、二年级
  | 'primary-3-4' // 小学三、四年级
  | 'primary-5-6' // 小学五、六年级
  | 'junior' // 初中
  | 'senior' // 高中
  | 'college' // 大学

/** 指标的口径。同一个项目名在不同报告里可能是达标率、也可能是均值。 */
export type MetricKind =
  | 'rate' // 达标率 / 优良率，0–1
  | 'mean' // 均值（成绩或指数）
  | 'index' // 指数（如 BMI、体质总分）

/**
 * 数据来源声明。
 *
 * **每一项都必填且会被校验。** 宁可在加载时报错，也不要在页面上出现一个
 * 无法溯源的数字。
 */
export interface Provenance {
  /** 数据集正式名称，显示在页面角落与图表下方 */
  title: string
  /** 发布机构（教育部、体育总局、某省教育厅……） */
  publisher: string
  /** **发布年份**，不是抓取年份 —— 两者含义完全不同 */
  publishedYear: number
  /** 可核验的链接。必须是能打开看到原始数据的地方，不是二手转载 */
  url: string
  /** 许可与引用方式。公开报告可直接引用，但页面上要标注 */
  license: string
  /** 覆盖范围描述，例如「2019 年全国 31 个省市自治区」 */
  coverage: string
  /** 口径备注。例如「按学段汇总，未分省」「样本为抽测，非全量」 */
  notes?: string
}

/** 一条指标记录。 */
export interface MetricRecord {
  /** 指标代码。国标项目用统一的编码，见 `gbStandard.ts` */
  code: string
  /** 显示名 */
  name: string
  /** 数值。`rate` 口径下为 0–1，`mean` / `index` 口径下为对应单位的量 */
  value: number
  /** 单位。`rate` 用 `'ratio'`，其余用实际单位（秒、厘米、毫升……） */
  unit: string
  kind: MetricKind
  /** 样本量。抽测数据没有它就没法判断可信度，缺失时页面应提示 */
  sampleSize?: number
}

/** 一个「学段 × 年份 × 地区」的观测。 */
export interface Observation {
  stage: SchoolStage
  year: number
  /** 省份名称。缺省表示「全国」—— 刻意不用 `'全国'` 字符串占位，
   *  那样无法区分「全国汇总」与「有个叫全国的省」 */
  region?: string
  metrics: MetricRecord[]
}

/** 一份宏观数据集。 */
export interface MacroDataset {
  /** 数据格式版本，用于演进时判断兼容性 */
  schemaVersion: string
  provenance: Provenance
  observations: Observation[]
}

/** 加载结果。三种状态互斥，调用方必须显式处理「没有数据」这一支。 */
export type LoadResult =
  | { status: 'ok'; dataset: MacroDataset }
  | { status: 'missing'; path: string; hint: string }
  | { status: 'invalid'; path: string; errors: string[] }

/** 学段的中文名与顺序。图表按这个顺序排列，而不是按字典序。 */
export const STAGE_LABELS: ReadonlyArray<{ stage: SchoolStage; label: string }> = [
  { stage: 'primary-1-2', label: '小学一、二年级' },
  { stage: 'primary-3-4', label: '小学三、四年级' },
  { stage: 'primary-5-6', label: '小学五、六年级' },
  { stage: 'junior', label: '初中' },
  { stage: 'senior', label: '高中' },
  { stage: 'college', label: '大学' },
]

/** 当前的数据格式版本。加载器会据此判断兼容性。 */
export const SCHEMA_VERSION = '1.0'
