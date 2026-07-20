<script setup>
//
// Грид пользователей (users) — access-and-roles-users.md §5, resources-pattern.md.
// Главная область экрана «Пользователи»: поиск, фильтр по роли/статусу
// вынесены в попаперы заголовков колонок, создание/редактирование учётной
// записи, действия жизненного цикла — в модалке (#header-extra).
//
// Анти-эскалация на клиенте (access-and-roles-users.md §5.3) — только UX-подсказка,
// сервер (RLS users_update/users_delete) перепроверяет всё самостоятельно (403).
//
import { ref, computed, h, watch } from 'vue'
import { NButton, NTag, NInput, NSelect, NSpace } from 'naive-ui'
import { getClient } from '../../lib/postgrest'
import { useAuthStore } from '../../stores/auth'
import { useReferenceList } from '../../adapters/naivePostgrest'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'
import StatusTag from '../references/StatusTag.vue'
import GridFilterHeader from '../references/GridFilterHeader.vue'
import OrgUnitTree from './OrgUnitTree.vue'

const auth = useAuthStore()
const lifecycle = useRecordLifecycle({ getClient, table: 'users', entityLabel: 'пользователя' })

const roleFilter = ref(null)
/** @type {import('vue').Ref<Array<{id: string, code: string, name: string}>>} */
const roles = ref([])

const {
  rows,
  loading,
  search,
  statusFilter,
  pagination,
  reload,
} = useReferenceList({
  getClient,
  table: 'users',
  // Явная подсказка связи обязательна: у users→org_unit три FK
  // (org_unit_id, org_unit.created_by, org_unit.updated_by), без hint
  // PostgREST отвечает 300 PGRST201 "more than one relationship was found".
  // Явный список колонок обязателен и отдельно от этого: колонка password
  // не входит в column-level GRANT SELECT (access-and-roles-api.md), а
  // select=* требует прав на ВСЕ колонки таблицы разом и падает 403.
  select:
    'id,email,full_name,role,org_unit_id,status,created_at,updated_at,org_unit!users_org_unit_id_fkey(name)',
  searchColumn: 'full_name',
  extraFilters: () => (roleFilter.value ? [['role', roleFilter.value]] : []),
})

async function loadRoles() {
  const { data, error } = await getClient().from('roles').select('id,code,name').order('name')
  if (error) {
    console.error('Не удалось загрузить роли:', error)
    return
  }
  roles.value = data
}
loadRoles()

const roleOptions = computed(() => roles.value.map((r) => ({ label: r.name, value: r.code })))

const statusOptions = [
  { label: 'Создана', value: 'created' },
  { label: 'Активна', value: 'enabled' },
  { label: 'Отключена', value: 'disabled' },
  { label: 'Удалена', value: 'deprecated' },
]

function roleLabel(code) {
  return roles.value.find((r) => r.code === code)?.name ?? code
}

// --- форма создания/редактирования ---

const formShow = ref(false)
const formMode = ref('create') // 'create' | 'edit'
const formLoading = ref(false)
const formRef = ref(null)
const editingRecord = ref(null)

const emptyModel = () => ({
  email: '',
  password: '',
  full_name: '',
  role: null,
  org_unit_id: null,
  org_unit_name: '',
})
const formModel = ref(emptyModel())

/** Собственная запись редактируется — поля «Роль»/«Организация» блокируются (§5.3). */
const isSelfEdit = computed(
  () => formMode.value === 'edit' && editingRecord.value?.id === auth.user?.id,
)

const formRules = computed(() => ({
  email: [
    { required: true, message: 'Введите email', trigger: ['input', 'blur'] },
    { type: 'email', message: 'Некорректный формат email', trigger: ['input', 'blur'] },
  ],
  password: [
    {
      required: formMode.value === 'create',
      message: 'Введите пароль',
      trigger: ['input', 'blur'],
    },
  ],
  full_name: [{ required: true, message: 'Введите ФИО', trigger: ['input', 'blur'] }],
  role: [{ required: true, message: 'Выберите роль', trigger: ['change', 'blur'] }],
  org_unit_id: [{ required: true, message: 'Выберите организацию', trigger: ['change', 'blur'] }],
}))

function openCreateForm() {
  formMode.value = 'create'
  editingRecord.value = null
  formModel.value = emptyModel()
  formShow.value = true
}

function openEditForm(record) {
  formMode.value = 'edit'
  editingRecord.value = record
  formModel.value = {
    email: record.email,
    password: '',
    full_name: record.full_name,
    role: record.role,
    org_unit_id: record.org_unit_id,
    org_unit_name: record.org_unit?.name ?? '',
  }
  formShow.value = true
}

function closeForm() {
  formShow.value = false
  editingRecord.value = null
}

/**
 * Отправка формы создания/редактирования. При редактировании пустой пароль
 * означает «не менять» — поле не включается в тело запроса (§5.2).
 * @returns {Promise<void>}
 */
