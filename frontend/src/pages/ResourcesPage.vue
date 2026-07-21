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
  <div class="h-full flex flex-col">
    <template v-if="title">
      <header class="page-head-left">
        <div>
          <h1 class="page-head-left-title">
            {{ title }}
          </h1>
        </div>
      </header>
      <ResourcesGrid
        :key="kind"
        :kind="kind"
        class="flex-1 min-h-0 px-6 pb-6"
      />
    </template>
    <template v-else>
      <header class="page-head-left">
        <div>
          <h1 class="page-head-left-title">
            Справочник ресурсов
          </h1>
        </div>
      </header>
      <p class="px-6 pb-6">
        Неизвестный вид ресурса
      </p>
    </template>
  </div>
</template>
