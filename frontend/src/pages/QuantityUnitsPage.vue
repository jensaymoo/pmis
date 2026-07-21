<script setup>
//
// Экран «Единицы объёма работ» — pmis.wiki/docs/planning-qty-unit.md.
// Маршрут /quantity-units, доступ planner/admin (CRUD), dispatcher (только чтение
// активных). Экран — тонкая обёртка вокруг грида-справочника в режиме управления
// (resources-pattern.md §2.1, §7.1).
//
import QtyUnitsGrid from '../components/references/QtyUnitsGrid.vue'
</script>

<template>
  <div class="h-full flex flex-col">
    <div class="flex-1 min-h-0 px-6 pb-6">
      <QtyUnitsGrid />
    </div>
  </div>
</template>
