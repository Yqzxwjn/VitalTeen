import { describe, expect, it, vi } from 'vitest'

import { fromRaw, loadFrom, MISSING_DATA_HINT, validate } from './loader'
import { SCHEMA_VERSION } from './types'

function validRaw(): Record<string, unknown> {
  return {
    schemaVersion: SCHEMA_VERSION,
    provenance: {
      title: '测试数据集',
      publisher: '某机构',
      publishedYear: 2024,
      url: 'https://example.org/report',
      license: '公开报告，引用需注明来源',
      coverage: '2024 年全国',
    },
    observations: [
      {
        stage: 'junior',
        year: 2024,
        metrics: [{ code: 'BMI', name: '体重指数', value: 0.62, unit: 'ratio', kind: 'rate' }],
      },
    ],
  }
}

describe('validate —— 出处是硬门槛', () => {
  it('完整的数据通过校验', () => {
    expect(validate(validRaw())).toEqual([])
  })

  it.each([
    ['title', '数据集名称'],
    ['publisher', '发布机构'],
    ['publishedYear', '发布年份'],
    ['url', '可核验链接'],
    ['license', '引用许可'],
    ['coverage', '覆盖范围'],
  ])('缺少 provenance.%s 时被拒绝', (field, label) => {
    const raw = validRaw()
    const provenance = { ...(raw['provenance'] as Record<string, unknown>) }
    delete provenance[field]
    raw['provenance'] = provenance

    const errors = validate(raw)
    expect(errors.some((e) => e.includes(label))).toBe(true)
  })

  it('完全没有 provenance 时被拒绝', () => {
    const raw = validRaw()
    delete raw['provenance']
    expect(validate(raw).some((e) => e.includes('provenance'))).toBe(true)
  })

  it('空字符串不算「填了」', () => {
    const raw = validRaw()
    ;(raw['provenance'] as Record<string, unknown>)['url'] = ''
    expect(validate(raw).some((e) => e.includes('可核验链接'))).toBe(true)
  })

  it('publishedYear 超出合理范围时被拒绝', () => {
    const raw = validRaw()
    ;(raw['provenance'] as Record<string, unknown>)['publishedYear'] = 1200
    expect(validate(raw).some((e) => e.includes('publishedYear'))).toBe(true)
  })
})

describe('validate —— 结构校验', () => {
  it('顶层不是对象时被拒绝', () => {
    expect(validate([])).toEqual(['顶层应当是一个对象'])
    expect(validate(null)).toEqual(['顶层应当是一个对象'])
  })

  it('缺少 schemaVersion 时被拒绝', () => {
    const raw = validRaw()
    delete raw['schemaVersion']
    expect(validate(raw).some((e) => e.includes('schemaVersion'))).toBe(true)
  })

  it('大版本不兼容时被拒绝', () => {
    const raw = validRaw()
    raw['schemaVersion'] = '2.0'
    expect(validate(raw).some((e) => e.includes('不兼容'))).toBe(true)
  })

  it('小版本不同但大版本相同则接受', () => {
    const raw = validRaw()
    raw['schemaVersion'] = '1.7'
    expect(validate(raw).some((e) => e.includes('不兼容'))).toBe(false)
  })

  it('observations 为空时被拒绝', () => {
    const raw = validRaw()
    raw['observations'] = []
    expect(validate(raw).some((e) => e.includes('空数据集'))).toBe(true)
  })

  it('学段取值非法时被拒绝', () => {
    const raw = validRaw()
    raw['observations'] = [{ stage: '幼儿园', year: 2024, metrics: [] }]
    expect(validate(raw).some((e) => e.includes('stage 非法'))).toBe(true)
  })

  it('年份不合理时被拒绝', () => {
    const raw = validRaw()
    raw['observations'] = [{ stage: 'junior', year: 0, metrics: [] }]
    expect(validate(raw).some((e) => e.includes('year 不合理'))).toBe(true)
  })

  it('一次性报出全部问题，而不是只报第一个', () => {
    const raw = validRaw()
    delete raw['schemaVersion']
    raw['observations'] = [{ stage: 'x', year: 0, metrics: [] }]
    const errors = validate(raw)
    expect(errors.length).toBeGreaterThan(2)
  })
})

