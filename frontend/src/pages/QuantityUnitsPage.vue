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
  <div class="p-6 h-full flex flex-col">
    <n-h1>Единицы объёма работ</n-h1>
    <div class="flex-1 min-h-0">
      <QtyUnitsGrid />
    </div>
  </div>
</template>
