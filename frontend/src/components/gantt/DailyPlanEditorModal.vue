<script setup>
//
// Редактор дневного плана — модальное окно ВТОРОГО уровня, открывается из
// ячейки обзорного календаря Редактора работы (TaskEditorModal.vue).
// planning-task-resources.md целиком. Контракт фиксирован Агентом B (см.
// импорт/использование в TaskEditorModal.vue): props { show, task, date,
// taskSectionId }, emits ['update:show','saved'].
//
// Режим определяется по факту наличия записи task_daily_plan для (task_id,
// date, task_section_id): если найдена — редактирование, иначе — создание.
// Три таба ресурсов активны только когда запись дневного плана уже существует
// (иначе task_daily_plan_id ещё нет, привязывать назначения некуда).
//
import { computed, h, reactive, ref, watch } from 'vue'
import { useMessage, useNotification, useDialog, NButton, NTag } from 'naive-ui'
import { getClient } from '../../lib/postgrest'
import GroupsTableModal from '../resources/GroupsTableModal.vue'
import ResourcePickerModal from './ResourcePickerModal.vue'
import SectionsGrid from '../references/SectionsGrid.vue'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** Родительская работа: id, name, plan_qty, qty_unit {short_name, is_integer}. */
  task: { type: Object, default: null },
  /** 'YYYY-MM-DD' */
  date: { type: String, default: null },
  /** preset участка; null = несекционированная ИЛИ ещё не выбран. */
  taskSectionId: { type: String, default: null },
})

const emit = defineEmits(['update:show', 'saved'])

const message = useMessage()
const notification = useNotification()
const dialog = useDialog()

const RESOURCE_KINDS = [
  { key: 'personnel', label: 'Персонал' },
  { key: 'equipment', label: 'Техника' },
  { key: 'materials', label: 'Материалы' },
]

// --------------------------------------------------------------------------
// Состояние работы / участка / режима
// --------------------------------------------------------------------------

/** Работа секционирована, если у неё есть привязанные (не deprecated) task_section. */
const isSectioned = ref(false)
const sectionOptions = ref([]) // [{ label, value }]
const loadingSections = ref(false)

/** null = ещё не определён (в процессе загрузки). */
const existingId = ref(null)
const existingLoaded = ref(false)
const loadingPlan = ref(false)

/** Выбранный участок формы (id task_section или null). */
const selectedTaskSectionId = ref(props.taskSectionId ?? null)
/** Заблокирован ли select участка (редактирование или preset). */
const sectionLocked = computed(() => existingId.value !== null || props.taskSectionId !== null)

const isCreating = computed(() => existingId.value === null)

/** Плановый объём выбранного участка (для расчёта максимума), либо plan_qty работы для несекц. */
const targetPlanQty = ref(null)
const loadingTargetPlanQty = ref(false)

const planQty = ref(null)
const otherDaysSum = ref(0)
const loadingOtherDays = ref(false)

const formattedDate = computed(() => {
  if (!props.date) return ''
  const d = new Date(`${props.date}T00:00:00`)
  return d.toLocaleDateString('ru-RU', { day: '2-digit', month: 'long', year: 'numeric' })
})

const unitLabel = computed(() => props.task?.qty_unit?.short_name ?? '')
const isIntegerUnit = computed(() => !!props.task?.qty_unit?.is_integer)

const modalTitle = computed(() => `${props.task?.name ?? ''} — ${formattedDate.value}`)

// --------------------------------------------------------------------------
// Загрузка: определение секционирования и опций участков
// --------------------------------------------------------------------------

async function loadSectionOptions() {
  if (!props.task?.id) {
    sectionOptions.value = []
    isSectioned.value = false
    return
  }
  loadingSections.value = true
  try {
    const { data, error } = await getClient()
      .from('task_section')
      .select('id,section:section_id(name)')
      .eq('task_id', props.task.id)
      .neq('status', 'deprecated')
    if (error) {
      console.error('Не удалось загрузить участки работы:', error)
      notification.error({ content: error.message, duration: 6000 })
      sectionOptions.value = []
      isSectioned.value = false
      return
    }
    sectionOptions.value = (data ?? []).map((ts) => ({ label: ts.section?.name ?? ts.id, value: ts.id }))
    isSectioned.value = (data ?? []).length > 0
  } finally {
    loadingSections.value = false
  }
}

