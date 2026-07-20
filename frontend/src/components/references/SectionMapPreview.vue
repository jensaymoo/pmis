<script setup>
//
// Тонкая обёртка над vue3-openlayers для предпросмотра геометрии
// географического участка — sections-screen.md §4.4.
//
// Только отображение: точки не редактируются кликом, вся правка — через
// таблицу точек (SectionFormModal). Компонент не монтируется в DOM для
// негеографических участков — этим управляет родитель (v-if вокруг него).
//
// Библиотека уже установлена (package.json) и импортируется статически —
// обычный ESM-импорт, без top-level await (компонент с async setup требует
// родительский <Suspense>, которого у вызывающей формы нет). Если сама
// библиотека всё же не работает в текущей среде (например, отсутствует
// нативный слой у ol в SSR/тестовом окружении), рендер геометрии обёрнут в
// onErrorCaptured — компонент откатывается на статическую заглушку и не
// ломает npm run build / рантайм (frontend-spec.md §10, sections-screen.md §4.4).
//
// Теги vue3-openlayers — составные member-expressions (Map.OlMap и т. п.),
// в шаблон Vue такие теги напрямую не подставляются, поэтому используем
// <component :is> с локальными алиасами.
//
import { computed, ref, shallowRef, onErrorCaptured } from 'vue'
import * as olModule from 'vue3-openlayers'

const OlMap = olModule?.Map?.OlMap ?? null
const OlView = olModule?.Map?.OlView ?? null
const OlFeature = olModule?.Map?.OlFeature ?? null
const OlTileLayer = olModule?.Layers?.OlTileLayer ?? null
const OlVectorLayer = olModule?.Layers?.OlVectorLayer ?? null
const OlSourceOSM = olModule?.Sources?.OlSourceOSM ?? null
const OlSourceVector = olModule?.Sources?.OlSourceVector ?? null
const OlGeomLineString = olModule?.Geometries?.OlGeomLineString ?? null
const OlGeomPolygon = olModule?.Geometries?.OlGeomPolygon ?? null

const props = defineProps({
  /** @type {import('vue').PropType<Array<{x: number, y: number|null, z: number|null}>>} */
  points: { type: Array, default: () => [] },
  /** 'area' | 'linear' */
  kind: { type: String, required: true },
})

const renderError = shallowRef(null)
onErrorCaptured((err) => {
  console.error('Ошибка рендера карты предпросмотра участка:', err)
  renderError.value = err
  return false
})

const moduleAvailable = computed(() => !!OlMap && !renderError.value)

/** x = широта, y = долгота (sections-screen.md §4.2); OpenLayers ждёт [lon, lat]. */
const coordinates = computed(() =>
  props.points
    .filter((p) => p.x != null && p.y != null)
    .map((p) => [Number(p.y), Number(p.x)]),
)

const hasEnoughPoints = computed(() => {
  const min = props.kind === 'area' ? 3 : 2
  return coordinates.value.length >= min
})

/** Полигон в OpenLayers должен быть замкнутым кольцом координат. */
const polygonRing = computed(() => {
  const coords = coordinates.value
  if (coords.length === 0) return []
  const first = coords[0]
  const last = coords[coords.length - 1]
  const closed = first[0] === last[0] && first[1] === last[1]
  return closed ? [coords] : [[...coords, first]]
})

const center = computed(() => {
  if (coordinates.value.length === 0) return [0, 0]
  const sum = coordinates.value.reduce((acc, c) => [acc[0] + c[0], acc[1] + c[1]], [0, 0])
  return [sum[0] / coordinates.value.length, sum[1] / coordinates.value.length]
})

const zoom = ref(13)
</script>

<template>
  <div class="w-full h-full min-h-[280px] border border-gray-200 rounded">
    <template v-if="!moduleAvailable">
      <div class="w-full h-full flex items-center justify-center text-sm text-gray-400 p-4 text-center">
        Картографический модуль не подключён
      </div>
    </template>
    <template v-else-if="!hasEnoughPoints">
      <div class="w-full h-full flex items-center justify-center text-sm text-gray-400 p-4 text-center">
        Добавьте точки, чтобы увидеть геометрию
      </div>
    </template>
    <template v-else>
      <component
        :is="OlMap"
        class="w-full h-full"
      >
        <component
          :is="OlView"
          :center="center"
          :zoom="zoom"
          projection="EPSG:4326"
        />
        <component :is="OlTileLayer">
          <component :is="OlSourceOSM" />
        </component>
        <component :is="OlVectorLayer">
          <component :is="OlSourceVector">
            <component :is="OlFeature">
              <component
                :is="OlGeomLineString"
                v-if="props.kind === 'linear'"
                :coordinates="coordinates"
                layout="XY"
              />
              <component
                :is="OlGeomPolygon"
                v-else
                :coordinates="polygonRing"
                layout="XY"
              />
            </component>
          </component>
        </component>
      </component>
    </template>
  </div>
</template>
