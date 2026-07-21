<script setup>
//
// Экран «Гант» (Фаза 6) — planning-gantt.md §4.1: диаграмма занимает всю
// область контента, без внутренних отступов страницы (в отличие от других
// экранов с .page-head-left). Тулбар и сама диаграмма — внутри GanttView.
//
import GanttView from '../components/gantt/GanttView.vue'
</script>

<template>
  <div class="h-full flex flex-col">
    <GanttView class="flex-1 min-h-0" />
  </div>
</template>
