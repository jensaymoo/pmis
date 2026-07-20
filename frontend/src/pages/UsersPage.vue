<script setup>
//
// Экран «Пользователи» — access-and-roles-users.md. Маршрут /users, доступ
// только admin (сервер перепроверяет через RLS независимо от UI).
//
// Грид пользователей — главная область экрана. Управление организациями
// (org_unit) открывается отдельной модалкой в режиме manage — точка входа,
// отличная от режима pick внутри формы пользователя (access-and-roles-users.md
// §1 «Пункт меню», §4.4).
//
import { ref } from 'vue'
import UsersGrid from '../components/admin/UsersGrid.vue'
import OrgUnitTree from '../components/admin/OrgUnitTree.vue'

const orgManageShow = ref(false)
</script>

<template>
  <div class="flex h-full flex-col gap-4 p-6">
    <header class="page-head-left">
      <div>
        <h1 class="page-head-left-title">
          Пользователи
        </h1>
      </div>
      <div class="page-head-right">
        <n-button @click="orgManageShow = true">
          Организации
        </n-button>
      </div>
    </header>

    <div class="min-h-0 grow">
      <UsersGrid />
    </div>

    <OrgUnitTree
      v-model:show="orgManageShow"
      mode="manage"
    />
  </div>
</template>
