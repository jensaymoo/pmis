<script setup>
//
// Раздел «Факт» Редактора работы — planning-task-editor.md §5. ПОЛНОСТЬЮ
// read-only блок: прогресс (%), фактическое начало, фактическое завершение.
// Ни одного элемента ввода ни для какой роли — правка факта возможна только
// закрытием наряда (fact-and-work-orders-business, правило 1). Показывается
// для любого типа узла, в т.ч. составной работы (агрегат по листовым
// потомкам, планируется сервером) и вехи (без объёмов).
//
import { computed } from 'vue'

const props = defineProps({
  /** Полная запись работы (task) + вложенные qty_unit, org_unit. */
  task: { type: Object, required: true },
  isLeaf: { type: Boolean, default: false },
  isSectioned: { type: Boolean, default: false },
  readonly: { type: Boolean, default: false },
})

/** @param {string|null} value */
function formatDate(value) {
  if (!value) return '—'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleDateString('ru-RU')
}

const percentDone = computed(() => Number(props.task?.percent_done) || 0)
const actualStart = computed(() => formatDate(props.task?.actual_start))
const actualEnd = computed(() => formatDate(props.task?.actual_end))
const isMilestone = computed(() => props.task?.task_type === 'milestone')
</script>

<template>
  <div class="border-t border-gray-200 pt-4 mt-4">
    <h3
      class="text-base font-medium mb-2"
      aria-label="Факт (только просмотр)"
    >
      Факт
      <span class="text-xs font-normal text-gray-400">(только просмотр)</span>
    </h3>

    <div class="bg-gray-50 border border-gray-200 rounded p-3">
      <dl class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-sm">
        <div>
          <dt class="text-gray-500">
            Прогресс
          </dt>
          <dd class="font-medium">
            {{ percentDone }}%
          </dd>
        </div>
        <div v-if="!isMilestone">
          <dt class="text-gray-500">
            Фактическое начало
          </dt>
          <dd class="font-medium">
            {{ actualStart }}
          </dd>
        </div>
        <div v-if="!isMilestone">
          <dt class="text-gray-500">
            Фактическое завершение
          </dt>
          <dd class="font-medium">
            {{ actualEnd }}
          </dd>
        </div>
      </dl>
      <p class="text-xs text-gray-500 mt-3">
        данные поступают из закрытых нарядов
      </p>
    </div>
  </div>
</template>
