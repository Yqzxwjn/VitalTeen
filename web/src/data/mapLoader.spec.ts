/**
 * 地图加载测试。
 *
 * 重点是**三种状态要分得清**：拿到了、没有文件、文件有问题。
 * 「没有文件」和「文件坏了」对使用者要说不同的话 —— 前者是还没接入，
 * 后者是接进来的东西不对。混成一句「地图加载失败」等于什么也没说。
 */

import { readFileSync } from 'node:fs'

import { describe, expect, it, vi } from 'vitest'

import type { MapGeoJson } from '@/charts/regions'
import {
  CHINA_MAP_NAME,
  DEFAULT_MAP_URL,
  MISSING_MAP_HINT,
  loadChinaMap,
  prepareGeoJson,
} from './mapLoader'

const REAL_MAP_PATH = 'public/maps/china.geojson'

function realGeoJson(): MapGeoJson {
  return JSON.parse(readFileSync(REAL_MAP_PATH, 'utf8')) as MapGeoJson
}

function fakeResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as unknown as Response
}

describe('prepareGeoJson', () => {
  it('把全称改写成简称，让数据能对上', () => {
    const result = prepareGeoJson({
      type: 'FeatureCollection',
      features: [{ properties: { name: '北京市' } }, { properties: { name: '广东省' } }],
    })
    expect(result.status).toBe('ok')
    if (result.status === 'ok') {
      expect(result.geo.features?.[0]?.properties?.['name']).toBe('北京')
      expect(result.regions).toEqual(['北京', '广东'])
    }
  })

  it('境界线不进可匹配列表', () => {
    const result = prepareGeoJson({
      type: 'FeatureCollection',
      features: [{ properties: { name: '北京市' } }, { properties: { name: '境界线' } }],
    })
    expect(result.status).toBe('ok')
    if (result.status === 'ok') {
      expect(result.regions).toEqual(['北京'])
    }
  })

  it('不合法的数据返回 invalid 并带上原因', () => {
    const result = prepareGeoJson({ type: 'FeatureCollection', features: [] })
    expect(result.status).toBe('invalid')
    if (result.status === 'invalid') {
      expect(result.errors.some((e) => e.includes('空地图'))).toBe(true)
    }
  })

  it('真实地图文件通过', () => {
    const result = prepareGeoJson(realGeoJson())
    expect(result.status).toBe('ok')
    if (result.status === 'ok') {
      expect(result.regions).toHaveLength(34)
    }
  })
})

describe('loadChinaMap', () => {
  it('404 被识别为「还没接入地图」，而不是错误', () => {
    return loadChinaMap('maps/x.geojson', async () =>
      fakeResponse(null, 404),
    ).then((result) => {
      expect(result.status).toBe('missing')
      if (result.status === 'missing') {
        expect(result.hint).toBe(MISSING_MAP_HINT)
      }
    })
  })

  it('其它 HTTP 错误识别为 invalid', async () => {
    const result = await loadChinaMap('maps/x.geojson', async () => fakeResponse(null, 500))
    expect(result.status).toBe('invalid')
  })

  it('网络异常不抛出，返回 invalid', async () => {
    const result = await loadChinaMap('maps/x.geojson', async () => {
      throw new Error('network down')
    })
    expect(result.status).toBe('invalid')
    if (result.status === 'invalid') {
      expect(result.errors[0]).toContain('读取地图数据失败')
    }
  })

  it('响应不是 JSON 时给出明确原因', async () => {
    const broken = {
      ok: true,
      status: 200,
      json: async () => {
        throw new Error('Unexpected token')
      },
    } as unknown as Response
    const result = await loadChinaMap('maps/x.geojson', async () => broken)
    expect(result.status).toBe('invalid')
    if (result.status === 'invalid') {
      expect(result.errors[0]).toContain('不是合法 JSON')
    }
  })

  it('加载真实地图成功', async () => {
    const result = await loadChinaMap('maps/china.geojson', async () =>
      fakeResponse(realGeoJson()),
    )
    expect(result.status).toBe('ok')
    if (result.status === 'ok') {
      expect(result.regions).toContain('北京')
      expect(result.regions).toContain('内蒙古')
      expect(result.regions).not.toContain('境界线')
    }
  })

  it('走 no-cache，避免看到陈旧地图', async () => {
    const spy = vi.fn(async () => fakeResponse(realGeoJson()))
    await loadChinaMap('maps/china.geojson', spy as unknown as typeof fetch)
    expect(spy).toHaveBeenCalledWith('maps/china.geojson', { cache: 'no-cache' })
  })
})

describe('常量', () => {
  it('默认路径与注册名稳定', () => {
    // 这两个值会出现在文档与部署说明里，改动要同步
    expect(DEFAULT_MAP_URL).toBe('maps/china.geojson')
    expect(CHINA_MAP_NAME).toBe('china')
  })

  it('缺地图的提示里写明了来源要求', () => {
    expect(MISSING_MAP_HINT).toContain('审图号')
  })
})
