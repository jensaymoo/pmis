<script setup>
//
// Раздел «Зависимости» Редактора работы — planning-dependencies.md §3.
// Таблица связей «работа-сиблинг» (task_dependency), где текущая работа —
// предшественник или последователь. Доступен для ЛЮБОГО типа узла (включая
// веху и составную работу — у зависимостей нет собственного disabled-
// состояния по типу узла, work-structure-business правило 14).
//
// Как и «Участки» — построчное сохранение: каждая операция (создать, сменить
// тип/лаг, удалить) уходит на сервер немедленно (planning-task-editor.md §2).
// После любого успешного изменения эмитим 'changed', чтобы родитель
// (TaskEditorModal) перечитал task.
//
import { computed, h, ref, watch } from 'vue'
import { NButton, NInputNumber, NSelect, NTag } from 'naive-ui'
import { useMessage, useNotification, useDialog } from 'naive-ui'
import { getClient } from '../../lib/postgrest'

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

const TYPE_LABELS = {
  FS: 'окончание–начало',
  SS: 'начало–начало',
  FF: 'окончание–окончание',
  SF: 'начало–окончание',
}
const TYPE_OPTIONS = Object.entries(TYPE_LABELS).map(([value, label]) => ({ value, label }))

const rows = ref([])
const loading = ref(false)

