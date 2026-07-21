<script setup>
//
// Диаграмма Bryntum Gantt — экран «Гант» (Фаза 6), planning-gantt.md §4–§5.
// Тонкая обёртка-компонент: вся загрузка/синхронизация данных вынесена в
// adapters/bryntumPostgrest.js (frontend-spec.md §4, §10). Встроенный редактор
// задач Bryntum и встроенные контекстные меню отключены — единственная точка
// правки атрибутов работы — кастомная модалка TaskEditorModal (Агент B).
//
import { ref, shallowRef, computed, onMounted, onUnmounted, nextTick } from 'vue'
import { useMessage, useNotification, useDialog } from 'naive-ui'
import { Gantt } from '@bryntum/gantt'
// Структурные стили компонента + тема Stockholm (переменные) — раздельные файлы
// в установленной версии пакета (не единый `gantt.stockholm.css`, как в старых
// версиях/примерах документации). Проверено напрямую по составу node_modules.
import '@bryntum/gantt/gantt.css'
import '@bryntum/gantt/stockholm-light.css'
import '../../assets/bryntum.css'
import { getClient } from '../../lib/postgrest'
import { useAuthStore } from '../../stores/auth'
import {
  resolveActiveProject,
  createProject,
  loadProject,
  syncTaskDates,
  syncTaskParent,
  deleteTaskCascade,
  DEPENDENCY_TYPE_FROM_BRYNTUM,
} from '../../adapters/bryntumPostgrest'
import SectionsGrid from '../references/SectionsGrid.vue'
import TaskEditorModal from './TaskEditorModal.vue'

const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()
const dialog = useDialog()

//
// Официальной Vue3-обёртки (@bryntum/gantt-vue-3) в проекте нет — пользователь
// авторизовал установку только основного пакета @bryntum/gantt (публичный
// trial-алиас @bryntum/gantt-trial, без приватного registry). Виджет создаётся
// и уничтожается вручную через vanilla API (`new Gantt()` / `.destroy()`),
// без обёрточного компонента.
//

/** Контейнер, в который монтируется виджет (передаётся в конфиг `appendTo`). */
const ganttContainerRef = ref(null)
// shallowRef, а не ref: обычный ref() глубоко реактивирует присвоенный объект
// (оборачивает в Proxy), что ломает внутренние WeakMap-привязки и this-идентичность
// Bryntum (задокументированная особенность интеграции с Vue reactivity — тот же
// нюанс, из-за которого официальная обёртка прячет инстанс за .instance.value и
// прямо предупреждает не присваивать его в обычное реактивное поле).
/** @type {import('vue').ShallowRef<Gantt|null>} Созданный императивно инстанс Bryntum Gantt. */
const ganttInstance = shallowRef(null)

// --- состояние экрана: загрузка / пусто (нет проекта) / ошибка / данные ---

const phase = ref('loading') // 'loading' | 'no-project' | 'loading-project' | 'error' | 'ready'
const loadError = ref('')
/** @type {import('vue').Ref<{id: string, name: string, org_unit_id: string}|null>} */
const activeProject = ref(null)
const hasNoTasks = ref(false)

// --- выделение строки для тулбара/контекстного меню ---

/** @type {import('vue').Ref<object|null>} Полная task-запись Bryntum (не сырой серверный row) */
const selectedTask = ref(null)

// --- модалка создания проекта ---

const createProjectVisible = ref(false)
const createProjectName = ref('')
const createProjectLoading = ref(false)

// --- модалка «Участки» ---

const sectionsGridVisible = ref(false)

// --- редактор работы (TaskEditorModal, контракт — Агент B) ---

const editorVisible = ref(false)
const editingTaskId = ref(null)
const editingParentTask = ref(null)
const editingPresetMilestone = ref(false)

// --- поиск по дереву ---

const searchQuery = ref('')

// --- контекстное меню (n-dropdown) ---

const contextMenuVisible = ref(false)
const contextMenuX = ref(0)
const contextMenuY = ref(0)
/** @type {import('vue').Ref<object|null>} Task, на котором открыто меню */
const contextMenuTask = ref(null)

