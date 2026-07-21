/**
 * Адаптер данных для диаграммы Bryntum Gantt поверх PostgREST: разрешение
 * активного проекта зоны, загрузка/маппинг дерева работ и зависимостей в
 * формат Bryntum, обратный маппинг для быстрых правок с диаграммы (drag/resize,
 * смена родителя) и удаление. Инкапсулирует все обращения к API — компонент
 * GanttView.vue не строит запросы самостоятельно (frontend-spec.md §4 «Адаптеры»,
 * §10 «Интеграция сторонних виджетов»).
 *
 * См. planning-gantt.md, backend-planning.md, work-structure-api.md.
 */

/**
 * Числовые коды типов зависимостей Bryntum (DependencyType):
 * 0 — StartToStart, 1 — StartToEnd, 2 — EndToStart, 3 — EndToEnd.
 * @type {Record<'SS'|'SF'|'FS'|'FF', number>}
 */
export const DEPENDENCY_TYPE_TO_BRYNTUM = {
  SS: 0,
  SF: 1,
  FS: 2,
  FF: 3,
}

/** Обратная карта: числовой код Bryntum → серверный код типа связи. */
export const DEPENDENCY_TYPE_FROM_BRYNTUM = {
  0: 'SS',
  1: 'SF',
  2: 'FS',
  3: 'FF',
}

/**
 * Определяет активный проект зоны пользователя: проект той же организации,
 * а если такого нет — первый доступный (созданный вышестоящей/видимой зоной).
 * @param {import('@supabase/postgrest-js').PostgrestClient} client
 * @param {string} orgUnitId
 * @returns {Promise<{id: string, name: string, org_unit_id: string, status: string}|null>}
 */
export async function resolveActiveProject(client, orgUnitId) {
  const { data, error } = await client
    .from('project')
    .select('id,name,org_unit_id,status')
    .neq('status', 'deprecated')
    .order('name')
  if (error) {
    console.error('Не удалось загрузить проекты:', error)
    throw new Error(error.message)
  }
  if (!data || data.length === 0) {
    return null
  }
  return data.find((p) => p.org_unit_id === orgUnitId) ?? data[0]
}

/**
 * Создаёт проект в зоне текущего пользователя (org_unit_id подставляет сервер
 * из JWT-claim). Возвращает созданную запись.
 * @param {import('@supabase/postgrest-js').PostgrestClient} client
 * @param {string} name
 * @returns {Promise<{id: string, name: string, org_unit_id: string, status: string}>}
 */
export async function createProject(client, name) {
  const { data, error } = await client
    .from('project')
    .insert({ name })
    .select('id,name,org_unit_id,status')
    .single()
  if (error) {
    console.error('Не удалось создать проект:', error)
    throw new Error(error.message)
  }
  return data
}

/**
 * Маппинг серверной записи `task` в формат Bryntum. Плоский список с
 * `parentId` — движок Bryntum нативно строит дерево из плоских данных по
 * этому полю, ручная сборка вложенных `children` не нужна.
 *
 * Помимо стандартных полей Bryntum сохраняет исходные серверные значения под
 * префиксом `pmis*` — они нужны кастомным колонкам (Объём/Прогресс) и редактору
 * (открывается с исходным task-объектом по клику).
 *
 * @param {object} row Строка ответа GET /task
 * @returns {object} Task-запись Bryntum
 */
function mapTaskRow(row) {
  return {
    id: row.id,
    parentId: row.parent_id,
    name: row.name,
    startDate: row.start_date ? new Date(row.start_date) : null,
    endDate: row.end_date ? new Date(row.end_date) : null,
    duration: row.duration,
    percentDone: row.percent_done ?? 0,
    milestone: row.task_type === 'milestone',
    // Факт read-only — используется только для отображения, не для правки.
    actualStartDate: row.actual_start ? new Date(row.actual_start) : null,
    actualEndDate: row.actual_end ? new Date(row.actual_end) : null,

    // Исходные серверные поля — для кастомных колонок и открытия редактора.
    pmisProjectId: row.project_id,
    pmisParentId: row.parent_id,
    pmisOrgUnitId: row.org_unit_id,
    pmisTaskType: row.task_type,
    pmisPlanQty: row.plan_qty,
    pmisQtyUnitId: row.qty_unit_id,
    pmisQtyUnitShortName: row.qty_unit?.short_name ?? null,
    pmisPercentDone: row.percent_done,
    pmisStatus: row.status,
    pmisRaw: row,
  }
}

/**
 * Маппинг серверной записи `task_dependency` в формат Bryntum.
 * @param {object} row Строка ответа GET /task_dependency
 * @returns {object} Dependency-запись Bryntum
 */
