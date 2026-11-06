<script setup lang="ts">
/**
 * ECharts 的薄封装。
 *
 * 只做三件事：挂载时初始化、option 变化时更新、卸载时销毁，外加把点击事件抛出去。
 * 所有业务逻辑都在 `@/charts/options` 的纯函数里 —— 这个组件不该知道
 * 「什么数据该怎么画」，那是构造器的事。
 */
import type { EChartsOption } from 'echarts'
import * as echarts from 'echarts'
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = withDefaults(
  defineProps<{
    option: EChartsOption
    height?: number
  }>(),
  { height: 320 },
)

/**
 * 点击图表元素时抛出**被点中的类目名**（轴上的标签），供上层做下钻。
 *
 * 刻意不抛下标：分省排名是按数值降序排的，数值一变，同一个省份的下标就变了，
 * 拿下标做下钻会在数据更新后指向另一个省。类目名（「北京」）本身才是稳定的身份。
 * 上层用 `stageFromLabel` 把显示名映射回内部标识，也不拿显示文本当键用。
 */
const emit = defineEmits<{ select: [name: string] }>()

/**
 * ECharts 的事件回调参数类型没有从包根导出，而这里只依赖 `name` 一个字段。
 * 与其从内部路径 `echarts/types/...` 引一个脆弱的类型，不如声明我们真正依赖的
 * 最小结构，并在运行时收窄 —— 这样不会假装知道得比实际更多。
 */
interface ClickParams {
  name?: unknown
}

const host = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null
let observer: ResizeObserver | null = null

onMounted(() => {
  if (host.value === null) return
  chart = echarts.init(host.value, undefined, { renderer: 'canvas' })
  chart.setOption(props.option)

  chart.on('click', (params: ClickParams) => {
    if (typeof params.name === 'string' && params.name !== '') {
      emit('select', params.name)
    }
  })

  // 大屏往往在答辩现场临时改分辨率（投影、分屏），不监听尺寸变化的话
  // 图表会停在初始大小，右边或下边留一大片空白。
  observer = new ResizeObserver(() => chart?.resize())
  observer.observe(host.value)
})

watch(
  () => props.option,
  (next) => {
    // notMerge：换指标或下钻时旧系列必须被清掉，否则两组数据会叠在同一张图上
    chart?.setOption(next, { notMerge: true })
  },
  { deep: true },
)

onBeforeUnmount(() => {
  observer?.disconnect()
  observer = null
  // dispose 会一并清掉事件监听，不需要手工 off
  chart?.dispose()
  chart = null
})
</script>

<template>
  <div ref="host" class="echart" :style="{ height: `${props.height}px` }" />
</template>

<style scoped>
.echart {
  width: 100%;
}
</style>
