<script setup lang="ts">
/**
 * 大屏外壳。
 *
 * 三种数据状态各自有明确的呈现，**没有任何一种会画一张空图充数**：
 *
 * - `missing`：数据还没接入 —— 直说要放什么文件、需要哪些字段
 * - `invalid`：数据接进来了但有问题 —— 把校验错误逐条列出来
 * - `ok`：正常展示，并在显眼处常驻数据出处
 *
 * 出处常驻是刻意的：本页面展示的是**外部统计数据**，不是本平台产生的结果。
 * 答辩时被问「这个数据哪来的」，指着屏幕就能回答。
 *
 * 地图数据是**另一份**外部输入，独立加载、独立失败：缺地图时只有地图视图不可用，
 * 其余四个视图照常。
 */
import { computed, onMounted, ref } from 'vue'

import EChart from '@/components/EChart.vue'
import {
  availableMetrics,
  buildDistribution,
  buildRegionHeatmap,
  buildRegionRanking,
  buildStageOverview,
  buildTrend,
  stageFromLabel,
  stageLabel,
  type ChartResult,
  type TrendFilter,
} from '@/charts/options'
import { loadFrom } from '@/data/loader'
import { loadChinaMap, registerChinaMap, type MapLoadResult } from '@/data/mapLoader'
import type { LoadResult } from '@/data/types'

type ViewState = { status: 'loading' } | LoadResult
type MapState = { status: 'loading' } | MapLoadResult
type ViewName = 'stage' | 'trend' | 'heatmap' | 'region' | 'distribution'

const VIEW_ORDER: ReadonlyArray<{ name: ViewName; label: string }> = [
  { name: 'stage', label: '学段对比' },
  { name: 'trend', label: '年度趋势' },
  { name: 'heatmap', label: '地图热力' },
  { name: 'region', label: '分省对比' },
  { name: 'distribution', label: '指标分布' },
]

const state = ref<ViewState>({ status: 'loading' })
const mapState = ref<MapState>({ status: 'loading' })
const activeCode = ref<string | null>(null)
const activeView = ref<ViewName>('stage')
const drilldown = ref<TrendFilter | null>(null)

onMounted(async () => {
  // 两份外部输入并行取：地图挂了不该拖住数据，反之亦然
  const [dataResult, mapResult] = await Promise.all([loadFrom(), loadChinaMap()])
  state.value = dataResult
  mapState.value = mapResult

  if (mapResult.status === 'ok') {
    // 注册放进 onMounted 而不是构造期：它是个副作用，且必须在任何地图视图
    // 渲染之前完成。地图数据是异步来的，这一步不能想当然
    registerChinaMap(mapResult.geo)
  }
  if (dataResult.status === 'ok') {
    activeCode.value = availableMetrics(dataResult.dataset)[0]?.code ?? null
  }
})

const dataset = computed(() => (state.value.status === 'ok' ? state.value.dataset : null))
const metrics = computed(() => (dataset.value ? availableMetrics(dataset.value) : []))

const chart = computed<ChartResult | null>(() => {
  if (dataset.value === null || activeCode.value === null) return null
  const data = dataset.value
  const code = activeCode.value
  switch (activeView.value) {
    case 'trend':
      return buildTrend(data, code, drilldown.value ?? undefined)
    case 'region':
      return buildRegionRanking(data, code)
    case 'heatmap':
      // 未注册地图时 ECharts 会画一张空白地图**且不报错** —— 空白地图看起来像
      // 「全国数据都是零」，是很糟的误导。所以这里显式拦住并说明原因。
      if (mapState.value.status === 'missing') {
        return { ok: false, reason: '缺少地图边界数据，地图视图不可用（其余四个视图不受影响）。' }
      }
      if (mapState.value.status !== 'ok') {
        return { ok: false, reason: '地图数据尚未就绪或有问题，地图视图暂不可用。' }
      }
      return buildRegionHeatmap(data, code)
    case 'distribution':
      return buildDistribution(data, code)
    case 'stage':
      return buildStageOverview(data, code)
  }
})

/**
 * 处理图表点击。
 *
 * **只在能下钻的视图上响应。** 趋势图与分布图上的点击没有明确的下钻语义 ——
 * 点一条折线的某个点是要看那一年的详情吗？那是另一个功能，不是下钻，
 * 不该顺手接上。
 *
 * 传进来的是类目名（「初中」「北京」），不是下标：分省排名按数值降序，
 * 数值一变下标就指向另一个省了；地图上的点击给的也是省名。
 */
function handleSelect(name: string): void {
  if (activeView.value === 'stage') {
    const stage = stageFromLabel(name)
    // 认不出的类目名就什么也不做，不猜、不兜底 —— 猜错了会下钻到不相干的范围
    if (stage === null) return
    drilldown.value = { kind: 'stage', stage }
  } else if (activeView.value === 'region' || activeView.value === 'heatmap') {
    drilldown.value = { kind: 'region', region: name }
  } else {
    return
  }
  activeView.value = 'trend'
}

function clearDrilldown(): void {
  drilldown.value = null
}

const drilldownLabel = computed(() => {
  const current = drilldown.value
  if (current === null) return ''
  return current.kind === 'region' ? current.region : stageLabel(current.stage)
})

function switchView(name: ViewName): void {
  // 手动切视图时清掉下钻：留着它会让「年度趋势」悄悄只显示一个学段，
  // 而标签在另一个位置，很容易被忽略
  if (name !== 'trend') drilldown.value = null
  activeView.value = name
}
</script>

