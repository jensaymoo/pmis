/**
 * Канонический список статусов записи справочника для фильтров.
 * Один источник правды по набору статусов и их локализованным подписям
 * (resources-pattern.md §6.1, backend-spec.md — enum record_status).
 *
 * @type {Array<{ label: string, value: string }>}
 */
export const STATUS_OPTIONS = [
  { label: 'Создана', value: 'created' },
  { label: 'Активна', value: 'enabled' },
  { label: 'Отключена', value: 'disabled' },
  { label: 'Удалена', value: 'deprecated' },
]

/** Статусы, показываемые по умолчанию (без удалённых). */
export const DEFAULT_STATUSES = ['created', 'enabled', 'disabled']