const contextMenuOptions = computed(() => [
  { label: 'Создать подчинённую работу', key: 'create-child-task' },
  { label: 'Создать подчинённую веху', key: 'create-child-milestone' },
  { label: 'Редактировать', key: 'edit' },
  { label: 'Удалить', key: 'delete' },
])

// --- контекстное меню зависимости ---

const depContextMenuVisible = ref(false)
const depContextMenuX = ref(0)
const depContextMenuY = ref(0)
/** @type {import('vue').Ref<object|null>} */
const depContextMenuTarget = ref(null)
const depContextMenuOptions = [{ label: 'Удалить', key: 'delete' }]

// --- компактная форма зависимости (создание/редактирование) ---

const depFormVisible = ref(false)
const depFormLoading = ref(false)
/** @type {import('vue').Ref<null|{mode: 'create'|'edit', id?: string, fromId: string, toId: string, type: string, lag: number}>} */
const depForm = ref(null)

const DEPENDENCY_TYPE_OPTIONS = [
  { label: 'Окончание – начало (FS)', value: 'FS' },
  { label: 'Начало – начало (SS)', value: 'SS' },
  { label: 'Окончание – окончание (FF)', value: 'FF' },
  { label: 'Начало – окончание (SF)', value: 'SF' },
]

/**
 * Статическая конфигурация диаграммы (создаётся один раз при первом монтировании
 * инстанса `new Gantt()`, дальнейшие обновления данных — через
 * `project.loadInlineData()`, см. `ensureGanttInstance`/`reloadTasks`).
 *
 * Имена фич/событий сверены напрямую с типами установленного пакета
 * (node_modules/@bryntum/gantt/gantt.d.ts), а не по памяти/устаревшим примерам
 * документации — раздел с Vue3-обёрткой в ней использует другие имена (например,
 * `onTaskClick` вместо `taskClick`, `dependencyRecord` вместо `dependency`).
 */
