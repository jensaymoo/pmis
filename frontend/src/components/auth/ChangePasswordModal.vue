<script setup>
//
// Модалка смены пароля — открывается из зоны пользователя топ-бара
// (auth-and-navigation-main-layout.md §4.4).
//
// При успехе сервер инкрементирует token_version — текущий токен становится
// невалиден, поэтому после успешной смены пароля выполняется logout() и
// редирект на /login (см. контракт auth.changePassword в CLAUDE.md задачи).
//
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useMessage, useNotification } from 'naive-ui'
import { useAuthStore } from '../../stores/auth'

const props = defineProps({
  show: {
    type: Boolean,
    required: true,
  },
})

const emit = defineEmits(['update:show'])

const router = useRouter()
const auth = useAuthStore()
const message = useMessage()
const notification = useNotification()

const formRef = ref(null)
const loading = ref(false)

const model = ref({
  oldPassword: '',
  newPassword: '',
})

const rules = {
  oldPassword: [
    { required: true, message: 'Введите текущий пароль', trigger: ['input', 'blur'] },
  ],
  newPassword: [
    { required: true, message: 'Введите новый пароль', trigger: ['input', 'blur'] },
  ],
}

/** Сбрасывает поля формы. */
function resetForm() {
  model.value.oldPassword = ''
  model.value.newPassword = ''
}

/**
 * Закрывает модалку без сохранения.
 */
function onClose() {
  resetForm()
  emit('update:show', false)
}

/**
 * Отправка формы смены пароля. При успехе — сообщение, закрытие модалки,
 * принудительный выход и редирект на /login (токен инвалидирован сервером).
 * При ошибке — уведомление с текстом сервера (не обобщаем, в отличие от входа).
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
    await auth.changePassword(model.value.oldPassword, model.value.newPassword)
    message.success('Пароль изменён')
    resetForm()
    emit('update:show', false)
    await auth.logout()
    router.push('/login')
  } catch (err) {
    console.error('Ошибка смены пароля:', err)
    notification.error({
      content: err.message,
      duration: 5000,
    })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    title="Смена пароля"
    class="w-full max-w-sm"
    @update:show="(value) => emit('update:show', value)"
    @close="onClose"
  >
    <n-form
      ref="formRef"
      :model="model"
      :rules="rules"
      :disabled="loading"
    >
      <n-form-item
        label="Текущий пароль"
        path="oldPassword"
      >
        <n-input
          v-model:value="model.oldPassword"
          type="password"
          show-password-on="click"
          :disabled="loading"
        />
      </n-form-item>
      <n-form-item
        label="Новый пароль"
        path="newPassword"
      >
        <n-input
          v-model:value="model.newPassword"
          type="password"
          show-password-on="click"
          :disabled="loading"
        />
      </n-form-item>
    </n-form>
    <template #footer>
      <div class="flex justify-end gap-2">
        <n-button
          :disabled="loading"
          @click="onClose"
        >
          Отмена
        </n-button>
        <n-button
          type="primary"
          :loading="loading"
          :disabled="loading"
          @click="onSubmit"
        >
          Сменить пароль
        </n-button>
      </div>
    </template>
  </n-modal>
</template>
