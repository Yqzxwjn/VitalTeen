/**
 * 外壳组件的状态与交互测试。
 *
 * 三组重点：
 *
 * 1. **三种数据状态各自的呈现** —— 那才是这个组件存在的理由：数据没接入时说清楚
 *    要放什么，数据有问题时逐条列出错误，而不是任何情况下都画一张空图。
 * 2. **地图是独立的第二份外部输入** —— 缺地图时只有地图视图不可用，其余照常。
 * 3. **下钻** —— 点击后视图与筛选状态是否一致。这类交互的 bug 通常是
 *    「图变了但筛选标签没变」或反之，肉眼不容易发现，但会让用户以为看的是全量数据。
 *
 * EChart 被替身取代：它的渲染需要 canvas，而这里要测的是状态分支与事件流。
 */

import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, type Component } from 'vue'

import type { MacroDataset, MetricRecord, Observation } from '@/data/types'
import { SCHEMA_VERSION } from '@/data/types'

const mocks = vi.hoisted(() => ({
  loadFrom: vi.fn(),
  loadChinaMap: vi.fn(),
  registerChinaMap: vi.fn(),
}))
vi.mock('@/data/loader', () => ({ loadFrom: mocks.loadFrom }))
vi.mock('@/data/mapLoader', () => ({
  loadChinaMap: mocks.loadChinaMap,
  registerChinaMap: mocks.registerChinaMap,
}))

import App from '@/App.vue'

function rate(value: number): MetricRecord[] {
  return [{ code: 'BMI', name: '体重指数达标率', value, unit: 'ratio', kind: 'rate' }]
}

function obs(stage: Observation['stage'], year: number, value: number, region?: string): Observation {
  const base: Observation = { stage, year, metrics: rate(value) }
  return region === undefined ? base : { ...base, region }
}

function dataset(): MacroDataset {
  return {
    schemaVersion: SCHEMA_VERSION,
    provenance: {
      title: '某年度全国学生体质健康调研',
      publisher: '某发布机构',
      publishedYear: 2024,
      url: 'https://example.org/report',
      license: '公开报告，引用需注明来源',
      coverage: '2024 年全国',
    },
    observations: [obs('junior', 2024, 0.62)],
  }
}

/**
 * 一份「五个视图都画得出来」的数据集。
 *
 * 与最小数据集分开：最小那份用来验证**不画图**的分支
 * （一年数据画不出趋势、没有分省数据画不出地图），这份用来验证**画得出来**的分支。
 * 用同一份数据测两种意图，测试会自相矛盾。
 */
function richDataset(): MacroDataset {
  return {
    ...dataset(),
    observations: [
      obs('junior', 2023, 0.55),
      obs('junior', 2024, 0.62),
      obs('senior', 2023, 0.48),
      obs('senior', 2024, 0.51),
      obs('junior', 2023, 0.68, '北京'),
      obs('junior', 2024, 0.71, '北京'),
      obs('junior', 2024, 0.58, '河北'),
    ],
  }
}

const OK_MAP = { status: 'ok' as const, geo: { type: 'FeatureCollection', features: [] }, regions: ['北京', '河北'] }

/** 点击后抛出指定类目名的 EChart 替身。 */
function chartStub(label = ''): Component {
  return defineComponent({
    name: 'EChart',
    props: {
      option: { type: Object, required: true },
      height: { type: Number, default: 360 },
    },
    emits: ['select'],
    template: `<button class="echart-stub" @click="$emit('select', '${label}')" />`,
  })
}

function mountApp(stub: Component = chartStub()) {
  return mount(App, { global: { stubs: { EChart: stub } } })
}

/**
 * 按**标签名**找标签页，不按下标。
 *
 * 用下标索引 UI 元素很脆：中间插一个标签页，后面每一个下标都错位，
 * 而失败信息会指向别处（「找不到元素」而不是「我找错了那个」）。
 * 这些测试曾经就是这么坏的。
 */
function tabByLabel(wrapper: VueWrapper, label: string) {
  const tab = wrapper.findAll('.tab').find((t) => t.text() === label)
  if (tab === undefined) {
    const available = wrapper.findAll('.tab').map((t) => t.text())
    throw new Error(`没有名为「${label}」的标签页；当前有：${available.join('、')}`)
  }
  return tab
}

beforeEach(() => {
  mocks.loadFrom.mockReset()
  mocks.loadChinaMap.mockReset()
  mocks.registerChinaMap.mockReset()
  // 默认地图可用：测「五个视图都能画」时需要它。
  // 地图缺失/损坏的分支由专门的用例覆盖
  mocks.loadChinaMap.mockResolvedValue(OK_MAP)
})