const ganttStaticConfig = {
  dependencyIdField: 'sequenceNumber',
  rowHeight: 40,
  barMargin: 8,

  // Единственная точка правки атрибутов — кастомный редактор (planning-gantt.md §4.3).
  taskEdit: false,

  // Отключаем встроенные контекстные меню — заменены Naive UI n-dropdown (§5.3).
  features: {
    taskMenu: false,
    scheduleMenu: false,
    // Прогресс — read-only факт, драг заливки отключён (planning-gantt.md §4.3).
    percentBar: { allowResize: false },
    dependencies: { allowCreate: true },
    dependencyEdit: false,
    tree: true,
  },

  columns: [
    { type: 'name', text: 'Наименование', field: 'name', width: 280 },
    { type: 'startdate', text: 'Начало', field: 'startDate', width: 110, editor: false },
    { type: 'enddate', text: 'Окончание', field: 'endDate', width: 110, editor: false },
    { type: 'duration', text: 'Длительность', width: 110, editor: false },
    {
      text: 'Объём',
      field: 'pmisPlanQty',
      width: 130,
      editor: false,
      renderer({ record }) {
        const qty = record.pmisPlanQty
        const unit = record.pmisQtyUnitShortName
        return `${qty ?? '—'} ${unit ?? ''}`.trim()
      },
    },
    {
      text: 'Прогресс',
      field: 'percentDone',
      width: 140,
      editor: false,
      renderer({ record }) {
        const pct = record.percentDone ?? 0
        return `${pct}%`
      },
    },
  ],

  listeners: {
    // taskClick/taskDblClick/taskContextMenu срабатывают только на баре в
    // правой (диаграммной) панели; для строк табличной панели слева —
    // отдельные grid-события cellClick/cellDblClick/cellContextMenu, где
    // `record` — та же task-запись. Оба входа должны вести к одному
    // поведению (planning-gantt.md §5.2: «Одинарный клик по строке/бару
    // выделяет работу... двойной — открывает редактор»).
    taskClick({ taskRecord }) {
      selectedTask.value = taskRecord
    },
    taskDblClick({ taskRecord }) {
      openEditTask(taskRecord)
    },
    taskContextMenu({ taskRecord, event }) {
      event.preventDefault()
      selectedTask.value = taskRecord
      contextMenuTask.value = taskRecord
      contextMenuX.value = event.clientX
      contextMenuY.value = event.clientY
      contextMenuVisible.value = true
    },
    cellClick({ record }) {
      selectedTask.value = record
    },
    cellDblClick({ record }) {
      openEditTask(record)
    },
    cellContextMenu({ record, event }) {
      event.preventDefault()
      selectedTask.value = record
      contextMenuTask.value = record
      contextMenuX.value = event.clientX
      contextMenuY.value = event.clientY
      contextMenuVisible.value = true
    },
    dependencyContextMenu({ dependency, event }) {
      event.preventDefault()
      depContextMenuTarget.value = dependency
      depContextMenuX.value = event.clientX
      depContextMenuY.value = event.clientY
      depContextMenuVisible.value = true
    },
    dependencyDblClick({ dependency }) {
      openEditDependency(dependency)
    },
    // Окончание перетаскивания/растягивания бара — единичное срабатывание,
    // а не на каждый промежуточный кадр (planning-gantt.md §6.3).
    async taskDrop({ taskRecords }) {
      for (const taskRecord of taskRecords) {
        await persistTaskDates(taskRecord)
      }
    },
    async taskResizeEnd({ taskRecord }) {
      await persistTaskDates(taskRecord)
    },
    // Смена родителя (drag-реорганизация дерева); valid=false — Bryntum сам
    // отклонил перенос (например, недопустимая позиция), синхронизировать нечего.
    async afterTaskDrop({ taskRecords, valid }) {
      if (!valid) return
      for (const taskRecord of taskRecords) {
        await persistTaskParent(taskRecord)
      }
    },
    // Протягивание от края бара к краю другого — отклоняем автоматическое
    // локальное создание связи (return false), открываем свою форму
    // подтверждения типа/лага; создание на сервере — только после неё.
    beforeDependencyCreateFinalize({ source, target }) {
      const fromId = source?.id
      const toId = target?.id
      if (fromId == null || toId == null) return false
      openCreateDependency(fromId, toId)
      return false
    },
  },
}

/**
 * Открывает редактор работы в режиме редактирования.
 * @param {object} taskRecord Bryntum task-запись
 */
function openEditTask(taskRecord) {
  editingTaskId.value = String(taskRecord.id)
  editingParentTask.value = null
  editingPresetMilestone.value = false
  editorVisible.value = true
}

/**
 * Открывает редактор работы в режиме создания.
 * @param {object|null} parentTask Родительская задача (null — создание в корне)
 * @param {boolean} presetMilestone
 */
function openCreateTask(parentTask, presetMilestone) {
  editingTaskId.value = null
  editingParentTask.value = parentTask ?? null
  editingPresetMilestone.value = presetMilestone
  editorVisible.value = true
}

/** Кнопка тулбара «Создать работу» — использует текущее выделение как родителя. */
function onToolbarCreateTask() {
  openCreateTask(selectedTask.value, false)
}

/** Кнопка тулбара «Создать веху». */
function onToolbarCreateMilestone() {
  openCreateTask(selectedTask.value, true)
}

/** Пустое состояние «создайте первую работу» — дублирует кнопку тулбара. */
function onEmptyStateCreateTask() {
  openCreateTask(null, false)
}

/** Обработчик выбора пункта контекстного меню строки/бара. */
function onContextMenuSelect(key) {
  contextMenuVisible.value = false
  const task = contextMenuTask.value
  if (!task) return
  switch (key) {
    case 'create-child-task':
      openCreateTask(task, false)
      break
    case 'create-child-milestone':
      openCreateTask(task, true)
      break
    case 'edit':
      openEditTask(task)
      break
    case 'delete':
      confirmDeleteTask(task)
      break
  }
}