async function onFormSubmit() {
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  formLoading.value = true
  try {
    if (formMode.value === 'create') {
      const payload = {
        email: formModel.value.email,
        password: formModel.value.password,
        full_name: formModel.value.full_name,
        role: formModel.value.role,
        org_unit_id: formModel.value.org_unit_id,
      }
      const { error } = await getClient().from('users').insert(payload)
      if (error) {
        console.error('Не удалось создать пользователя:', error)
        return
      }
    } else {
      const payload = {
        email: formModel.value.email,
        full_name: formModel.value.full_name,
      }
      // Анти-эскалация: на своей записи роль/организация не отправляются вовсе.
      if (!isSelfEdit.value) {
        payload.role = formModel.value.role
        payload.org_unit_id = formModel.value.org_unit_id
      }
      if (formModel.value.password) {
        payload.password = formModel.value.password
      }
      const { error } = await getClient().from('users').update(payload).eq('id', editingRecord.value.id)
      if (error) {
        console.error('Не удалось обновить пользователя:', error)
        return
      }
    }
    closeForm()
    await reload()
  } finally {
    formLoading.value = false
  }
}

// --- выбор организации через дерево (режим pick) ---

const orgPickerShow = ref(false)

function openOrgPicker() {
  orgPickerShow.value = true
}

function onOrgPicked({ id, name }) {
  formModel.value.org_unit_id = id
  formModel.value.org_unit_name = name
}

// --- управление организациями (режим manage, из тулбара экрана) ---
// Отдельная точка входа находится на UsersPage.vue — этот грид не дублирует кнопку.

// --- действия жизненного цикла перенесены в модалку (#header-extra) ---

const isAdmin = computed(() => auth.user?.role === 'admin')

/** Локальная копия записи для отражения смены статуса без мутации пропса. */
const editing = ref(null)

const actions = computed(() => {
  if (!editing.value) return []
  // Анти-эскалация на своей записи: жизненные действия недоступны (§5.3).
  if (editing.value.id === auth.user?.id) return []
  return lifecycle.availableActions(editing.value.status, isAdmin.value)
})

/** Обновляет статус локальной копии записи после lifecycle-действия. */
function patchStatus(status) {
  if (editing.value) {
    editing.value.status = status
  }
}

/** @param {() => Promise<boolean>} action */
async function runLifecycle(action) {
  const ok = await action()
  if (ok) {
    await reload()
  }
  return ok
}

async function doActivate() {
  if (await runLifecycle(() => lifecycle.activate(editing.value))) {
    patchStatus('enabled')
  }
}
async function doDeactivate() {
  if (await runLifecycle(() => lifecycle.deactivate(editing.value))) {
    patchStatus('disabled')
  }
}
async function doRestore() {
  if (await runLifecycle(() => lifecycle.restore(editing.value))) {
    patchStatus('disabled')
  }
}
async function doDelete() {
  if (await runLifecycle(() => lifecycle.softDelete(editing.value))) {
    closeForm()
  }
}

// Синхронизация локальной копии записи при открытии модалки.
watch(
  () => formShow.value,
  (visible) => {
    if (visible && formMode.value === 'edit' && editingRecord.value) {
      editing.value = { ...editingRecord.value }
    } else {
      editing.value = null
    }
  },
)

/**
 * Заголовок колонки «ФИО» с попапером текстового поиска.
 * @returns {import('vue').VNode}
 */
