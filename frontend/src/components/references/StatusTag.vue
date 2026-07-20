<script setup>
/**
 * Тег статуса записи справочника: текст + цветовая семантика, различимо не
 * только по цвету (resources-pattern.md §4.1, §8).
 */

/** @type {Record<string, string>} */
const LABELS = {
  created: 'Создана',
  enabled: 'Активна',
  disabled: 'Отключена',
  deprecated: 'Удалена',
}

/** @type {Record<string, 'default'|'success'|'warning'>} */
const TYPES = {
  created: 'default',
  enabled: 'success',
  disabled: 'warning',
  deprecated: 'default',
}

const props = defineProps({
  status: { type: String, required: true },
})
</script>

<template>
  <n-tag
    :type="TYPES[props.status] ?? 'default'"
    :bordered="false"
    size="small"
    :class="props.status === 'deprecated' ? 'line-through opacity-60' : ''"
  >
    {{ LABELS[props.status] ?? props.status }}
  </n-tag>
</template>
