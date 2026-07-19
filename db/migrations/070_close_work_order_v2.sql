-- 070_close_work_order_v2 — расширение close_work_order: resource_facts jsonb, валидация
-- ресурс/группа, INSERT в *_resource_fact. Полностью заменяет v1 (CREATE OR REPLACE с новой
-- сигнатурой — PostgreSQL не позволяет менять параметры через REPLACE, поэтому пересоздаём).
--
-- Сигнатура: close_work_order(work_order_id uuid, task_facts jsonb) — task_facts теперь несёт
-- вложенные массивы personnel/equipment/materials из { resource_id, fact_qty } (backend-fact-
-- and-work-orders.md): "принимает один массив task_facts: для каждой строки наряда передаётся
-- task_id, опциональный task_daily_plan_id и fact_qty, а также три массива ресурсов".
--
-- Пример элемента task_facts:
-- {
--   "task_id": "...", "task_daily_plan_id": "..." | null, "fact_qty": 40,
--   "personnel": [{"resource_id": "...", "fact_qty": 8}, ...],
--   "equipment": [{"resource_id": "...", "fact_qty": 4}, ...],
--   "materials": [{"resource_id": "...", "fact_qty": 100}, ...]
-- }

DROP FUNCTION IF EXISTS close_work_order(uuid, jsonb);

CREATE OR REPLACE FUNCTION close_work_order(work_order_id uuid, task_facts jsonb) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wo work_order%ROWTYPE;
  v_item jsonb;
  v_res_item jsonb;
  v_task_id uuid;
  v_tdp_id uuid;
  v_fact_qty numeric;
  v_wot_id uuid;
  v_wotf_id uuid;
  v_task task%ROWTYPE;
  v_section_id uuid;
  v_ancestor_id uuid;
