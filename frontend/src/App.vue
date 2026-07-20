<script setup>
import { ruRU, dateRuRU } from 'naive-ui'
</script>

<template>
  <!--
    Провайдеры Naive UI монтируются здесь, в корне, а не только в MainLayout:
    LoginPage.vue — отдельный маршрут вне MainLayout (auth-and-navigation-login.md),
    но использует useNotification() для единого канала ошибок входа. Композабл
    работает только у потомков n-notification-provider — без провайдера в корне
    страница входа падает при монтировании ("No outer n-notification-provider
    found"). MainLayout остаётся единственным местом, где рендерится сам топ-бар
    и остальной каркас — здесь только провайдеры темы/уведомлений.
  -->
  <n-config-provider
    :locale="ruRU"
    :date-locale="dateRuRU"
  >
    <n-loading-bar-provider>
      <n-message-provider>
        <n-notification-provider>
          <n-dialog-provider>
            <router-view />
          </n-dialog-provider>
        </n-notification-provider>
      </n-message-provider>
    </n-loading-bar-provider>
  </n-config-provider>
</template>
