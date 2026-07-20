/**
 * Действия жизненного цикла записи справочника: активировать, деактивировать,
 * мягко удалить, восстановить. Централизует диалоги подтверждения, вызовы
 * PATCH/DELETE через PostgrestClient и единый канал уведомлений об успехе/ошибке.
 *
 * См. pmis.wiki/docs/resources-pattern.md §4 (статусы и действия), §5 (открытая
 * ссылка — отказ сервера), §6.3 (обработка ошибок).
 *
 * Должен вызываться внутри setup() компонента-потребителя провайдеров
 * n-dialog-provider/n-notification-provider (см. App.vue).
 */

import { useDialog, useNotification } from 'naive-ui'

/**
 * @param {object} opts
 * @param {() => import('@supabase/postgrest-js').PostgrestClient} opts.getClient
 * @param {string} opts.table
 * @param {string} [opts.entityLabel] Наименование сущности в текстах диалогов, например «ресурс», «группу», «единицу измерения»
 * @returns {{
 *   activate: (record: {id: string}) => Promise<boolean>,
 *   deactivate: (record: {id: string}) => Promise<boolean>,
 *   softDelete: (record: {id: string}) => Promise<boolean>,
 *   restore: (record: {id: string}) => Promise<boolean>,
 *   availableActions: (status: string, isAdmin?: boolean) => Array<'activate'|'deactivate'|'delete'|'restore'>,
 * }}
 */
export function useRecordLifecycle({ getClient, table, entityLabel = 'запись' }) {
  const dialog = useDialog()
  const notification = useNotification()

  /**
   * Выполняет PATCH/DELETE и превращает ответ сервера в уведомление; при ошибке
   * дублирует её в консоль (frontend-spec.md §8) и возвращает false, не бросая исключение.
   * @param {() => Promise<{error: {message: string}|null}>} request
   * @param {string} successMessage
   * @returns {Promise<boolean>}
   */
  async function run(request, successMessage) {
    const { error } = await request()
    if (error) {
      console.error(`Операция над ${table} отклонена:`, error)
      notification.error({ content: error.message, duration: 6000 })
      return false
    }
    notification.success({ content: successMessage, duration: 3000 })
    return true
  }

  /** @param {{id: string}} record @returns {Promise<boolean>} */
  function activate(record) {
    return run(
      () => getClient().from(table).update({ status: 'enabled' }).eq('id', record.id),
      'Запись активирована',
    )
  }

  /** @param {{id: string}} record @returns {Promise<boolean>} */
  function deactivate(record) {
    return new Promise((resolve) => {
      dialog.warning({
        title: 'Деактивировать запись?',
        content: `Деактивированн${entityLabel === 'запись' ? 'ая запись' : `ый(ую) ${entityLabel}`} станет недоступн${entityLabel === 'запись' ? 'а' : 'ым(ой)'} для новых назначений и выбора.`,
        positiveText: 'Деактивировать',
        negativeText: 'Отмена',
        autoFocus: false,
        onPositiveClick: async () => {
          resolve(
            await run(
              () => getClient().from(table).update({ status: 'disabled' }).eq('id', record.id),
              'Запись деактивирована',
            ),
          )
        },
        onNegativeClick: () => resolve(false),
        onClose: () => resolve(false),
        onMaskClick: () => resolve(false),
      })
    })
  }

  /** @param {{id: string}} record @returns {Promise<boolean>} */
  function softDelete(record) {
    return new Promise((resolve) => {
      dialog.warning({
        title: 'Удалить запись?',
        content: 'Запись не удаляется физически, а помечается устаревшей (можно восстановить позже).',
        positiveText: 'Удалить',
        negativeText: 'Отмена',
        autoFocus: false,
        onPositiveClick: async () => {
          resolve(
            await run(
              () => getClient().from(table).delete().eq('id', record.id),
              'Запись удалена',
            ),
          )
        },
        onNegativeClick: () => resolve(false),
        onClose: () => resolve(false),
        onMaskClick: () => resolve(false),
      })
    })
  }

  /** @param {{id: string}} record @returns {Promise<boolean>} */
  function restore(record) {
    return run(
      () => getClient().from(table).update({ status: 'disabled' }).eq('id', record.id),
      'Запись восстановлена в статус «Отключена». Активируйте её отдельным действием, когда потребуется.',
    )
  }

  /**
   * Набор действий, доступных для текущего статуса записи (pattern.md §4.1).
   * «Восстановить» доступно только администратору.
   * @param {string} status
   * @param {boolean} [isAdmin]
   * @returns {Array<'activate'|'deactivate'|'delete'|'restore'>}
   */
  function availableActions(status, isAdmin = false) {
    switch (status) {
      case 'created':
      case 'disabled':
        return ['activate', 'delete']
      case 'enabled':
        return ['deactivate', 'delete']
      case 'deprecated':
        return isAdmin ? ['restore'] : []
      default:
        return []
    }
  }

  return { activate, deactivate, softDelete, restore, availableActions }
}
