<script setup>
//
// Грид ресурсов вида (персонал/техника/материалы) — переиспользуемый через
// prop kind. Тулбар: поиск, фильтр статуса, «Создать», «Единицы измерения»,
// «Группы» (скрыты для dispatcher, кроме поиска/фильтра). Колонки —
// resources-personnel.md §4.4 (общий состав для всех трёх видов).
//
import { computed, h, ref, watch } from 'vue'
import { NTag, NTooltip, NEllipsis } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import { useReferenceList } from '../../adapters/naivePostgrest'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'
import StatusTag from '../references/StatusTag.vue'
import ResourceFormModal from './ResourceFormModal.vue'
import UnitsTableModal from './UnitsTableModal.vue'
import GroupsTableModal from './GroupsTableModal.vue'

const props = defineProps({
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
})

const auth = useAuthStore()

const resourceTable = computed(() => `${props.kind}_resource`)
const groupTable = computed(() => `${props.kind}_group`)
const linkTable = computed(() => `${props.kind}_group_resource`)
const unitTable = computed(() => `${props.kind}_unit`)

const isAdmin = computed(() => auth.user?.role === 'admin')
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const list = useReferenceList({
  getClient,
  table: resourceTable.value,
  select: '*',
  searchColumn: 'name',
  defaultStatuses: isDispatcher.value ? ['enabled'] : ['created', 'enabled', 'disabled'],
})

const lifecycle = useRecordLifecycle({
  getClient,
  table: resourceTable.value,
  entityLabel: 'ресурс',
})

// --- справочные данные для колонок (единица измерения, группы) ---

const unitsById = ref({})
const groupsByResource = ref({})

/** Подгружает единицы измерения вида для колонки «Единица измерения». */
async function loadUnits() {
  const { data, error } = await getClient().from(unitTable.value).select('id,name,short_name')
  if (error) {
    console.error('Не удалось загрузить единицы измерения:', error)
    return
  }
  unitsById.value = Object.fromEntries(data.map((u) => [u.id, u]))
}

/** Подгружает членство в группах для видимых строк (колонка «Группы»). */
async function loadGroupMembership() {
  const resourceIds = list.rows.value.map((r) => r.id)
  if (resourceIds.length === 0) {
    groupsByResource.value = {}
    return
  }
  const { data: links, error: linkError } = await getClient()
    .from(linkTable.value)
    .select('resource_id,group_id')
    .in('resource_id', resourceIds)
  if (linkError) {
    console.error('Не удалось загрузить членство в группах:', linkError)
    return
  }
  const groupIds = [...new Set(links.map((l) => l.group_id))]
  if (groupIds.length === 0) {
    groupsByResource.value = {}
    return
  }
  const { data: groups, error: groupError } = await getClient()
    .from(groupTable.value)
    .select('id,name')
    .in('id', groupIds)
  if (groupError) {
    console.error('Не удалось загрузить группы:', groupError)
    return
  }
  const groupsById = Object.fromEntries(groups.map((g) => [g.id, g]))
  const map = {}
  for (const link of links) {
    if (!map[link.resource_id]) map[link.resource_id] = []
    const group = groupsById[link.group_id]
    if (group) map[link.resource_id].push(group)
  }
  groupsByResource.value = map
}

watch(
  () => list.rows.value,
  () => loadGroupMembership(),
)

// --- форма ресурса ---

const formVisible = ref(false)
const editingRecord = ref(null)
const formReadonlyOverride = ref(false)

function openCreate() {
  editingRecord.value = null
  formReadonlyOverride.value = false
  formVisible.value = true
}

/** @param {object} row */
function openEdit(row) {
  editingRecord.value = row
  formReadonlyOverride.value = false
  formVisible.value = true
}

function onSaved() {
  list.reload()
}

// --- действия жизненного цикла (колонка «Действия») ---

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

const ACTION_LABELS = {
  activate: 'Активировать',
  deactivate: 'Деактивировать',
  delete: 'Удалить',
  restore: 'Восстановить',
}

/** Запись редактируема, только если принадлежит собственной зоне (pattern.md §3.2). */
function isOwnZone(row) {
  return row.org_unit_id === auth.user?.org_unit_id
}

// --- колонки грида ---