describe('数据未接入', () => {
  it('说明要放什么文件，而不是画一张空图', async () => {
    mocks.loadFrom.mockResolvedValue({
      status: 'missing',
      path: 'data/macro-dataset.json',
      hint: '请把宏观数据集放到 public/data/macro-dataset.json。',
    })
    const wrapper = mountApp()
    await flushPromises()

    expect(wrapper.text()).toContain('数据未接入')
    expect(wrapper.text()).toContain('不会画出任何图表')
    expect(wrapper.text()).toContain('public/data/macro-dataset.json')
    expect(wrapper.find('.echart-stub').exists()).toBe(false)
  })
})

describe('数据有问题', () => {
  it('逐条列出校验错误', async () => {
    mocks.loadFrom.mockResolvedValue({
      status: 'invalid',
      path: 'data/macro-dataset.json',
      errors: ['provenance 缺少「发布机构」（字段 publisher）', 'observations 为空'],
    })
    const wrapper = mountApp()
    await flushPromises()

    expect(wrapper.text()).toContain('已拒绝加载')
    const items = wrapper.findAll('.errors li')
    expect(items).toHaveLength(2)
    expect(items[0]?.text()).toContain('发布机构')
  })
})

describe('数据正常', () => {
  beforeEach(() => {
    mocks.loadFrom.mockResolvedValue({ status: 'ok', dataset: dataset() })
  })

  it('出处常驻显示，含可核验链接', async () => {
    const wrapper = mountApp()
    await flushPromises()

    expect(wrapper.text()).toContain('某年度全国学生体质健康调研')
    expect(wrapper.text()).toContain('某发布机构')
    expect(wrapper.text()).toContain('公开报告，引用需注明来源')
    expect(wrapper.find('a.provenance__link').attributes('href')).toBe('https://example.org/report')
  })

  it('默认选中第一个指标并画图', async () => {
    const wrapper = mountApp()
    await flushPromises()

    expect(wrapper.find('.echart-stub').exists()).toBe(true)
    expect(wrapper.find('select').element.value).toBe('BMI')
  })

  it('五个视图都在，且切换都能出图', async () => {
    mocks.loadFrom.mockResolvedValue({ status: 'ok', dataset: richDataset() })
    const wrapper = mountApp()
    await flushPromises()

    expect(wrapper.findAll('.tab').map((t) => t.text())).toEqual([
      '学段对比',
      '年度趋势',
      '地图热力',
      '分省对比',
      '指标分布',
    ])

    for (const label of ['学段对比', '年度趋势', '地图热力', '分省对比', '指标分布']) {
      await tabByLabel(wrapper, label).trigger('click')
      await flushPromises()
      expect(wrapper.find('.echart-stub').exists()).toBe(true)
    }
  })

  it('地图在渲染前被注册 —— 未注册时 ECharts 画空白图且不报错', async () => {
    mountApp()
    await flushPromises()
    expect(mocks.registerChinaMap).toHaveBeenCalledTimes(1)
  })

  it('只有一年数据时，趋势视图说明原因而不是画一条直线', async () => {
    const wrapper = mountApp()
    await flushPromises()

    await tabByLabel(wrapper, '年度趋势').trigger('click')
    await flushPromises()

    expect(wrapper.find('.echart-stub').exists()).toBe(false)
    expect(wrapper.text()).toContain('两年')
  })

  it('没有分省数据时，分省视图指路到学段概览', async () => {
    const wrapper = mountApp()
    await flushPromises()

    await tabByLabel(wrapper, '分省对比').trigger('click')
    await flushPromises()

    expect(wrapper.find('.echart-stub').exists()).toBe(false)
    expect(wrapper.text()).toContain('学段概览')
  })

  it('没有分省数据时，分布视图说明它需要省际差异', async () => {
    const wrapper = mountApp()
    await flushPromises()

    await tabByLabel(wrapper, '指标分布').trigger('click')
    await flushPromises()

    expect(wrapper.find('.echart-stub').exists()).toBe(false)
    expect(wrapper.text()).toContain('省际差异')
  })
})

