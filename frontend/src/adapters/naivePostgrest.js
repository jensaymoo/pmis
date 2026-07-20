/**
 * Адаптер данных для n-data-table поверх PostgREST: серверная пагинация,
 * поиск (ilike) и фильтр по статусу. Инкапсулирует построение query-параметров
 * postgrest-js — компоненты справочников получают готовые rows/pagination и не
 * обращаются к API напрямую (frontend-spec.md §4 «Адаптеры»).
 *
 * См. roadmap/05-references.md §5.1, resources-pattern.md §6.1, §6.4.
 */

import { ref, computed, watch } from 'vue'

const DEFAULT_PAGE_SIZE = 20

/**
 * @param {object} opts
 * @param {() => import('@supabase/postgrest-js').PostgrestClient} opts.getClient Фабрика клиента (см. lib/postgrest.js)
 * @param {string} opts.table Имя таблицы/представления
 * @param {string} [opts.select] Список полей/эмбеддингов postgrest (по умолчанию '*')
 * @param {string|null} [opts.searchColumn] Колонка для ilike-поиска (по умолчанию 'name'); null отключает поиск
 * @param {string[]} [opts.defaultStatuses] Статусы, показанные по умолчанию (все, кроме `deprecated` — pattern.md §6.1)
 * @param {() => Array<[string, string|number|boolean]>} [opts.extraFilters] Реактивная функция доп. eq-фильтров, например () => [['org_unit_id', id]]
 * @param {string} [opts.order] Колонка сортировки (по умолчанию значение searchColumn или 'id')
 * @returns {{
 *   rows: import('vue').Ref<Array<object>>,
 *   loading: import('vue').Ref<boolean>,
 *   total: import('vue').Ref<number>,
 *   search: import('vue').Ref<string>,
 *   statusFilter: import('vue').Ref<string[]>,
 *   page: import('vue').Ref<number>,
 *   pageSize: import('vue').Ref<number>,
 *   pagination: import('vue').ComputedRef<object>,
 *   reload: () => Promise<void>,
 * }}
 */
export function useReferenceList(opts) {
  const {
    getClient,
    table,
    select = '*',
    searchColumn = 'name',
    defaultStatuses = ['created', 'enabled', 'disabled'],
    extraFilters = () => [],
    order = searchColumn ?? 'id',
  } = opts

  const rows = ref([])
  const loading = ref(false)
  const total = ref(0)
  const search = ref('')
  const statusFilter = ref([...defaultStatuses])
  const page = ref(1)
  const pageSize = ref(DEFAULT_PAGE_SIZE)

  // Ключ последнего ОТПРАВЛЕННОГО запроса. Нужен, чтобы не слать два
  // одинаковых запроса подряд (гонка debounce-эмита фильтра и его же
  // flush по закрытию попапера, либо синхронизация modelValue) — пока
  // висит ответ на такой же ключ, повторный reload пропускается.
  /** @type {string|null} */
  let inflightKey = null

  /**
   * Перезагружает текущую страницу с учётом поиска, фильтра статуса и
   * дополнительных фильтров. Не бросает исключение — ошибка логируется,
   * rows/total сбрасываются в пустое состояние (pattern.md §6.3).
   * @returns {Promise<void>}
   */
  async function reload() {
    const key = JSON.stringify([
      page.value,
      pageSize.value,
      search.value,
      statusFilter.value,
      extraFilters(),
    ])
    // Дедупликация: тот же запрос уже в полёте — второй не шлём. Явный
    // вызов после сохранения (когда loading уже false) всё равно пройдёт.
    if (loading.value && key === inflightKey) {
      return
    }
    inflightKey = key
    loading.value = true
    try {
      let query = getClient()
        .from(table)
        .select(select, { count: 'exact' })
        .order(order)
        .range((page.value - 1) * pageSize.value, page.value * pageSize.value - 1)

      if (searchColumn && search.value.trim()) {
        query = query.ilike(searchColumn, `%${search.value.trim()}%`)
      }
      if (statusFilter.value.length > 0) {
        query = query.in('status', statusFilter.value)
      }
      for (const [column, value] of extraFilters()) {
        query = query.eq(column, value)
      }

      const { data, count, error } = await query
      if (error) {
        console.error(`Не удалось загрузить ${table}:`, error)
        rows.value = []
        total.value = 0
      } else {
        rows.value = data
        total.value = count ?? data.length
      }
    } finally {
      // Сбрасываем ключ только если он всё ещё соответствует этому запросу —
      // чтобы новый reload под тем же ключом (после save) прошёл заново.
      if (inflightKey === key) {
        inflightKey = null
      }
      loading.value = false
    }
  }

  const pagination = computed(() => ({
    page: page.value,
    pageSize: pageSize.value,
    itemCount: total.value,
    showSizePicker: true,
    pageSizes: [10, 20, 50, 100],
    onUpdatePage: (p) => {
      page.value = p
      reload()
    },
    onUpdatePageSize: (ps) => {
      pageSize.value = ps
      page.value = 1
      reload()
    },
  }))

  watch([search, statusFilter], () => {
    page.value = 1
    reload()
  })

  // Первичная загрузка при создании composable — без неё грид остаётся пустым,
  // пока пользователь не тронет поиск/фильтр (реактивный watch выше не
  // срабатывает immediate).
  reload()

  return { rows, loading, total, search, statusFilter, page, pageSize, pagination, reload }
}
