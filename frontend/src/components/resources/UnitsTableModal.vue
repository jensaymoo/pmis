<script setup>
//
// Модалка-справочник «Единицы измерения» для вида ресурса (персонал/техника/
// материалы) — грид + форма CRUD, с поддержкой режима выбора (пикер).
// См. resources-pattern.md §2.2, §6.1-6.4, resources-personnel-units.md.
//
import { computed, reactive, ref, watch } from 'vue'
import { useMessage, useNotification } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import { useReferenceList } from '../../adapters/naivePostgrest'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
  /** Режим выбора (пикер) — resources-pattern.md §2.2 */
  pickMode: { type: Boolean, default: false },
})

const emit = defineEmits(['update:show', 'pick'])

const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()

const table = computed(() => `${props.kind}_unit`)
const isAdmin = computed(() => auth.user?.role === 'admin')
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const list = useReferenceList({
  getClient,
  table: table.value,
  select: '*',
  searchColumn: 'name',
  defaultStatuses: isDispatcher.value ? ['enabled'] : ['created', 'enabled', 'disabled'],
})

const lifecycle = useRecordLifecycle({
  getClient,
  table: table.value,
  entityLabel: 'единицу измерения',
})

const selectedRow = ref(null)
const rowKey = (row) => row.id

/** @param {object} row */
function isRowSelected(row) {
  return selectedRow.value?.id === row.id
}

/** @param {object} row */
function onRowClick(row) {
  selectedRow.value = row
}

/** @param {object} row */
function onRowDblClick(row) {
  openForm(row, true)
}

const rowProps = (row) => ({
  style: isRowSelected(row) ? 'cursor: pointer; background-color: var(--n-merged-th-color);' : 'cursor: pointer;',
  onClick: () => onRowClick(row),
  onDblclick: () => onRowDblClick(row),
})

// --- форма создания/редактирования ---

const formVisible = ref(false)
const formLoading = ref(false)
const formRef = ref(null)
const editingRecord = ref(null)
const formReadonly = ref(false)

const formModel = reactive({
  name: '',
  short_name: '',
  is_integer: false,
})

const formRules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  short_name: [{ required: true, message: 'Введите сокращение', trigger: ['input', 'blur'] }],
}

/** Открывает форму создания. */
function openCreate() {
  editingRecord.value = null
  formReadonly.value = false
  formModel.name = ''
  formModel.short_name = ''
  formModel.is_integer = false
  formVisible.value = true
}

/**
 * Открывает форму просмотра/редактирования существующей записи.
 * @param {object} row
 * @param {boolean} [readonly]
 */
function openForm(row, readonly = false) {
  editingRecord.value = row
  const editable = row.org_unit_id === auth.user?.org_unit_id && !isDispatcher.value
  formReadonly.value = readonly ? !editable : !editable
  formModel.name = row.name
  formModel.short_name = row.short_name
  formModel.is_integer = row.is_integer
  formVisible.value = true
}

function closeForm() {
  formVisible.value = false
  editingRecord.value = null
}

/** Отправка формы: создание либо обновление. */
async function onSubmitForm() {
  if (formReadonly.value) return
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  formLoading.value = true
  try {
    const payload = {
      name: formModel.name,
      short_name: formModel.short_name,
      is_integer: formModel.is_integer,
    }
    const { error } = editingRecord.value
      ? await getClient().from(table.value).update(payload).eq('id', editingRecord.value.id)
      : await getClient().from(table.value).insert(payload)

    if (error) {
      console.error(`Не удалось сохранить единицу измерения (${table.value}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    message.success(editingRecord.value ? 'Единица измерения обновлена' : 'Единица измерения создана')
    closeForm()
    await list.reload()
  } finally {
    formLoading.value = false
  }
}

// --- действия жизненного цикла ---

/** @param {object} row @param {'activate'|'deactivate'|'delete'|'restore'} action */
async function runAction(row, action) {
  const handlers = {
    activate: lifecycle.activate,
    deactivate: lifecycle.deactivate,
    delete: lifecycle.softDelete,
    restore: lifecycle.restore,
  }
  const ok = await handlers[action](row)
  if (ok) await list.reload()
}

/** @param {string} status */
function actionsFor(status) {
  return lifecycle.availableActions(status, isAdmin.value)
}

const ACTION_LABELS = {
  activate: 'Активировать',
  deactivate: 'Деактивировать',
  delete: 'Удалить',
  restore: 'Восстановить',
}

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
    <div class="flex items-center gap-3 mb-3">
      <n-input
        v-model:value="list.search.value"
        placeholder="Поиск по наименованию"
        clearable
        class="max-w-xs"
      />
      <n-select
        v-if="!isDispatcher"
        v-model:value="list.statusFilter.value"
        multiple
        placeholder="Статус"
        class="max-w-xs"
        :options="[
          { label: 'Создана', value: 'created' },
          { label: 'Активна', value: 'enabled' },
          { label: 'Отключена', value: 'disabled' },
          { label: 'Удалена', value: 'deprecated' },
        ]"
      />
      <div class="flex-1" />
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
      :columns="[
        { title: 'Наименование', key: 'name' },
        { title: 'Сокращение', key: 'short_name', width: 120 },
        {
          title: 'Целочисленность',
          key: 'is_integer',
          width: 130,
          render: (row) => (row.is_integer ? 'целая' : 'дробная'),
        },
        { title: 'Статус', key: 'status', width: 110 },
        { title: 'Действия', key: 'actions', width: isDispatcher ? 0 : 200 },
      ]"
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

  <n-modal
    :show="formVisible"
    preset="card"
    :title="editingRecord ? (formReadonly ? 'Просмотр единицы измерения' : 'Редактирование единицы измерения') : 'Новая единица измерения'"
    class="w-full max-w-md"
    @update:show="(value) => { if (!value) closeForm() }"
  >
    <n-form
      ref="formRef"
      :model="formModel"
      :rules="formRules"
      :disabled="formLoading || formReadonly"
      @submit.prevent="onSubmitForm"
    >
      <n-form-item
        label="Наименование"
        path="name"
      >
        <n-input
          v-model:value="formModel.name"
          placeholder="человеко-час"
        />
      </n-form-item>
      <n-form-item
        label="Сокращение"
        path="short_name"
      >
        <n-input
          v-model:value="formModel.short_name"
          placeholder="чел·ч"
        />
      </n-form-item>
      <n-form-item
        label="Целочисленность"
        path="is_integer"
      >
        <n-switch v-model:value="formModel.is_integer" />
        <p class="text-xs text-gray-500 mt-1">
          Допускать только целые значения
        </p>
      </n-form-item>
    </n-form>

    <template #footer>
      <div class="flex justify-between items-center">
        <div
          v-if="editingRecord"
          class="flex gap-2"
        >
          <n-button
            v-for="action in actionsFor(editingRecord.status)"
            :key="action"
            size="small"
            @click="runAction(editingRecord, action)"
          >
            {{ ACTION_LABELS[action] }}
          </n-button>
        </div>
        <div class="flex justify-end gap-2 flex-1">
          <n-button @click="closeForm">
            {{ formReadonly ? 'Закрыть' : 'Отмена' }}
          </n-button>
          <n-button
            v-if="!formReadonly"
            type="primary"
            attr-type="submit"
            :loading="formLoading"
            :disabled="formLoading"
            @click="onSubmitForm"
          >
            Сохранить
          </n-button>
        </div>
      </div>
    </template>
  </n-modal>
</template>
