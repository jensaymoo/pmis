-- 043_close_work_order_v1 — SECURITY DEFINER: суммирование факта, percent_done, actual_start/end,
-- роллап по дереву. v1 — без ресурсных фактов (добавляются в 070_close_work_order_v2 как
-- resource_facts jsonb). Сигнатура v1 по backend-fact-and-work-orders.md:
-- close_work_order(work_order_id uuid, task_facts jsonb).
--
-- task_facts: массив объектов { task_id, task_daily_plan_id (опционально, NULL=внеплановая
-- строка), fact_qty }.

CREATE OR REPLACE FUNCTION close_work_order(work_order_id uuid, task_facts jsonb) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wo work_order%ROWTYPE;
  v_item jsonb;
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

    -- Находим или создаём work_order_task по (work_order_id, task_daily_plan_id) либо явному task_id
    -- для внеплановой строки (task_daily_plan_id IS NULL — UNIQUE(work_order_id, task_daily_plan_id)
    -- допускает максимум одну NULL-строку на наряд по стандартной SQL-семантике NULL<>NULL в UNIQUE,
    -- поэтому внеплановых строк может быть несколько; ищем по совпадению НЕ через UNIQUE, а явно).
    IF v_tdp_id IS NOT NULL THEN
      SELECT wot.id INTO v_wot_id FROM work_order_task wot
      WHERE wot.work_order_id = v_wo.id AND wot.task_daily_plan_id = v_tdp_id;

      IF v_wot_id IS NULL THEN
        INSERT INTO work_order_task (work_order_id, task_daily_plan_id)
        VALUES (v_wo.id, v_tdp_id)
        RETURNING id INTO v_wot_id;
      END IF;
    ELSE
      -- Внеплановая строка: создаём новую work_order_task без task_daily_plan_id при каждом
      -- вызове (нет естественного ключа для "найти существующую" без daily_plan — по духу
      -- fact-and-work-orders-business.md п.15.1 внеплановый факт создаётся отдельной строкой).
      INSERT INTO work_order_task (work_order_id, task_daily_plan_id)
      VALUES (v_wo.id, NULL)
      RETURNING id INTO v_wot_id;
    END IF;

    -- Пишем work_order_task_fact.
    INSERT INTO work_order_task_fact (work_order_task_id, fact_qty, actual_start, actual_end)
    VALUES (v_wot_id, v_fact_qty, NULL, NULL)
    RETURNING id INTO v_wotf_id;

    -- Определяем task и (для секционированной) section, затрагиваемые этой строкой.
    IF v_tdp_id IS NOT NULL THEN
      SELECT tdp.task_id, tdp.task_section_id INTO v_task_id, v_section_id
      FROM task_daily_plan tdp WHERE tdp.id = v_tdp_id;
    ELSE
      v_section_id := NULL; -- внеплановый факт по task_id, переданному клиентом напрямую
    END IF;

    SELECT * INTO v_task FROM task WHERE id = v_task_id FOR UPDATE;

    IF v_section_id IS NOT NULL THEN
      -- Секционированная работа: материализуем факт по участку.
      UPDATE task_section
      SET fact_qty = fact_qty + v_fact_qty,
          percent_done = LEAST(100, (fact_qty + v_fact_qty) / NULLIF(plan_qty, 0) * 100),
          actual_start = COALESCE(actual_start, CASE WHEN v_fact_qty > 0 THEN now() END),
          actual_end = CASE WHEN LEAST(100, (fact_qty + v_fact_qty) / NULLIF(plan_qty, 0) * 100) >= 100 THEN now() ELSE actual_end END
      WHERE id = v_section_id;

      -- Прогресс работы = SUM(fact_qty)/SUM(plan_qty) по всем её участкам.
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
      -- Несекционированная работа: факт прямо на task. task_accumulated_fact() уже включает
      -- только что вставленный work_order_task_fact (см. INSERT выше) — НЕ прибавляем v_fact_qty
      -- повторно, иначе двойной счёт.
      UPDATE task
      SET percent_done = LEAST(100, task_accumulated_fact(v_task.id) / NULLIF(plan_qty, 0) * 100),
          actual_start = COALESCE(actual_start, CASE WHEN v_fact_qty > 0 THEN now() END),
          actual_end = CASE WHEN LEAST(100, task_accumulated_fact(v_task.id) / NULLIF(plan_qty, 0) * 100) >= 100 THEN now() ELSE actual_end END
      WHERE id = v_task.id;
    END IF;

    -- Rollup по дереву: пересчитываем percent_done каждого предка как SUM(fact)/SUM(plan)
    -- по ВСЕМ листовым потомкам.
    v_ancestor_id := v_task.parent_id;
    WHILE v_ancestor_id IS NOT NULL LOOP
      PERFORM rollup_composite_task_progress(v_ancestor_id);
      SELECT parent_id INTO v_ancestor_id FROM task WHERE id = v_ancestor_id;
    END LOOP;
  END LOOP;

  UPDATE work_order SET status = 'closed', closed_at = now() WHERE id = v_wo.id;
END;
$$;

-- Пересчёт percent_done составной работы = SUM(fact_qty)/SUM(plan_qty) по всем ЛИСТОВЫМ потомкам
-- (рекурсивно, не только непосредственным детям).
CREATE OR REPLACE FUNCTION rollup_composite_task_progress(p_task_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $$
DECLARE
  v_total_fact numeric;
  v_total_plan numeric;
BEGIN
  WITH RECURSIVE descendants AS (
    SELECT id FROM task WHERE parent_id = p_task_id
    UNION ALL
    SELECT t.id FROM task t JOIN descendants d ON t.parent_id = d.id
  ),
  leaves AS (
    SELECT d.id FROM descendants d WHERE NOT EXISTS (SELECT 1 FROM task c WHERE c.parent_id = d.id)
  )
  SELECT
    COALESCE(sum(
      CASE WHEN EXISTS (SELECT 1 FROM task_section ts WHERE ts.task_id = l.id)
        THEN (SELECT COALESCE(sum(ts.fact_qty), 0) FROM task_section ts WHERE ts.task_id = l.id)
        ELSE task_accumulated_fact(l.id)
      END
    ), 0),
    COALESCE(sum(
      CASE WHEN EXISTS (SELECT 1 FROM task_section ts WHERE ts.task_id = l.id)
        THEN (SELECT COALESCE(sum(ts.plan_qty), 0) FROM task_section ts WHERE ts.task_id = l.id)
        ELSE COALESCE(t.plan_qty, 0)
      END
    ), 0)
  INTO v_total_fact, v_total_plan
  FROM leaves l JOIN task t ON t.id = l.id;

  UPDATE task
  SET percent_done = CASE WHEN v_total_plan > 0 THEN LEAST(100, v_total_fact / v_total_plan * 100) ELSE percent_done END
  WHERE id = p_task_id;
END;
$$;

REVOKE ALL ON FUNCTION close_work_order(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION close_work_order(uuid, jsonb) TO dispatcher;
