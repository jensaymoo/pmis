<script setup>
//
// Форма создания/редактирования участка — sections-screen.md §4.2–§4.5.
// Отклонение от типовой формы справочника (§4.3): крупный размер, встроенная
// редактируемая таблица точек и область предпросмотра геометрии.
//
// Точки не являются отдельным справочником — живут только внутри формы и
// отправляются вместе с участком (POST/PATCH /section, затем
// POST/PATCH/DELETE /section_point по разнице, sections-api.md).
//
import { ref, computed, watch, nextTick } from 'vue'
import { useNotification } from 'naive-ui'
import { getClient } from '../../lib/postgrest'
import SectionMapPreview from './SectionMapPreview.vue'

const props = defineProps({
  show: { type: Boolean, required: true },
  /** Запись для редактирования; null — форма создания */
  record: { type: Object, default: null },
})

const emit = defineEmits(['update:show', 'saved'])

const notification = useNotification()
const formRef = ref(null)
const nameInputRef = ref(null)
const loading = ref(false)

const isEdit = computed(() => !!props.record)

const model = ref({
  name: '',
  kind: 'linear',
  is_geographic: false,
})

/** @type {import('vue').Ref<Array<{key: number, id?: string, name: string, x: number|null, y: number|null, z: number|null}>>} */
const points = ref([])
let nextKey = 1

const rules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
}

const kindOptions = [
  { label: 'Протяжённый', value: 'linear' },
  { label: 'Площадной', value: 'area' },
]

const minPoints = computed(() => (model.value.kind === 'area' ? 3 : 2))
// y обязателен при is_geographic или для 2D/3D негеографического режима; для
// негеографического 1D (linear, не географический) колонка скрывается —
// sections-screen.md §4.3.
const yColumnVisible = computed(() => model.value.is_geographic || model.value.kind === 'area')

const pointsErrorMessage = ref('')

/** Заполняет форму при открытии, включая загрузку точек существующего участка. */
watch(
  () => props.show,
  async (visible) => {
    if (!visible) return
    pointsErrorMessage.value = ''
    formRef.value?.restoreValidation()

    if (props.record) {
      model.value = {
        name: props.record.name,
        kind: props.record.kind,
        is_geographic: !!props.record.is_geographic,
      }
      points.value = []
      loading.value = true
      try {
        const { data, error } = await getClient()
          .from('section_point')
          .select('id,seq,name,x,y,z')
          .eq('section_id', props.record.id)
          .order('seq')
        if (error) {
          console.error('Не удалось загрузить точки участка:', error)
          notification.error({ content: error.message, duration: 6000 })
        } else {
          points.value = data.map((p) => ({
            key: nextKey++,
            id: p.id,
            name: p.name,
            x: p.x,
            y: p.y,
            z: p.z,
          }))
        }
      } finally {
        loading.value = false
      }
    } else {
      model.value = { name: '', kind: 'linear', is_geographic: false }
      points.value = []
    }

    await nextTick()
    nameInputRef.value?.focus()
  },
)

/**
 * Переключение «Географический» меняет интерпретацию координат
 * (sections-screen.md §4.2). Если существующие точки невалидны для нового
 * режима (не заполнены x/y там, где теперь обязательны), таблица очищается
 * с уведомлением — предупреждение показывается всегда при переключении.
 * @param {boolean} value
 */
function onGeographicChange(value) {
  const willNeedY = value || model.value.kind === 'area'
  const invalid = willNeedY && points.value.some((p) => p.y == null)
  model.value.is_geographic = value

  if (invalid) {
    points.value = []
    notification.warning({
      content:
        'Смена режима «Географический» меняет интерпретацию координат точек. Введённые точки не соответствуют новому режиму и были очищены — заполните их заново.',
      duration: 7000,
    })
  } else {
    notification.info({
      content: 'Интерпретация координат точек изменена. Проверьте введённые значения.',
      duration: 5000,
    })
  }
}

/**
 * Переключение вида (протяжённый/площадной) может изменить обязательность
 * колонки y — тот же принцип предупреждения, что и для is_geographic.
 * @param {string} value
 */
function onKindChange(value) {
  const willNeedY = model.value.is_geographic || value === 'area'
  const invalid = willNeedY && points.value.some((p) => p.y == null)
  model.value.kind = value

  if (invalid) {
    points.value = []
    notification.warning({
      content: 'Смена вида участка меняет минимальные требования к точкам. Введённые точки были очищены — заполните их заново.',
      duration: 7000,
    })
  }
}

function addPoint() {
  points.value.push({ key: nextKey++, name: '', x: null, y: null, z: null })
}

/** @param {number} index */
function removePoint(index) {
  points.value.splice(index, 1)
}

/** @param {number} index */
function moveUp(index) {
  if (index === 0) return
  const arr = points.value
  ;[arr[index - 1], arr[index]] = [arr[index], arr[index - 1]]
}

/** @param {number} index */
function moveDown(index) {
  if (index === points.value.length - 1) return
  const arr = points.value
  ;[arr[index], arr[index + 1]] = [arr[index + 1], arr[index]]
}

