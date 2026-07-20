<script setup>
//
// Форма создания/редактирования ресурса (персонал/техника/материалы):
// наименование, описание, единица измерения (выпадающий список + переход
// просмотра/выбора через UnitsTableModal), блок «Группы» (только просмотр,
// ссылка «управлять составом» открывает GroupsTableModal).
// См. resources-pattern.md §2.4, §6.2, resources-personnel.md §4.2, §4.4.
//
import { computed, reactive, ref, watch } from 'vue'
import { useMessage, useNotification, NSpace, NButton } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'
import { getClient } from '../../lib/postgrest'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'
import UnitsTableModal from './UnitsTableModal.vue'
import GroupsTableModal from './GroupsTableModal.vue'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** @type {import('vue').PropType<'personnel'|'equipment'|'materials'>} */
  kind: { type: String, required: true },
  /** Запись для редактирования/просмотра; null — создание новой записи. */
  record: { type: Object, default: null },
  /**
   * Форма только для просмотра — переиспользуется вне справочника (наряды и
   * т. п., будущие фазы). Не отправляет запросов на сервер.
   */
  readonly: { type: Boolean, default: false },
})

const emit = defineEmits(['update:show', 'saved'])

const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()

const resourceTable = computed(() => `${props.kind}_resource`)
const groupTable = computed(() => `${props.kind}_group`)
const linkTable = computed(() => `${props.kind}_group_resource`)
const unitTable = computed(() => `${props.kind}_unit`)

const isAdmin = computed(() => auth.user?.role === 'admin')

const lifecycle = useRecordLifecycle({ getClient, table: resourceTable.value, entityLabel: 'ресурс' })

const isEditing = computed(() => !!props.record)

/** Локальная копия записи для отражения смены статуса без мутации пропса. */
const editing = ref(null)

const actions = computed(() =>
  editing.value ? lifecycle.availableActions(editing.value.status, isAdmin.value) : [],
)

/** Запись редактируема, только если принадлежит собственной зоне пользователя (pattern.md §3.2). */
const isOwnZone = computed(() => !props.record || props.record.org_unit_id === auth.user?.org_unit_id)
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')
const formReadonly = computed(() => props.readonly || isDispatcher.value || !isOwnZone.value)

const formRef = ref(null)
const loading = ref(false)

const model = reactive({
  name: '',
  description: '',
  unit_id: null,
})

const rules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  unit_id: [{ required: true, message: 'Выберите единицу измерения', trigger: ['blur', 'change'] }],
}

/** Активные единицы измерения текущего вида (своей и видимых родительских зон). */
const unitOptions = ref([])
/** Единица текущего значения формы (для перехода «просмотр»). */
const currentUnit = ref(null)

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

/** Группы, в которых состоит редактируемый ресурс (только просмотр из этой формы). */
const memberGroups = ref([])
const memberGroupsLoading = ref(false)

/** Подгружает группы членства для редактируемой записи. */
async function loadMemberGroups() {
  if (!props.record) {
    memberGroups.value = []
    return
  }
  memberGroupsLoading.value = true
  try {
    const { data: links, error: linkError } = await getClient()
      .from(linkTable.value)
      .select('group_id')
      .eq('resource_id', props.record.id)
    if (linkError) {
      console.error('Не удалось загрузить членство в группах:', linkError)
      memberGroups.value = []
      return
    }
    if (links.length === 0) {
      memberGroups.value = []
      return
    }
    const ids = links.map((l) => l.group_id)
    const { data: groups, error: groupError } = await getClient()
      .from(groupTable.value)
      .select('id,name')
      .in('id', ids)
    if (groupError) {
      console.error('Не удалось загрузить группы:', groupError)
      memberGroups.value = []
      return
    }
    memberGroups.value = groups
  } finally {
    memberGroupsLoading.value = false
  }
}

/** Смену единицы измерения нельзя выполнить при членстве хотя бы в одной группе. */
const unitLocked = computed(() => isEditing.value && memberGroups.value.length > 0)

function resetForm() {
  model.name = props.record?.name ?? ''
  model.description = props.record?.description ?? ''
  model.unit_id = props.record?.unit_id ?? null
}

watch(
  () => props.show,
  async (visible) => {
    if (!visible) return
    editing.value = props.record ? { ...props.record } : null
    resetForm()
    await loadUnitOptions()
    await loadMemberGroups()
  },
  { immediate: true },
)