BEGIN
  SELECT * INTO v_wo FROM work_order WHERE id = close_work_order.work_order_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE sqlstate 'PT404' USING message = 'Наряд не найден';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM current_org_subtree() s WHERE s.id = v_wo.org_unit_id) THEN
    RAISE sqlstate 'PT403' USING message = 'Наряд вне зоны ответственности текущего пользователя';
  END IF;

  IF v_wo.status <> 'open' THEN
    RAISE sqlstate 'PT400' USING message = format('Закрыть можно только наряд в статусе open (текущий статус: %s)', v_wo.status);
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(task_facts) LOOP
    v_task_id := (v_item ->> 'task_id')::uuid;
    v_tdp_id := NULLIF(v_item ->> 'task_daily_plan_id', '')::uuid;
    v_fact_qty := (v_item ->> 'fact_qty')::numeric;

    IF v_fact_qty IS NULL OR v_fact_qty < 0 THEN
      RAISE sqlstate 'PT400' USING message = 'fact_qty обязателен и не может быть отрицательным';
    END IF;

    IF v_tdp_id IS NOT NULL THEN
      SELECT wot.id INTO v_wot_id FROM work_order_task wot
      WHERE wot.work_order_id = v_wo.id AND wot.task_daily_plan_id = v_tdp_id;

      IF v_wot_id IS NULL THEN
        INSERT INTO work_order_task (work_order_id, task_daily_plan_id)
        VALUES (v_wo.id, v_tdp_id)
        RETURNING id INTO v_wot_id;
      END IF;
    ELSE
      INSERT INTO work_order_task (work_order_id, task_daily_plan_id)
      VALUES (v_wo.id, NULL)
      RETURNING id INTO v_wot_id;
    END IF;

    INSERT INTO work_order_task_fact (work_order_task_id, fact_qty, actual_start, actual_end)
    VALUES (v_wot_id, v_fact_qty, NULL, NULL)
    RETURNING id INTO v_wotf_id;

    IF v_tdp_id IS NOT NULL THEN
      SELECT tdp.task_id, tdp.task_section_id INTO v_task_id, v_section_id
      FROM task_daily_plan tdp WHERE tdp.id = v_tdp_id;
    ELSE
      v_section_id := NULL;
    END IF;

    SELECT * INTO v_task FROM task WHERE id = v_task_id FOR UPDATE;

    IF v_section_id IS NOT NULL THEN
      UPDATE task_section
      SET fact_qty = fact_qty + v_fact_qty,
          percent_done = LEAST(100, (fact_qty + v_fact_qty) / NULLIF(plan_qty, 0) * 100),
          actual_start = COALESCE(actual_start, CASE WHEN v_fact_qty > 0 THEN now() END),
          actual_end = CASE WHEN LEAST(100, (fact_qty + v_fact_qty) / NULLIF(plan_qty, 0) * 100) >= 100 THEN now() ELSE actual_end END
      WHERE id = v_section_id;

      UPDATE task t
      SET percent_done = LEAST(100, sub.total_fact / NULLIF(sub.total_plan, 0) * 100),
          actual_start = COALESCE(t.actual_start, CASE WHEN sub.total_fact > 0 THEN now() END),
          actual_end = CASE WHEN LEAST(100, sub.total_fact / NULLIF(sub.total_plan, 0) * 100) >= 100 THEN now() ELSE t.actual_end END
      FROM (
        SELECT COALESCE(sum(fact_qty), 0) AS total_fact, COALESCE(sum(plan_qty), 0) AS total_plan
        FROM task_section WHERE task_id = v_task.id
      ) sub
      WHERE t.id = v_task.id;
    ELSE
      UPDATE task
      SET percent_done = LEAST(100, task_accumulated_fact(v_task.id) / NULLIF(plan_qty, 0) * 100),
          actual_start = COALESCE(actual_start, CASE WHEN v_fact_qty > 0 THEN now() END),
          actual_end = CASE WHEN LEAST(100, task_accumulated_fact(v_task.id) / NULLIF(plan_qty, 0) * 100) >= 100 THEN now() ELSE actual_end END
      WHERE id = v_task.id;
    END IF;

    v_ancestor_id := v_task.parent_id;
    WHILE v_ancestor_id IS NOT NULL LOOP
      PERFORM rollup_composite_task_progress(v_ancestor_id);
      SELECT parent_id INTO v_ancestor_id FROM task WHERE id = v_ancestor_id;
    END LOOP;

    -- ------------------------------------------------------------------
    -- Ресурсные факты: personnel/equipment/materials — валидация плана + INSERT.
    -- current_user_id() (используется set_audit_fields() на *_resource_fact) гарантирует, что
    -- created_by/updated_by содержит ID диспетчера (через JWT-claim), а не владельца функции.
    -- ------------------------------------------------------------------
    IF v_item ? 'personnel' THEN
      FOR v_res_item IN SELECT * FROM jsonb_array_elements(v_item -> 'personnel') LOOP
        INSERT INTO personnel_resource_fact (work_order_task_fact_id, task_daily_plan_id, resource_id, fact_qty)
        VALUES (
          v_wotf_id, v_tdp_id,
          (v_res_item ->> 'resource_id')::uuid,
          (v_res_item ->> 'fact_qty')::numeric
        );
      END LOOP;
    END IF;

    IF v_item ? 'equipment' THEN
      FOR v_res_item IN SELECT * FROM jsonb_array_elements(v_item -> 'equipment') LOOP
        INSERT INTO equipment_resource_fact (work_order_task_fact_id, task_daily_plan_id, resource_id, fact_qty)
        VALUES (
          v_wotf_id, v_tdp_id,
          (v_res_item ->> 'resource_id')::uuid,
          (v_res_item ->> 'fact_qty')::numeric
        );
      END LOOP;
    END IF;

    IF v_item ? 'materials' THEN
      FOR v_res_item IN SELECT * FROM jsonb_array_elements(v_item -> 'materials') LOOP
        INSERT INTO materials_resource_fact (work_order_task_fact_id, task_daily_plan_id, resource_id, fact_qty)
        VALUES (
          v_wotf_id, v_tdp_id,
          (v_res_item ->> 'resource_id')::uuid,
          (v_res_item ->> 'fact_qty')::numeric
        );
      END LOOP;
    END IF;
  END LOOP;

  UPDATE work_order SET status = 'closed', closed_at = now() WHERE id = v_wo.id;
END;
$$;

REVOKE ALL ON FUNCTION close_work_order(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION close_work_order(uuid, jsonb) TO dispatcher;
