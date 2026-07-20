<script setup>
//
// Модалка-справочник «Участки» — sections-screen.md §4.6. Маршрута нет
// (sections-screen.md §1, §7 — фиксированное решение): грид вызывается из
// тулбара экрана «Гант» (Фаза 6, пока не существует) и из режима выбора
// в редакторе работы/наряда. Сам компонент не знает, кто его открыл — точку
// входа монтирует вызывающий экран.
//
// Записи вышестоящей зоны показаны приглушённо, колонка «Действия» для них
// скрыта (sections-screen.md §4.6, resources-pattern.md §3.2).
//
import { h, ref, computed } from 'vue'
import { NButton, NSpace, NTag, NInput, NCheckboxGroup, NCheckbox } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { useReferenceList } from '../../adapters/naivePostgrest'
import { getClient } from '../../lib/postgrest'
import StatusTag from './StatusTag.vue'
import SectionFormModal from './SectionFormModal.vue'
import GridFilterHeader from './GridFilterHeader.vue'
import { STATUS_OPTIONS, DEFAULT_STATUSES } from '../../constants/statusOptions'

const props = defineProps({
  /** Модалка открыта */
  show: { type: Boolean, default: true },
  /** Режим выбора (пикер) — resources-pattern.md §2.2 */
  pickMode: { type: Boolean, default: false },
})

const emit = defineEmits(['update:show', 'pick'])

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
  table: 'section',
  select: '*,org_unit:org_unit_id(name),section_point(count)',
  searchColumn: 'name',
  defaultStatuses: isDispatcher.value ? ['enabled'] : ['created', 'enabled', 'disabled'],
  order: 'name',
})

const showForm = ref(false)
const editingRecord = ref(null)
const selectedRow = ref(null)

const statusOptions = STATUS_OPTIONS

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

function onSaved() {
  reload()
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
                statusOptions.map((opt) =>
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

const KIND_LABELS = { linear: 'Протяжённый', area: 'Площадной' }

const columns = computed(() => {
  const cols = [
    {
      title: nameHeader,
      key: 'name',
      render: (row) =>
        h(
          'span',
          { class: row.status === 'deprecated' ? 'line-through opacity-60' : '' },
          row.name,
        ),
    },
    {
      title: 'Вид',
      key: 'kind',
      width: 130,
      render: (row) => KIND_LABELS[row.kind] ?? row.kind,
    },
    {
      title: 'Географический',
      key: 'is_geographic',
      width: 140,
      render: (row) =>
        h(NTag, { size: 'small', bordered: false, type: row.is_geographic ? 'info' : 'default' }, () =>
          row.is_geographic ? 'Да' : 'Нет'),
    },
    {
      title: 'Точек',
      key: 'points_count',
      width: 90,
      render: (row) => row.section_point?.[0]?.count ?? 0,
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
  ]

  return cols
})
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    title="Участки"
    class="w-full max-w-6xl"
    :style="{ height: '80vh' }"
    :mask-closable="false"
    @update:show="(v) => emit('update:show', v)"
  >
    <div class="flex flex-col h-full">
      <div class="flex items-center justify-end mb-3">
        <n-button
          v-if="!isDispatcher"
          type="primary"
          @click="openCreate"
        >
          Создать
        </n-button>
      </div>

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
    </div>

    <SectionFormModal
      v-model:show="showForm"
      :record="editingRecord"
      @saved="onSaved"
    />
  </n-modal>
</template>
