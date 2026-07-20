<script setup>
import { ruRU, dateRuRU } from 'naive-ui'
const themeOverrides = {
  common: {
    borderRadius: '5px',
    primaryColor:        '#014eb4',
    primaryColorHover:   '#013e8f',
    primaryColorPressed: '#012e6b',
    primaryColorSuppl:   '#3d88ee',
    textColorDisabled: '#6E6E6E',
  },
  Spin: {
    opacitySpinning: 0.4
  },
  Badge: {
    colorInfo: '#3889C5',
  },
  Typography: {
    textColorInfo: '#3889C5',
  }
}
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
    :theme-overrides="themeOverrides"
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
