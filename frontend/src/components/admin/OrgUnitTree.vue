<script setup>
//
// Дерево организаций (org_unit) — access-and-roles-users.md §4, resources-pattern.md §2.2.
//
// Два режима:
// - manage — полный CRUD (тулбар экрана «Пользователи», кнопка «Организации»).
// - pick   — режим выбора (лукап из формы пользователя, поле «Организация»):
//            одинарный клик выделяет узел, кнопка «Выбрать» внизу активна
//            только при выделении, двойной клик по-прежнему открывает форму
//            просмотра/редактирования (pattern.md §2.2).
//
// Скоупинг: в отличие от справочников ресурсов, здесь нет деления на
// «свою зону» и «видимую, но не редактируемую родительскую» — единственная
// допущенная роль (admin) редактирует всё видимое поддерево целиком
// (access-and-roles-users.md §4.1, resources-pattern.md §3.3).
//
import { ref, computed, watch, nextTick } from 'vue'
import { getClient } from '../../lib/postgrest'
import { useAuthStore } from '../../stores/auth'
import { useRecordLifecycle } from '../../composables/useRecordLifecycle'
import StatusTag from '../references/StatusTag.vue'

const props = defineProps({
  show: {
    type: Boolean,
    required: true,
  },
  mode: {
    type: String,
    default: 'manage', // 'manage' | 'pick'
  },
  /** Предвыбранный org_unit_id (для открытия дерева повторно из формы пользователя). */
  modelValue: {
    type: String,
    default: null,
  },
})

const emit = defineEmits(['update:show', 'select'])

const auth = useAuthStore()
const lifecycle = useRecordLifecycle({ getClient, table: 'org_unit', entityLabel: 'организацию' })

/** @type {import('vue').Ref<Array<{id: string, name: string, parent_id: string|null, status: string}>>} */
const flatNodes = ref([])
const loading = ref(false)
const selectedKey = ref(null)
const expandedKeys = ref([])

const formShow = ref(false)
const formMode = ref('create') // 'create' | 'edit'
const formLoading = ref(false)
const formRef = ref(null)
const editingRecord = ref(null)
const formParentId = ref(null)
const formModel = ref({ name: '' })
const formRules = {
  name: [{ required: true, message: 'Введите наименование', trigger: ['input', 'blur'] }],
}

/**
 * Строит дерево n-tree (children + служебные key/label) из плоского списка по parent_id.
 * Похоже на построение дерева меню в stores/menu.js, но со своим набором полей.
 */
const treeData = computed(() => {
  const nodes = flatNodes.value.map((n) => ({ ...n, key: n.id, label: n.name, children: [] }))
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const roots = []
  for (const node of nodes) {
    if (node.parent_id && byId.has(node.parent_id)) {
      byId.get(node.parent_id).children.push(node)
    } else {
      roots.push(node)
    }
  }
  const sortByName = (list) => {
    list.sort((a, b) => a.name.localeCompare(b.name, 'ru'))
    for (const n of list) sortByName(n.children)
  }
  sortByName(roots)
  return roots
})

const selectedNode = computed(() => flatNodes.value.find((n) => n.id === selectedKey.value) ?? null)

/**
 * Загружает список организаций видимого поддерева целиком (обычно немного
 * записей — дерево строится на клиенте, серверная пагинация не требуется,
 * см. бриф задачи).
 * @returns {Promise<void>}
 */
async function reload() {
  loading.value = true
  try {
    const { data, error } = await getClient()
      .from('org_unit')
      .select('id,name,parent_id,status')
      .order('name')
    if (error) {
      console.error('Не удалось загрузить организации:', error)
      flatNodes.value = []
    } else {
      flatNodes.value = data
    }
  } finally {
    loading.value = false
  }
}

watch(
  () => props.show,
  (visible) => {
    if (visible) {
      selectedKey.value = props.modelValue ?? null
      reload()
    }
  },
  { immediate: true },
)

/** Одинарный клик — только выделение, не открывает и не закрывает дерево (pattern.md §6.1). */
function onUpdateSelectedKeys(keys) {
  selectedKey.value = keys[0] ?? null
}

/** Двойной клик по узлу — открывает форму просмотра/редактирования (pattern.md §2.4, §6.1). */
function onNodeDblClick(node) {
  openEditForm(node)
}

function openCreateForm(parentId) {
  formMode.value = 'create'
  editingRecord.value = null
  formParentId.value = parentId
  formModel.value = { name: '' }
  formShow.value = true
}

function openEditForm(node) {
  formMode.value = 'edit'
  editingRecord.value = node
  formParentId.value = node.parent_id
  formModel.value = { name: node.name }
  formShow.value = true
}

function closeForm() {
  formShow.value = false
  editingRecord.value = null
}

/**
 * Отправка формы создания/редактирования узла. При создании дочернего узла
 * parent_id предзаполнен и неизменяем (access-and-roles-users.md §4.3).
 * @returns {Promise<void>}
 */
async function onFormSubmit() {
  try {
    await formRef.value?.validate()
  } catch {
    return
  }

  formLoading.value = true
  try {
    if (formMode.value === 'create') {
      const { error } = await getClient()
        .from('org_unit')
        .insert({ name: formModel.value.name, parent_id: formParentId.value })
      if (error) {
        console.error('Не удалось создать организацию:', error)
        return
      }
      if (formParentId.value && !expandedKeys.value.includes(formParentId.value)) {
        expandedKeys.value = [...expandedKeys.value, formParentId.value]
      }
    } else {
      const { error } = await getClient()
        .from('org_unit')
        .update({ name: formModel.value.name })
        .eq('id', editingRecord.value.id)
      if (error) {
        console.error('Не удалось обновить организацию:', error)
        return
      }
    }
    closeForm()
    await reload()
  } finally {
    formLoading.value = false
  }
}

