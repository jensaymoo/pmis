<script setup>
//
// Раздел «Сводка ресурсов» Редактора работы — planning-task-editor.md §4.4.
// ПОЛНОСТЬЮ read-only, без кнопок редактирования. Агрегирует плановые
// назначения ресурсов (personnel_resource_plan / equipment_resource_plan /
// materials_resource_plan) за весь плановый период работы. Показывается для
// любого task.task_type !== 'milestone'; у вехи раздел отсутствует.
//
// Логика по типу узла (planning-task-editor.md §4.4):
//  - лист несекционированный: назначения по task_daily_plan работы (без участка);
//  - лист секционированный: блок на каждый участок + итоговая сводная строка;
//  - составная: агрегат из ЛИСТОВЫХ потомков (рекурсивный обход дерева на клиенте).
//
// Раздел обновляется после каждого закрытия Редактора дневного плана — родитель
// (TaskEditorModal) передаёт проп refreshToken (dailyPlanRefreshCounter), рост
// которого запускает перезагрузку.
//
import { computed, ref, watch } from 'vue'
import { useNotification } from 'naive-ui'
import { getClient } from '../../lib/postgrest'

const props = defineProps({
  /** Полная запись работы (task) + вложенные qty_unit, org_unit. */
  task: { type: Object, required: true },
  isLeaf: { type: Boolean, default: false },
  isSectioned: { type: Boolean, default: false },
  readonly: { type: Boolean, default: false },
  /** Растёт при каждом сохранении Редактора дневного плана — сигнал перезагрузки. */
  refreshToken: { type: [Number, String], default: 0 },
})

const notification = useNotification()

const KIND_LABELS = { personnel: 'персонал', equipment: 'техника', materials: 'материалы' }
const KIND_TABLES = {
  personnel: 'personnel_resource_plan',
  equipment: 'equipment_resource_plan',
  materials: 'materials_resource_plan',
}
const RESOURCE_EMBED_SELECT =
  'id,resource_id,group_id,plan_qty,status,resource:resource_id(name,unit:unit_id(short_name)),group:group_id(name,unit:unit_id(short_name))'

const loading = ref(false)
const isMilestone = computed(() => props.task?.task_type === 'milestone')

/**
 * Плоский список агрегированных строк для отображения (лист несекционированный,
 * либо итог для составной): [{ kind, label, isGroup, unit, qty }].
 * @type {import('vue').Ref<Array<{kind:string,label:string,isGroup:boolean,unit:string,qty:number}>>}
 */
const flatSummary = ref([])

/**
 * Для секционированной работы: массив { sectionId, sectionName, rows } + itogRows.
 * @type {import('vue').Ref<Array<{sectionId:string,sectionName:string,rows:Array}>>}
 */
const sectionedSummary = ref([])
const sectionedTotal = ref([])

/** @type {import('vue').Ref<string>} 'leaf-plain' | 'leaf-sectioned' | 'composite' | 'milestone' */
const mode = ref('leaf-plain')

/**
 * Агрегирует плановые назначения трёх видов ресурсов по списку id дневных планов.
 * @param {string[]} dailyPlanIds
 * @returns {Promise<Array<{kind:string,label:string,isGroup:boolean,unit:string,qty:number}>>}
 */
