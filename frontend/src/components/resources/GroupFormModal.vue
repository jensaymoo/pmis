<script setup>
//
// Форма создания/редактирования группы вида ресурса (персонал/техника/
// материалы) + панель управления составом группы —
// resources-pattern.md §2.4, §6.2, resources-personnel-groups.md.
// Действия жизненного цикла и кнопка «Состав» вынесены в слот #header-extra
// модалки, как в ResourceFormModal.vue/QtyUnitFormModal.vue.
//
import { computed, reactive, ref, watch } from 'vue'
import { useMessage, useNotification, useDialog, NSpace, NButton } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
  /** Запись для редактирования; null — форма создания */
  record: { type: Object, default: null },
})

const emit = defineEmits(['update:show', 'saved'])

const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()
const dialog = useDialog()

const groupTable = computed(() => `${props.kind}_group`)
const resourceTable = computed(() => `${props.kind}_resource`)
const linkTable = computed(() => `${props.kind}_group_resource`)
const unitTable = computed(() => `${props.kind}_unit`)
const isAdmin = computed(() => auth.user?.role === 'admin')
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const lifecycle = useRecordLifecycle({
  getClient,
  table: groupTable.value,
  entityLabel: 'группу',
})

const isEditing = computed(() => !!props.record)

/** Локальная копия записи для отражения смены статуса без мутации пропса. */
const editing = ref(null)

const actions = computed(() =>
  editing.value ? lifecycle.availableActions(editing.value.status, isAdmin.value) : [],
)

/** Запись редактируема, только если принадлежит собственной зоне пользователя (pattern.md §3.2). */
const isOwnZone = computed(() => !props.record || props.record.org_unit_id === auth.user?.org_unit_id)
const formReadonly = computed(() => isDispatcher.value || !isOwnZone.value)

const formRef = ref(null)
const loading = ref(false)

const model = reactive({
  name: '',
  unit_id: null,
})

const rules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  unit_id: [{ required: true, message: 'Выберите единицу измерения', trigger: ['blur', 'change'] }],
}

/** Активные единицы измерения текущего вида. */
const unitOptions = ref([])

/** Загружает активные единицы измерения для выпадающего списка. */
async function loadUnitOptions() {
  const { data, error } = await getClient()
    .from(unitTable.value)
    .select('id,name,short_name')
    .eq('status', 'enabled')
    .order('name')
  if (error) {
    console.error('Не удалось загрузить единицы измерения:', error)
    return
  }
  unitOptions.value = data.map((u) => ({ label: `${u.name} (${u.short_name})`, value: u.id }))
}

/** Кэш "количество участников" редактируемой группы (для блокировки смены единицы). */
const memberCount = ref(0)

/** Подсчитывает количество активных связей редактируемой группы. */
async function loadMemberCount() {
  if (!props.record) {
    memberCount.value = 0
    return
  }
  const { count, error } = await getClient()
    .from(linkTable.value)
    .select('id', { count: 'exact', head: true })
    .eq('group_id', props.record.id)
  if (error) {
    console.error('Не удалось загрузить состав группы:', error)
    return
  }
  memberCount.value = count ?? 0
}

/** Блокировка смены единицы измерения при наличии участников (personnel-groups.md §5). */
const unitLocked = computed(() => isEditing.value && memberCount.value > 0)

function resetForm() {
  model.name = props.record?.name ?? ''
  model.unit_id = props.record?.unit_id ?? null
}

watch(
  () => props.show,
  async (visible) => {
    if (!visible) return
    editing.value = props.record ? { ...props.record } : null
    resetForm()
    formRef.value?.restoreValidation()
    await Promise.all([loadUnitOptions(), loadMemberCount()])
  },
  { immediate: true },
)

