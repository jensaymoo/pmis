<script setup>
//
// Горизонтальное меню топ-бара — pmis.wiki/docs/auth-and-navigation-main-layout.md §4.3.
//
// Строится из menuStore.tree (дерево по parent_id, уже отсортировано по
// sort_order). Листовые пункты (screen_id задан) используют screen.route как
// ключ и как цель навигации. Группирующие пункты без screen_id получают
// синтетический ключ (item.id) и не выполняют переход — Naive UI сам
// раскрывает их children по наведению/клику.
//
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useMenuStore } from '../stores/menu'

const router = useRouter()
const route = useRoute()
const menuStore = useMenuStore()

/**
 * Рекурсивно превращает узел дерева меню в MenuOption Naive UI.
 * @param {object} node
 * @returns {object}
 */
function toMenuOption(node) {
  const key = node.screen?.route ?? node.id
  const option = {
    label: node.label,
    key,
  }
  if (node.children && node.children.length > 0) {
    option.children = node.children.map(toMenuOption)
  }
  return option
}

const options = computed(() => menuStore.tree.map(toMenuOption))

/** Активный пункт — ключ, совпадающий с текущим маршрутом. */
const activeKey = computed(() => route.path)

/**
 * Клик по пункту меню. Переход выполняется только для пунктов с реальным
 * маршрутом экрана (screen.route); группирующие пункты без маршрута не
 * навигируют — Naive UI лишь раскрывает их подменю.
 * @param {string} key
 */
function onSelect(key) {
  if (typeof key === 'string' && key.startsWith('/')) {
    router.push(key)
  }
}
</script>

<template>
  <n-menu
    v-if="menuStore.tree.length > 0"
    mode="horizontal"
    :options="options"
    :value="activeKey"
    @update:value="onSelect"
  />
</template>
