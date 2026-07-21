<script setup>
//
// Модалка-справочник «Единицы измерения» для вида ресурса (персонал/техника/
// материалы) — грид с поддержкой режима выбора (пикер). Фильтры (поиск по
// имени и по статусу) вынесены в попаперы в заголовках колонок
// (resources-pattern.md §7.1). Форма создания/редактирования и действия
// жизненного цикла — в UnitFormModal.vue (слот #header-extra).
// См. resources-pattern.md §2.2, §6.1-6.4, resources-personnel-units.md.
//
import { h, computed, ref, watch } from 'vue'
import { NInput, NCheckboxGroup, NCheckbox, NSpace } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import { useReferenceList } from '../../adapters/naivePostgrest'
import StatusTag from '../references/StatusTag.vue'
import GridFilterHeader from '../references/GridFilterHeader.vue'
import UnitFormModal from './UnitFormModal.vue'
import { STATUS_OPTIONS, DEFAULT_STATUSES } from '../../constants/statusOptions'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
  /** Режим выбора (пикер) — resources-pattern.md §2.2 */
  pickMode: { type: Boolean, default: false },
})

const emit = defineEmits(['update:show', 'pick'])

const auth = useAuthStore()
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const table = computed(() => `${props.kind}_unit`)

const list = useReferenceList({
  getClient,
  table: table.value,
  select: '*',
  searchColumn: 'name',
  defaultStatuses: isDispatcher.value ? ['enabled'] : ['created', 'enabled', 'disabled'],
})

const selectedRow = ref(null)
const rowKey = (row) => row.id

function isRowSelected(row) {
  return selectedRow.value?.id === row.id
}

function onRowClick(row) {
  selectedRow.value = row
}

function onRowDblClick(row) {
  openEdit(row)
}

const rowProps = (row) => ({
  class: isRowSelected(row) ? 'bg-blue-50 cursor-pointer' : 'cursor-pointer',
  onClick: () => onRowClick(row),
  onDblclick: () => onRowDblClick(row),
})

// --- форма создания/редактирования ---

const formVisible = ref(false)
const editingRecord = ref(null)

function openCreate() {
  editingRecord.value = null
  formVisible.value = true
}

/** @param {object} row */
function openEdit(row) {
  editingRecord.value = row
  formVisible.value = true
}

function onSaved() {
  list.reload()
}

// --- заголовки колонок с попаперами-фильтрами ---

/**
 * Заголовок колонки «Наименование» с попапером текстового поиска.
 * Debounce перед отправкой значения в search берёт на себя GridFilterHeader.
 * @returns {import('vue').VNode}
 */
function nameHeader() {
  return h(
    GridFilterHeader,
    {
      label: 'Наименование',
      modelValue: list.search.value,
      apply: (v) => (list.search.value = v),
      active: !!list.search.value.trim(),
    },
    {
      default: ({ value, update }) =>
        h(NInput, {
          value: value.value,
          clearable: true,
          size: 'small',
          placeholder: 'Поиск...',
          style: 'width: 224px',
          'onUpdate:value': update,
        }),
    },
  )
}

/**
 * Заголовок колонки «Статус» с попапером выбора статуса.
 * @returns {import('vue').VNode}
 */
function statusHeader() {
  return h(
    GridFilterHeader,
    {
      label: 'Статус',
      modelValue: list.statusFilter.value,
      apply: (v) => (list.statusFilter.value = v),
      active: !arraysEqual(list.statusFilter.value, DEFAULT_STATUSES),
    },
    {
      default: ({ value, update }) =>
        h(
          NCheckboxGroup,
          {
            value: value.value,
            'onUpdate:value': update,
          },
          () =>
            h(
              NSpace,
              { vertical: true, size: 4 },
              () =>
                STATUS_OPTIONS.map((opt) =>
                  h(NCheckbox, { value: opt.value, label: opt.label }),
                ),
            ),
        ),
    },
  )
}

/** Побитовое сравнение двух массивов статусов без учёта порядка. */
function arraysEqual(a, b) {
  if (a.length !== b.length) return false
  const set = new Set(a)
  return b.every((x) => set.has(x))
}

const columns = computed(() => [
  { title: nameHeader, key: 'name' },
  { title: 'Сокращение', key: 'short_name', width: 120 },
  {
    title: 'Целочисленность',
    key: 'is_integer',
    width: 140,
    render: (row) => (row.is_integer ? 'Целая' : 'Дробная'),
  },
  {
    title: statusHeader,
    key: 'status',
    width: 110,
    render: (row) => h(StatusTag, { status: row.status }),
  },
])

// --- футер режима выбора ---

function onPick() {
  if (!selectedRow.value) return
  emit('pick', selectedRow.value)
  emit('update:show', false)
}

function onClose() {
  selectedRow.value = null
  emit('update:show', false)
}

watch(
  () => props.show,
  (visible) => {
    if (visible) {
      selectedRow.value = null
      list.reload()
    }
  },
)
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    title="Единицы измерения"
    class="w-full max-w-3xl"
    @update:show="(value) => emit('update:show', value)"
    @close="onClose"
  >
    <div class="flex items-center justify-end mb-3">
      <n-button
        v-if="!isDispatcher && !props.pickMode"
        type="primary"
        @click="openCreate"
      >
        Создать
      </n-button>
    </div>

    <n-data-table
      remote
      :columns="columns"
      :data="list.rows.value"
      :pagination="list.pagination.value"
      :loading="list.loading.value"
      :row-key="rowKey"
      :row-props="rowProps"
      :bordered="false"
      max-height="360"
    >
      <template #empty>
        Пока нет ни одной записи, создайте первую.
      </template>
    </n-data-table>

    <template #footer>
      <div
        v-if="props.pickMode"
        class="flex justify-end"
      >
        <n-button
          type="primary"
          :disabled="!selectedRow"
          @click="onPick"
        >
          Выбрать
        </n-button>
      </div>
    </template>
  </n-modal>

  <UnitFormModal
    v-model:show="formVisible"
    :kind="props.kind"
    :record="editingRecord"
    @saved="onSaved"
  />
</template>
