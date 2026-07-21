<script setup>
//
// Форма создания/редактирования единицы измерения вида ресурса (персонал/
// техника/материалы) — resources-pattern.md §2.4, §6.2. Действия жизненного
// цикла (активировать, деактивировать, удалить, восстановить) вынесены в
// слот #header-extra модалки, как в ResourceFormModal.vue/QtyUnitFormModal.vue.
//
import { computed, reactive, ref, watch } from 'vue'
import { useMessage, useNotification, NSpace, NButton } from 'naive-ui'
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

const table = computed(() => `${props.kind}_unit`)
const isAdmin = computed(() => auth.user?.role === 'admin')
const isDispatcher = computed(() => auth.user?.role === 'dispatcher')

const lifecycle = useRecordLifecycle({
  getClient,
  table: table.value,
  entityLabel: 'единицу измерения',
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
  short_name: '',
  is_integer: false,
})

const rules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  short_name: [{ required: true, message: 'Введите сокращение', trigger: ['input', 'blur'] }],
}

function resetForm() {
  model.name = props.record?.name ?? ''
  model.short_name = props.record?.short_name ?? ''
  model.is_integer = !!props.record?.is_integer
}

watch(
  () => props.show,
  (visible) => {
    if (!visible) return
    editing.value = props.record ? { ...props.record } : null
    resetForm()
    formRef.value?.restoreValidation()
  },
  { immediate: true },
)

/** Отправка формы: создание либо обновление единицы измерения. */
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
      short_name: model.short_name,
      is_integer: model.is_integer,
    }
    const { error } = isEditing.value
      ? await getClient().from(table.value).update(payload).eq('id', props.record.id)
      : await getClient().from(table.value).insert(payload)

    if (error) {
      console.error(`Не удалось сохранить единицу измерения (${table.value}):`, error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    message.success(isEditing.value ? 'Единица измерения обновлена' : 'Единица измерения создана')
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
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    :title="isEditing ? (formReadonly ? 'Просмотр единицы измерения' : 'Редактирование единицы измерения') : 'Новая единица измерения'"
    class="w-full max-w-md"
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
          placeholder="человеко-час"
        />
      </n-form-item>
      <n-form-item
        label="Сокращение"
        path="short_name"
      >
        <n-input
          v-model:value="model.short_name"
          placeholder="чел·ч"
        />
      </n-form-item>
      <n-form-item
        label="Целочисленность"
        path="is_integer"
      >
        <div>
          <n-switch v-model:value="model.is_integer" />
          <p class="text-xs text-gray-500 mt-1">
            допускать только целые значения
          </p>
        </div>
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
</template>