async function onSubmit() {
  if (formReadonly.value) return
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  loading.value = true
  try {
    const payload = { name: model.name, unit_id: model.unit_id }
    const { error } = isEditing.value
      ? await getClient().from(groupTable.value).update(payload).eq('id', props.record.id)
      : await getClient().from(groupTable.value).insert(payload)

    if (error) {
      console.error(`Не удалось сохранить группу (${groupTable.value}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    message.success(isEditing.value ? 'Группа обновлена' : 'Группа создана')
    emit('update:show', false)
    emit('saved')
  } finally {
    loading.value = false
  }
}

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
    emit('saved')
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
    emit('update:show', false)
  }
}

function onClose() {
  emit('update:show', false)
}

// --- панель управления составом ---

const compositionVisible = ref(false)
const membersLoading = ref(false)
const availableLoading = ref(false)
const members = ref([])
const available = ref([])
const memberSearch = ref('')
const availableSearch = ref('')
const matchingUnitOnly = ref(true)

async function openComposition() {
  compositionVisible.value = true
  memberSearch.value = ''
  availableSearch.value = ''
  matchingUnitOnly.value = true
  await Promise.all([loadMembers(), loadAvailable()])
}

function closeComposition() {
  compositionVisible.value = false
  members.value = []
  available.value = []
}

/** Загружает текущий состав группы (join через link table). */
async function loadMembers() {
  if (!props.record) return
  membersLoading.value = true
  try {
    const { data: links, error: linkError } = await getClient()
      .from(linkTable.value)
      .select('id,resource_id')
      .eq('group_id', props.record.id)
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
  if (!props.record) return
  availableLoading.value = true
  try {
    const memberIds = members.value.map((m) => m.id)
    const { data, error } = await getClient()
      .from(resourceTable.value)
      .select('id,name,unit_id,status')
      .eq('status', 'enabled')
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
  if (matchingUnitOnly.value && props.record) {
    list_ = list_.filter((r) => r.unit_id === props.record.unit_id)
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
      group_id: props.record.id,
      resource_id: resource.id,
    })
    if (error) {
      console.error('Не удалось добавить ресурс в группу:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }
    message.success('Ресурс добавлен в группу')
    await Promise.all([loadMembers(), loadAvailable()])
    await loadMemberCount()
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
        await loadMemberCount()
      } finally {
        removingId.value = null
      }
    },
  })
}
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    :title="isEditing ? (formReadonly ? 'Просмотр группы' : 'Редактирование группы') : 'Новая группа'"
    class="w-full max-w-md"
    @update:show="(value) => emit('update:show', value)"
    @close="onClose"
  >
    <template
      v-if="isEditing"
      #header-extra
    >
      <n-space
        :wrap="false"
        :size="4"
      >
        <n-button
          size="small"
          @click="openComposition"
        >
          Состав
        </n-button>
        <template v-if="!formReadonly">
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
        </template>
      </n-space>
    </template>

    <n-form
      ref="formRef"
      :model="model"
      :rules="rules"
      :disabled="loading || formReadonly"
      @submit.prevent="onSubmit"
    >
      <n-form-item
        label="Наименование"
        path="name"
      >
        <n-input
          v-model:value="model.name"
          placeholder="Бригада сварщиков"
        />
      </n-form-item>
      <n-form-item
        label="Единица измерения"
        path="unit_id"
      >
        <n-select
          v-model:value="model.unit_id"
          :options="unitOptions"
          :disabled="loading || formReadonly || unitLocked"
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
      <div class="flex justify-end gap-2">
        <n-button @click="onClose">
          {{ formReadonly ? 'Закрыть' : 'Отмена' }}
        </n-button>
        <n-button
          v-if="!formReadonly"
          type="primary"
          attr-type="submit"
          :loading="loading"
          :disabled="loading"
          @click="onSubmit"
        >
          Сохранить
        </n-button>
      </div>
    </template>
  </n-modal>

  <!-- Панель управления составом -->
  <n-modal
    :show="compositionVisible"
    preset="card"
    :title="`Состав группы «${props.record?.name ?? ''}»`"
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
