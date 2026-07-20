<script setup>
//
// Форма создания/редактирования единицы объёма работ —
// pmis.wiki/docs/planning-qty-unit.md §4.2, §4.4.
//
// Поля: Наименование, Сокращение, переключатель «Целочисленность»
// (по умолчанию выключен = дробная). Организация вычисляется сервером при
// создании и показана как неизменяемое поле при редактировании
// (resources-pattern.md §6.2).
//
import { ref, computed, watch, nextTick } from 'vue'
import { useNotification } from 'naive-ui'
import { getClient } from '../../lib/postgrest'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** Запись для редактирования; null — форма создания */
  record: { type: Object, default: null },
})

const emit = defineEmits(['update:show', 'saved'])

const notification = useNotification()
const formRef = ref(null)
const nameInputRef = ref(null)
const loading = ref(false)

const isEdit = computed(() => !!props.record)

const model = ref({
  name: '',
  short_name: '',
  is_integer: false,
})

const rules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
  short_name: [{ required: true, message: 'Введите сокращение', trigger: ['input', 'blur'] }],
}

/** Сбрасывает/предзаполняет форму при открытии (resources-pattern.md §6.2). */
watch(
  () => props.show,
  async (visible) => {
    if (!visible) return
    model.value = props.record
      ? {
          name: props.record.name,
          short_name: props.record.short_name,
          is_integer: !!props.record.is_integer,
        }
      : { name: '', short_name: '', is_integer: false }
    formRef.value?.restoreValidation()
    await nextTick()
    nameInputRef.value?.focus()
  },
)

/**
 * Отправляет форму: POST при создании, PATCH при редактировании.
 * @returns {Promise<void>}
 */
async function onSubmit() {
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  loading.value = true
  try {
    const payload = {
      name: model.value.name,
      short_name: model.value.short_name,
      is_integer: model.value.is_integer,
    }
    const { error } = isEdit.value
      ? await getClient().from('qty_unit').update(payload).eq('id', props.record.id)
      : await getClient().from('qty_unit').insert(payload)

    if (error) {
      console.error('Не удалось сохранить единицу объёма работ:', error)
      notification.error({ content: error.message, duration: 6000 })
      return
    }

    notification.success({
      content: isEdit.value ? 'Единица объёма работ обновлена' : 'Единица объёма работ создана',
      duration: 3000,
    })
    emit('saved')
    emit('update:show', false)
  } finally {
    loading.value = false
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
    :title="isEdit ? 'Единица объёма работ' : 'Новая единица объёма работ'"
    class="w-full max-w-md"
    :mask-closable="false"
    @update:show="(v) => emit('update:show', v)"
    @close="onClose"
  >
    <n-form
      ref="formRef"
      :model="model"
      :rules="rules"
      :disabled="loading"
      label-placement="top"
      @submit.prevent="onSubmit"
    >
      <n-form-item
        label="Наименование"
        path="name"
      >
        <n-input
          ref="nameInputRef"
          v-model:value="model.name"
          placeholder="Например, «кубометр»"
        />
      </n-form-item>
      <n-form-item
        label="Сокращение"
        path="short_name"
      >
        <n-input
          v-model:value="model.short_name"
          placeholder="Например, «м3»"
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

      <div
        v-if="isEdit"
        class="mb-4 text-sm text-gray-500"
      >
        Организация: {{ props.record.org_unit_name ?? props.record.org_unit_id }}
      </div>

      <n-form-item :show-label="false">
        <n-button
          type="primary"
          attr-type="submit"
          block
          :loading="loading"
          :disabled="loading"
        >
          Сохранить
        </n-button>
      </n-form-item>
    </n-form>
  </n-modal>
</template>
