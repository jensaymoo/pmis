<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import DynamicMenu from '../components/DynamicMenu.vue'
import ChangePasswordModal from '../components/auth/ChangePasswordModal.vue'

const router = useRouter()
const auth = useAuthStore()

const showChangePassword = ref(false)

/**
 * Выход из системы: очищает токен/сессию/меню и перенаправляет на /login
 * (auth-and-navigation-main-layout.md §4.4, §5.3).
 * @returns {Promise<void>}
 */
async function onLogout() {
  await auth.logout()
  router.push('/login')
}
</script>

<template>
  <div class="h-screen flex flex-col">
    <header class="shrink-0 border-b border-gray-200 px-4 py-2 shadow flex items-center justify-between gap-4">
      <div class="shrink-0 text-lg font-semibold text-gray-800">
        PMIS
      </div>

      <div class="flex-1 min-w-0">
        <DynamicMenu />
      </div>

      <div
        v-if="auth.user"
        class="shrink-0 flex items-center gap-3"
      >
        <span class="text-sm text-gray-700">{{ auth.user.full_name }}</span>
        <n-button
          size="small"
          quaternary
          @click="showChangePassword = true"
        >
          Сменить пароль
        </n-button>
        <n-button
          size="small"
          @click="onLogout"
        >
          Выйти
        </n-button>
      </div>
    </header>
    <main class="flex-1 overflow-auto">
      <router-view />
    </main>
  </div>

  <ChangePasswordModal v-model:show="showChangePassword" />
</template>