function nameHeader() {
  return h(
    GridFilterHeader,
    {
      label: 'ФИО',
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
 * Заголовок колонки «Роль» с попапером выбора роли (single, clearable).
 * @returns {import('vue').VNode}
 */
function roleHeader() {
  return h(
    GridFilterHeader,
    {
      label: 'Роль',
      modelValue: roleFilter.value ?? '',
      apply: (v) => (roleFilter.value = v || null),
      active: !!roleFilter.value,
    },
    {
      default: ({ value, update }) =>
        h(NSelect, {
          value: value.value || null,
          options: roleOptions.value,
          placeholder: 'Роль',
          clearable: true,
          size: 'small',
          style: 'width: 200px',
          'onUpdate:value': update,
        }),
    },
  )
}

/**
 * Заголовок колонки «Статус» с попапером множественного выбора статусов.
 * @returns {import('vue').VNode}
 */
function statusHeader() {
  return h(
    GridFilterHeader,
    {
      label: 'Статус',
      modelValue: statusFilter.value.join(','),
      apply: () => {},
      active: statusFilter.value.includes('deprecated'),
    },
    {
      default: ({ value, update }) =>
        h(NSelect, {
          value: value.value ? value.value.split(',') : [],
          options: statusOptions,
          placeholder: 'Статус',
          multiple: true,
          clearable: true,
          size: 'small',
          style: 'width: 220px',
          'onUpdate:value': (arr) => {
            statusFilter.value = arr
            update(arr.join(','))
          },
        }),
    },
  )
}

const columns = computed(() => [
  { title: nameHeader, key: 'full_name' },
  { title: 'Email', key: 'email' },
  {
    title: roleHeader,
    key: 'role',
    render: (row) => h(NTag, { bordered: false, size: 'small' }, { default: () => roleLabel(row.role) }),
  },
  {
    title: 'Организация',
    key: 'org_unit',
    render: (row) => row.org_unit?.name ?? '—',
  },
  {
    title: statusHeader,
    key: 'status',
    render: (row) => h(StatusTag, { status: row.status }),
  },
])
</script>

<template>
  <div class="flex h-full flex-col gap-3">
    <div class="flex items-center justify-end mb-3">
      <n-button
        type="primary"
        @click="openCreateForm"
      >
        Создать
      </n-button>
    </div>

    <n-spin :show="loading">
      <div
        v-if="!loading && rows.length === 0"
        class="py-12 text-center text-gray-400"
      >
        Пока нет ни одной записи, создайте первую
      </div>
      <n-data-table
        v-else
        :columns="columns"
        :data="rows"
        :pagination="pagination"
        :bordered="false"
        remote
        :row-props="(row) => ({
          class: 'cursor-pointer',
          onDblclick: () => openEditForm(row),
        })"
      />
    </n-spin>

    <n-modal
      :show="formShow"
      preset="card"
      :title="formMode === 'create' ? 'Новый пользователь' : 'Редактирование пользователя'"
      class="w-full max-w-md"
      @update:show="(v) => !v && closeForm()"
    >
      <template
        v-if="formMode === 'edit'"
        #header-extra
      >
        <n-space
          :wrap="false"
          :size="4"
        >
          <n-button
            v-if="actions.includes('activate')"
            size="small"
            @click="doActivate"
          >
            Активировать
          </n-button>
          <n-button
            v-if="actions.includes('deactivate')"
            size="small"
            @click="doDeactivate"
          >
            Деактивировать
          </n-button>
          <n-button
            v-if="actions.includes('restore')"
            size="small"
            @click="doRestore"
          >
            Восстановить
          </n-button>
          <n-button
            v-if="actions.includes('delete')"
            size="small"
            type="error"
            ghost
            @click="doDelete"
          >
            Удалить
          </n-button>
        </n-space>
      </template>
      <n-form
        ref="formRef"
        :model="formModel"
        :rules="formRules"
        :disabled="formLoading"
        @submit.prevent="onFormSubmit"
      >
        <n-form-item
          label="Email"
          path="email"
        >
          <n-input
            v-model:value="formModel.email"
            :disabled="formLoading"
            placeholder="user@example.com"
          />
        </n-form-item>
        <n-form-item
          :label="formMode === 'create' ? 'Пароль' : 'Новый пароль'"
          path="password"
        >
          <n-input
            v-model:value="formModel.password"
            type="password"
            show-password-on="click"
            :disabled="formLoading"
            :placeholder="formMode === 'edit' ? 'Оставьте пустым, чтобы не менять' : ''"
          />
        </n-form-item>
        <n-form-item
          label="ФИО"
          path="full_name"
        >
          <n-input
            v-model:value="formModel.full_name"
            :disabled="formLoading"
          />
        </n-form-item>
        <n-form-item
          label="Роль"
          path="role"
        >
          <n-select
            v-model:value="formModel.role"
            :options="roleOptions"
            :disabled="formLoading || isSelfEdit"
            :title="isSelfEdit ? 'нельзя изменить собственную роль или зону' : undefined"
          />
          <p
            v-if="isSelfEdit"
            class="mt-1 text-xs text-gray-400"
          >
            нельзя изменить собственную роль или зону
          </p>
        </n-form-item>
        <n-form-item
          label="Организация"
          path="org_unit_id"
        >
          <div class="flex w-full items-center gap-2">
            <n-input
              :value="formModel.org_unit_name"
              disabled
              placeholder="Организация не выбрана"
              class="grow"
            />
            <n-button
              :disabled="formLoading || isSelfEdit"
              @click="openOrgPicker"
            >
              Выбрать
            </n-button>
          </div>
        </n-form-item>
        <n-form-item :show-label="false">
          <div class="flex justify-end gap-2">
            <n-button
              :disabled="formLoading"
              @click="closeForm"
            >
              Отмена
            </n-button>
            <n-button
              type="primary"
              attr-type="submit"
              :loading="formLoading"
              :disabled="formLoading"
            >
              Сохранить
            </n-button>
          </div>
        </n-form-item>
      </n-form>
    </n-modal>

    <OrgUnitTree
      v-model:show="orgPickerShow"
      mode="pick"
      :model-value="formModel.org_unit_id"
      @select="onOrgPicked"
    />
  </div>
</template>