/** Загружает зависимости, где текущая работа — from или to (активные). */
async function loadRows() {
  if (!props.task?.id) {
    rows.value = []
    return
  }
  loading.value = true
  try {
    const { data, error } = await getClient()
      .from('task_dependency')
      .select('id,from_id,to_id,type,lag,status,from:from_id(name),to:to_id(name)')
      .or(`from_id.eq.${props.task.id},to_id.eq.${props.task.id}`)
      .neq('status', 'deprecated')
    if (error) {
      console.error('Не удалось загрузить зависимости работы:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    rows.value = data ?? []
  } finally {
    loading.value = false
  }
}

watch(() => props.task?.id, () => loadRows(), { immediate: true })

// --- построчное редактирование: тип связи / лаг ---

/** @param {object} row @param {string} type */
async function updateType(row, type) {
  const prev = row.type
  row.type = type // оптимистично, откатим при отказе
  const { error } = await getClient().from('task_dependency').update({ type }).eq('id', row.id)
  if (error) {
    console.error('Не удалось изменить тип связи:', error)
    notification.error({ content: error.message, duration: 6000 })
    row.type = prev
    return
  }
  message.success('Тип связи изменён')
  emit('changed')
}

/** @param {object} row @param {number} lag */
async function updateLag(row, lag) {
  if (lag === null || lag === undefined) return
  const prev = row.lag
  row.lag = lag
  const { error } = await getClient().from('task_dependency').update({ lag }).eq('id', row.id)
  if (error) {
    console.error('Не удалось изменить лаг:', error)
    notification.error({ content: error.message, duration: 6000 })
    row.lag = prev
    return
  }
  message.success('Лаг изменён')
  emit('changed')
}

// --- удаление ---

/** @param {object} row */
function removeDependency(row) {
  dialog.warning({
    title: 'Удалить зависимость?',
    content: 'Связь порядка выполнения между работами будет удалена.',
    positiveText: 'Удалить',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      const { error } = await getClient().from('task_dependency').delete().eq('id', row.id)
      if (error) {
        console.error('Не удалось удалить зависимость:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      message.success('Зависимость удалена')
      await loadRows()
      emit('changed')
    },
    onNegativeClick: () => {},
  })
}

const columns = computed(() => {
  const cols = [
    {
      title: 'Работа',
      key: 'related',
      render: (row) => (row.from_id === props.task.id ? row.to?.name ?? row.to_id : row.from?.name ?? row.from_id),
    },
    {
      title: 'Направление',
      key: 'direction',
      width: 140,
      render: (row) =>
        h(
          NTag,
          { size: 'small', bordered: false },
          () => (row.from_id === props.task.id ? 'предшествует' : 'следует за'),
        ),
    },
    {
      title: 'Тип связи',
      key: 'type',
      width: 220,
      render: (row) => {
        if (props.readonly) return TYPE_LABELS[row.type] ?? row.type
        return h(NSelect, {
          value: row.type,
          options: TYPE_OPTIONS,
          size: 'small',
          onUpdateValue: (v) => updateType(row, v),
        })
      },
    },
    {
      title: 'Лаг',
      key: 'lag',
      width: 120,
      render: (row) => {
        if (props.readonly) return `${row.lag ?? 0}`
        return h(NInputNumber, {
          value: row.lag,
          size: 'small',
          class: 'w-full',
          onUpdateValue: (v) => updateLag(row, v),
        })
      },
    },
  ]
  if (!props.readonly) {
    cols.push({
      title: 'Действия',
      key: 'actions',
      width: 120,
      render: (row) =>
        h(NButton, { size: 'tiny', onClick: () => removeDependency(row) }, () => 'Удалить'),
    })
  }
  return cols
})

// --------------------------------------------------------------------------
// Добавление зависимости — форма в два шага
// --------------------------------------------------------------------------

const formVisible = ref(false)
const formSaving = ref(false)
const formStep = ref(1) // 1: выбор работы, 2: направление/тип/лаг

const candidates = ref([])
const candidatesLoading = ref(false)

const selectedSiblingId = ref(null)
/** true — текущая работа предшествует выбранной (текущая = from); false — следует за (текущая = to). */
const currentIsFrom = ref(true)
const formType = ref('FS')
const formLag = ref(0)

const candidateOptions = computed(() =>
  candidates.value.map((c) => ({ value: c.id, label: c.name })),
)

/** Загружает кандидатов-сиблингов текущей работы. */
async function loadCandidates() {
  candidatesLoading.value = true
  try {
    let query = getClient().from('task').select('id,name').neq('id', props.task.id).neq('status', 'deprecated')
    if (props.task.parent_id) {
      query = query.eq('parent_id', props.task.parent_id)
    } else {
      query = query.is('parent_id', null).eq('project_id', props.task.project_id)
    }
    const { data, error } = await query
    if (error) {
      console.error('Не удалось загрузить кандидатов для зависимости:', error)
      notification.error({ content: error.message, duration: 6000 })
      candidates.value = []
      return
    }
    candidates.value = data ?? []
  } finally {
    candidatesLoading.value = false
  }
}

function openAddForm() {
  if (props.readonly) return
  formStep.value = 1
  selectedSiblingId.value = null
  currentIsFrom.value = true
  formType.value = 'FS'
  formLag.value = 0
  formVisible.value = true
  loadCandidates()
}

function closeAddForm() {
  formVisible.value = false
}

function goToStep2() {
  if (!selectedSiblingId.value) return
  formStep.value = 2
}

async function submitAddForm() {
  if (!selectedSiblingId.value) return
  formSaving.value = true
  try {
    const payload = {
      project_id: props.task.project_id,
      from_id: currentIsFrom.value ? props.task.id : selectedSiblingId.value,
      to_id: currentIsFrom.value ? selectedSiblingId.value : props.task.id,
      type: formType.value,
      lag: formLag.value ?? 0,
    }
    const { error } = await getClient().from('task_dependency').insert(payload)
    if (error) {
      console.error('Не удалось создать зависимость:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    message.success('Зависимость создана')
    closeAddForm()
    await loadRows()
    emit('changed')
  } finally {
    formSaving.value = false
  }
}
</script>

<template>
  <div class="border-t border-gray-200 pt-4 mt-4">
    <div class="flex items-center justify-between mb-2">
      <h3 class="text-base font-medium">
        Зависимости
      </h3>
      <n-button
        v-if="!readonly"
        size="small"
        type="primary"
        @click="openAddForm"
      >
        Добавить зависимость
      </n-button>
    </div>

    <div
      v-if="rows.length === 0 && !loading"
      class="bg-gray-50 border border-gray-200 rounded p-3 text-sm text-gray-500"
    >
      у работы нет связей порядка выполнения с другими работами
    </div>

    <n-data-table
      v-else
      :columns="columns"
      :data="rows"
      :loading="loading"
      :row-key="(row) => row.id"
      :bordered="false"
      size="small"
    />

    <!-- Форма добавления зависимости -->
    <n-modal
      :show="formVisible"
      preset="card"
      title="Добавить зависимость"
      class="w-full max-w-md"
      @update:show="(v) => { if (!v) closeAddForm() }"
    >
      <div v-if="formStep === 1">
        <p class="text-sm text-gray-600 mb-2">
          Выберите связанную работу (сиблинги текущей работы)
        </p>
        <n-select
          v-model:value="selectedSiblingId"
          filterable
          :loading="candidatesLoading"
          :options="candidateOptions"
          placeholder="Работа"
        />
      </div>

      <div
        v-else
        class="flex flex-col gap-3"
      >
        <div>
          <p class="text-sm text-gray-600 mb-1">
            Направление
          </p>
          <n-radio-group v-model:value="currentIsFrom">
            <n-space vertical>
              <n-radio :value="true">
                текущая работа предшествует
              </n-radio>
              <n-radio :value="false">
                текущая работа следует за
              </n-radio>
            </n-space>
          </n-radio-group>
        </div>

        <n-form-item
          label="Тип связи"
          class="mb-0"
        >
          <n-select
            v-model:value="formType"
            :options="TYPE_OPTIONS"
          />
        </n-form-item>

        <n-form-item
          label="Лаг (дней)"
          class="mb-0"
        >
          <n-input-number
            v-model:value="formLag"
            :min="0"
            class="w-full"
          />
        </n-form-item>
      </div>

      <template #footer>
        <div class="flex justify-end gap-2">
          <n-button @click="closeAddForm">
            Отмена
          </n-button>
          <n-button
            v-if="formStep === 1"
            type="primary"
            :disabled="!selectedSiblingId"
            @click="goToStep2"
          >
            Далее
          </n-button>
          <template v-else>
            <n-button @click="formStep = 1">
              Назад
            </n-button>
            <n-button
              type="primary"
              :loading="formSaving"
              @click="submitAddForm"
            >
              Создать
            </n-button>
          </template>
        </div>
      </template>
    </n-modal>
  </div>
</template>
