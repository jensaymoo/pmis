<script setup>
//
// Редактор работы — единственная точка правки атрибутов работы (встроенный
// редактор задач Bryntum отключён). Модальное окно с единой вертикальной
// прокруткой: Атрибуты → Календарный план (обзор) → Участки → Сводка
// ресурсов → Зависимости → Факт. См. planning-task-editor.md целиком.
//
// Контракт компонента фиксирован (см. бриф Агента B, роадмап фазы 6, Гант):
// props { show, taskId, parentTask, presetMilestone }, emits ['update:show','saved'].
//
// Дочерние разделы (TaskSectionsPanel/ResourceSummaryPanel/TaskDependenciesPanel/
// TaskFactPanel) создаёт параллельно Агент C — на момент написания этого файла
// их ещё нет на диске, импорты ниже — по контракту. DailyPlanEditorModal
// (Редактор дневного плана, модалка второго уровня) создаёт Агент D — тоже
// по контракту, файла может не быть на диске на момент сборки.
//
import { computed, reactive, ref, watch, nextTick } from 'vue'
import { useMessage, useNotification, useDialog } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import QtyUnitPickerModal from './QtyUnitPickerModal.vue'
import OrgUnitTree from '../admin/OrgUnitTree.vue'
import TaskSectionsPanel from './TaskSectionsPanel.vue'
import ResourceSummaryPanel from './ResourceSummaryPanel.vue'
import TaskDependenciesPanel from './TaskDependenciesPanel.vue'
import TaskFactPanel from './TaskFactPanel.vue'
import DailyPlanEditorModal from './DailyPlanEditorModal.vue'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** null = создание новой работы. */
  taskId: { type: String, default: null },
  /** Родительская работа (полная запись) либо null для корневого узла. */
  parentTask: { type: Object, default: null },
  presetMilestone: { type: Boolean, default: false },
  /**
   * Активный проект — нужен только при создании КОРНЕВОЙ работы (когда нет
   * parentTask), чтобы отправить project_id. Передаётся родительским
   * GanttView.vue из его resolveActiveProject(). Если пуст при создании
   * корневой работы — это ошибка использования компонента, но мы не
   * блокируем код: просто не отправляем project_id и даём серверу вернуть
   * 400/403, показываем это уведомлением (см. бриф §«project_id»).
   */
  activeProjectId: { type: String, default: null },
})

const emit = defineEmits(['update:show', 'saved'])

const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()
const dialog = useDialog()

// --------------------------------------------------------------------------
// Состояние работы (загрузка + производные флаги)
// --------------------------------------------------------------------------

/** @type {import('vue').Ref<object|null>} */
const task = ref(null)
const isLeaf = ref(false)
const isSectioned = ref(false)
const isReadonly = ref(false)
const loadingTask = ref(false)

/** ID текущей работы: taskId проп при редактировании, либо ID, полученный после первого POST при создании. */
const currentTaskId = ref(props.taskId)

const isCreating = computed(() => currentTaskId.value === null)

const TASK_SELECT =
  'id,project_id,parent_id,org_unit_id,task_type,name,start_date,end_date,duration,plan_qty,qty_unit_id,percent_done,actual_start,actual_end,status,qty_unit:qty_unit_id(name,short_name,is_integer),org_unit:org_unit_id(name)'

/**
 * Загружает работу целиком + вычисляет isLeaf/isSectioned/isReadonly.
 * Переиспользуется дочерними разделами через @changed="reloadTask".
 * @returns {Promise<void>}
 */