/**
 * Подтверждение и удаление работы (planning-gantt.md §5.4). При отказе сервера
 * дерево не меняется локально — перезагружается с сервера.
 * @param {object} taskRecord
 */
function confirmDeleteTask(taskRecord) {
  dialog.warning({
    title: 'Удалить работу?',
    content: 'Удаляется работа и её поддерево, связи и плановые назначения.',
    positiveText: 'Удалить',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      const { error } = await deleteTaskCascade(getClient(), taskRecord.id)
      if (error) {
        notification.error({ content: error.message, duration: 6000 })
        await reloadTasks()
        return
      }
      message.success('Работа удалена')
      if (selectedTask.value?.id === taskRecord.id) {
        selectedTask.value = null
      }
      await reloadTasks()
    },
  })
}

/**
 * Сохраняет плановые даты после окончания drag/resize бара. При ошибке —
 * откат перезагрузкой данных и уведомление (planning-gantt.md §6.3).
 * @param {object} taskRecord
 */
async function persistTaskDates(taskRecord) {
  const { error } = await syncTaskDates(getClient(), taskRecord.id, {
    startDate: taskRecord.startDate,
    endDate: taskRecord.endDate,
  })
  if (error) {
    notification.error({ content: error.message, duration: 6000 })
    await reloadTasks()
  }
}

/**
 * Сохраняет нового родителя после drag&drop-реорганизации дерева. При ошибке —
 * откат перезагрузкой и уведомление.
 * @param {object} taskRecord
 */
async function persistTaskParent(taskRecord) {
  const { error } = await syncTaskParent(getClient(), taskRecord.id, taskRecord.parentId ?? null)
  if (error) {
    notification.error({ content: error.message, duration: 6000 })
    await reloadTasks()
  }
}

// --- зависимости: создание/редактирование через компактную форму ---

/**
 * Открывает форму создания зависимости, предложенной протягиванием стрелки.
 * @param {string} fromId
 * @param {string} toId
 */
function openCreateDependency(fromId, toId) {
  depForm.value = { mode: 'create', fromId: String(fromId), toId: String(toId), type: 'FS', lag: 0 }
  depFormVisible.value = true
}

/**
 * Открывает форму редактирования существующей зависимости (двойной клик по стрелке).
 * @param {object} dependencyRecord
 */
function openEditDependency(dependencyRecord) {
  depForm.value = {
    mode: 'edit',
    id: String(dependencyRecord.id),
    fromId: String(dependencyRecord.fromEvent?.id ?? dependencyRecord.fromEvent),
    toId: String(dependencyRecord.toEvent?.id ?? dependencyRecord.toEvent),
    type: DEPENDENCY_TYPE_FROM_BRYNTUM[dependencyRecord.type] ?? 'FS',
    lag: dependencyRecord.lag ?? 0,
  }
  depFormVisible.value = true
}

/** Подтверждение компактной формы зависимости — создаёт или обновляет связь. */
async function submitDependencyForm() {
  if (!depForm.value) return
  depFormLoading.value = true
  try {
    if (depForm.value.mode === 'create') {
      const { error } = await getClient().from('task_dependency').insert({
        project_id: activeProject.value.id,
        from_id: depForm.value.fromId,
        to_id: depForm.value.toId,
        type: depForm.value.type,
        lag: depForm.value.lag,
      })
      if (error) {
        notification.error({ content: error.message, duration: 6000 })
        await reloadTasks()
        return
      }
      message.success('Зависимость создана')
    } else {
      const { error } = await getClient()
        .from('task_dependency')
        .update({ type: depForm.value.type, lag: depForm.value.lag })
        .eq('id', depForm.value.id)
      if (error) {
        notification.error({ content: error.message, duration: 6000 })
        await reloadTasks()
        return
      }
      message.success('Зависимость обновлена')
    }
    depFormVisible.value = false
    await reloadTasks()
  } finally {
    depFormLoading.value = false
  }
}