async function aggregateByDailyPlanIds(dailyPlanIds) {
  if (dailyPlanIds.length === 0) return []
  /** @type {Map<string, {kind:string,label:string,isGroup:boolean,unit:string,qty:number}>} */
  const acc = new Map()

  for (const kind of Object.keys(KIND_TABLES)) {
    const { data, error } = await getClient()
      .from(KIND_TABLES[kind])
      .select(RESOURCE_EMBED_SELECT)
      .in('task_daily_plan_id', dailyPlanIds)
      .neq('status', 'deprecated')
    if (error) {
      console.error(`Не удалось загрузить плановые назначения (${kind}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      continue
    }
    for (const rec of data ?? []) {
      const isGroup = rec.group_id !== null && rec.group_id !== undefined
      const entity = isGroup ? rec.group : rec.resource
      const name = entity?.name ?? (isGroup ? rec.group_id : rec.resource_id)
      const unit = entity?.unit?.short_name ?? ''
      const key = `${kind}|${isGroup ? 'g' : 'r'}|${isGroup ? rec.group_id : rec.resource_id}|${unit}`
      const existing = acc.get(key)
      if (existing) {
        existing.qty += Number(rec.plan_qty) || 0
      } else {
        acc.set(key, { kind, label: name, isGroup, unit, qty: Number(rec.plan_qty) || 0 })
      }
    }
  }
  return Array.from(acc.values())
}

/**
 * Рекурсивно собирает все id поддерева (включая корень), начиная с task.id, и
 * определяет, какие из них листовые (никогда не встретились как parent_id).
 * @param {string} rootId
 * @returns {Promise<string[]>} id листовых потомков корня
 */
async function collectLeafDescendantIds(rootId) {
  let currentLevelIds = [rootId]
  const allIds = new Set([rootId])
  const parentIds = new Set() // id, у которых есть хотя бы один ребёнок

  while (currentLevelIds.length > 0) {
    const { data, error } = await getClient()
      .from('task')
      .select('id,parent_id')
      .in('parent_id', currentLevelIds)
      .neq('status', 'deprecated')
    if (error) {
      console.error('Не удалось загрузить подчинённые работы для сводки ресурсов:', error)
      notification.error({ content: error.message, duration: 6000 })
      break
    }
    if (!data || data.length === 0) break

    for (const t of data) {
      parentIds.add(t.parent_id)
      allIds.add(t.id)
    }
    currentLevelIds = data.map((t) => t.id)
  }

  return Array.from(allIds).filter((id) => !parentIds.has(id))
}

async function loadSummary() {
  flatSummary.value = []
  sectionedSummary.value = []
  sectionedTotal.value = []

  if (!props.task?.id || isMilestone.value) return

  loading.value = true
  try {
    if (!props.isLeaf) {
      // --- составная работа: агрегат из листовых потомков ---
      mode.value = 'composite'
      const leafIds = await collectLeafDescendantIds(props.task.id)
      if (leafIds.length === 0) {
        flatSummary.value = []
        return
      }
      const { data: dailyPlans, error } = await getClient()
        .from('task_daily_plan')
        .select('id')
        .in('task_id', leafIds)
      if (error) {
        console.error('Не удалось загрузить дневные планы подчинённых работ:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      const ids = (dailyPlans ?? []).map((p) => p.id)
      flatSummary.value = await aggregateByDailyPlanIds(ids)
      return
    }

    if (!props.isSectioned) {
      // --- лист несекционированный ---
      mode.value = 'leaf-plain'
      const { data: dailyPlans, error } = await getClient()
        .from('task_daily_plan')
        .select('id')
        .eq('task_id', props.task.id)
        .is('task_section_id', null)
      if (error) {
        console.error('Не удалось загрузить дневной план работы:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      const ids = (dailyPlans ?? []).map((p) => p.id)
      flatSummary.value = await aggregateByDailyPlanIds(ids)
      return
    }

    // --- лист секционированный: блок на каждый участок + итог ---
    mode.value = 'leaf-sectioned'
    const [{ data: dailyPlans, error: dpError }, { data: taskSections, error: tsError }] = await Promise.all([
      getClient().from('task_daily_plan').select('id,task_section_id').eq('task_id', props.task.id),
      getClient().from('task_section').select('id,section:section_id(name)').eq('task_id', props.task.id),
    ])
    if (dpError) {
      console.error('Не удалось загрузить дневной план работы:', dpError)
      notification.error({ content: dpError.message, duration: 6000 })
      return
    }
    if (tsError) {
      console.error('Не удалось загрузить участки работы:', tsError)
      notification.error({ content: tsError.message, duration: 6000 })
      return
    }

    const sectionNameMap = Object.fromEntries(
      (taskSections ?? []).map((ts) => [ts.id, ts.section?.name ?? ts.id]),
    )

    /** @type {Map<string, string[]>} task_section_id -> daily plan ids */
    const bySection = new Map()
    for (const p of dailyPlans ?? []) {
      if (!p.task_section_id) continue
      if (!bySection.has(p.task_section_id)) bySection.set(p.task_section_id, [])
      bySection.get(p.task_section_id).push(p.id)
    }

    const blocks = []
    for (const [sectionId, ids] of bySection.entries()) {
      const rows = await aggregateByDailyPlanIds(ids)
      blocks.push({ sectionId, sectionName: sectionNameMap[sectionId] ?? sectionId, rows })
    }
    sectionedSummary.value = blocks

    const allIds = (dailyPlans ?? []).filter((p) => p.task_section_id).map((p) => p.id)
    sectionedTotal.value = await aggregateByDailyPlanIds(allIds)
  } finally {
    loading.value = false
  }
}

watch(
  () => [props.task?.id, props.isLeaf, props.isSectioned, props.refreshToken],
  () => loadSummary(),
  { immediate: true },
)

/** @param {Array} rows */
function hasRows(rows) {
  return Array.isArray(rows) && rows.length > 0
}
</script>

<template>
  <div class="border-t border-gray-200 pt-4 mt-4">
    <h3
      class="text-base font-medium mb-2"
      aria-label="Сводка ресурсов (только просмотр)"
    >
      Сводка ресурсов
      <span class="text-xs font-normal text-gray-400">(только просмотр)</span>
    </h3>

    <div
      v-if="isMilestone"
      class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
    >
      у вехи нет ресурсов
    </div>

    <template v-else>
      <p
        v-if="mode === 'composite'"
        class="text-xs text-gray-500 mb-2"
      >
        назначения складываются из подчинённых работ
      </p>

      <n-spin :show="loading">
        <!-- Лист несекционированный / составная (плоский список) -->
        <template v-if="mode === 'leaf-plain' || mode === 'composite'">
          <div
            v-if="!hasRows(flatSummary) && !loading"
            class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
          >
            ресурсы не назначены
          </div>
          <table
            v-else
            class="w-full text-sm"
          >
            <thead>
              <tr class="text-left text-gray-500 border-b border-gray-200">
                <th class="py-1 pr-2 font-normal">
                  Вид
                </th>
                <th class="py-1 pr-2 font-normal">
                  Ресурс/группа
                </th>
                <th class="py-1 pr-2 font-normal">
                  Плановое количество
                </th>
                <th class="py-1 font-normal">
                  Единица
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="(row, idx) in flatSummary"
                :key="idx"
                class="border-b border-gray-100 last:border-0"
              >
                <td class="py-1 pr-2">
                  {{ KIND_LABELS[row.kind] }}
                </td>
                <td class="py-1 pr-2">
                  <n-tag
                    size="small"
                    bordered="false"
                    class="mr-1"
                  >
                    {{ row.isGroup ? 'группа' : 'ресурс' }}
                  </n-tag>
                  {{ row.label }}
                </td>
                <td class="py-1 pr-2">
                  {{ row.qty }}
                </td>
                <td class="py-1">
                  {{ row.unit }}
                </td>
              </tr>
            </tbody>
          </table>
        </template>

        <!-- Лист секционированный: блок на участок + итог -->
        <template v-else-if="mode === 'leaf-sectioned'">
          <div
            v-if="sectionedSummary.length === 0 && !loading"
            class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
          >
            ресурсы не назначены ни по одному участку
          </div>
          <div
            v-else
            class="flex flex-col gap-4"
          >
            <div
              v-for="block in sectionedSummary"
              :key="block.sectionId"
            >
              <h4 class="text-sm font-medium mb-1">
                {{ block.sectionName }}
              </h4>
              <div
                v-if="!hasRows(block.rows)"
                class="text-sm text-gray-400 italic"
              >
                ресурсы не назначены
              </div>
              <table
                v-else
                class="w-full text-sm"
              >
                <thead>
                  <tr class="text-left text-gray-500 border-b border-gray-200">
                    <th class="py-1 pr-2 font-normal">
                      Вид
                    </th>
                    <th class="py-1 pr-2 font-normal">
                      Ресурс/группа
                    </th>
                    <th class="py-1 pr-2 font-normal">
                      Плановое количество
                    </th>
                    <th class="py-1 font-normal">
                      Единица
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="(row, idx) in block.rows"
                    :key="idx"
                    class="border-b border-gray-100 last:border-0"
                  >
                    <td class="py-1 pr-2">
                      {{ KIND_LABELS[row.kind] }}
                    </td>
                    <td class="py-1 pr-2">
                      <n-tag
                        size="small"
                        bordered="false"
                        class="mr-1"
                      >
                        {{ row.isGroup ? 'группа' : 'ресурс' }}
                      </n-tag>
                      {{ row.label }}
                    </td>
                    <td class="py-1 pr-2">
                      {{ row.qty }}
                    </td>
                    <td class="py-1">
                      {{ row.unit }}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="border-t border-gray-300 pt-2">
              <h4 class="text-sm font-medium mb-1">
                Итого по работе
              </h4>
              <div
                v-if="!hasRows(sectionedTotal)"
                class="text-sm text-gray-400 italic"
              >
                ресурсы не назначены
              </div>
              <table
                v-else
                class="w-full text-sm"
              >
                <thead>
                  <tr class="text-left text-gray-500 border-b border-gray-200">
                    <th class="py-1 pr-2 font-normal">
                      Вид
                    </th>
                    <th class="py-1 pr-2 font-normal">
                      Ресурс/группа
                    </th>
                    <th class="py-1 pr-2 font-normal">
                      Плановое количество
                    </th>
                    <th class="py-1 font-normal">
                      Единица
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="(row, idx) in sectionedTotal"
                    :key="idx"
                    class="border-b border-gray-100 last:border-0"
                  >
                    <td class="py-1 pr-2">
                      {{ KIND_LABELS[row.kind] }}
                    </td>
                    <td class="py-1 pr-2">
                      <n-tag
                        size="small"
                        bordered="false"
                        class="mr-1"
                      >
                        {{ row.isGroup ? 'группа' : 'ресурс' }}
                      </n-tag>
                      {{ row.label }}
                    </td>
                    <td class="py-1 pr-2">
                      {{ row.qty }}
                    </td>
                    <td class="py-1">
                      {{ row.unit }}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </template>
      </n-spin>

      <p class="text-xs text-gray-500 mt-2">
        для изменения откройте Редактор дневного плана из ячейки обзорного календаря
      </p>
    </template>
  </div>
</template>