// --------------------------------------------------------------------------
// Загрузка: существующая запись дневного плана (режим)
// --------------------------------------------------------------------------

async function loadExistingPlan() {
  if (!props.task?.id || !props.date) return
  loadingPlan.value = true
  existingLoaded.value = false
  try {
    let query = getClient()
      .from('task_daily_plan')
      .select('id,plan_qty')
      .eq('task_id', props.task.id)
      .eq('date', props.date)

    if (selectedTaskSectionId.value === null) {
      query = query.is('task_section_id', null)
    } else {
      query = query.eq('task_section_id', selectedTaskSectionId.value)
    }

    const { data, error } = await query.maybeSingle()
    if (error) {
      console.error('Не удалось загрузить дневной план:', error)
      notification.error({ content: error.message, duration: 6000 })
      existingId.value = null
      planQty.value = null
      return
    }

    if (data) {
      existingId.value = data.id
      planQty.value = Number(data.plan_qty)
    } else {
      existingId.value = null
      planQty.value = null
    }
  } finally {
    loadingPlan.value = false
    existingLoaded.value = true
  }
}

// --------------------------------------------------------------------------
// Загрузка: максимум (plan_qty участка/работы) и сумма остальных дней
// --------------------------------------------------------------------------

async function loadTargetPlanQty() {
  loadingTargetPlanQty.value = true
  try {
    if (selectedTaskSectionId.value === null) {
      targetPlanQty.value = props.task?.plan_qty ?? null
      return
    }
    const { data, error } = await getClient()
      .from('task_section')
      .select('plan_qty')
      .eq('id', selectedTaskSectionId.value)
      .single()
    if (error) {
      console.error('Не удалось загрузить плановый объём участка:', error)
      targetPlanQty.value = null
      return
    }
    targetPlanQty.value = Number(data.plan_qty)
  } finally {
    loadingTargetPlanQty.value = false
  }
}

async function loadOtherDaysSum() {
  if (!props.task?.id) return
  loadingOtherDays.value = true
  try {
    let query = getClient().from('task_daily_plan').select('id,plan_qty').eq('task_id', props.task.id)
    if (selectedTaskSectionId.value === null) {
      query = query.is('task_section_id', null)
    } else {
      query = query.eq('task_section_id', selectedTaskSectionId.value)
    }
    const { data, error } = await query
    if (error) {
      console.error('Не удалось загрузить дневные планы для расчёта остатка:', error)
      otherDaysSum.value = 0
      return
    }
    otherDaysSum.value = (data ?? [])
      .filter((p) => p.id !== existingId.value)
      .reduce((sum, p) => sum + (Number(p.plan_qty) || 0), 0)
  } finally {
    loadingOtherDays.value = false
  }
}

async function reloadVolumeContext() {
  await Promise.all([loadTargetPlanQty(), loadOtherDaysSum()])
}

// --------------------------------------------------------------------------
// Остаток / валидация объёма
// --------------------------------------------------------------------------

const remainder = computed(() => {
  const total = targetPlanQty.value ?? 0
  return total - otherDaysSum.value - (planQty.value ?? 0)
})

const maxAllowed = computed(() => {
  const total = targetPlanQty.value ?? 0
  return Math.max(0, total - otherDaysSum.value)
})

const volumeInvalid = computed(() => {
  if (planQty.value === null || planQty.value === undefined) return true
  if (planQty.value < 0) return true
  if (targetPlanQty.value !== null && planQty.value > maxAllowed.value) return true
  return false
})

const sectionMissing = computed(() => isSectioned.value && !selectedTaskSectionId.value)

// --------------------------------------------------------------------------
// Резолвинг всей формы при открытии / смене участка
// --------------------------------------------------------------------------

async function resolveMode() {
  await loadExistingPlan()
  await reloadVolumeContext()
}

watch(
  () => props.show,
  async (visible) => {
    if (!visible) return
    selectedTaskSectionId.value = props.taskSectionId ?? null
    existingId.value = null
    existingLoaded.value = false
    planQty.value = null
    targetPlanQty.value = null
    otherDaysSum.value = 0
    activeTab.value = 'personnel'
    resetAssignmentTables()

    await loadSectionOptions()
    await resolveMode()

    if (existingId.value) {
      loadAllAssignments()
    }
  },
  { immediate: true },
)

/** Смена участка вручную (только когда select не заблокирован). */
watch(selectedTaskSectionId, async (val, oldVal) => {
  if (!props.show) return
  if (val === oldVal) return
  if (sectionLocked.value) return
  existingId.value = null
  planQty.value = null
  await resolveMode()
})

