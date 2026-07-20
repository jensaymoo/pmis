<script setup>
//
// Абстрактный заголовок колонки грида-справочника с попапером-фильтром.
// Чистая оболочка: текст колонки + иконка-воронка-триггер (заливается,
// когда фильтр активен) + NPopover со слотом #default для тела фильтра.
//
// Debounce живёт внутри компонента: слот пишет в промежуточный буфер
// (через scoped-проп update), а задебаунсенное значение отправляется
// наружу через проп-колбэк apply — до записи во внешний фильтр, чтобы не
// дёргать сервер на каждый символ (useReferenceList перезагружает данные
// по изменению внешнего рефа). Никакой логики конкретного фильтра здесь
// нет — тип контрола и значение задаёт потребитель через слот и пропы.
//
import { ref, watch } from 'vue'
import { refDebounced } from '@vueuse/core'
import { NPopover, NButton, NIcon } from 'naive-ui'
import { FunnelOutline, Funnel } from '@vicons/ionicons5'

const props = defineProps({
  /** Текст заголовка колонки */
  label: { type: String, required: true },
  /** Текущее значение фильтра (для чтения: active, начальное значение) */
  modelValue: { type: [String, Array, Object], default: '' },
  /** Колбэк-отправка задебаунсенного значения наружу */
  apply: { type: Function, default: () => {} },
  /** Фильтр активен — иконка заливается. Задаёт потребитель */
  active: { type: Boolean, default: false },
  /** Позиция попапера относительно триггера */
  placement: { type: String, default: 'bottom-start' },
  /** Размер иконки-триггера, px */
  iconSize: { type: Number, default: 16 },
  /** Задержка debounce перед отправкой, мс */
  delay: { type: Number, default: 300 },
})

// Промежуточный буфер: слот пишет сюда, отправка наружу — с debounce.
const buffer = ref(props.modelValue)
const lastEmitted = ref(props.modelValue)
const debounced = refDebounced(buffer, props.delay)

// Внешнее изменение подтягивается в буфер (сброс/обновление извне),
// синхронизируя и lastEmitted, чтобы не было ложного повторного apply.
watch(
  () => props.modelValue,
  (v) => {
    if (v !== buffer.value) {
      buffer.value = v
      lastEmitted.value = v
    }
  },
)

// Debounce перед отправкой: отправляем, только если значение реально
// отличается от последнего отправленного (сравнение с пропом modelValue
// убрано — оно могло гоняться с внешним обновлением и пропускать emit).
watch(debounced, (v) => {
  if (v !== lastEmitted.value) {
    lastEmitted.value = v
    props.apply(v)
  }
})

// Страховочный коммит при закрытии попапера: живой debounce (delay) —
// основной механизм применения, но если попапер закрывается раньше, чем
// сработает таймер (например, дискретный выбор в радио-группе), буфер
// всё равно коммитится, чтобы значение не терялось.
function flush() {
  if (buffer.value !== lastEmitted.value) {
    lastEmitted.value = buffer.value
    props.apply(buffer.value)
  }
}

// Запись из слота попадает в буфер; отправка наружу — с debounce.
function update(v) {
  buffer.value = v
}

// Слот получает ref на текущее значение буфера и функцию записи в него.
const slotProps = { value: buffer, update }
</script>

<template>
  <div class="flex w-full items-center justify-between gap-1">
    <span>{{ label }}</span>
    <NPopover
      :placement="placement"
      trigger="click"
      @update:show="(shown) => { if (!shown) flush() }"
    >
      <template #trigger>
        <NButton
          text
          size="tiny"
          :type="active ? 'primary' : 'default'"
          class="opacity-70 hover:opacity-100"
          :class="active ? '' : 'text-gray-400'"
        >
          <template #icon>
            <NIcon :size="iconSize">
              <component :is="active ? Funnel : FunnelOutline" />
            </NIcon>
          </template>
        </NButton>
      </template>
      <div class="py-1">
        <slot v-bind="slotProps" />
      </div>
    </NPopover>
  </div>
</template>