function cancelDependencyForm() {
  depFormVisible.value = false
  // Протянутая, но не подтверждённая стрелка не должна оставаться на диаграмме —
  // перезагружаем данные, чтобы вернуть фактическое состояние сервера.
  reloadTasks()
}

/** Обработчик выбора пункта контекстного меню зависимости. */
function onDepContextMenuSelect(key) {
  depContextMenuVisible.value = false
  const dep = depContextMenuTarget.value
  if (!dep || key !== 'delete') return
  dialog.warning({
    title: 'Удалить зависимость?',
    content: 'Связь между работами будет удалена.',
    positiveText: 'Удалить',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      const { error } = await getClient().from('task_dependency').delete().eq('id', dep.id)
      if (error) {
        notification.error({ content: error.message, duration: 6000 })
        await reloadTasks()
        return
      }
      message.success('Зависимость удалена')
      await reloadTasks()
    },
  })
}

// --- масштаб шкалы времени ---

function zoomIn() {
  ganttInstance.value?.zoomIn?.()
}
function zoomOut() {
  ganttInstance.value?.zoomOut?.()
}
function zoomToFit() {
  ganttInstance.value?.zoomToFit?.()
}

// --- поиск (подсветка + скролл, без фильтрации, planning-gantt.md §5.1) ---

function onSearch() {
  const query = searchQuery.value.trim()
  const gantt = ganttInstance.value
  if (!gantt || !query) return
  const match = gantt.taskStore?.query?.(
    (record) => record.name?.toLowerCase().includes(query.toLowerCase()),
    true,
  )?.[0]
  if (match) {
    gantt.scrollRowIntoView?.(match)
    gantt.selectRow?.(match)
    selectedTask.value = match
  }
}

// --- создание проекта (пустое состояние) ---

function openCreateProjectModal() {
  createProjectName.value = ''
  createProjectVisible.value = true
}

async function submitCreateProject() {
  if (!createProjectName.value.trim()) return
  createProjectLoading.value = true
  try {
    const project = await createProject(getClient(), createProjectName.value.trim())
    createProjectVisible.value = false
    activeProject.value = project
    message.success('Проект создан')
    await reloadTasks()
  } catch (err) {
    notification.error({ content: err.message, duration: 6000 })
  } finally {
    createProjectLoading.value = false
  }
}

// --- загрузка ---

/** Полная перезагрузка: определяет проект зоны, затем грузит его дерево. */
async function initialize() {
  phase.value = 'loading'
  loadError.value = ''
  try {
    const project = await resolveActiveProject(getClient(), auth.user?.org_unit_id)
    if (!project) {
      activeProject.value = null
      phase.value = 'no-project'
      return
    }
    activeProject.value = project
    await reloadTasks()
  } catch (err) {
    loadError.value = err.message
    phase.value = 'error'
  }
}

/**
 * Создаёт инстанс `Gantt` (при первом вызове, когда контейнер уже в DOM) либо
 * подгружает новые данные в уже существующий (`project.loadInlineData`) — сама
 * Vue3-обёртка делала бы это реактивно за нас, здесь это делается императивно.
 * @param {Array<object>} tasksData
 * @param {Array<object>} dependenciesData
 * @returns {Promise<void>}
 */
async function ensureGanttInstance(tasksData, dependenciesData) {
  if (ganttInstance.value) {
    // `tasks`/`dependencies` — актуальные ключи (tasksData/dependenciesData
    // помечены deprecated начиная с 6.3.0, будут удалены в v9).
    await ganttInstance.value.project.loadInlineData({ tasks: tasksData, dependencies: dependenciesData })
    return
  }
  await nextTick()
  if (!ganttContainerRef.value) {
    // Контейнер мог ещё не попасть в DOM при первом синхронном присвоении
    // phase — ждём следующий тик на всякий случай.
    await nextTick()
  }
  ganttInstance.value = new Gantt({
    appendTo: ganttContainerRef.value,
    ...ganttStaticConfig,
    project: {
      autoLoad: true,
      tasks: tasksData,
      dependencies: dependenciesData,
    },
  })
}