<template>
  <div class="shell">
    <header class="shell__head">
      <h1>健知行绎 · 青少年体质数据可视化平台</h1>
      <p class="muted">数据可视化与智能交互 · 全国大学生数字媒体科技作品及创意竞赛</p>
    </header>

    <main class="shell__body">
      <p v-if="state.status === 'loading'" class="muted">正在加载数据…</p>

      <section v-else-if="state.status === 'missing'" class="panel">
        <div class="notice">
          <h2>数据未接入</h2>
          <p>
            本页面展示的是<strong>外部公开统计数据</strong>，不是本平台产生的结果。
            数据尚未接入时，这里不会画出任何图表 —— 一张空图比什么都不画更容易被误读。
          </p>
        </div>
        <pre class="mono hint">{{ state.hint }}</pre>
      </section>

      <section v-else-if="state.status === 'invalid'" class="panel">
        <div class="notice notice--danger">
          <h2>数据文件有问题，已拒绝加载</h2>
          <p class="mono">{{ state.path }}</p>
        </div>
        <ul class="errors">
          <li v-for="(error, index) in state.errors" :key="index" class="mono">{{ error }}</li>
        </ul>
      </section>

      <template v-else>
        <section class="panel provenance">
          <h2 class="provenance__title">{{ state.dataset.provenance.title }}</h2>
          <dl class="provenance__grid">
            <dt>发布机构</dt>
            <dd>{{ state.dataset.provenance.publisher }}</dd>
            <dt>发布年份</dt>
            <dd>{{ state.dataset.provenance.publishedYear }}</dd>
            <dt>覆盖范围</dt>
            <dd>{{ state.dataset.provenance.coverage }}</dd>
            <dt>引用许可</dt>
            <dd>{{ state.dataset.provenance.license }}</dd>
          </dl>
          <p v-if="state.dataset.provenance.notes" class="muted">
            口径备注：{{ state.dataset.provenance.notes }}
          </p>
          <a
            class="provenance__link"
            :href="state.dataset.provenance.url"
            target="_blank"
            rel="noreferrer"
          >
            查看原始数据 ↗
          </a>
        </section>

        <section class="panel">
          <div class="toolbar">
            <label>
              指标
              <select v-model="activeCode">
                <option v-for="item in metrics" :key="item.code" :value="item.code">
                  {{ item.name }}
                </option>
              </select>
            </label>
            <div class="tabs">
              <button
                v-for="view in VIEW_ORDER"
                :key="view.name"
                :class="['tab', { 'tab--active': activeView === view.name }]"
                @click="switchView(view.name)"
              >
                {{ view.label }}
              </button>
            </div>
          </div>

          <p v-if="drilldown" class="drill">
            <button class="chip" @click="clearDrilldown">
              只看：{{ drilldownLabel }} <span aria-hidden="true">×</span>
            </button>
            <span class="muted">切换到别的视图会清除这个筛选</span>
          </p>

          <EChart
            v-if="chart?.ok"
            :option="chart.option"
            :height="chart.height ?? 360"
            @select="handleSelect"
          />
          <div v-else-if="chart" class="notice">
            <p>无法绘制：{{ chart.reason }}</p>
          </div>
          <p v-else class="muted">数据集里没有任何指标。</p>

          <p class="muted hintline">
            提示：在「学段对比」点某个学段、在「地图热力」或「分省对比」点某个省份，
            可下钻查看它的历年趋势。
          </p>
        </section>
      </template>
    </main>
  </div>
</template>

<style scoped>
.shell {
  min-height: 100%;
  display: flex;
  flex-direction: column;
}

.shell__head {
  padding: 20px 28px 12px;
  border-bottom: 1px solid var(--border);
}

.shell__head h1 {
  font-size: 20px;
  letter-spacing: 0.5px;
}

.shell__head p {
  margin: 4px 0 0;
  font-size: 12px;
}

.shell__body {
  flex: 1;
  padding: 20px 28px 40px;
  display: flex;
  flex-direction: column;
  gap: var(--gap);
  max-width: 1400px;
  width: 100%;
  margin: 0 auto;
}

.hint {
  margin: 14px 0 0;
  padding: 14px;
  background: var(--bg);
  border-radius: var(--radius);
  color: var(--fg-muted);
  white-space: pre-wrap;
  line-height: 1.7;
}

.errors {
  margin: 14px 0 0;
  padding-left: 20px;
  color: var(--danger);
}

.provenance__title {
  font-size: 15px;
  margin-bottom: 10px;
}

.provenance__grid {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: 4px 16px;
  margin: 0;
  font-size: 13px;
}

.provenance__grid dt {
  color: var(--fg-dim);
}

.provenance__grid dd {
  margin: 0;
}

.provenance__link {
  display: inline-block;
  margin-top: 12px;
  color: var(--accent);
  font-size: 13px;
}

.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 12px;
  flex-wrap: wrap;
}

.toolbar label {
  color: var(--fg-muted);
  font-size: 13px;
}

select {
  margin-left: 8px;
  padding: 5px 8px;
  background: var(--bg);
  color: var(--fg);
  border: 1px solid var(--border);
  border-radius: 6px;
}

.tabs {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.tab {
  padding: 5px 14px;
  background: transparent;
  color: var(--fg-muted);
  border: 1px solid var(--border);
  border-radius: 6px;
  cursor: pointer;
  font-size: 13px;
}

.tab--active {
  color: var(--bg);
  background: var(--accent);
  border-color: var(--accent);
}

.drill {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 0 0 10px;
  font-size: 12px;
}

.chip {
  padding: 3px 10px;
  background: var(--accent-dim);
  color: var(--fg);
  border: none;
  border-radius: 999px;
  cursor: pointer;
  font-size: 12px;
}

.hintline {
  margin: 12px 0 0;
  font-size: 12px;
}
</style>
