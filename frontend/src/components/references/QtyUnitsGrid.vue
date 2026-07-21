<script setup>
//
// Грид справочника «Единицы объёма работ» — planning-qty-unit.md §4.4.
// Плоский грид: Наименование, Сокращение, Целочисленность, Организация,
// Статус. Фильтры (поиск по имени и по статусу) вынесены в попаперы в
// заголовках колонок (resources-pattern.md §7.1). Действия жизненного цикла
// перенесены в модалку редактирования (слот #header-extra). Поддерживает
// режим выбора (resources-pattern.md §2.2).
//
import { h, ref, computed } from 'vue'
import { NButton, NInput, NCheckboxGroup, NCheckbox, NSpace } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { useReferenceList } from '../../adapters/naivePostgrest'
import { getClient } from '../../lib/postgrest'
import StatusTag from './StatusTag.vue'
import QtyUnitFormModal from './QtyUnitFormModal.vue'
import GridFilterHeader from './GridFilterHeader.vue'
import { STATUS_OPTIONS, DEFAULT_STATUSES } from '../../constants/statusOptions'

const props = defineProps({
  /** Режим выбора (пикер) — resources-pattern.md §2.2 */
  pickMode: { type: Boolean, default: false },
})

const emit = defineEmits(['pick'])

const auth = useAuthStore()
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const {
  rows,
  loading,
  search,
  statusFilter,
  pagination,
  reload,
} = useReferenceList({
  getClient,
  table: 'qty_unit',
  select: '*,org_unit:org_unit_id(name)',
  searchColumn: 'name',
  defaultStatuses: isDispatcher.value ? ['enabled'] : ['created', 'enabled', 'disabled'],
  order: 'name',
})

const showForm = ref(false)
const editingRecord = ref(null)
const selectedRow = ref(null)

/** @param {object} record @returns {boolean} */
function isOwnRecord(record) {
  return record.org_unit_id === auth.user?.org_unit_id
}

function openCreate() {
  editingRecord.value = null
  showForm.value = true
}

/** @param {object} record */
function openEdit(record) {
  editingRecord.value = record
  showForm.value = true
}

/** @param {object} row */
function onRowClick(row) {
  selectedRow.value = row
}

/** @param {object} row */
function onRowDblClick(row) {
  openEdit(row)
}

function onPick() {
  if (selectedRow.value) {
    emit('pick', selectedRow.value)
  }
}

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
      modelValue: search.value,
      apply: (v) => (search.value = v),
      active: !!search.value.trim(),
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
      modelValue: statusFilter.value,
      apply: (v) => (statusFilter.value = v),
      active: !arraysEqual(statusFilter.value, DEFAULT_STATUSES),
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
  { title: 'Сокращение', key: 'short_name', width: 180 },
  {
    title: 'Целочисленность',
    key: 'is_integer',
    width: 170,
    render: (row) => (row.is_integer ? 'Целая' : 'Дробная'),
  },
  {
    title: 'Организация',
    key: 'org_unit',
    render: (row) =>
      h(
        'span',
        { class: !isOwnRecord(row) ? 'text-gray-400' : '' },
        row.org_unit?.name ?? row.org_unit_id,
      ),
  },
  {
    title: statusHeader,
    key: 'status',
    width: 110,
    render: (row) => h(StatusTag, { status: row.status }),
  },
])

function onSaved() {
  reload()
}
</script>

<template>
  <div class="flex flex-col h-full">
    <header class="page-head-left">
      <div>
        <h1 class="page-head-left-title">
          Единицы объёма работ
        </h1>
        <div class="page-head-left-subtitle">
          Справочник единиц объёма работ проекта
        </div>
      </div>
      <div class="page-head-right">
        <n-button
          v-if="!isDispatcher"
          type="primary"
          @click="openCreate"
        >
          Создать
        </n-button>
      </div>
    </header>

    <div class="flex-1 min-h-0">
      <n-data-table
        remote
        :columns="columns"
        :data="rows"
        :loading="loading"
        :pagination="pagination"
        :row-key="(row) => row.id"
        :row-props="(row) => ({
          class: selectedRow?.id === row.id ? 'bg-blue-50 cursor-pointer' : 'cursor-pointer',
          onClick: () => onRowClick(row),
          onDblclick: () => onRowDblClick(row),
        })"
        flex-height
        class="h-full"
      />
    </div>

    <div
      v-if="props.pickMode"
      class="flex justify-end mt-3 pt-3 border-t border-gray-200"
    >
      <n-button
        type="primary"
        :disabled="!selectedRow"
        @click="onPick"
      >
        Выбрать
      </n-button>
    </div>

    <QtyUnitFormModal
      v-model:show="showForm"
      :record="editingRecord"
      @saved="onSaved"
    />
  </div>
</template>