/** Перезагружает дерево работ/зависимостей текущего проекта без смены проекта. */
async function reloadTasks() {
  if (!activeProject.value) return
  phase.value = 'loading-project'
  try {
    const { tasksData, dependenciesData } = await loadProject(getClient(), activeProject.value.id)
    hasNoTasks.value = tasksData.length === 0
    await ensureGanttInstance(tasksData, dependenciesData)
    phase.value = 'ready'
  } catch (err) {
    loadError.value = err.message
    phase.value = 'error'
  }
}

/** На сохранение в TaskEditorModal — перезагружает дерево, новая/изменённая работа должна появиться. */
async function onTaskSaved() {
  await reloadTasks()
}

onMounted(() => {
  initialize()
})

onUnmounted(() => {
  ganttInstance.value?.destroy?.()
  ganttInstance.value = null
})
</script>

<template>
  <div class="pmis-gantt-view flex flex-col h-full w-full">
    <!-- Тулбар (planning-gantt.md §5.1) -->
    <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-200 shrink-0">
      <n-button
        type="primary"
        :disabled="phase !== 'ready'"
        @click="onToolbarCreateTask"
      >
        Создать работу
      </n-button>
      <n-button
        :disabled="phase !== 'ready'"
        @click="onToolbarCreateMilestone"
      >
        Создать веху
      </n-button>
      <n-button
        :disabled="phase === 'loading'"
        @click="sectionsGridVisible = true"
      >
        Участки
      </n-button>

      <n-input
        v-model:value="searchQuery"
        placeholder="Поиск по наименованию"
        clearable
        class="max-w-xs"
        :disabled="phase !== 'ready'"
        @keydown.enter="onSearch"
        @update:value="onSearch"
      />

      <div class="flex-1" />

      <n-button-group>
        <n-button
          :disabled="phase !== 'ready'"
          title="Уменьшить"
          @click="zoomOut"
        >
          −
        </n-button>
        <n-button
          :disabled="phase !== 'ready'"
          title="Увеличить"
          @click="zoomIn"
        >
          +
        </n-button>
        <n-button
          :disabled="phase !== 'ready'"
          title="По ширине проекта"
          @click="zoomToFit"
        >
          По ширине
        </n-button>
      </n-button-group>
    </div>

    <!-- Область диаграммы -->
    <div class="relative flex-1 min-h-0">
      <!-- Загрузка первичная -->
      <n-spin
        v-if="phase === 'loading'"
        :show="true"
        class="absolute inset-0 flex items-center justify-center"
      />

      <!-- Нет проекта в зоне -->
      <div
        v-else-if="phase === 'no-project'"
        class="h-full flex flex-col items-center justify-center gap-3 text-gray-500"
      >
        <p>В вашей зоне ответственности пока нет проекта</p>
        <n-button
          type="primary"
          @click="openCreateProjectModal"
        >
          Создать проект
        </n-button>
      </div>

      <!-- Ошибка загрузки -->
      <div
        v-else-if="phase === 'error'"
        class="h-full flex flex-col items-center justify-center gap-3 text-gray-500"
      >
        <p>Не удалось загрузить данные: {{ loadError }}</p>
        <n-button @click="initialize">
          Повторить
        </n-button>
      </div>

      <!-- Данные -->
      <template v-else>
        <!--
          v-if, а не :show — n-spin без слотового содержимого (нет обёрнутого
          контента) не убирает свой контейнер `.n-spin-body` из потока и не
          снимает pointer-events при show=false (поведение компонента расчитано
          на оборачивание контента, не на самостоятельный оверлей); при show=false
          он остаётся `display:flex` и перехватывает клики по диаграмме под собой.
        -->
        <n-spin
          v-if="phase === 'loading-project'"
          :show="true"
          class="absolute inset-0 z-10"
        />

        <div
          v-if="hasNoTasks && phase === 'ready'"
          class="absolute inset-0 flex flex-col items-center justify-center gap-3 text-gray-500 bg-white/70 z-10"
        >
          <p>Пока нет ни одной работы, создайте первую</p>
          <n-button
            type="primary"
            @click="onEmptyStateCreateTask"
          >
            Создать работу
          </n-button>
        </div>

        <div
          ref="ganttContainerRef"
          class="pmis-gantt-container h-full w-full"
        />
      </template>
    </div>

    <!-- Контекстное меню строки/бара (planning-gantt.md §5.3) -->
    <n-dropdown
      placement="bottom-start"
      trigger="manual"
      :show="contextMenuVisible"
      :x="contextMenuX"
      :y="contextMenuY"
      :options="contextMenuOptions"
      @select="onContextMenuSelect"
      @clickoutside="contextMenuVisible = false"
    />

    <!-- Контекстное меню зависимости (dependencies.md §2) -->
    <n-dropdown
      placement="bottom-start"
      trigger="manual"
      :show="depContextMenuVisible"
      :x="depContextMenuX"
      :y="depContextMenuY"
      :options="depContextMenuOptions"
      @select="onDepContextMenuSelect"
      @clickoutside="depContextMenuVisible = false"
    />

    <!-- Модалка создания проекта (пустое состояние зоны) -->
    <n-modal
      :show="createProjectVisible"
      preset="card"
      title="Новый проект"
      class="w-full max-w-sm"
      @update:show="(v) => (createProjectVisible = v)"
    >
      <n-form
        :disabled="createProjectLoading"
        @submit.prevent="submitCreateProject"
      >
        <n-form-item label="Наименование">
          <n-input
            v-model:value="createProjectName"
            placeholder="Наименование проекта"
            @keydown.enter="submitCreateProject"
          />
        </n-form-item>
        <n-form-item :show-label="false">
          <div class="flex justify-end gap-2 w-full">
            <n-button
              :disabled="createProjectLoading"
              @click="createProjectVisible = false"
            >
              Отмена
            </n-button>
            <n-button
              type="primary"
              :loading="createProjectLoading"
              :disabled="createProjectLoading || !createProjectName.trim()"
              @click="submitCreateProject"
            >
              Создать
            </n-button>
          </div>
        </n-form-item>
      </n-form>
    </n-modal>

    <!-- Компактная форма зависимости (создание/редактирование) -->
    <n-modal
      :show="depFormVisible"
      preset="card"
      :title="depForm?.mode === 'create' ? 'Новая зависимость' : 'Редактирование зависимости'"
      class="w-full max-w-sm"
      @update:show="(v) => { if (!v) cancelDependencyForm() }"
    >
      <n-form
        v-if="depForm"
        :disabled="depFormLoading"
      >
        <n-form-item label="Тип связи">
          <n-select
            v-model:value="depForm.type"
            :options="DEPENDENCY_TYPE_OPTIONS"
          />
        </n-form-item>
        <n-form-item label="Лаг (дней)">
          <n-input-number
            v-model:value="depForm.lag"
            class="w-full"
          />
        </n-form-item>
        <n-form-item :show-label="false">
          <div class="flex justify-end gap-2 w-full">
            <n-button
              :disabled="depFormLoading"
              @click="cancelDependencyForm"
            >
              Отмена
            </n-button>
            <n-button
              type="primary"
              :loading="depFormLoading"
              @click="submitDependencyForm"
            >
              Сохранить
            </n-button>
          </div>
        </n-form-item>
      </n-form>
    </n-modal>

    <!-- Справочник «Участки» — режим управления (sections-screen.md) -->
    <SectionsGrid v-model:show="sectionsGridVisible" />

    <!-- Редактор работы — контракт с Агентом B, файл появится параллельно -->
    <TaskEditorModal
      v-model:show="editorVisible"
      :task-id="editingTaskId"
      :parent-task="editingParentTask"
      :preset-milestone="editingPresetMilestone"
      :active-project-id="activeProject?.id ?? null"
      @saved="onTaskSaved"
    />
  </div>
</template>

<style scoped>
.pmis-gantt-view {
  min-height: 0;
}
</style>
