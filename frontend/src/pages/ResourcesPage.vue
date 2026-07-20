<script setup>
//
// Экран справочника ресурсов — читает route.params.kind (personnel/equipment/
// materials) и рендерит ResourcesGrid соответствующего вида. См. CLAUDE.md
// «Экраны» и resources-pattern.md.
//
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import ResourcesGrid from '../components/resources/ResourcesGrid.vue'

/** @type {Record<string, string>} */
const TITLES = {
  personnel: 'Персонал',
  equipment: 'Техника',
  materials: 'Материалы',
}

const route = useRoute()

const kind = computed(() => route.params.kind)
const title = computed(() => TITLES[kind.value] ?? null)
</script>

<template>
  <div class="p-6 h-full flex flex-col">
    <template v-if="title">
      <n-h1>{{ title }}</n-h1>
      <ResourcesGrid
        :key="kind"
        :kind="kind"
        class="flex-1 min-h-0"
      />
    </template>
    <template v-else>
      <n-h1>Справочник ресурсов</n-h1>
      <p>Неизвестный вид ресурса</p>
    </template>
  </div>
</template>