describe('地图数据缺失或损坏', () => {
  beforeEach(() => {
    mocks.loadFrom.mockResolvedValue({ status: 'ok', dataset: richDataset() })
  })

  it('缺地图时只有地图视图不可用，其余视图照常', async () => {
    mocks.loadChinaMap.mockResolvedValue({
      status: 'missing',
      path: 'maps/china.geojson',
      hint: '请把地图数据放到 public/maps/china.geojson',
    })
    const wrapper = mountApp()
    await flushPromises()

    await tabByLabel(wrapper, '地图热力').trigger('click')
    await flushPromises()
    expect(wrapper.find('.echart-stub').exists()).toBe(false)
    expect(wrapper.text()).toContain('缺少地图边界数据')
    // 关键：其余视图不受影响。
    // 断言的是「不受影响」而不是「不影响」—— 后者不是前者的子串
    expect(wrapper.text()).toContain('不受影响')

    await tabByLabel(wrapper, '分省对比').trigger('click')
    await flushPromises()
    expect(wrapper.find('.echart-stub').exists()).toBe(true)
  })

  it('地图缺失时不注册，也不崩', async () => {
    mocks.loadChinaMap.mockResolvedValue({
      status: 'missing',
      path: 'maps/china.geojson',
      hint: 'x',
    })
    mountApp()
    await flushPromises()
    expect(mocks.registerChinaMap).not.toHaveBeenCalled()
  })

  it('地图文件损坏时地图视图说明情况', async () => {
    mocks.loadChinaMap.mockResolvedValue({
      status: 'invalid',
      path: 'maps/china.geojson',
      errors: ['features 为空'],
    })
    const wrapper = mountApp()
    await flushPromises()

    await tabByLabel(wrapper, '地图热力').trigger('click')
    await flushPromises()
    expect(wrapper.find('.echart-stub').exists()).toBe(false)
    expect(wrapper.text()).toContain('暂不可用')
  })
})

describe('下钻', () => {
  beforeEach(() => {
    mocks.loadFrom.mockResolvedValue({ status: 'ok', dataset: richDataset() })
  })

  it('从学段对比点某个学段，跳到该学段的趋势', async () => {
    const wrapper = mountApp(chartStub('初中'))
    await flushPromises()

    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()

    expect(tabByLabel(wrapper, '年度趋势').classes()).toContain('tab--active')
    expect(wrapper.find('.chip').text()).toContain('初中')
    expect(wrapper.find('.echart-stub').exists()).toBe(true)
  })

  it('从分省对比点某个省份，跳到该省份的趋势', async () => {
    const wrapper = mountApp(chartStub('北京'))
    await flushPromises()

    await tabByLabel(wrapper, '分省对比').trigger('click')
    await flushPromises()
    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()

    expect(tabByLabel(wrapper, '年度趋势').classes()).toContain('tab--active')
    expect(wrapper.find('.chip').text()).toContain('北京')
  })

  it('点地图上的省份也能下钻', async () => {
    const wrapper = mountApp(chartStub('河北'))
    await flushPromises()

    await tabByLabel(wrapper, '地图热力').trigger('click')
    await flushPromises()
    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()

    expect(tabByLabel(wrapper, '年度趋势').classes()).toContain('tab--active')
    expect(wrapper.find('.chip').text()).toContain('河北')
  })

  it('筛选标签可清除', async () => {
    const wrapper = mountApp(chartStub('初中'))
    await flushPromises()

    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()
    expect(wrapper.find('.chip').exists()).toBe(true)

    await wrapper.find('.chip').trigger('click')
    await flushPromises()
    expect(wrapper.find('.chip').exists()).toBe(false)
    expect(wrapper.find('.echart-stub').exists()).toBe(true)
  })

  it('手动切换到别的视图会清掉筛选', async () => {
    const wrapper = mountApp(chartStub('初中'))
    await flushPromises()

    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()
    expect(wrapper.find('.chip').exists()).toBe(true)

    await tabByLabel(wrapper, '学段对比').trigger('click')
    await flushPromises()
    expect(wrapper.find('.chip').exists()).toBe(false)
  })

  it('认不出的类目名不下钻，也不猜', async () => {
    const wrapper = mountApp(chartStub('某个不存在的东西'))
    await flushPromises()

    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()

    expect(wrapper.find('.chip').exists()).toBe(false)
    expect(tabByLabel(wrapper, '学段对比').classes()).toContain('tab--active')
  })

  it('趋势图上的点击不做下钻', async () => {
    const wrapper = mountApp(chartStub('初中'))
    await flushPromises()

    await tabByLabel(wrapper, '年度趋势').trigger('click')
    await flushPromises()
    await wrapper.find('.echart-stub').trigger('click')
    await flushPromises()

    expect(wrapper.find('.chip').exists()).toBe(false)
  })
})

describe('数据集没有任何指标', () => {
  it('提示而不是报错', async () => {
    mocks.loadFrom.mockResolvedValue({
      status: 'ok',
      dataset: { ...dataset(), observations: [{ stage: 'junior', year: 2024, metrics: [] }] },
    })
    const wrapper = mountApp()
    await flushPromises()

    expect(wrapper.text()).toContain('没有任何指标')
  })
})
