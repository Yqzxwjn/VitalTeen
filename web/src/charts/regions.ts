/**
 * 行政区划名称归一化。
 *
 * **为什么必须有这一层**
 *
 * ECharts 的地图按 ``name`` **精确匹配**数据。而中国地图 GeoJSON 里的名称通常是
 * 全称（「北京市」「内蒙古自治区」），统计数据集里却常是简称（「北京」「内蒙古」）。
 * 两边对不上时，地图会渲染成**一片没有数据的灰块，而且不报任何错** ——
 * 这种失败最难发现，因为图上确实画出了东西，只是全是空的。
 *
 * 所以这里把两边都归一到一个**规范简称**上再比。地图注册前会用它重写
 * feature 的 name，数据侧取地区名时也走同一个函数。
 *
 * **非省级要素原样保留。** GeoJSON 里除了省级面，还有「境界线」（国界、省界、
 * 南海诸岛那类）。它们不参与数据匹配，但**不能删** —— 中国地图上南海诸岛与
 * 九段线是必须出现的，删掉是合规问题，不是视觉问题。
 */

/**
 * 注册到 ECharts 时的地图名。地图系列通过它引用这份数据。
 *
 * 放在本模块而不是 :mod:`@/data/mapLoader`：这个常量本身与「加载」无关，
 * 而 ``options.ts`` 需要它来构造地图系列 —— 从加载器引会把 echarts 一起
 * 拖进构造器的依赖里，测试里 mock 加载器时还得顺带 mock 一个常量。
 */
export const CHINA_MAP_NAME = 'china'

/** 地图要素的最小结构。只描述我们用到的字段，不假装知道得更多。 */
export interface MapFeature {
  type?: string
  properties?: { name?: unknown; [key: string]: unknown } | null
  geometry?: unknown
}

export interface MapGeoJson {
  type?: string
  crs?: unknown
  features?: MapFeature[]
  [key: string]: unknown
}

/** 非省级要素的名称，匹配时跳过。 */
const NON_PROVINCE_NAMES = new Set(['境界线'])

/**
 * 全称 → 规范简称。
 *
 * **不能用「去掉『省/市/自治区』后缀」这种规则代替。** 五个自治区的全称里
 * 带有民族名（「广西壮族自治区」「新疆维吾尔自治区」「宁夏回族自治区」），
 * 机械去后缀会得到「广西壮族」「新疆维吾尔」「宁夏回族」—— 都不是它们该有的简称。
 * 所以这里逐个列出来，宁可写满 34 行。
 */
const FULL_TO_SHORT: Readonly<Record<string, string>> = {
  // 直辖市
  北京市: '北京',
  天津市: '天津',
  上海市: '上海',
  重庆市: '重庆',

  // 省
  河北省: '河北',
  山西省: '山西',
  辽宁省: '辽宁',
  吉林省: '吉林',
  黑龙江省: '黑龙江',
  江苏省: '江苏',
  浙江省: '浙江',
  安徽省: '安徽',
  福建省: '福建',
  江西省: '江西',
  山东省: '山东',
  河南省: '河南',
  湖北省: '湖北',
  湖南省: '湖南',
  广东省: '广东',
  海南省: '海南',
  四川省: '四川',
  贵州省: '贵州',
  云南省: '云南',
  陕西省: '陕西',
  甘肃省: '甘肃',
  青海省: '青海',
  台湾省: '台湾',

  // 自治区：全称里带民族名，去后缀得不到正确的简称
  内蒙古自治区: '内蒙古',
  广西壮族自治区: '广西',
  西藏自治区: '西藏',
  宁夏回族自治区: '宁夏',
  新疆维吾尔自治区: '新疆',

  // 特别行政区
  香港特别行政区: '香港',
  澳门特别行政区: '澳门',
}

/** 反过来也认：数据里若用简称，归一后还是它自己。 */
export function normalizeRegion(name: string): string {
  const trimmed = name.trim()
  return FULL_TO_SHORT[trimmed] ?? trimmed
}

/** 是否为非省级要素（境界线之类），匹配数据时应跳过。 */
export function isNonProvince(name: string): boolean {
  return NON_PROVINCE_NAMES.has(name.trim())
}

/**
 * 把 GeoJSON 里 feature 的 name 改写成规范简称，供 ``registerMap`` 使用。
 *
 * 不改几何、不删要素；只动 ``properties.name`` 这一个字段。
 * 返回新对象而不是就地修改 —— 调用方可能还要用原始名称做别的匹配。
 */
export function normalizeGeoJsonNames(geojson: MapGeoJson): MapGeoJson {
  const features = (geojson.features ?? []).map((feature) => {
    const properties = feature.properties ?? {}
    const raw = properties['name']
    if (typeof raw !== 'string') return feature
    return { ...feature, properties: { ...properties, name: normalizeRegion(raw) } }
  })
  return { ...geojson, features }
}

/** 从 GeoJSON 里取出可参与数据匹配的省级名称（规范简称），去重且保持顺序。 */
export function matchableRegions(geojson: MapGeoJson): string[] {
  const seen = new Set<string>()
  for (const feature of geojson.features ?? []) {
    const raw = feature.properties?.['name']
    if (typeof raw !== 'string') continue
    const name = normalizeRegion(raw)
    if (isNonProvince(name)) continue
    seen.add(name)
  }
  return [...seen]
}

/**
 * 检查 GeoJSON 是否可用。返回错误列表，空数组表示通过。
 *
 * 与数据集的校验同样的思路：**不合法就明说**，不要让地图悄悄画不出东西。
 */
export function validateGeoJson(raw: unknown): string[] {
  const errors: string[] = []
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return ['顶层应当是一个对象']
  }
  const geo = raw as MapGeoJson
  if (geo.type !== undefined && geo.type !== 'FeatureCollection') {
    errors.push(`type 应当是 FeatureCollection，实际是 ${String(geo.type)}`)
  }
  if (!Array.isArray(geo.features)) {
    errors.push('缺少 features 数组')
    return errors
  }
  if (geo.features.length === 0) {
    errors.push('features 为空 —— 空地图与「没有地图数据」没有区别')
    return errors
  }
  const regions = matchableRegions(geo)
  if (regions.length === 0) {
    errors.push('没有任何可匹配的省级要素（name 字段可能缺失或格式不同）')
  }
  const missingName = geo.features.filter((f) => typeof f.properties?.['name'] !== 'string').length
  if (missingName > 0) {
    errors.push(`有 ${missingName} 个要素缺少 properties.name，它们无法与数据匹配`)
  }
  return errors
}

export const REGION_ALIASES = FULL_TO_SHORT
