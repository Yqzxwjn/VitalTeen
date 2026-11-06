/**
 * 地图边界数据的加载。
 *
 * 与宏观数据同样是**外部输入**：没有它时地图视图要如实说「缺少地图数据」，
 * 而不是画一张空白地图 —— 空白地图看起来像「全国数据都是零」，那是最糟的误导。
 *
 * ## 关于来源（重要）
 *
 * 中国地图边界数据有合规要求。正规来源是**自然资源部标准地图服务**，
 * 使用时有审图号要求。仓库里这份 `china.geojson` 目前**没有携带任何出处信息**，
 * 因此：
 *
 * - 本地开发与界面预览：可以用
 * - **进答辩材料、公开演示、任何对外场合之前：必须确认它的来源与授权**
 *
 * 这不是洁癖。地图的边界表示在竞赛材料里是会被审查的内容，
 * 而且它和数据集不一样 —— 数据集错了是数据问题，地图错了是另一类问题。
 *
 * ## 为什么归一化在这里做
 *
 * ECharts 按 ``name`` 精确匹配数据。地图文件里是全称（「北京市」），
 * 统计数据集里常是简称（「北京」），对不上时地图会渲染成一片灰且**不报错**。
 * 因此在注册之前统一改名，见 :mod:`@/charts/regions`。
 */

import * as echarts from 'echarts'

import type { MapGeoJson } from '@/charts/regions'
import {
  CHINA_MAP_NAME,
  matchableRegions,
  normalizeGeoJsonNames,
  validateGeoJson,
} from '@/charts/regions'

export const DEFAULT_MAP_URL = 'maps/china.geojson'

// 从 regions 转出，保持既有引用路径可用（常量本身定义在那里，见其说明）
export { CHINA_MAP_NAME }

export type MapLoadResult =
  | { status: 'ok'; geo: MapGeoJson; regions: string[] }
  | { status: 'missing'; path: string; hint: string }
  | { status: 'invalid'; path: string; errors: string[] }

export const MISSING_MAP_HINT = [
  `请把中国地图边界数据放到 public/${DEFAULT_MAP_URL}`,
  '（GeoJSON 格式，FeatureCollection，每个省级要素需要 properties.name）。',
  '',
  '来源要求：正规来源是自然资源部标准地图服务，使用时有审图号要求。',
  '这份文件会出现在演示材料里，请确认它的来源与授权，并在文档中记录。',
].join('\n')

/**
 * 校验并规范化一份 GeoJSON。
 *
 * 抽成纯函数是为了能在不碰网络、不碰 ECharts 的情况下测试 ——
 * 加载逻辑里最容易错的是「名称对不上」，而那部分不需要网络就能验。
 */
export function prepareGeoJson(
  raw: unknown,
  path = DEFAULT_MAP_URL,
): MapLoadResult {
  const errors = validateGeoJson(raw)
  if (errors.length > 0) {
    return { status: 'invalid', path, errors }
  }
  const geo = normalizeGeoJsonNames(raw as MapGeoJson)
  return { status: 'ok', geo, regions: matchableRegions(geo) }
}

/** 把地图注册给 ECharts。注册之后地图系列才能用 `CHINA_MAP_NAME` 引用它。 */
export function registerChinaMap(geo: MapGeoJson, name = CHINA_MAP_NAME): void {
  // registerMap 接受 GeoJSON 对象；用 normalize 后的副本，名称才与数据对得上
  echarts.registerMap(name, geo as Parameters<typeof echarts.registerMap>[1])
}

/**
 * 加载并准备地图数据（**不注册**）。
 *
 * 刻意不在这里注册：注册是个副作用，而调用方可能想先看看拿到的是什么，
 * 或者注册失败时要自己处理。分开之后这个函数是纯的，好测。
 */
export async function loadChinaMap(
  url: string = DEFAULT_MAP_URL,
  fetchImpl: typeof fetch = fetch,
): Promise<MapLoadResult> {
  let response: Response
  try {
    response = await fetchImpl(url, { cache: 'no-cache' })
  } catch (error) {
    return {
      status: 'invalid',
      path: url,
      errors: [`读取地图数据失败：${error instanceof Error ? error.message : String(error)}`],
    }
  }

  if (response.status === 404) {
    return { status: 'missing', path: url, hint: MISSING_MAP_HINT }
  }
  if (!response.ok) {
    return { status: 'invalid', path: url, errors: [`地图文件返回 HTTP ${response.status}`] }
  }

  let raw: unknown
  try {
    raw = await response.json()
  } catch (error) {
    return {
      status: 'invalid',
      path: url,
      errors: [`地图文件不是合法 JSON：${error instanceof Error ? error.message : String(error)}`],
    }
  }

  return prepareGeoJson(raw, url)
}
