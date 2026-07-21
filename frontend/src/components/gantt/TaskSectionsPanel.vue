<script setup>
//
// Раздел «Участки» Редактора работы — planning-task-sections.md. Таблица связей
// «работа × участок» (task_section) с итоговой строкой Σ, пикером справочника
// участков (SectionsGrid.vue, pick-mode) и построчными операциями «изменить
// объём» / «отвязать». Доступен только листовым работам (props.isLeaf).
//
// Каждая операция уходит на сервер немедленно (planning-task-editor.md §2) —
// собственного сохранения у раздела нет. После любого успешного изменения
// эмитим 'changed', чтобы родитель (TaskEditorModal) перечитал task: plan_qty
// секционированной работы — производная сумма, считает её сервер.
//
import { computed, h, ref, watch } from 'vue'
import { NButton, NInputNumber, NTag } from 'naive-ui'
import { useMessage, useNotification, useDialog } from 'naive-ui'
import { getClient } from '../../lib/postgrest'
import SectionsGrid from '../references/SectionsGrid.vue'

const props = defineProps({
  /** Полная запись работы (task) + вложенные qty_unit, org_unit. */
  task: { type: Object, required: true },
  isLeaf: { type: Boolean, default: false },
  isSectioned: { type: Boolean, default: false },
  readonly: { type: Boolean, default: false },
})

const emit = defineEmits(['changed'])

const message = useMessage()
const notification = useNotification()
const dialog = useDialog()

const KIND_LABELS = { linear: 'протяжённый', area: 'площадной' }

const rows = ref([])
const loading = ref(false)

