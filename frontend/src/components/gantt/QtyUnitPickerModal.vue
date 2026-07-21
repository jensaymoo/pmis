<script setup>
//
// Тонкая обёртка над справочником «Единицы объёма работ» в режиме выбора —
// используется полем «Единица объёма» в TaskEditorModal (planning-task-editor.md §3).
// Сама логика грида/пикера — в QtyUnitsGrid.vue (Фаза 5, resources-pattern.md §2.2):
// prop pickMode (Boolean) переключает грид в режим выбора (кнопка «Выбрать» в
// футере), emit pick(record) отдаёт выбранную запись целиком
// ({id, name, short_name, is_integer, org_unit_id, status, ...}).
//
import QtyUnitsGrid from '../references/QtyUnitsGrid.vue'

defineProps({
  show: { type: Boolean, required: true },
})

const emit = defineEmits(['update:show', 'pick'])

/** @param {object} record Выбранная запись справочника единиц объёма работ. */
function onPick(record) {
  emit('pick', record)
  emit('update:show', false)
}
</script>

<template>
  <n-modal
    :show="show"
    preset="card"
    title="Единицы объёма работ"
    class="w-full max-w-3xl"
    @update:show="(value) => emit('update:show', value)"
  >
    <QtyUnitsGrid
      pick-mode
      @pick="onPick"
    />
  </n-modal>
</template>
