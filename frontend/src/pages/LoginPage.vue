<script setup>
//
// Экран «Вход» — pmis.wiki/docs/auth-and-navigation-login.md
//
// Отдельный маршрут вне общего лэйаута (без топ-бара, без меню). Проверка
// «пользователь уже аутентифицирован» выполняется в router.beforeEach —
// этот компонент не делает собственный редирект.
//
import { ref, nextTick, onMounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useNotification } from 'naive-ui'
import { useAuthStore } from '../stores/auth'
import { useMenuStore } from '../stores/menu'

const router = useRouter()
const route = useRoute()
const auth = useAuthStore()
const menuStore = useMenuStore()
const notification = useNotification()

const formRef = ref(null)
const passwordInputRef = ref(null)
const emailInputRef = ref(null)

const model = ref({
  email: '',
  password: '',
})

const loading = ref(false)

const rules = {
  email: [
    { required: true, message: 'Введите email', trigger: ['input', 'blur'] },
    { type: 'email', message: 'Некорректный формат email', trigger: ['input', 'blur'] },
  ],
  password: [
    { required: true, message: 'Введите пароль', trigger: ['input', 'blur'] },
  ],
}

onMounted(() => {
  emailInputRef.value?.focus()
})

/**
 * Отправка формы входа. Валидирует поля, вызывает auth.login(), затем
 * подгружает профиль и меню и перенаправляет на сохранённую целевую ссылку
 * либо на стартовый экран роли. При ошибке — единое обобщённое уведомление
 * через основной канал (n-notification-provider), очистка пароля и фокус на
 * поле пароля (auth-and-navigation-login.md §4.2, §5.6, §5.9).
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
    await auth.login(model.value.email, model.value.password)
    await auth.fetchMe()
    await menuStore.load()
    const redirect = route.query.redirect
    router.push(redirect || auth.user?.start_route || '/')
  } catch (err) {
    console.error('Ошибка входа:', err)
    notification.error({
      content: 'Неверный email или пароль',
      duration: 5000,
    })
    model.value.password = ''
    await nextTick()
    passwordInputRef.value?.focus()
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="h-screen flex flex-col items-center justify-center bg-gray-50">
    <div class="mb-6 text-center">
      <span class="text-2xl font-semibold text-gray-800">PMIS</span>
    </div>

    <n-card
      class="w-full max-w-sm"
      :bordered="true"
    >
      <n-form
        ref="formRef"
        :model="model"
        :rules="rules"
        :disabled="loading"
        @submit.prevent="onSubmit"
      >
        <n-form-item
          label="Email"
          path="email"
        >
          <n-input
            ref="emailInputRef"
            v-model:value="model.email"
            type="text"
            placeholder="user@example.com"
            :disabled="loading"
          />
        </n-form-item>
        <n-form-item
          label="Пароль"
          path="password"
        >
          <n-input
            ref="passwordInputRef"
            v-model:value="model.password"
            type="password"
            show-password-on="click"
            placeholder="Пароль"
            :disabled="loading"
          />
        </n-form-item>
        <n-form-item :show-label="false">
          <n-button
            type="primary"
            attr-type="submit"
            block
            :loading="loading"
            :disabled="loading"
          >
            Войти
          </n-button>
        </n-form-item>
      </n-form>
    </n-card>

    <p class="mt-4 text-sm text-gray-500">
      Доступ предоставляется администратором
    </p>
  </div>
</template>