watch(
  () => model.unit_id,
  (id) => {
    currentUnit.value = unitOptions.value.find((o) => o.value === id) ?? null
  },
)

/** Отправка формы: создание либо обновление ресурса. */
async function onSubmit() {
  if (formReadonly.value) return
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  loading.value = true
  try {
    const payload = {
      name: model.name,
      description: model.description || null,
      unit_id: model.unit_id,
    }
    const { error } = isEditing.value
      ? await getClient().from(resourceTable.value).update(payload).eq('id', props.record.id)
      : await getClient().from(resourceTable.value).insert(payload)

    if (error) {
      console.error(`Не удалось сохранить ресурс (${resourceTable.value}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    message.success(isEditing.value ? 'Ресурс обновлён' : 'Ресурс создан')
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

// --- переход "просмотр"/"выбор" единицы измерения ---

const unitsModalVisible = ref(false)
const unitsModalPickMode = ref(false)

/** Открывает грид единиц в режиме просмотра текущего значения. */
function viewUnit() {
  unitsModalPickMode.value = false
  unitsModalVisible.value = true
}

/** Открывает грид единиц в режиме выбора нового значения. */
function pickUnit() {
  if (formReadonly.value || unitLocked.value) return
  unitsModalPickMode.value = true
  unitsModalVisible.value = true
}

/** @param {{id: string, name: string, short_name: string}} unit */
function onUnitPicked(unit) {
  model.unit_id = unit.id
  if (!unitOptions.value.some((o) => o.value === unit.id)) {
    unitOptions.value.push({ label: `${unit.name} (${unit.short_name})`, value: unit.id })
  }
}

// --- переход "просмотр" группы / управление составом ---

const groupsModalVisible = ref(false)

function openGroupComposition() {
  groupsModalVisible.value = true
}

/** После закрытия панели групп состав ресурса мог измениться — перечитываем. */
watch(groupsModalVisible, (visible) => {
  if (!visible) loadMemberGroups()
})
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    :title="isEditing ? (formReadonly ? 'Просмотр ресурса' : 'Редактирование ресурса') : 'Новый ресурс'"
    class="w-full max-w-lg"
    @update:show="(value) => emit('update:show', value)"
    @close="onClose"
  >
    <template
      v-if="isEditing && !formReadonly"
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
          placeholder="Бригада №3"
        />
      </n-form-item>

      <n-form-item
        label="Описание"
        path="description"
      >
        <n-input
          v-model:value="model.description"
          type="textarea"
          :rows="3"
          placeholder="Дополнительный контекст"
        />
      </n-form-item>

      <n-form-item
        label="Единица измерения"
        path="unit_id"
      >
        <div class="flex items-center gap-2 w-full">
          <n-select
            v-model:value="model.unit_id"
            :options="unitOptions"
            :disabled="loading || formReadonly || unitLocked"
            placeholder="Выберите единицу измерения"
            class="flex-1"
          />
          <n-button
            size="small"
            :disabled="!model.unit_id"
            @click="viewUnit"
          >
            Просмотр
          </n-button>
          <n-button
            v-if="!formReadonly"
            size="small"
            :disabled="unitLocked"
            @click="pickUnit"
          >
            Выбрать
          </n-button>
        </div>
        <p
          v-if="unitLocked"
          class="text-xs text-gray-500 mt-1"
        >
          Нельзя изменить: ресурс состоит хотя бы в одной группе
        </p>
      </n-form-item>

      <n-form-item
        v-if="isEditing"
        label="Группы"
      >
        <n-spin :show="memberGroupsLoading">
          <div class="flex flex-wrap items-center gap-2">
            <n-tag
              v-for="group in memberGroups"
              :key="group.id"
              size="small"
              round
            >
              {{ group.name }}
            </n-tag>
            <span
              v-if="memberGroups.length === 0"
              class="text-xs text-gray-500"
            >
              Не состоит ни в одной группе
            </span>
          </div>
        </n-spin>
        <n-button
          text
          type="primary"
          size="small"
          class="mt-1"
          @click="openGroupComposition"
        >
          управлять составом
        </n-button>
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

  <UnitsTableModal
    v-model:show="unitsModalVisible"
    :kind="props.kind"
    :pick-mode="unitsModalPickMode"
    @pick="onUnitPicked"
  />

  <GroupsTableModal
    v-model:show="groupsModalVisible"
    :kind="props.kind"
  />
</template>
