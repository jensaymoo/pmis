/**
 * Стор навигационного меню: плоский список пунктов от API и производное дерево.
 *
 * См. pmis.wiki/docs/auth-and-navigation-api.md (GET /menu_item),
 * auth-and-navigation-main-layout.md §5.5 (обработка ошибки загрузки).
 */

import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { getClient } from '../lib/postgrest'

export const useMenuStore = defineStore('menu', () => {
  /** Плоский массив пунктов меню как есть от API. @type {import('vue').Ref<Array<object>>} */
  const items = ref([])
  /** @type {import('vue').Ref<boolean>} */
  const loaded = ref(false)
  /** @type {import('vue').Ref<string|null>} */
  const error = ref(null)

  /**
   * Дерево пунктов меню, построенное из items по parent_id. Корневые узлы
   * (parent_id === null) и дочерние списки отсортированы по sort_order;
   * каждый узел дополнен полем children.
   */
  const tree = computed(() => {
    const nodes = items.value.map((item) => ({ ...item, children: [] }))
    const byId = new Map(nodes.map((node) => [node.id, node]))
    const roots = []

    for (const node of nodes) {
      if (node.parent_id === null || node.parent_id === undefined) {
        roots.push(node)
      } else {
        const parent = byId.get(node.parent_id)
        if (parent) {
          parent.children.push(node)
        } else {
          roots.push(node)
        }
      }
    }

    const sortBySortOrder = (list) => list.sort((a, b) => a.sort_order - b.sort_order)
    for (const node of nodes) {
      sortBySortOrder(node.children)
    }
    sortBySortOrder(roots)

    return roots
  })

  /**
   * Есть ли в текущем меню пункт с указанным маршрутом экрана.
   * @param {string} path
   * @returns {boolean}
   */
  function hasRoute(path) {
    return items.value.some((i) => i.screen?.route === path)
  }

  /**
   * Загружает пункты меню, доступные текущей роли (эмбеддинг screen через FK).
   * Не бросает исключение — ошибка сохраняется в error, а не пробрасывается.
   * @returns {Promise<void>}
   */
  async function load() {
    const { data, error: reqError } = await getClient()
      .from('menu_item')
      .select('*, screen(code, route)')
      .order('sort_order')

    if (!reqError) {
      items.value = data
      loaded.value = true
      error.value = null
    } else {
      error.value = reqError.message
      console.error('Не удалось загрузить меню:', reqError)
      loaded.value = false
    }
  }

  /**
   * Сбрасывает стор меню (вызывается из auth.logout()).
   * @returns {void}
   */
  function reset() {
    items.value = []
    loaded.value = false
    error.value = null
  }

  return {
    items,
    loaded,
    error,
    tree,
    hasRoute,
    load,
    reset,
  }
})