/**
 * Клиентская валидация точек: заполненность обязательных ячеек и минимум
 * точек с учётом вида/географичности (sections-screen.md §4.3). Достаточность
 * размерности проверяет сервер.
 * @returns {boolean}
 */
function validatePoints() {
  if (points.value.length < minPoints.value) {
    pointsErrorMessage.value = `Нужно минимум ${minPoints.value} ${model.value.kind === 'area' ? 'точки для площадного участка' : 'точки для протяжённого участка'}.`
    return false
  }
  const requireY = yColumnVisible.value
  const incomplete = points.value.some((p) => {
    if (!p.name?.trim() || p.x == null) return true
    if (requireY && p.y == null) return true
    return false
  })
  if (incomplete) {
    pointsErrorMessage.value = 'Заполните наименование и координаты всех точек.'
    return false
  }
  pointsErrorMessage.value = ''
  return true
}

const previewPoints = computed(() =>
  points.value.map((p) => ({ x: p.x, y: p.y, z: p.z })),
)

/**
 * Отправляет форму: сохраняет участок, затем синхронизирует точки —
 * обновляет существующие, создаёт новые, удаляет отсутствующие в текущем
 * списке (sections-api.md POST/PATCH/DELETE /section_point). При отказе
 * сервера (недостаточно точек/размерности) введённые точки не теряются
 * (sections-screen.md §4.5).
 * @returns {Promise<void>}
 */