async function onDeactivate(node) {
  if (await lifecycle.deactivate(node)) await reload()
}
async function onActivate(node) {
  if (await lifecycle.activate(node)) await reload()
}
async function onSoftDelete(node) {
  if (await lifecycle.softDelete(node)) await reload()
}
async function onRestore(node) {
  if (await lifecycle.restore(node)) await reload()
}

function onClose() {
  emit('update:show', false)
}

/** Кнопка «Выбрать» в режиме pick — возвращает выделенный узел вызывающему полю (pattern.md §7.4). */
function onPick() {
  if (!selectedNode.value) return
  emit('select', { id: selectedNode.value.id, name: selectedNode.value.name })
  emit('update:show', false)
}

/** Фокус на дереве при открытии модалки (resources-pattern.md §8). */
const treeWrapperRef = ref(null)
watch(
  () => props.show,
  async (visible) => {
    if (visible) {
      await nextTick()
      treeWrapperRef.value?.focus?.()
    }
  },
)
</script>

<template>
  <n-modal
    :show="props.show"
    preset="card"
    title="Организации"
    class="w-full max-w-lg"
    @update:show="(v) => emit('update:show', v)"
    @close="onClose"
  >
    <div
      ref="treeWrapperRef"
      class="flex flex-col gap-2"
      tabindex="-1"
    >
      <div
        v-if="props.mode === 'manage'"
        class="flex justify-end"
      >
        <n-button
          size="small"
          type="primary"
          @click="openCreateForm(auth.user?.org_unit_id ?? null)"
        >
          Создать
        </n-button>
      </div>

      <n-spin :show="loading">
        <div
          v-if="!loading && treeData.length === 0"
          class="py-8 text-center text-gray-400"
        >
          Пока нет ни одной организации, создайте первую
        </div>
        <n-tree
          v-else
          block-line
          :data="treeData"
          :selected-keys="selectedKey ? [selectedKey] : []"
          :expanded-keys="expandedKeys"
          key-field="key"
          label-field="label"
          children-field="children"
          class="max-h-96 overflow-y-auto"
          @update:selected-keys="onUpdateSelectedKeys"
          @update:expanded-keys="(keys) => (expandedKeys = keys)"
        >
          <template #default="{ option }">
            <div
              class="flex items-center justify-between gap-2 py-0.5"
              @dblclick="onNodeDblClick(option)"
            >
              <span :class="option.status === 'deprecated' ? 'line-through opacity-60' : ''">
                {{ option.label }}
              </span>
              <StatusTag :status="option.status" />
              <div
                v-if="props.mode === 'manage'"
                class="flex items-center gap-1"
              >
                <n-button
                  quaternary
                  size="tiny"
                  title="Добавить дочернюю"
                  @click.stop="openCreateForm(option.id)"
                >
                  +
                </n-button>
                <n-button
                  v-if="lifecycle.availableActions(option.status, true).includes('activate')"
                  quaternary
                  size="tiny"
                  title="Активировать"
                  @click.stop="onActivate(option)"
                >
                  Вкл
                </n-button>
                <n-button
                  v-if="lifecycle.availableActions(option.status, true).includes('deactivate')"
                  quaternary
                  size="tiny"
                  title="Деактивировать"
                  @click.stop="onDeactivate(option)"
                >
                  Откл
                </n-button>
                <n-button
                  v-if="lifecycle.availableActions(option.status, true).includes('delete')"
                  quaternary
                  size="tiny"
                  title="Удалить"
                  @click.stop="onSoftDelete(option)"
                >
                  Удал
                </n-button>
                <n-button
                  v-if="lifecycle.availableActions(option.status, true).includes('restore')"
                  quaternary
                  size="tiny"
                  title="Восстановить"
                  @click.stop="onRestore(option)"
                >
                  Восст
                </n-button>
              </div>
            </div>
          </template>
        </n-tree>
      </n-spin>
    </div>

    <template
      v-if="props.mode === 'pick'"
      #footer
    >
      <div class="flex justify-end">
        <n-button
          type="primary"
          :disabled="!selectedNode"
          @click="onPick"
        >
          Выбрать
        </n-button>
      </div>
    </template>

    <n-modal
      :show="formShow"
      preset="card"
      :title="formMode === 'create' ? 'Новая организация' : 'Редактирование организации'"
      class="w-full max-w-sm"
      @update:show="(v) => !v && closeForm()"
    >
      <n-form
        ref="formRef"
        :model="formModel"
        :rules="formRules"
        :disabled="formLoading"
        @submit.prevent="onFormSubmit"
      >
        <n-form-item
          label="Наименование"
          path="name"
        >
          <n-input
            v-model:value="formModel.name"
            :disabled="formLoading"
            placeholder="Например, «Участок №1»"
          />
        </n-form-item>
        <n-form-item
          v-if="formMode === 'create'"
          label="Родительская организация"
        >
          <n-input
            :value="flatNodes.find((n) => n.id === formParentId)?.name ?? '— (корневая)'"
            disabled
          />
        </n-form-item>
        <n-form-item :show-label="false">
          <div class="flex justify-end gap-2">
            <n-button
              :disabled="formLoading"
              @click="closeForm"
            >
              Отмена
            </n-button>
            <n-button
              type="primary"
              attr-type="submit"
              :loading="formLoading"
              :disabled="formLoading"
            >
              Сохранить
            </n-button>
          </div>
        </n-form-item>
      </n-form>
    </n-modal>
  </n-modal>
</template>
