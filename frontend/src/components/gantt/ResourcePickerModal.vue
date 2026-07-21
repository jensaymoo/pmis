<script setup>
//
// Простой пикер конкретного ресурса (персонал/техника/материалы) — используется
// формой добавления ресурса в DailyPlanEditorModal, шаг 2 (§3.1 контракта Агента
// D, planning-task-resources.md). Отдельный от группового пикера (GroupsTableModal
// уже покрывает выбор группы, Фаза 5). Только активные записи (status = enabled).
//
import { computed, ref, watch } from 'vue'
import { useNotification } from 'naive-ui'
import { getClient } from '../../lib/postgrest'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
})

const emit = defineEmits(['update:show', 'pick'])

const notification = useNotification()

const TITLES = {
  personnel: 'Выбор персонала',
  equipment: 'Выбор техники',
  materials: 'Выбор материалов',
}
const modalTitle = computed(() => TITLES[props.kind] ?? 'Выбор ресурса')

const search = ref('')
const rows = ref([])
const loading = ref(false)
const selectedRow = ref(null)

async function loadRows() {
  loading.value = true
  try {
    let query = getClient()
      .from(`${props.kind}_resource`)
      .select('id,name,unit_id,unit:unit_id(short_name)')
      .eq('status', 'enabled')
      .order('name')
    if (search.value.trim()) {
      query = query.ilike('name', `%${search.value.trim()}%`)
    }
    const { data, error } = await query
    if (error) {
      console.error('Не удалось загрузить ресурсы:', error)
      notification.error({ content: error.message, duration: 6000 })
      rows.value = []
      return
    }
    rows.value = data ?? []
  } finally {
    loading.value = false
  }
}

watch(search, () => loadRows())

watch(
  () => props.show,
  (visible) => {
    if (visible) {
      search.value = ''
      selectedRow.value = null
      loadRows()
    }
  },
)

function isRowSelected(row) {
  return selectedRow.value?.id === row.id
}

function onRowClick(row) {
  selectedRow.value = row
}

const rowProps = (row) => ({
  style: isRowSelected(row) ? 'cursor: pointer; background-color: var(--n-merged-th-color);' : 'cursor: pointer;',
  onClick: () => onRowClick(row),
})

const columns = computed(() => [
  { title: 'Наименование', key: 'name' },
  {
    title: 'Единица',
    key: 'unit',
    width: 120,
    render: (row) => row.unit?.short_name ?? '—',
  },
])

function onPick() {
  if (!selectedRow.value) return
  emit('pick', selectedRow.value)
  emit('update:show', false)
}

function onClose() {
  selectedRow.value = null
  emit('update:show', false)
}
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    :title="modalTitle"
    class="w-full max-w-lg"
    @update:show="(value) => emit('update:show', value)"
    @close="onClose"
  >
    <n-input
      v-model:value="search"
      placeholder="Поиск по наименованию"
      clearable
      class="mb-3"
    />

    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :row-key="(row) => row.id"
      :row-props="rowProps"
      :bordered="false"
      max-height="360"
    >
      <template #empty>
        Нет активных записей
      </template>
    </n-data-table>

    <template #footer>
      <div class="flex justify-end gap-2">
        <n-button @click="onClose">
          Отмена
        </n-button>
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
</template>