async function onSubmit() {
  try {
    await formRef.value?.validate()
  } catch {
    return
  }
  if (!validatePoints()) return

  loading.value = true
  try {
    const client = getClient()
    const sectionPayload = {
      name: model.value.name,
      kind: model.value.kind,
      is_geographic: model.value.is_geographic,
    }

    let sectionId = props.record?.id
    if (isEdit.value) {
      const { error } = await client.from('section').update(sectionPayload).eq('id', sectionId)
      if (error) {
        console.error('Не удалось сохранить участок:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
    } else {
      const { data, error } = await client.from('section').insert(sectionPayload).select().single()
      if (error) {
        console.error('Не удалось создать участок:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
      sectionId = data.id
    }

    // Синхронизация точек: существующие id из БД, отсутствующие в текущем
    // списке — удаляются; остальные — upsert с новым seq по позиции в массиве.
    if (isEdit.value) {
      const { data: existing, error: fetchErr } = await client
        .from('section_point')
        .select('id')
        .eq('section_id', sectionId)
      if (fetchErr) {
        console.error('Не удалось прочитать текущие точки участка:', fetchErr)
        notification.error({ content: fetchErr.message, duration: 6000 })
        return
      }
      const keptIds = new Set(points.value.filter((p) => p.id).map((p) => p.id))
      const toDelete = existing.filter((p) => !keptIds.has(p.id)).map((p) => p.id)
      for (const id of toDelete) {
        const { error } = await client.from('section_point').delete().eq('id', id)
        if (error) {
          console.error('Не удалось удалить точку участка:', error)
          notification.error({ content: error.message, duration: 6000 })
          return
        }
      }
    }

    // Обновления существующих точек — по одной (PATCH .../:id).
    const updates = points.value
      .map((p, i) => ({ p, seq: i + 1 }))
      .filter(({ p }) => p.id)
    for (const { p, seq } of updates) {
      const { error } = await client
        .from('section_point')
        .update({ section_id: sectionId, seq, name: p.name, x: p.x, y: p.y, z: p.z })
        .eq('id', p.id)
      if (error) {
        console.error('Не удалось сохранить точку участка:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
    }

    // Новые точки — единым batch-INSERT (массив строк в одном запросе/транзакции).
    // section_point имеет DEFERRABLE INITIALLY DEFERRED constraint trigger
    // "минимум точек" (032_section_triggers.sql), который коммитится в конце
    // каждого отдельного REST-запроса — при поштучной вставке первая же точка
    // отклоняется, так как в момент её коммита остальных ещё не существует.
    // Один запрос с массивом строк — один INSERT-стейтмент, одна транзакция,
    // отложенная проверка видит финальное количество точек участка.
    const newPoints = points.value
      .map((p, i) => ({ p, seq: i + 1 }))
      .filter(({ p }) => !p.id)
      .map(({ p, seq }) => ({ section_id: sectionId, seq, name: p.name, x: p.x, y: p.y, z: p.z }))
    if (newPoints.length > 0) {
      const { error } = await client.from('section_point').insert(newPoints)
      if (error) {
        console.error('Не удалось сохранить точки участка:', error)
        notification.error({ content: error.message, duration: 6000 })
        return
      }
    }

    notification.success({
      content: isEdit.value ? 'Участок обновлён' : 'Участок создан',
      duration: 3000,
    })
    emit('saved')
    emit('update:show', false)
  } finally {
    loading.value = false
  }
}

function onClose() {
  emit('update:show', false)
}
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    :title="isEdit ? 'Участок' : 'Новый участок'"
    class="w-full max-w-5xl"
    :mask-closable="false"
    @update:show="(v) => emit('update:show', v)"
    @close="onClose"
  >
    <n-form
      ref="formRef"
      :model="model"
      :rules="rules"
      :disabled="loading"
      label-placement="top"
      @submit.prevent="onSubmit"
    >
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
        <n-form-item
          label="Наименование"
          path="name"
          class="md:col-span-1"
        >
          <n-input
            ref="nameInputRef"
            v-model:value="model.name"
            placeholder="Например, «ПК0+00 — ПК10+00»"
          />
        </n-form-item>
        <n-form-item label="Вид">
          <n-radio-group
            :value="model.kind"
            @update:value="onKindChange"
          >
            <n-radio-button
              v-for="opt in kindOptions"
              :key="opt.value"
              :value="opt.value"
              :label="opt.label"
            />
          </n-radio-group>
        </n-form-item>
        <n-form-item label="Географический">
          <div>
            <n-switch
              :value="model.is_geographic"
              @update:value="onGeographicChange"
            />
            <p class="text-xs text-gray-500 mt-1">
              включён — координаты как широта/долгота/высота, предпросмотр на карте
            </p>
          </div>
        </n-form-item>
      </div>

      <div
        v-if="isEdit && props.record"
        class="mb-4 text-sm text-gray-500"
      >
        Организация: {{ props.record.org_unit_name ?? props.record.org_unit_id }}
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div>
          <div class="flex items-center justify-between mb-2">
            <span class="text-sm font-medium">Точки</span>
            <n-button
              size="small"
              @click="addPoint"
            >
              Добавить точку
            </n-button>
          </div>

          <div class="border border-gray-200 rounded max-h-96 overflow-y-auto">
            <table class="w-full text-sm">
              <thead class="sticky top-0 bg-gray-50">
                <tr>
                  <th class="p-1 text-left w-10">
                    №
                  </th>
                  <th class="p-1 text-left">
                    Наименование
                  </th>
                  <th class="p-1 text-left w-24">
                    {{ model.is_geographic ? 'Широта' : 'x' }}
                  </th>
                  <th
                    v-if="yColumnVisible"
                    class="p-1 text-left w-24"
                  >
                    {{ model.is_geographic ? 'Долгота' : 'y' }}
                  </th>
                  <th class="p-1 text-left w-24">
                    {{ model.is_geographic ? 'Высота' : 'z' }}
                  </th>
                  <th class="p-1 w-24" />
                </tr>
              </thead>
              <tbody>
                <tr
                  v-for="(p, index) in points"
                  :key="p.key"
                  class="border-t border-gray-100"
                >
                  <td class="p-1 text-gray-400">
                    {{ index + 1 }}
                  </td>
                  <td class="p-1">
                    <n-input
                      v-model:value="p.name"
                      size="small"
                      placeholder="Наименование"
                    />
                  </td>
                  <td class="p-1">
                    <n-input-number
                      v-model:value="p.x"
                      size="small"
                      :show-button="false"
                    />
                  </td>
                  <td
                    v-if="yColumnVisible"
                    class="p-1"
                  >
                    <n-input-number
                      v-model:value="p.y"
                      size="small"
                      :show-button="false"
                    />
                  </td>
                  <td class="p-1">
                    <n-input-number
                      v-model:value="p.z"
                      size="small"
                      :show-button="false"
                    />
                  </td>
                  <td class="p-1">
                    <n-space size="small">
                      <n-button
                        size="tiny"
                        :disabled="index === 0"
                        @click="moveUp(index)"
                      >
                        ↑
                      </n-button>
                      <n-button
                        size="tiny"
                        :disabled="index === points.length - 1"
                        @click="moveDown(index)"
                      >
                        ↓
                      </n-button>
                      <n-button
                        size="tiny"
                        type="error"
                        @click="removePoint(index)"
                      >
                        Удалить
                      </n-button>
                    </n-space>
                  </td>
                </tr>
                <tr v-if="points.length === 0">
                  <td
                    colspan="6"
                    class="p-3 text-center text-gray-400"
                  >
                    Точек пока нет
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="text-xs text-gray-500 mt-1">
            Минимум точек: {{ minPoints }}
          </p>
          <p
            v-if="pointsErrorMessage"
            class="text-xs text-red-500 mt-1"
          >
            {{ pointsErrorMessage }}
          </p>
        </div>

        <div>
          <span class="text-sm font-medium">Предпросмотр</span>
          <div class="mt-2 h-96">
            <SectionMapPreview
              v-if="model.is_geographic"
              :points="previewPoints"
              :kind="model.kind"
            />
            <div
              v-else
              class="w-full h-full flex items-center justify-center text-sm text-gray-400 border border-dashed border-gray-200 rounded"
            >
              Предпросмотр недоступен для негеографических участков
            </div>
          </div>
        </div>
      </div>

      <n-form-item
        :show-label="false"
        class="mt-4"
      >
        <n-button
          type="primary"
          attr-type="submit"
          block
          :loading="loading"
          :disabled="loading"
        >
          Сохранить
        </n-button>
      </n-form-item>
    </n-form>
  </n-modal>
</template>