describe('validate —— rate 口径的取值陷阱', () => {
  it('rate 超过 1 时被拒绝，并提示要除以 100', () => {
    const raw = validRaw()
    raw['observations'] = [
      {
        stage: 'junior',
        year: 2024,
        metrics: [{ code: 'X', name: '达标率', value: 85, unit: 'ratio', kind: 'rate' }],
      },
    ]
    const errors = validate(raw)
    expect(errors.some((e) => e.includes('0–1'))).toBe(true)
    expect(errors.some((e) => e.includes('除以 100'))).toBe(true)
  })

  it('rate 为负数时被拒绝', () => {
    const raw = validRaw()
    raw['observations'] = [
      {
        stage: 'junior',
        year: 2024,
        metrics: [{ code: 'X', name: '达标率', value: -0.1, unit: 'ratio', kind: 'rate' }],
      },
    ]
    expect(validate(raw).some((e) => e.includes('0–1'))).toBe(true)
  })

  it('mean 口径不受 0–1 限制', () => {
    const raw = validRaw()
    raw['observations'] = [
      {
        stage: 'junior',
        year: 2024,
        metrics: [{ code: 'X', name: '肺活量', value: 2600, unit: '毫升', kind: 'mean' }],
      },
    ]
    expect(validate(raw)).toEqual([])
  })

  it('非有限数值被拒绝', () => {
    const raw = validRaw()
    raw['observations'] = [
      {
        stage: 'junior',
        year: 2024,
        metrics: [{ code: 'X', name: 'X', value: Number.NaN, unit: 'x', kind: 'mean' }],
      },
    ]
    expect(validate(raw).some((e) => e.includes('有限数值'))).toBe(true)
  })
})

describe('fromRaw', () => {
  it('合法数据返回 ok', () => {
    const result = fromRaw(validRaw())
    expect(result.status).toBe('ok')
  })

  it('非法数据返回 invalid 并带上错误清单', () => {
    const result = fromRaw({})
    expect(result.status).toBe('invalid')
    if (result.status === 'invalid') {
      expect(result.errors.length).toBeGreaterThan(0)
    }
  })
})

describe('loadFrom', () => {
  const fakeResponse = (body: unknown, init: { status?: number } = {}) =>
    ({
      ok: (init.status ?? 200) >= 200 && (init.status ?? 200) < 300,
      status: init.status ?? 200,
      json: async () => body,
    }) as unknown as Response

  it('404 被识别为「未接入数据」而不是错误', async () => {
    const result = await loadFrom('data/x.json', async () => fakeResponse(null, { status: 404 }))
    expect(result.status).toBe('missing')
    if (result.status === 'missing') {
      expect(result.hint).toBe(MISSING_DATA_HINT)
      expect(result.path).toBe('data/x.json')
    }
  })

  it('其它 HTTP 错误被识别为 invalid', async () => {
    const result = await loadFrom('data/x.json', async () => fakeResponse(null, { status: 500 }))
    expect(result.status).toBe('invalid')
  })

  it('响应不是 JSON 时被识别为 invalid', async () => {
    const broken = {
      ok: true,
      status: 200,
      json: async () => {
        throw new Error('Unexpected token')
      },
    } as unknown as Response
    const result = await loadFrom('data/x.json', async () => broken)
    expect(result.status).toBe('invalid')
    if (result.status === 'invalid') {
      expect(result.errors[0]).toContain('不是合法 JSON')
    }
  })

  it('网络异常被识别为 invalid 而不是抛出', async () => {
    const result = await loadFrom('data/x.json', async () => {
      throw new Error('network down')
    })
    expect(result.status).toBe('invalid')
  })

  it('加载合法文件返回 ok', async () => {
    const result = await loadFrom('data/x.json', async () => fakeResponse(validRaw()))
    expect(result.status).toBe('ok')
  })

  it('加载非法文件返回 invalid', async () => {
    const result = await loadFrom('data/x.json', async () => fakeResponse({ schemaVersion: '1.0' }))
    expect(result.status).toBe('invalid')
  })

  it('请求走 no-cache，避免看到陈旧数据', async () => {
    const fetchSpy = vi.fn(async () => fakeResponse(validRaw()))
    await loadFrom('data/x.json', fetchSpy as unknown as typeof fetch)
    expect(fetchSpy).toHaveBeenCalledWith('data/x.json', { cache: 'no-cache' })
  })
})