async function reloadTask() {
  if (!currentTaskId.value) return
  loadingTask.value = true
  try {
    const [{ data, error }, leafCount, sectionCount] = await Promise.all([
      getClient().from('task').select(TASK_SELECT).eq('id', currentTaskId.value).single(),
      getClient()
        .from('task')
        .select('id', { count: 'exact', head: true })
        .eq('parent_id', currentTaskId.value)
        .neq('status', 'deprecated'),
      getClient()
        .from('task_section')
        .select('id', { count: 'exact', head: true })
        .eq('task_id', currentTaskId.value)
        .neq('status', 'deprecated'),
    ])

    if (error) {
      console.error('Не удалось загрузить работу:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    task.value = data
    isLeaf.value = (leafCount.count ?? 0) === 0
    isSectioned.value = (sectionCount.count ?? 0) > 0
    isReadonly.value = data.org_unit_id !== auth.user?.org_unit_id

    resetFormFromTask()
  } finally {
    loadingTask.value = false
  }
}

// --------------------------------------------------------------------------
// Форма атрибутов
// --------------------------------------------------------------------------

const formRef = ref(null)
const saving = ref(false)
const dirty = ref(false)

const form = reactive({
  name: '',
  isMilestone: false,
  start_date: null, // ms timestamp (n-date-picker)
  end_date: null,
  duration: 0,
  plan_qty: null,
  qty_unit_id: null,
  qty_unit_label: '',
  org_unit_id: null,
  org_unit_label: '',
})

/** Флаг подавления взаимного пересчёта дат/длительности (см. §3 брифа). */
let isRecalculating = false

function resetFormFromTask() {
  const t = task.value
  if (!t) return
  form.name = t.name ?? ''
  form.isMilestone = t.task_type === 'milestone'
  form.start_date = t.start_date ? new Date(t.start_date).getTime() : null
  form.end_date = t.end_date ? new Date(t.end_date).getTime() : null
  form.duration = t.duration ?? 0
  form.plan_qty = t.plan_qty ?? null
  form.qty_unit_id = t.qty_unit_id ?? null
  form.qty_unit_label = t.qty_unit?.name ?? ''
  form.org_unit_id = t.org_unit_id ?? null
  form.org_unit_label = t.org_unit?.name ?? ''
  dirty.value = false
}

/** Инициализирует форму для режима создания. */
function resetFormForCreate() {
  form.name = ''
  form.isMilestone = props.presetMilestone
  const now = new Date()
  now.setHours(0, 0, 0, 0)
  form.start_date = now.getTime()
  form.end_date = props.presetMilestone ? now.getTime() : now.getTime()
  form.duration = 0
  form.plan_qty = null
  form.qty_unit_id = null
  form.qty_unit_label = ''
  form.org_unit_id = props.parentTask?.org_unit_id ?? auth.user?.org_unit_id ?? null
  form.org_unit_label = props.parentTask?.org_unit?.name ?? ''
  dirty.value = false
}

/** Тип узла для матрицы §6: 'milestone' | 'leaf-plain' | 'leaf-sectioned' | 'composite'. */
const nodeKind = computed(() => {
  if (form.isMilestone) return 'milestone'
  if (isCreating.value) return 'leaf-plain'
  if (!isLeaf.value) return 'composite'
  return isSectioned.value ? 'leaf-sectioned' : 'leaf-plain'
})

const showPlanQty = computed(() => nodeKind.value !== 'milestone')
const planQtyDisabled = computed(
  () => nodeKind.value === 'leaf-sectioned' || nodeKind.value === 'composite',
)
const planQtyHint = computed(() => {
  if (nodeKind.value === 'leaf-sectioned') return 'сумма по участкам'
  if (nodeKind.value === 'composite') return 'объём составной работы складывается из подчинённых'
  return ''
})

const showQtyUnit = computed(() => nodeKind.value !== 'milestone')
const qtyUnitDisabled = computed(() => nodeKind.value === 'composite')

const showEndDate = computed(() => !form.isMilestone)
const durationDisabled = computed(() => form.isMilestone)

const milestoneSwitchDisabled = computed(() => !isCreating.value)

const formDisabled = computed(() => saving.value || isReadonly.value || loadingTask.value)

const rules = computed(() => ({
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  start_date: [{ required: true, type: 'number', message: 'Укажите дату начала', trigger: ['blur', 'change'] }],
  end_date: showEndDate.value
    ? [{ required: true, type: 'number', message: 'Укажите дату окончания', trigger: ['blur', 'change'] }]
    : [],
  plan_qty:
    showPlanQty.value && !planQtyDisabled.value
      ? [{ required: true, type: 'number', message: 'Укажите плановый объём', trigger: ['blur', 'change'] }]
      : [],
  qty_unit_id:
    showQtyUnit.value && !qtyUnitDisabled.value
      ? [{ required: true, message: 'Выберите единицу объёма', trigger: ['blur', 'change'] }]
      : [],
}))

// --- пересчёт дат/длительности (без циклов) ---

function msToDuration(startMs, endMs) {
  if (startMs == null || endMs == null) return 0
  return Math.round((endMs - startMs) / 86400000)
}

function durationToEndMs(startMs, days) {
  if (startMs == null) return null
  return startMs + days * 86400000
}

watch(
  () => [form.start_date, form.end_date],
  ([startMs, endMs]) => {
    if (isRecalculating || form.isMilestone) return
    if (startMs == null || endMs == null) return
    isRecalculating = true
    form.duration = msToDuration(startMs, endMs)
    isRecalculating = false
  },
)

watch(
  () => form.duration,
  (days) => {
    if (isRecalculating || form.isMilestone) return
    if (days == null || form.start_date == null) return
    isRecalculating = true
    form.end_date = durationToEndMs(form.start_date, days)
    isRecalculating = false
  },
)

watch(
  () => form.isMilestone,
  (isMilestone) => {
    if (isMilestone) {
      isRecalculating = true
      form.duration = 0
      form.end_date = form.start_date
      isRecalculating = false
    }
  },
)

/** Отмечает форму как «изменённую» на любую правку атрибутов (для §7.4). */
watch(
  () => [
    form.name,
    form.isMilestone,
    form.start_date,
    form.end_date,
    form.duration,
    form.plan_qty,
    form.qty_unit_id,
    form.org_unit_id,
  ],
  () => {
    if (!loadingTask.value) dirty.value = true
  },
)

// --------------------------------------------------------------------------
// Сохранение атрибутов
// --------------------------------------------------------------------------

/** @returns {string} ISO-дата (полночь UTC) для отправки на сервер. */
function toIsoDate(ms) {
  return new Date(ms).toISOString()
}

function buildPayload() {
  const payload = {
    name: form.name,
    task_type: form.isMilestone ? 'milestone' : 'task',
    start_date: toIsoDate(form.start_date),
    end_date: toIsoDate(form.isMilestone ? form.start_date : form.end_date),
    duration: form.isMilestone ? 0 : form.duration,
    org_unit_id: form.org_unit_id,
  }
  if (!form.isMilestone) {
    payload.plan_qty = planQtyDisabled.value ? undefined : form.plan_qty
    payload.qty_unit_id = qtyUnitDisabled.value ? undefined : form.qty_unit_id
  }
  return payload
}

async function onSubmit() {
  if (isReadonly.value) return
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  saving.value = true
  try {
    if (isCreating.value) {
      const payload = {
        parent_id: props.parentTask?.id ?? null,
        ...buildPayload(),
      }
      const projectId = props.parentTask?.project_id ?? props.activeProjectId
      if (projectId) {
        payload.project_id = projectId
      } else {
        console.warn('TaskEditorModal: activeProjectId не задан при создании корневой работы')
      }

      const { data, error } = await getClient().from('task').insert(payload).select().single()
      if (error) {
        console.error('Не удалось создать работу:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }

      message.success(form.isMilestone ? 'Веха создана' : 'Работа создана')
      currentTaskId.value = data.id
      dirty.value = false
      await reloadTask()
      emit('saved')
      // Окно НЕ закрывается (task-editor.md §7.1, §10) — разделы становятся доступны.
    } else {
      const payload = buildPayload()
      const { error } = await getClient().from('task').update(payload).eq('id', currentTaskId.value)
      if (error) {
        console.error('Не удалось сохранить работу:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }

      message.success('Работа сохранена')
      await reloadTask()
      emit('saved')
    }
  } finally {
    saving.value = false
  }
}

// --------------------------------------------------------------------------
// Пикер единицы объёма
// --------------------------------------------------------------------------

const qtyUnitPickerVisible = ref(false)

function openQtyUnitPicker() {
  if (formDisabled.value || qtyUnitDisabled.value) return
  qtyUnitPickerVisible.value = true
}

/** @param {{id: string, name: string, short_name: string, is_integer: boolean}} record */
function onQtyUnitPicked(record) {
  form.qty_unit_id = record.id
  form.qty_unit_label = record.name
}

// --------------------------------------------------------------------------
// Пикер организации (OrgUnitTree, mode="pick", emit "select")
// --------------------------------------------------------------------------

const orgUnitPickerVisible = ref(false)

function openOrgUnitPicker() {
  if (formDisabled.value) return
  orgUnitPickerVisible.value = true
}

/** OrgUnitTree в режиме pick эмитит `select`, не `pick` — {id, name}. */
function onOrgUnitSelected({ id, name }) {
  form.org_unit_id = id
  form.org_unit_label = name
}

// --------------------------------------------------------------------------
// Календарный план (обзор)
// --------------------------------------------------------------------------

const showCalendarSection = computed(() => isLeaf.value && !isCreating.value && !form.isMilestone)
const calendarDisabledReason = computed(() => {
  if (isCreating.value) return 'календарный план доступен после первого сохранения'
  if (form.isMilestone) return 'календарный план доступен только для листовых работ'
  if (!isLeaf.value) return 'календарный план доступен только для листовых работ'
  return ''
})

/** @type {import('vue').Ref<Array<{id:string, task_id:string, task_section_id:string|null, date:string, plan_qty:number}>>} */
const dailyPlans = ref([])
const dailyPlansLoading = ref(false)

/** Карта task_section_id -> имя участка (для секционированной работы). */
const sectionNames = ref({})

async function loadDailyPlans() {
  if (!currentTaskId.value || !isLeaf.value) return
  dailyPlansLoading.value = true
  try {
    const { data, error } = await getClient()
      .from('task_daily_plan')
      .select('id,task_id,task_section_id,date,plan_qty')
      .eq('task_id', currentTaskId.value)
      .order('date')
    if (error) {
      console.error('Не удалось загрузить дневной план:', error)
      dailyPlans.value = []
      return
    }
    dailyPlans.value = data
  } finally {
    dailyPlansLoading.value = false
  }
}

async function loadSectionNames() {
  if (!currentTaskId.value || !isSectioned.value) {
    sectionNames.value = {}
    return
  }
  const { data, error } = await getClient()
    .from('task_section')
    .select('id,section:section_id(name)')
    .eq('task_id', currentTaskId.value)
  if (error) {
    console.error('Не удалось загрузить участки работы:', error)
    sectionNames.value = {}
    return
  }
  sectionNames.value = Object.fromEntries(data.map((ts) => [ts.id, ts.section?.name ?? ts.id]))
}

watch([currentTaskId, isLeaf, isSectioned], () => {
  if (currentTaskId.value && isLeaf.value) {
    loadDailyPlans()
    loadSectionNames()
  }
})

/** Дни планового периода [start_date, end_date] как массив ISO-дат (YYYY-MM-DD). */
const periodDays = computed(() => {
  if (!task.value?.start_date || !task.value?.end_date) return []
  const start = new Date(task.value.start_date)
  const end = new Date(task.value.end_date)
  start.setHours(0, 0, 0, 0)
  end.setHours(0, 0, 0, 0)
  const days = []
  for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
    days.push(d.toISOString().slice(0, 10))
  }
  return days
})

/** Множество дат планового периода — быстрая проверка «входит ли день в период». */
const periodDaySet = computed(() => new Set(periodDays.value))

/** Первый день планового периода — начальное значение выбора в date-picker. */
const calendarDefaultValue = computed(() => {
  if (!task.value?.start_date) return null
  const d = new Date(task.value.start_date)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
})

/** @param {number} ts @returns {boolean} true, если день вне планового периода (для is-date-disabled). */
function isDateOutsidePeriod(ts) {
  return !periodDaySet.value.has(new Date(ts).toISOString().slice(0, 10))
}

/** Выбранный в date-picker день (timestamp), слева от таблицы плана на сутки. */
const calendarPickerValue = ref(null)

/** При первой загрузке работы — выставляем выбор на первый день периода. */
watch(calendarDefaultValue, (v) => {
  if (v != null && calendarPickerValue.value == null) calendarPickerValue.value = v
})

/** Выбранный день как YYYY-MM-DD. */
const selectedDayStr = computed(() => {
  if (calendarPickerValue.value == null) return null
  return new Date(calendarPickerValue.value).toISOString().slice(0, 10)
})

const selectedDayInPeriod = computed(
  () => selectedDayStr.value != null && periodDaySet.value.has(selectedDayStr.value),
)

/** Плановый объём выбранного дня (несекционированная работа). */
const selectedDayPlainQty = computed(() => plainPlanByDate.value[selectedDayStr.value]?.plan_qty ?? 0)

/** Строки таблицы плана на выбранные сутки для секционированной работы: все участки работы, с признаком наличия записи. */
const selectedDaySectionRows = computed(() => {
  if (!selectedDayStr.value) return []
  const plans = sectionedPlanByDate.value[selectedDayStr.value] ?? []
  const plansBySection = Object.fromEntries(plans.map((p) => [p.task_section_id, p]))
  return Object.entries(sectionNames.value).map(([taskSectionId, name]) => ({
    taskSectionId,
    name,
    planQty: plansBySection[taskSectionId]?.plan_qty ?? null,
    exists: Boolean(plansBySection[taskSectionId]),
  }))
})

/** Записи дневного плана несекционированной работы, сгруппированные по дате. */
const plainPlanByDate = computed(() => {
  const map = {}
  for (const p of dailyPlans.value) {
    if (p.task_section_id === null) map[p.date] = p
  }
  return map
})

/** Записи дневного плана секционированной работы, сгруппированные по дате -> список. */
const sectionedPlanByDate = computed(() => {
  const map = {}
  for (const p of dailyPlans.value) {
    if (p.task_section_id !== null) {
      if (!map[p.date]) map[p.date] = []
      map[p.date].push(p)
    }
  }
  return map
})

/** Σ дневных объёмов (несекц. — по работе целиком; секц. — по всем участкам). */
const dailyPlanSum = computed(() => dailyPlans.value.reduce((sum, p) => sum + (p.plan_qty ?? 0), 0))

const remainder = computed(() => {
  const total = task.value?.plan_qty ?? 0
  return total - dailyPlanSum.value
})

const remainderOverflow = computed(() => remainder.value < 0)

// --- открытие Редактора дневного плана ---

const dailyPlanVisible = ref(false)
const selectedDate = ref(null)
const selectedTaskSectionId = ref(null)
/** Меняется при каждом сохранении дневного плана — заставляет ResourceSummaryPanel перечитаться. */
const dailyPlanRefreshCounter = ref(0)

/** @param {string} date */
function openDailyPlanForDate(date) {
  if (isReadonly.value) return
  selectedDate.value = date
  selectedTaskSectionId.value = null
  dailyPlanVisible.value = true
}

/** @param {string} date @param {string} taskSectionId */
function openDailyPlanForSection(date, taskSectionId) {
  if (isReadonly.value) return
  selectedDate.value = date
  selectedTaskSectionId.value = taskSectionId
  dailyPlanVisible.value = true
}

async function onDailyPlanSaved() {
  await loadDailyPlans()
  dailyPlanRefreshCounter.value += 1
}

// --------------------------------------------------------------------------
// Дочерние разделы: видимость по типу узла
// --------------------------------------------------------------------------

const sectionsChildLeaf = computed(() => isLeaf.value && !form.isMilestone)

// --------------------------------------------------------------------------
// Заголовок окна
// --------------------------------------------------------------------------

const modalTitle = computed(() => {
  if (!isCreating.value) return task.value?.name ?? ''
  const kind = props.presetMilestone ? 'Новая веха' : 'Новая работа'
  const parentLabel = props.parentTask?.name ?? 'в корне'
  return `${kind} — ${parentLabel}`
})

// --------------------------------------------------------------------------
// Открытие/закрытие окна
// --------------------------------------------------------------------------

const nameInputRef = ref(null)

watch(
  () => props.show,
  async (visible) => {
    if (!visible) return
    currentTaskId.value = props.taskId
    task.value = null
    isLeaf.value = false
    isSectioned.value = false
    isReadonly.value = false
    dailyPlans.value = []
    sectionNames.value = {}
    calendarPickerValue.value = null

    if (currentTaskId.value) {
      await reloadTask()
      await loadDailyPlans()
      await loadSectionNames()
    } else {
      resetFormForCreate()
    }

    await nextTick()
    nameInputRef.value?.focus?.()
  },
  { immediate: true },
)

/** Закрытие с проверкой несохранённых изменений атрибутов (§7.4). */
function requestClose() {
  if (dirty.value && !isReadonly.value) {
    dialog.warning({
      title: 'Изменения не сохранены',
      content: 'Закрыть окно без сохранения атрибутов работы?',
      positiveText: 'Закрыть без сохранения',
      negativeText: 'Продолжить редактирование',
      autoFocus: false,
      onPositiveClick: () => {
        emit('update:show', false)
      },
    })
    return
  }
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
    class="w-full max-w-5xl"
    :style="{ maxHeight: '90vh' }"
    :segmented="{ content: true, footer: true }"
    :trap-focus="false"
    @update:show="onModalUpdateShow"
    @close="requestClose"
    @esc="requestClose"
  >
    <n-spin :show="loadingTask">
      <div
        class="flex flex-col gap-6 overflow-y-auto pr-1"
        style="max-height: 72vh"
      >
        <!-- ================= Атрибуты работы ================= -->
        <section>
          <h3 class="font-medium mb-2">
            Атрибуты работы
          </h3>
          <n-form
            ref="formRef"
            :model="form"
            :rules="rules"
            :disabled="formDisabled"
            @submit.prevent="onSubmit"
          >
            <n-form-item
              label="Наименование"
              path="name"
              required
            >
              <n-input
                ref="nameInputRef"
                v-model:value="form.name"
                placeholder="Наименование работы"
              />
            </n-form-item>

            <n-form-item label="Веха">
              <n-switch
                v-model:value="form.isMilestone"
                :disabled="formDisabled || milestoneSwitchDisabled"
              />
              <span class="ml-2 text-xs text-gray-500">
                {{ milestoneSwitchDisabled ? 'признак фиксируется при создании и далее не меняется' : 'нулевая длительность, без объёма' }}
              </span>
            </n-form-item>

            <n-form-item
              label="Начало"
              path="start_date"
              required
            >
              <n-date-picker
                v-model:value="form.start_date"
                type="date"
                class="w-full"
              />
            </n-form-item>

            <n-form-item
              v-if="showEndDate"
              label="Окончание"
              path="end_date"
              required
            >
              <n-date-picker
                v-model:value="form.end_date"
                type="date"
                class="w-full"
              />
            </n-form-item>

            <n-form-item label="Длительность, дн.">
              <n-input-number
                v-model:value="form.duration"
                :disabled="formDisabled || durationDisabled"
                :min="0"
                class="w-full"
              />
            </n-form-item>

            <n-form-item
              v-if="showPlanQty"
              label="Плановый объём"
              path="plan_qty"
              :required="!planQtyDisabled"
            >
              <n-input-number
                v-model:value="form.plan_qty"
                :disabled="formDisabled || planQtyDisabled"
                :precision="task?.qty_unit?.is_integer ? 0 : undefined"
                class="w-full"
              />
              <p
                v-if="planQtyHint"
                class="text-xs text-gray-500 mt-1"
              >
                {{ planQtyHint }}
              </p>
            </n-form-item>

            <n-form-item
              v-if="showQtyUnit"
              label="Единица объёма"
              path="qty_unit_id"
              :required="!qtyUnitDisabled"
            >
              <div class="flex items-center gap-2 w-full">
                <n-input
                  :value="form.qty_unit_label"
                  readonly
                  placeholder="Не выбрана"
                  class="flex-1"
                />
                <n-button
                  size="small"
                  :disabled="formDisabled || qtyUnitDisabled"
                  @click="openQtyUnitPicker"
                >
                  Выбрать
                </n-button>
              </div>
              <p
                v-if="qtyUnitDisabled"
                class="text-xs text-gray-500 mt-1"
              >
                объём составной работы складывается из подчинённых
              </p>
            </n-form-item>

            <n-form-item label="Организация">
              <div class="flex items-center gap-2 w-full">
                <n-input
                  :value="form.org_unit_label"
                  readonly
                  placeholder="Не выбрана"
                  class="flex-1"
                />
                <n-button
                  size="small"
                  :disabled="formDisabled"
                  @click="openOrgUnitPicker"
                >
                  Выбрать
                </n-button>
              </div>
            </n-form-item>

            <div
              v-if="!isReadonly"
              class="flex justify-end"
            >
              <n-button
                type="primary"
                attr-type="submit"
                :loading="saving"
                :disabled="saving"
                @click="onSubmit"
              >
                {{ isCreating ? 'Создать' : 'Сохранить' }}
              </n-button>
            </div>
            <p
              v-else
              class="text-xs text-gray-500"
            >
              Работа вышестоящей зоны — только просмотр
            </p>
          </n-form>
        </section>

        <!-- ================= Календарный план (обзор) ================= -->
        <section v-if="!isCreating">
          <h3 class="font-medium mb-1">
            Календарный план
          </h3>
          <p class="text-xs text-gray-500 mb-2">
            выберите день слева — справа план на выбранные сутки
          </p>

          <div
            v-if="!showCalendarSection"
            class="text-sm text-gray-400 italic"
          >
            {{ calendarDisabledReason }}
          </div>

          <div v-else>
            <div class="flex items-center justify-between mb-2">
              <span
                class="text-sm"
                :class="remainderOverflow ? 'text-red-600 font-medium' : 'text-gray-600'"
              >
                Остаток: {{ remainder }} / plan_qty: {{ task?.plan_qty ?? 0 }}
              </span>
            </div>

            <n-spin :show="dailyPlansLoading">
              <div
                v-if="isSectioned && Object.keys(sectionNames).length === 0"
                class="text-sm text-gray-400 italic py-4"
              >
                привяжите участок в разделе «Участки» и создайте дневной план
              </div>

              <div
                v-else
                class="flex gap-4 items-start"
              >
                <n-date-picker
                  v-model:value="calendarPickerValue"
                  panel
                  type="date"
                  :is-date-disabled="isDateOutsidePeriod"
                />

                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium mb-2">
                    {{ selectedDayStr ?? 'Выберите день' }}
                  </div>

                  <div
                    v-if="!selectedDayInPeriod"
                    class="text-sm text-gray-400 italic"
                  >
                    день вне планового периода работы
                  </div>

                  <template v-else>
                    <!-- Несекционированная работа -->
                    <n-table
                      v-if="!isSectioned"
                      size="small"
                      :bordered="false"
                      :single-line="false"
                    >
                      <thead>
                        <tr>
                          <th>Плановый объём</th>
                          <th style="width: 1%" />
                        </tr>
                      </thead>
                      <tbody>
                        <tr>
                          <td>{{ selectedDayPlainQty }}</td>
                          <td>
                            <n-button
                              v-if="!isReadonly"
                              size="tiny"
                              quaternary
                              @click="openDailyPlanForDate(selectedDayStr)"
                            >
                              Редактировать
                            </n-button>
                          </td>
                        </tr>
                      </tbody>
                    </n-table>

                    <!-- Секционированная работа -->
                    <n-table
                      v-else
                      size="small"
                      :bordered="false"
                      :single-line="false"
                    >
                      <thead>
                        <tr>
                          <th>Участок</th>
                          <th>Объём</th>
                          <th style="width: 1%" />
                        </tr>
                      </thead>
                      <tbody>
                        <tr v-if="selectedDaySectionRows.length === 0">
                          <td
                            colspan="3"
                            class="text-gray-400 italic"
                          >
                            привяжите участок в разделе «Участки»
                          </td>
                        </tr>
                        <tr
                          v-for="row in selectedDaySectionRows"
                          :key="row.taskSectionId"
                        >
                          <td>{{ row.name }}</td>
                          <td>{{ row.planQty ?? '—' }}</td>
                          <td>
                            <n-button
                              v-if="!isReadonly"
                              size="tiny"
                              quaternary
                              @click="
                                row.exists
                                  ? openDailyPlanForSection(selectedDayStr, row.taskSectionId)
                                  : openDailyPlanForDate(selectedDayStr)
                              "
                            >
                              {{ row.exists ? 'Изменить' : 'Добавить' }}
                            </n-button>
                          </td>
                        </tr>
                      </tbody>
                    </n-table>
                  </template>
                </div>
              </div>
            </n-spin>
          </div>
        </section>

        <!-- ================= Участки / Сводка ресурсов / Зависимости / Факт ================= -->
        <template v-if="!isCreating">
          <TaskSectionsPanel
            :task="task"
            :is-leaf="sectionsChildLeaf"
            :is-sectioned="isSectioned"
            :readonly="isReadonly"
            @changed="reloadTask"
          />
          <ResourceSummaryPanel
            :task="task"
            :is-leaf="sectionsChildLeaf"
            :is-sectioned="isSectioned"
            :refresh-token="dailyPlanRefreshCounter"
          />
          <TaskDependenciesPanel
            :task="task"
            :is-leaf="sectionsChildLeaf"
            :is-sectioned="isSectioned"
            :readonly="isReadonly"
            @changed="reloadTask"
          />
          <TaskFactPanel
            :task="task"
            :is-leaf="sectionsChildLeaf"
            :is-sectioned="isSectioned"
          />
        </template>
      </div>
    </n-spin>

    <template #footer>
      <div class="flex justify-end">
        <n-button @click="requestClose">
          Закрыть
        </n-button>
      </div>
    </template>
  </n-modal>

  <QtyUnitPickerModal
    v-model:show="qtyUnitPickerVisible"
    @pick="onQtyUnitPicked"
  />

  <OrgUnitTree
    :show="orgUnitPickerVisible"
    mode="pick"
    :model-value="form.org_unit_id"
    @update:show="(v) => (orgUnitPickerVisible = v)"
    @select="onOrgUnitSelected"
  />

  <DailyPlanEditorModal
    v-model:show="dailyPlanVisible"
    :task="task"
    :date="selectedDate"
    :task-section-id="selectedTaskSectionId"
    @saved="onDailyPlanSaved"
  />
</template>