const columns = computed(() => {
  const cols = [
    { title: 'Наименование', key: 'name', minWidth: 160 },
    {
      title: 'Описание',
      key: 'description',
      minWidth: 200,
      render: (row) =>
        row.description
          ? h(NEllipsis, { style: { maxWidth: '260px' } }, { default: () => row.description })
          : '—',
    },
    {
      title: 'Единица измерения',
      key: 'unit_id',
      width: 150,
      render: (row) => unitsById.value[row.unit_id]?.short_name ?? '—',
    },
    {
      title: 'Группы',
      key: 'groups',
      width: 200,
      render: (row) => {
        const groups = groupsByResource.value[row.id] ?? []
        if (groups.length === 0) return '—'
        const visible = groups.slice(0, 2)
        const rest = groups.length - visible.length
        const tags = visible.map((g) => h(NTag, { size: 'small', round: true, class: 'mr-1' }, { default: () => g.name }))
        if (rest > 0) {
          tags.push(
            h(
              NTooltip,
              {},
              {
                trigger: () => h(NTag, { size: 'small', round: true }, { default: () => `+${rest}` }),
                default: () => groups.slice(2).map((g) => g.name).join(', '),
              },
            ),
          )
        }
        return h('div', { class: 'flex flex-wrap gap-1' }, tags)
      },
    },
    {
      title: 'Организация',
      key: 'org_unit_id',
      width: 140,
      render: (row) =>
        h(
          'span',
          { class: isOwnZone(row) ? '' : 'text-gray-400 italic' },
          isOwnZone(row) ? 'Своя зона' : 'Вышестоящая зона',
        ),
    },
    {
      title: 'Статус',
      key: 'status',
      width: 110,
      render: (row) => h(StatusTag, { status: row.status }),
    },
  ]

  if (!isDispatcher.value) {
    cols.push({
      title: 'Действия',
      key: 'actions',
      width: 220,
      render: (row) => {
        if (!isOwnZone(row)) {
          return h(
            'button',
            {
              class: 'text-xs text-blue-600 hover:underline',
              onClick: () => openEdit(row),
            },
            'Просмотр',
          )
        }
        const actions = lifecycle.availableActions(row.status, isAdmin.value)
        const buttons = [
          h(
            'button',
            { class: 'text-xs text-blue-600 hover:underline mr-2', onClick: () => openEdit(row) },
            'Изменить',
          ),
          ...actions.map((action) =>
            h(
              'button',
              {
                class: 'text-xs text-blue-600 hover:underline mr-2',
                onClick: () => runAction(row, action),
              },
              ACTION_LABELS[action],
            ),
          ),
        ]
        return h('div', { class: 'flex flex-wrap' }, buttons)
      },
    })
  }

  return cols
})

// --- модалки единиц измерения / групп (кнопки тулбара) ---

const unitsModalVisible = ref(false)
const groupsModalVisible = ref(false)

watch([unitsModalVisible, groupsModalVisible], () => {
  // после закрытия любой соседней модалки состав/единицы измерения могли
  // измениться — перегружаем справочные данные грида
  loadUnits()
  loadGroupMembership()
})

watch(
  () => props.kind,
  () => {
    list.reload()
    loadUnits()
  },
)

loadUnits()
</script>

<template>
  <div class="flex flex-col h-full">
    <div class="flex items-center gap-3 mb-3 flex-wrap">
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
      <template v-if="!isDispatcher">
        <n-button @click="unitsModalVisible = true">
          Единицы измерения
        </n-button>
        <n-button @click="groupsModalVisible = true">
          Группы
        </n-button>
        <n-button
          type="primary"
          @click="openCreate"
        >
          Создать
        </n-button>
      </template>
    </div>

    <n-data-table
      remote
      :columns="columns"
      :data="list.rows.value"
      :pagination="list.pagination.value"
      :loading="list.loading.value"
      :row-key="(row) => row.id"
      :bordered="false"
      flex-height
      class="flex-1"
    >
      <template #empty>
        Пока нет ни одной записи, создайте первую.
      </template>
    </n-data-table>

    <ResourceFormModal
      v-model:show="formVisible"
      :kind="props.kind"
      :record="editingRecord"
      :readonly="formReadonlyOverride"
      @saved="onSaved"
    />

    <UnitsTableModal
      v-model:show="unitsModalVisible"
      :kind="props.kind"
    />

    <GroupsTableModal
      v-model:show="groupsModalVisible"
      :kind="props.kind"
    />
  </div>
</template>
