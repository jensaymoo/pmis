<script setup>
//
// Модалка-справочник «Группы» для вида ресурса (персонал/техника/материалы) —
// грид групп + форма CRUD + панель управления составом. Поддерживает режим
// выбора (пикер). См. resources-pattern.md §2.2, resources-personnel-groups.md.
//
import { computed, reactive, ref, watch } from 'vue'
import { useMessage, useNotification, useDialog } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import { useReferenceList } from '../../adapters/naivePostgrest'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
  pickMode: { type: Boolean, default: false },
})

const emit = defineEmits(['update:show', 'pick'])

const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()
const dialog = useDialog()

const groupTable = computed(() => `${props.kind}_group`)
const resourceTable = computed(() => `${props.kind}_resource`)
const linkTable = computed(() => `${props.kind}_group_resource`)
const isAdmin = computed(() => auth.user?.role === 'admin')
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const list = useReferenceList({
  getClient,
  table: groupTable.value,
  select: '*',
  searchColumn: 'name',
  defaultStatuses: isDispatcher.value ? ['enabled'] : ['created', 'enabled', 'disabled'],
})

const lifecycle = useRecordLifecycle({
  getClient,
  table: groupTable.value,
  entityLabel: 'группу',
})

/** Кэш "наименование единицы" по id, для отображения сокращения в гриде. */
const unitsById = ref({})

/** Подгружает единицы измерения вида для колонки «Единица измерения». */
async function loadUnits() {
  const { data, error } = await getClient().from(`${props.kind}_unit`).select('id,name,short_name')
  if (error) {
    console.error('Не удалось загрузить единицы измерения:', error)
    return
  }
  unitsById.value = Object.fromEntries(data.map((u) => [u.id, u]))
}

/** Кэш "количество участников" по id группы. */
const memberCounts = ref({})

/** Подсчитывает количество активных связей по видимым группам. */
async function loadMemberCounts() {
  const ids = list.rows.value.map((g) => g.id)
  if (ids.length === 0) {
    memberCounts.value = {}
    return
  }
  const { data, error } = await getClient()
    .from(linkTable.value)
    .select('group_id')
    .in('group_id', ids)
  if (error) {
    console.error('Не удалось загрузить состав групп:', error)
    return
  }
  const counts = {}
  for (const row of data) {
    counts[row.group_id] = (counts[row.group_id] ?? 0) + 1
  }
  memberCounts.value = counts
}

watch(
  () => list.rows.value,
  () => loadMemberCounts(),
)

const selectedRow = ref(null)
const rowKey = (row) => row.id

function isRowSelected(row) {
  return selectedRow.value?.id === row.id
}

function onRowClick(row) {
  selectedRow.value = row
}

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
  unit_id: null,
})

const formRules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  unit_id: [{ required: true, message: 'Выберите единицу измерения', trigger: ['blur', 'change'] }],
}

const activeUnitOptions = computed(() =>
  Object.values(unitsById.value).map((u) => ({ label: `${u.name} (${u.short_name})`, value: u.id })),
)

/** Блокировка смены единицы измерения при наличии участников (personnel-groups.md §5). */
const unitLocked = computed(() => {
  if (!editingRecord.value) return false
  return (memberCounts.value[editingRecord.value.id] ?? 0) > 0
})

function openCreate() {
  editingRecord.value = null
  formReadonly.value = false
  formModel.name = ''
  formModel.unit_id = null
  formVisible.value = true
}

function openForm(row, readonly = false) {
  editingRecord.value = row
  const editable = row.org_unit_id === auth.user?.org_unit_id && !isDispatcher.value
  formReadonly.value = readonly ? !editable : !editable
  formModel.name = row.name
  formModel.unit_id = row.unit_id
  formVisible.value = true
}

function closeForm() {
  formVisible.value = false
  editingRecord.value = null
}