// --------------------------------------------------------------------------
// Просмотр карточки участка (read-only)
// --------------------------------------------------------------------------

const sectionViewVisible = ref(false)

function openSectionView() {
  if (!selectedTaskSectionId.value) return
  sectionViewVisible.value = true
}

// --------------------------------------------------------------------------
// Таблицы назначений ресурсов (3 таба)
// --------------------------------------------------------------------------

const activeTab = ref('personnel')

/** { personnel: { rows, loading }, equipment: {...}, materials: {...} } */
const assignments = reactive({
  personnel: { rows: [], loading: false },
  equipment: { rows: [], loading: false },
  materials: { rows: [], loading: false },
})

function resetAssignmentTables() {
  for (const kind of Object.keys(assignments)) {
    assignments[kind].rows = []
    assignments[kind].loading = false
  }
}

async function loadAssignments(kind) {
  if (!existingId.value) return
  assignments[kind].loading = true
  try {
    const { data, error } = await getClient()
      .from(`${kind}_resource_plan`)
      .select(
        'id,resource_id,group_id,plan_qty,status,resource:resource_id(name,unit:unit_id(short_name)),group:group_id(name,unit:unit_id(short_name))',
      )
      .eq('task_daily_plan_id', existingId.value)
      .neq('status', 'deprecated')
    if (error) {
      console.error(`Не удалось загрузить назначения ресурсов (${kind}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      assignments[kind].rows = []
      return
    }
    assignments[kind].rows = data ?? []
  } finally {
    assignments[kind].loading = false
  }
}

function loadAllAssignments() {
  for (const { key } of RESOURCE_KINDS) {
    loadAssignments(key)
  }
}

// --------------------------------------------------------------------------
// Форма добавления назначения (шаги: тип -> пикер -> количество)
// --------------------------------------------------------------------------

const addFormVisible = ref(false)
const addFormKind = ref(null)
const addFormType = ref('group') // 'group' | 'resource'
const addFormPicked = ref(null) // { id, name, unit: { short_name } } либо { id, name, unit_id }
const addFormQty = ref(null)
const addFormSaving = ref(false)
const addQtyInputRef = ref(null)

const groupPickerVisible = ref(false)
const resourcePickerVisible = ref(false)

function openAddForm(kind) {
  addFormKind.value = kind
  addFormType.value = 'group'
  addFormPicked.value = null
  addFormQty.value = null
  addFormVisible.value = true
}

function closeAddForm() {
  addFormVisible.value = false
  addFormKind.value = null
  addFormPicked.value = null
  addFormQty.value = null
}

function openPickerForAddForm() {
  if (addFormType.value === 'group') {
    groupPickerVisible.value = true
  } else {
    resourcePickerVisible.value = true
  }
}

/**
 * GroupsTableModal (pick-mode) отдаёт «сырую» запись группы (select: '*') —
 * без вложенного unit, только unit_id. Подгружаем short_name отдельно, чтобы
 * форма добавления показывала единицу так же, как для конкретного ресурса.
 * @param {object} record Запись группы: {id, name, unit_id, ...}.
 */
async function onGroupPicked(record) {
  addFormPicked.value = { id: record.id, name: record.name, unit: null }
  if (record.unit_id) {
    const { data, error } = await getClient()
      .from(`${addFormKind.value}_unit`)
      .select('short_name')
      .eq('id', record.unit_id)
      .maybeSingle()
    if (!error && data) {
      addFormPicked.value = { ...addFormPicked.value, unit: { short_name: data.short_name } }
    }
  }
  focusAddQty()
}

/** @param {object} record Из ResourcePickerModal: {id, name, unit_id, unit: {short_name}}. */
function onResourcePicked(record) {
  addFormPicked.value = record
  focusAddQty()
}

function focusAddQty() {
  requestAnimationFrame(() => {
    addQtyInputRef.value?.focus?.()
  })
}

const addFormUnitLabel = computed(() => addFormPicked.value?.unit?.short_name ?? '')

async function submitAddForm() {
  if (!addFormPicked.value || addFormQty.value === null || addFormQty.value === undefined) return
  if (!existingId.value) return
  addFormSaving.value = true
  try {
    const payload = {
      task_daily_plan_id: existingId.value,
      plan_qty: addFormQty.value,
      resource_id: addFormType.value === 'resource' ? addFormPicked.value.id : null,
      group_id: addFormType.value === 'group' ? addFormPicked.value.id : null,
    }
    const { error } = await getClient().from(`${addFormKind.value}_resource_plan`).insert(payload)
    if (error) {
      console.error('Не удалось добавить назначение ресурса:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    message.success('Ресурс назначен')
    closeAddForm()
    await loadAssignments(addFormKind.value)
    emit('saved')
  } finally {
    addFormSaving.value = false
  }
}

// --------------------------------------------------------------------------
// Изменение количества назначения
// --------------------------------------------------------------------------

const editQtyVisible = ref(false)
const editQtyKind = ref(null)
const editQtyRow = ref(null)
const editQtyValue = ref(null)
const editQtySaving = ref(false)
const editQtyInputRef = ref(null)

function openEditQty(kind, row) {
  editQtyKind.value = kind
  editQtyRow.value = row
  editQtyValue.value = Number(row.plan_qty)
  editQtyVisible.value = true
  requestAnimationFrame(() => {
    editQtyInputRef.value?.focus?.()
  })
}

function closeEditQty() {
  editQtyVisible.value = false
  editQtyKind.value = null
  editQtyRow.value = null
  editQtyValue.value = null
}

async function submitEditQty() {
  if (editQtyValue.value === null || editQtyValue.value === undefined) return
  editQtySaving.value = true
  try {
    const { error } = await getClient()
      .from(`${editQtyKind.value}_resource_plan`)
      .update({ plan_qty: editQtyValue.value })
      .eq('id', editQtyRow.value.id)
    if (error) {
      console.error('Не удалось изменить количество назначения:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    message.success('Количество обновлено')
    const kind = editQtyKind.value
    closeEditQty()
    await loadAssignments(kind)
    emit('saved')
  } finally {
    editQtySaving.value = false
  }
}

// --------------------------------------------------------------------------
// Удаление назначения
// --------------------------------------------------------------------------

/** @param {string} kind @param {object} row */
function removeAssignment(kind, row) {
  dialog.warning({
    title: 'Удалить назначение?',
    content: 'Назначение перестанет требоваться при фактировании.',
    positiveText: 'Удалить',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      const { error } = await getClient().from(`${kind}_resource_plan`).delete().eq('id', row.id)
      if (error) {
        console.error('Не удалось удалить назначение ресурса:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Назначение удалено')
      await loadAssignments(kind)
      emit('saved')
    },
  })
}

// --------------------------------------------------------------------------
// Сохранение дневного плана (Создать / Сохранить / Очистить)
// --------------------------------------------------------------------------

const saving = ref(false)

const canSubmit = computed(() => {
  if (volumeInvalid.value) return false
  if (sectionMissing.value) return false
  return true
})

async function onSubmit() {
  if (!canSubmit.value) return
  saving.value = true
  try {
    if (isCreating.value) {
      const payload = {
        task_id: props.task.id,
        task_section_id: selectedTaskSectionId.value ?? null,
        date: props.date,
        plan_qty: planQty.value,
      }
      const { data, error } = await getClient().from('task_daily_plan').insert(payload).select().single()
      if (error) {
        console.error('Не удалось создать дневной план:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Дневной план создан')
      existingId.value = data.id
      emit('saved')
      emit('update:show', false)
    } else {
      const { error } = await getClient()
        .from('task_daily_plan')
        .update({ plan_qty: planQty.value })
        .eq('id', existingId.value)
      if (error) {
        console.error('Не удалось сохранить дневной план:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Дневной план сохранён')
      emit('saved')
      emit('update:show', false)
    }
  } finally {
    saving.value = false
  }
}

function onClear() {
  if (!existingId.value) return
  dialog.warning({
    title: 'Очистить дневной план?',
    content: 'Плановый объём на этот день будет установлен в 0.',
    positiveText: 'Очистить',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      saving.value = true
      try {
        const { error } = await getClient()
          .from('task_daily_plan')
          .update({ plan_qty: 0 })
          .eq('id', existingId.value)
        if (error) {
          console.error('Не удалось очистить дневной план:', error)
          notification.error({ content: error.message, duration: 6000 })
          return
        }
        message.success('Дневной план очищен')
        emit('saved')
        emit('update:show', false)
      } finally {
        saving.value = false
      }
    },
  })
}

function requestClose() {
  emit('update:show', false)
}

function onModalUpdateShow(value) {
  if (!value) {
    requestClose()
    return
  }
  emit('update:show', value)
}
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    :title="modalTitle"
    class="w-full max-w-3xl"
    :style="{ maxHeight: '88vh' }"
    :segmented="{ content: true, footer: true }"
    @update:show="onModalUpdateShow"
    @close="requestClose"
    @esc="requestClose"
  >
    <div
      class="flex flex-col gap-4 overflow-y-auto pr-1"
      style="max-height: 68vh"
    >
      <!-- ================= Выбор участка ================= -->
      <div v-if="isSectioned">
        <n-spin :show="loadingSections">
          <label class="block text-sm font-medium mb-1">Участок</label>
          <div class="flex items-center gap-2">
            <n-select
              v-model:value="selectedTaskSectionId"
              :options="sectionOptions"
              :disabled="sectionLocked"
              placeholder="Выберите участок"
              class="flex-1"
            />
            <n-button
              size="small"
              circle
              :disabled="!selectedTaskSectionId"
              title="Просмотреть участок"
              @click="openSectionView"
            >
              🔍
            </n-button>
          </div>
          <p
            v-if="sectionMissing"
            class="text-xs text-red-600 mt-1"
          >
            выберите участок, чтобы указать плановый объём
          </p>
        </n-spin>
      </div>

      <!-- ================= Плановый объём ================= -->
      <div>
        <label class="block text-sm font-medium mb-1">Плановый объём</label>
        <n-spin :show="loadingPlan || loadingTargetPlanQty || loadingOtherDays">
          <div class="flex items-center gap-2">
            <n-input-number
              v-model:value="planQty"
              :min="0"
              :precision="isIntegerUnit ? 0 : undefined"
              :status="volumeInvalid ? 'error' : undefined"
              :disabled="sectionMissing"
              class="flex-1"
            />
            <span class="text-sm text-gray-500 w-16">{{ unitLabel }}</span>
          </div>
          <p
            class="text-xs mt-1"
            :class="remainder < 0 ? 'text-red-600 font-medium' : 'text-gray-500'"
          >
            Остаток: {{ remainder }}
          </p>
        </n-spin>
      </div>

      <!-- ================= Ресурсы (3 таба) ================= -->
      <div>
        <n-tabs
          v-model:value="activeTab"
          type="line"
        >
          <n-tab-pane
            v-for="kind in RESOURCE_KINDS"
            :key="kind.key"
            :name="kind.key"
            :tab="kind.label"
          >
            <div
              v-if="!existingId"
              class="text-sm text-gray-400 italic py-4"
            >
              сохраните дневной объём, чтобы назначить ресурсы
            </div>

            <template v-else>
              <div class="flex justify-end mb-2">
                <n-button
                  size="small"
                  @click="openAddForm(kind.key)"
                >
                  Добавить
                </n-button>
              </div>

              <div
                v-if="assignments[kind.key].rows.length === 0 && !assignments[kind.key].loading"
                class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
              >
                ресурсы не назначены
              </div>

              <n-data-table
                v-else
                :columns="[
                  {
                    title: 'Назначение',
                    key: 'assignment',
                    render: (row) =>
                      h('div', { class: 'flex items-center gap-2' }, [
                        h(
                          NTag,
                          { size: 'small', bordered: false, type: row.group_id ? 'info' : 'default' },
                          () => (row.group_id ? 'группа' : 'ресурс'),
                        ),
                        h('span', row.group_id ? (row.group?.name ?? row.group_id) : (row.resource?.name ?? row.resource_id)),
                      ]),
                  },
                  {
                    title: 'Плановое количество',
                    key: 'plan_qty',
                    width: 160,
                  },
                  {
                    title: 'Единица',
                    key: 'unit',
                    width: 110,
                    render: (row) => (row.group_id ? row.group?.unit?.short_name : row.resource?.unit?.short_name) ?? '—',
                  },
                  {
                    title: 'Действия',
                    key: 'actions',
                    width: 220,
                    render: (row) =>
                      h('div', { class: 'flex gap-2' }, [
                        h(
                          NButton,
                          { size: 'tiny', onClick: () => openEditQty(kind.key, row) },
                          () => 'Изменить количество',
                        ),
                        h(
                          NButton,
                          { size: 'tiny', onClick: () => removeAssignment(kind.key, row) },
                          () => 'Удалить',
                        ),
                      ]),
                  },
                ]"
                :data="assignments[kind.key].rows"
                :loading="assignments[kind.key].loading"
                :row-key="(row) => row.id"
                :bordered="false"
                size="small"
              />
            </template>
          </n-tab-pane>
        </n-tabs>
      </div>
    </div>

    <template #footer>
      <div class="flex justify-end gap-2">
        <template v-if="isCreating">
          <n-button
            type="primary"
            :loading="saving"
            :disabled="saving || !canSubmit"
            @click="onSubmit"
          >
            Создать
          </n-button>
        </template>
        <template v-else>
          <n-button
            :disabled="saving"
            @click="onClear"
          >
            Очистить
          </n-button>
          <n-button
            type="primary"
            :loading="saving"
            :disabled="saving || !canSubmit"
            @click="onSubmit"
          >
            Сохранить
          </n-button>
        </template>
      </div>
    </template>
  </n-modal>

  <!-- ================= Форма добавления назначения ================= -->
  <n-modal
    :show="addFormVisible"
    preset="card"
    title="Добавить ресурс"
    class="w-full max-w-md"
    @update:show="(v) => { if (!v) closeAddForm() }"
  >
    <div class="flex flex-col gap-3">
      <div>
        <label class="block text-sm font-medium mb-1">Тип</label>
        <n-radio-group
          v-model:value="addFormType"
          @update:value="addFormPicked = null"
        >
          <n-radio-button value="group">
            Группа
          </n-radio-button>
          <n-radio-button value="resource">
            Конкретный ресурс
          </n-radio-button>
        </n-radio-group>
      </div>

      <div>
        <label class="block text-sm font-medium mb-1">
          {{ addFormType === 'group' ? 'Группа' : 'Ресурс' }}
        </label>
        <div class="flex items-center gap-2">
          <n-input
            :value="addFormPicked?.name ?? ''"
            readonly
            placeholder="Не выбрано"
            class="flex-1"
          />
          <n-button
            size="small"
            @click="openPickerForAddForm"
          >
            Выбрать
          </n-button>
        </div>
      </div>

      <div>
        <label class="block text-sm font-medium mb-1">Количество</label>
        <div class="flex items-center gap-2">
          <n-input-number
            ref="addQtyInputRef"
            v-model:value="addFormQty"
            :min="0"
            :disabled="!addFormPicked"
            class="flex-1"
          />
          <span class="text-sm text-gray-500 w-16">{{ addFormUnitLabel }}</span>
        </div>
      </div>
    </div>

    <template #footer>
      <div class="flex justify-end gap-2">
        <n-button @click="closeAddForm">
          Отмена
        </n-button>
        <n-button
          type="primary"
          :loading="addFormSaving"
          :disabled="!addFormPicked || addFormQty === null || addFormQty === undefined"
          @click="submitAddForm"
        >
          Добавить
        </n-button>
      </div>
    </template>
  </n-modal>

  <!-- ================= Изменение количества назначения ================= -->
  <n-modal
    :show="editQtyVisible"
    preset="card"
    title="Изменить количество"
    class="w-full max-w-sm"
    @update:show="(v) => { if (!v) closeEditQty() }"
  >
    <n-input-number
      ref="editQtyInputRef"
      v-model:value="editQtyValue"
      :min="0"
      class="w-full"
    />
    <template #footer>
      <div class="flex justify-end gap-2">
        <n-button @click="closeEditQty">
          Отмена
        </n-button>
        <n-button
          type="primary"
          :loading="editQtySaving"
          :disabled="editQtyValue === null || editQtyValue === undefined"
          @click="submitEditQty"
        >
          Сохранить
        </n-button>
      </div>
    </template>
  </n-modal>

  <!-- ================= Пикеры для формы добавления ================= -->
  <GroupsTableModal
    v-if="groupPickerVisible"
    :show="groupPickerVisible"
    :kind="addFormKind"
    pick-mode
    @update:show="(v) => (groupPickerVisible = v)"
    @pick="onGroupPicked"
  />

  <ResourcePickerModal
    v-model:show="resourcePickerVisible"
    :kind="addFormKind ?? 'personnel'"
    @pick="onResourcePicked"
  />

  <!-- ================= Просмотр участка (read-only) ================= -->
  <SectionsGrid
    v-if="sectionViewVisible"
    :show="sectionViewVisible"
    @update:show="(v) => (sectionViewVisible = v)"
  />
</template>