/** Загружает связи «работа × участок», активные (не deprecated). */
async function loadRows() {
  if (!props.isLeaf || !props.task?.id) {
    rows.value = []
    return
  }
  loading.value = true
  try {
    const { data, error } = await getClient()
      .from('task_section')
      .select('id,section_id,plan_qty,percent_done,actual_start,actual_end,status,section:section_id(name,kind)')
      .eq('task_id', props.task.id)
      .neq('status', 'deprecated')
    if (error) {
      console.error('Не удалось загрузить участки работы:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    rows.value = data ?? []
  } finally {
    loading.value = false
  }
}

watch(
  () => [props.task?.id, props.isLeaf],
  () => loadRows(),
  { immediate: true },
)

const totalPlanQty = computed(() => rows.value.reduce((sum, r) => sum + (Number(r.plan_qty) || 0), 0))
const unitLabel = computed(() => props.task?.qty_unit?.short_name ?? '')

const addDisabledReason = computed(() => {
  if (!props.task?.qty_unit_id) return 'выберите единицу объёма работы'
  return ''
})

// --- пикер участков ---

const pickerVisible = ref(false)
const boundSectionIds = computed(() => new Set(rows.value.map((r) => r.section_id)))

function openPicker() {
  if (addDisabledReason.value) return
  pickerVisible.value = true
}

/** @param {object} record Выбранный участок из SectionsGrid (pick-mode). */
function onPickSection(record) {
  if (boundSectionIds.value.has(record.id)) {
    notification.warning({ content: 'Этот участок уже привязан к работе', duration: 4000 })
    return
  }
  pickerVisible.value = false
  openVolumeForm({ mode: 'create', section: record })
}

// --- мини-форма планового объёма ---

const volumeFormVisible = ref(false)
const volumeFormMode = ref('create') // 'create' | 'edit'
const volumeFormValue = ref(null)
const volumeFormSaving = ref(false)
const volumeFormTarget = ref(null) // { section } для create, { row } для edit
const volumeInputRef = ref(null)

/** @param {{mode: 'create'|'edit', section?: object, row?: object}} opts */
function openVolumeForm(opts) {
  volumeFormMode.value = opts.mode
  volumeFormTarget.value = opts.mode === 'create' ? { section: opts.section } : { row: opts.row }
  volumeFormValue.value = opts.mode === 'edit' ? Number(opts.row.plan_qty) : null
  volumeFormVisible.value = true
  requestAnimationFrame(() => {
    volumeInputRef.value?.focus?.()
  })
}

function closeVolumeForm() {
  volumeFormVisible.value = false
  volumeFormTarget.value = null
  volumeFormValue.value = null
}

async function submitVolumeForm() {
  if (volumeFormValue.value === null || volumeFormValue.value === undefined) return
  volumeFormSaving.value = true
  try {
    if (volumeFormMode.value === 'create') {
      const section = volumeFormTarget.value.section
      const { error } = await getClient().from('task_section').insert({
        task_id: props.task.id,
        section_id: section.id,
        plan_qty: volumeFormValue.value,
      })
      if (error) {
        console.error('Не удалось привязать участок к работе:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Участок привязан')
    } else {
      const row = volumeFormTarget.value.row
      const { error } = await getClient()
        .from('task_section')
        .update({ plan_qty: volumeFormValue.value })
        .eq('id', row.id)
      if (error) {
        console.error('Не удалось изменить плановый объём участка:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Плановый объём обновлён')
    }
    closeVolumeForm()
    await loadRows()
    emit('changed')
  } finally {
    volumeFormSaving.value = false
  }
}

// --- отвязка ---

/** @param {object} row */
function unbindSection(row) {
  dialog.warning({
    title: 'Отвязать участок?',
    content: 'Объём работы уменьшится на объём этого участка.',
    positiveText: 'Отвязать',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      const { error } = await getClient().from('task_section').delete().eq('id', row.id)
      if (error) {
        console.error('Не удалось отвязать участок:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Участок отвязан')
      await loadRows()
      emit('changed')
    },
    onNegativeClick: () => {},
  })
}

// --- просмотр участка (двойной клик по строке) ---

const viewSectionVisible = ref(false)

function openSectionView() {
  viewSectionVisible.value = true
}

const columns = computed(() => {
  const cols = [
    {
      title: 'Участок',
      key: 'section',
      render: (row) => row.section?.name ?? row.section_id,
    },
    {
      title: 'Вид',
      key: 'kind',
      width: 130,
      render: (row) => h(NTag, { size: 'small', bordered: false }, () => KIND_LABELS[row.section?.kind] ?? row.section?.kind),
    },
    {
      title: 'Плановый объём',
      key: 'plan_qty',
      width: 160,
      render: (row) => `${row.plan_qty} ${unitLabel.value}`.trim(),
    },
    {
      title: 'Прогресс',
      key: 'percent_done',
      width: 160,
      render: (row) => {
        const pct = h('span', `${row.percent_done ?? 0}%`)
        if (Number(row.percent_done) >= 100) {
          return h('div', { class: 'flex items-center gap-2' }, [
            pct,
            h(NTag, { size: 'small', type: 'success', bordered: false }, () => 'завершён'),
          ])
        }
        return pct
      },
    },
  ]
  if (!props.readonly) {
    cols.push({
      title: 'Действия',
      key: 'actions',
      width: 200,
      render: (row) =>
        h('div', { class: 'flex gap-2' }, [
          h(
            NButton,
            { size: 'tiny', onClick: () => openVolumeForm({ mode: 'edit', row }) },
            () => 'Изменить объём',
          ),
          h(
            NButton,
            { size: 'tiny', onClick: () => unbindSection(row) },
            () => 'Отвязать',
          ),
        ]),
    })
  }
  return cols
})
</script>

<template>
  <div class="border-t border-gray-200 pt-4 mt-4">
    <h3 class="text-base font-medium mb-2">
      Участки
    </h3>

    <div
      v-if="!isLeaf"
      class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
    >
      раздел доступен только для листовых работ
    </div>

    <template v-else>
      <div class="flex items-center justify-between mb-2">
        <div />
        <n-tooltip
          v-if="!readonly && addDisabledReason"
          trigger="hover"
        >
          <template #trigger>
            <n-button
              disabled
              size="small"
            >
              Добавить участок
            </n-button>
          </template>
          {{ addDisabledReason }}
        </n-tooltip>
        <n-button
          v-else-if="!readonly"
          size="small"
          type="primary"
          @click="openPicker"
        >
          Добавить участок
        </n-button>
      </div>

      <div
        v-if="rows.length === 0 && !loading"
        class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
      >
        работа ведётся целиком; привяжите участок, чтобы разбить её по строительным местам
      </div>

      <template v-else>
        <n-data-table
          :columns="columns"
          :data="rows"
          :loading="loading"
          :row-key="(row) => row.id"
          :row-props="() => ({ ondblclick: openSectionView })"
          :bordered="false"
          size="small"
        />
        <div class="flex justify-end mt-2 text-sm text-gray-600">
          <span>Σ {{ totalPlanQty }} {{ unitLabel }} — плановый объём работы</span>
        </div>
      </template>
    </template>

    <!-- Пикер участков (режим выбора) -->
    <SectionsGrid
      v-if="pickerVisible"
      :show="pickerVisible"
      pick-mode
      @update:show="(v) => (pickerVisible = v)"
      @pick="onPickSection"
    />

    <!-- Просмотр участка (справочник, режим управления — открывается на двойной клик) -->
    <SectionsGrid
      v-if="viewSectionVisible"
      :show="viewSectionVisible"
      @update:show="(v) => (viewSectionVisible = v)"
    />

    <!-- Мини-форма планового объёма по участку -->
    <n-modal
      :show="volumeFormVisible"
      preset="card"
      title="Плановый объём по участку"
      class="w-full max-w-sm"
      @update:show="(v) => { if (!v) closeVolumeForm() }"
    >
      <n-form
        :disabled="volumeFormSaving"
        @submit.prevent="submitVolumeForm"
      >
        <n-form-item :label="`Плановый объём (${unitLabel})`">
          <n-input-number
            ref="volumeInputRef"
            v-model:value="volumeFormValue"
            :min="0"
            :precision="task?.qty_unit?.is_integer ? 0 : undefined"
            class="w-full"
            autofocus
          />
        </n-form-item>
      </n-form>
      <template #footer>
        <div class="flex justify-end gap-2">
          <n-button @click="closeVolumeForm">
            Отмена
          </n-button>
          <n-button
            type="primary"
            :loading="volumeFormSaving"
            :disabled="volumeFormValue === null || volumeFormValue === undefined"
            @click="submitVolumeForm"
          >
            Сохранить
          </n-button>
        </div>
      </template>
    </n-modal>
  </div>
</template>