async function onSubmitForm() {
  if (formReadonly.value) return
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  formLoading.value = true
  try {
    const payload = { name: formModel.name, unit_id: formModel.unit_id }
    const { error } = editingRecord.value
      ? await getClient().from(groupTable.value).update(payload).eq('id', editingRecord.value.id)
      : await getClient().from(groupTable.value).insert(payload)

    if (error) {
      console.error(`Не удалось сохранить группу (${groupTable.value}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    message.success(editingRecord.value ? 'Группа обновлена' : 'Группа создана')
    closeForm()
    await list.reload()
  } finally {
    formLoading.value = false
  }
}

// --- действия жизненного цикла ---

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

function actionsFor(status) {
  return lifecycle.availableActions(status, isAdmin.value)
}

const ACTION_LABELS = {
  activate: 'Активировать',
  deactivate: 'Деактивировать',
  delete: 'Удалить',
  restore: 'Восстановить',
}

// --- панель управления составом ---

const compositionVisible = ref(false)
const compositionGroup = ref(null)
const membersLoading = ref(false)
const availableLoading = ref(false)
const members = ref([])
const available = ref([])
const memberSearch = ref('')
const availableSearch = ref('')
const matchingUnitOnly = ref(true)

/** @param {object} group */
async function openComposition(group) {
  compositionGroup.value = group
  compositionVisible.value = true
  memberSearch.value = ''
  availableSearch.value = ''
  matchingUnitOnly.value = true
  await Promise.all([loadMembers(), loadAvailable()])
}

function closeComposition() {
  compositionVisible.value = false
  compositionGroup.value = null
  members.value = []
  available.value = []
}

/** Загружает текущий состав группы (join через link table). */
async function loadMembers() {
  if (!compositionGroup.value) return
  membersLoading.value = true
  try {
    const { data: links, error: linkError } = await getClient()
      .from(linkTable.value)
      .select('id,resource_id')
      .eq('group_id', compositionGroup.value.id)
    if (linkError) {
      console.error('Не удалось загрузить состав группы:', linkError)
      members.value = []
      return
    }
    if (links.length === 0) {
      members.value = []
      return
    }
    const ids = links.map((l) => l.resource_id)
    const { data: resources, error: resError } = await getClient()
      .from(resourceTable.value)
      .select('id,name,unit_id,status')
      .in('id', ids)
    if (resError) {
      console.error('Не удалось загрузить ресурсы состава группы:', resError)
      members.value = []
      return
    }
    const linkByResource = Object.fromEntries(links.map((l) => [l.resource_id, l.id]))
    members.value = resources.map((r) => ({ ...r, linkId: linkByResource[r.id] }))
  } finally {
    membersLoading.value = false
  }
}

/** Загружает ресурсы, доступные для добавления (не входящие в группу). */
async function loadAvailable() {
  if (!compositionGroup.value) return
  availableLoading.value = true
  try {
    const memberIds = members.value.map((m) => m.id)
    let query = getClient()
      .from(resourceTable.value)
      .select('id,name,unit_id,status')
      .eq('status', 'enabled')
    const { data, error } = await query
    if (error) {
      console.error('Не удалось загрузить доступные ресурсы:', error)
      available.value = []
      return
    }
    available.value = data.filter((r) => !memberIds.includes(r.id))
  } finally {
    availableLoading.value = false
  }
}

const filteredMembers = computed(() => {
  const q = memberSearch.value.trim().toLowerCase()
  if (!q) return members.value
  return members.value.filter((r) => r.name.toLowerCase().includes(q))
})

const filteredAvailable = computed(() => {
  let list_ = available.value
  if (matchingUnitOnly.value && compositionGroup.value) {
    list_ = list_.filter((r) => r.unit_id === compositionGroup.value.unit_id)
  }
  const q = availableSearch.value.trim().toLowerCase()
  if (q) {
    list_ = list_.filter((r) => r.name.toLowerCase().includes(q))
  }
  return list_
})

const addingId = ref(null)
const removingId = ref(null)

/** @param {object} resource */
async function addToGroup(resource) {
  addingId.value = resource.id
  try {
    const { error } = await getClient().from(linkTable.value).insert({
      group_id: compositionGroup.value.id,
      resource_id: resource.id,
    })
    if (error) {
      console.error('Не удалось добавить ресурс в группу:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    message.success('Ресурс добавлен в группу')
    await Promise.all([loadMembers(), loadAvailable()])
    await loadMemberCounts()
  } finally {
    addingId.value = null
  }
}

/** @param {object} member */
function removeFromGroup(member) {
  dialog.warning({
    title: 'Удалить из группы?',
    content: 'Запись перестанет учитываться в этой группе при новых назначениях.',
    positiveText: 'Удалить',
    negativeText: 'Отмена',
    autoFocus: false,
    onPositiveClick: async () => {
      removingId.value = member.id
      try {
        const { error } = await getClient().from(linkTable.value).delete().eq('id', member.linkId)
        if (error) {
          console.error('Не удалось удалить ресурс из группы:', error)
          notification.error({ content: error.message, duration: 6000 })
          return
        }
        message.success('Ресурс удалён из группы')
        await Promise.all([loadMembers(), loadAvailable()])
        await loadMemberCounts()
      } finally {
        removingId.value = null
      }
    },
  })
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
  async (visible) => {
    if (visible) {
      selectedRow.value = null
      await loadUnits()
      await list.reload()
    }
  },
)
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    title="Группы"
    class="w-full max-w-4xl"
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
        {
          title: 'Единица измерения',
          key: 'unit_id',
          width: 160,
          render: (row) => unitsById[row.unit_id]?.short_name ?? '—',
        },
        {
          title: 'Участников',
          key: 'members',
          width: 110,
          render: (row) => memberCounts[row.id] ?? 0,
        },
        { title: 'Статус', key: 'status', width: 110 },
        { title: 'Действия', key: 'actions', width: isDispatcher ? 0 : 220 },
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

  <!-- Форма создания/редактирования группы -->
  <n-modal
    :show="formVisible"
    preset="card"
    :title="editingRecord ? (formReadonly ? 'Просмотр группы' : 'Редактирование группы') : 'Новая группа'"
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
          placeholder="Бригада сварщиков"
        />
      </n-form-item>
      <n-form-item
        label="Единица измерения"
        path="unit_id"
      >
        <n-select
          v-model:value="formModel.unit_id"
          :options="activeUnitOptions"
          :disabled="formLoading || formReadonly || unitLocked"
          placeholder="Выберите единицу измерения"
        />
        <p
          v-if="unitLocked"
          class="text-xs text-gray-500 mt-1"
        >
          Нельзя изменить: в группе есть участники
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
            size="small"
            @click="openComposition(editingRecord)"
          >
            Состав
          </n-button>
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

  <!-- Панель управления составом -->
  <n-modal
    :show="compositionVisible"
    preset="card"
    :title="`Состав группы «${compositionGroup?.name ?? ''}»`"
    class="w-full max-w-3xl"
    @update:show="(value) => { if (!value) closeComposition() }"
  >
    <div class="grid grid-cols-2 gap-4">
      <div>
        <h3 class="font-medium mb-2">
          В группе
        </h3>
        <n-input
          v-model:value="memberSearch"
          placeholder="Поиск"
          clearable
          class="mb-2"
        />
        <n-spin :show="membersLoading">
          <div class="border rounded max-h-72 overflow-y-auto">
            <div
              v-if="filteredMembers.length === 0"
              class="p-3 text-sm text-gray-500"
            >
              Нет участников
            </div>
            <div
              v-for="member in filteredMembers"
              :key="member.id"
              class="flex items-center justify-between px-3 py-2 border-b last:border-b-0"
            >
              <span class="text-sm">{{ member.name }}</span>
              <n-button
                size="tiny"
                :loading="removingId === member.id"
                :disabled="isDispatcher"
                @click="removeFromGroup(member)"
              >
                Удалить из группы
              </n-button>
            </div>
          </div>
        </n-spin>
      </div>

      <div>
        <h3 class="font-medium mb-2">
          Доступно для добавления
        </h3>
        <div class="flex items-center gap-2 mb-2">
          <n-switch
            v-model:value="matchingUnitOnly"
            size="small"
          />
          <span class="text-xs text-gray-600">Только с совпадающей единицей измерения</span>
        </div>
        <n-input
          v-model:value="availableSearch"
          placeholder="Поиск"
          clearable
          class="mb-2"
        />
        <n-spin :show="availableLoading">
          <div class="border rounded max-h-60 overflow-y-auto">
            <div
              v-if="filteredAvailable.length === 0"
              class="p-3 text-sm text-gray-500"
            >
              Нет доступных записей
            </div>
            <div
              v-for="resource in filteredAvailable"
              :key="resource.id"
              class="flex items-center justify-between px-3 py-2 border-b last:border-b-0"
            >
              <span class="text-sm">{{ resource.name }}</span>
              <n-button
                size="tiny"
                type="primary"
                :loading="addingId === resource.id"
                :disabled="isDispatcher"
                @click="addToGroup(resource)"
              >
                Добавить
              </n-button>
            </div>
          </div>
        </n-spin>
      </div>
    </div>

    <template #footer>
      <div class="flex justify-end">
        <n-button @click="closeComposition">
          Закрыть
        </n-button>
      </div>
    </template>
  </n-modal>
</template>