function mapDependencyRow(row) {
  return {
    id: row.id,
    fromEvent: row.from_id,
    toEvent: row.to_id,
    type: DEPENDENCY_TYPE_TO_BRYNTUM[row.type] ?? DEPENDENCY_TYPE_TO_BRYNTUM.FS,
    lag: row.lag ?? 0,
    pmisProjectId: row.project_id,
    pmisStatus: row.status,
  }
}

/**
 * Загружает дерево работ и зависимости проекта, готовые к передаче в
 * `tasksData`/`dependenciesData` компонента `<bryntum-gantt>`.
 * @param {import('@supabase/postgrest-js').PostgrestClient} client
 * @param {string} projectId
 * @returns {Promise<{tasksData: Array<object>, dependenciesData: Array<object>}>}
 */
export async function loadProject(client, projectId) {
  const [tasksRes, depsRes] = await Promise.all([
    client
      .from('task')
      .select(
        'id,project_id,parent_id,org_unit_id,task_type,name,start_date,end_date,duration,plan_qty,qty_unit_id,percent_done,actual_start,actual_end,status,qty_unit:qty_unit_id(short_name)',
      )
      .eq('project_id', projectId)
      .neq('status', 'deprecated'),
    client
      .from('task_dependency')
      .select('id,project_id,from_id,to_id,type,lag,status')
      .eq('project_id', projectId)
      .neq('status', 'deprecated'),
  ])

  if (tasksRes.error) {
    console.error('Не удалось загрузить работы проекта:', tasksRes.error)
    throw new Error(tasksRes.error.message)
  }
  if (depsRes.error) {
    console.error('Не удалось загрузить зависимости проекта:', depsRes.error)
    throw new Error(depsRes.error.message)
  }

  return {
    tasksData: tasksRes.data.map(mapTaskRow),
    dependenciesData: depsRes.data.map(mapDependencyRow),
  }
}

/**
 * Обратный маппинг записи Bryntum (после drag/resize/create на диаграмме) в
 * тело PATCH/POST для `/task`. Переносит только календарно-иерархические
 * поля — атрибуты вида name/plan_qty правит кастомный редактор (TaskEditorModal),
 * не диаграмма.
 * @param {{startDate?: Date, endDate?: Date, parentId?: string|null, name?: string}} bryntumTaskRecord
 * @returns {{start_date?: string, end_date?: string, parent_id?: string|null, name?: string}}
 */
export function taskToApiPayload(bryntumTaskRecord) {
  const payload = {}
  if (bryntumTaskRecord.startDate instanceof Date) {
    payload.start_date = bryntumTaskRecord.startDate.toISOString()
  }
  if (bryntumTaskRecord.endDate instanceof Date) {
    payload.end_date = bryntumTaskRecord.endDate.toISOString()
  }
  if ('parentId' in bryntumTaskRecord) {
    payload.parent_id = bryntumTaskRecord.parentId
  }
  if ('name' in bryntumTaskRecord) {
    payload.name = bryntumTaskRecord.name
  }
  return payload
}

/**
 * Синхронизирует плановые даты работы после перетаскивания/растягивания бара.
 * @param {import('@supabase/postgrest-js').PostgrestClient} client
 * @param {string} taskId
 * @param {{startDate: Date, endDate: Date}} dates
 * @returns {Promise<{data: object|null, error: object|null}>}
 */
export async function syncTaskDates(client, taskId, { startDate, endDate }) {
  const { data, error } = await client
    .from('task')
    .update({
      start_date: startDate instanceof Date ? startDate.toISOString() : startDate,
      end_date: endDate instanceof Date ? endDate.toISOString() : endDate,
    })
    .eq('id', taskId)
    .select()
    .single()
  if (error) {
    console.error('Не удалось синхронизировать даты работы:', error)
  }
  return { data, error }
}

/**
 * Синхронизирует родителя работы после drag&drop-реорганизации дерева.
 * @param {import('@supabase/postgrest-js').PostgrestClient} client
 * @param {string} taskId
 * @param {string|null} parentId
 * @returns {Promise<{data: object|null, error: object|null}>}
 */
export async function syncTaskParent(client, taskId, parentId) {
  const { data, error } = await client
    .from('task')
    .update({ parent_id: parentId })
    .eq('id', taskId)
    .select()
    .single()
  if (error) {
    console.error('Не удалось синхронизировать родителя работы:', error)
  }
  return { data, error }
}

/**
 * Удаляет работу (мягкое удаление, сервер каскадно обрабатывает поддерево,
 * связи и плановые назначения согласно бизнес-правилам работ). Клиент не
 * дублирует проверки — только вызывает DELETE и транслирует ошибку.
 * @param {import('@supabase/postgrest-js').PostgrestClient} client
 * @param {string} taskId
 * @returns {Promise<{error: object|null}>}
 */
export async function deleteTaskCascade(client, taskId) {
  const { error } = await client.from('task').delete().eq('id', taskId)
  if (error) {
    console.error('Не удалось удалить работу:', error)
  }
  return { error }
}
