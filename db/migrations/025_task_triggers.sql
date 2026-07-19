-- 025_task_triggers — рамки дат (child внутри родителя), пересчёт percent_done при правке
-- plan_qty после факта, роллап plan_qty секционированной работы из task_section, правила вехи,
-- блокировка операций у составной работы (переход leaf->composite блокирует task_section/
-- task_daily_plan/*_resource_plan правку — гард на child insert реализован здесь; гард на
-- потомков task_section/daily_plan — в соответствующих доменных миграциях 034/027).

-- ---------------------------------------------------------------------------
-- 1) Рамки дат: child.start_date >= parent.start_date AND child.end_date <= parent.end_date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_check_date_bounds() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_parent task%ROWTYPE;
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO v_parent FROM task WHERE id = NEW.parent_id;
    IF FOUND THEN
      IF NEW.start_date < v_parent.start_date OR NEW.end_date > v_parent.end_date THEN
        RAISE EXCEPTION 'Плановый период работы должен укладываться в рамки родительской работы (%..%)',
          v_parent.start_date, v_parent.end_date;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_date_bounds_trg ON task;
CREATE TRIGGER task_date_bounds_trg
  BEFORE INSERT OR UPDATE OF start_date, end_date, parent_id ON task
  FOR EACH ROW EXECUTE FUNCTION task_check_date_bounds();

-- ---------------------------------------------------------------------------
-- 2) Правила вехи: task_type='milestone' -> duration=0, start_date=end_date,
--    plan_qty IS NULL, qty_unit_id IS NULL. Смена типа на milestone проверяет percent_done IN (0,100).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_apply_milestone_rules() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.task_type = 'milestone' THEN
    IF NEW.percent_done NOT IN (0, 100) THEN
      RAISE EXCEPTION 'Веха допускает percent_done только 0 или 100';
    END IF;
    NEW.end_date := NEW.start_date;
    NEW.duration := 0;
    NEW.plan_qty := NULL;
    NEW.qty_unit_id := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_milestone_rules_trg ON task;
CREATE TRIGGER task_milestone_rules_trg
  BEFORE INSERT OR UPDATE ON task
  FOR EACH ROW EXECUTE FUNCTION task_apply_milestone_rules();

-- ---------------------------------------------------------------------------
-- 3) Пересчёт percent_done при правке plan_qty ПОСЛЕ того, как факт уже был внесён
--    (close_work_order материализует накопленный факт; здесь просто пере-выводим долю).
--    Правило: percent_done = LEAST(100, накопленный_факт / new_plan_qty * 100).
--    Для секционированной работы факт — это Σ task_section.fact_qty; для несекционированной —
--    накопленный факт восстанавливается из текущего percent_done * старого plan_qty (единственный
--    источник факта на task напрямую — сумма fact_qty по work_order_task_fact через work_order_task
--    -> task_daily_plan -> task, что вычисляется отдельной функцией task_accumulated_fact()).
-- ---------------------------------------------------------------------------
-- LANGUAGE plpgsql (не sql): тело ссылается на task_section/work_order_task_fact/work_order_task/
-- task_daily_plan, которые ещё не существуют на момент выполнения этой миграции (025 идёт раньше
-- 027/033/041/042 по номеру) — plpgsql не проверяет разрешение имён при CREATE FUNCTION (только
-- при первом вызове), в отличие от LANGUAGE sql, которая проверяется немедленно и упала бы здесь.
CREATE OR REPLACE FUNCTION task_accumulated_fact(p_task_id uuid) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET row_security = off
AS $$
DECLARE
  v_result numeric;
BEGIN
  IF EXISTS (SELECT 1 FROM task_section ts WHERE ts.task_id = p_task_id) THEN
    SELECT COALESCE(sum(ts.fact_qty), 0) INTO v_result FROM task_section ts WHERE ts.task_id = p_task_id;
  ELSE
    SELECT COALESCE(sum(wotf.fact_qty), 0) INTO v_result
    FROM work_order_task_fact wotf
    JOIN work_order_task wot ON wot.id = wotf.work_order_task_id
    JOIN task_daily_plan tdp ON tdp.id = wot.task_daily_plan_id
    WHERE tdp.task_id = p_task_id;
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION task_recalc_percent_on_plan_qty_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_fact numeric;
BEGIN
  IF NEW.plan_qty IS DISTINCT FROM OLD.plan_qty AND NEW.plan_qty IS NOT NULL AND NEW.plan_qty > 0 THEN
    -- Только для несекционированных работ (секционированные пере-выводятся из task_section
    -- своим собственным путём в 034_task_section_triggers / close_work_order).
    IF NOT EXISTS (SELECT 1 FROM task_section ts WHERE ts.task_id = NEW.id) THEN
      v_fact := task_accumulated_fact(NEW.id);
      NEW.percent_done := LEAST(100, CASE WHEN NEW.plan_qty > 0 THEN v_fact / NEW.plan_qty * 100 ELSE 0 END);
      IF NEW.percent_done < 100 THEN
        NEW.actual_end := NULL;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_recalc_percent_trg ON task;
CREATE TRIGGER task_recalc_percent_trg
  BEFORE UPDATE OF plan_qty ON task
  FOR EACH ROW EXECUTE FUNCTION task_recalc_percent_on_plan_qty_change();

-- ---------------------------------------------------------------------------
-- 4) Роллап plan_qty секционированной работы = Σ task_section.plan_qty. Вызывается из
--    034_task_section_triggers при изменении task_section; здесь только сама функция.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_rollup_plan_qty(p_task_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET row_security = off
AS $$
DECLARE
  v_sum numeric;
BEGIN
  IF EXISTS (SELECT 1 FROM task_section WHERE task_id = p_task_id) THEN
    SELECT COALESCE(sum(plan_qty), 0) INTO v_sum FROM task_section WHERE task_id = p_task_id AND status <> 'deprecated';
    UPDATE task SET plan_qty = v_sum WHERE id = p_task_id;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5) org_unit_id смена -> перепроверка зависимостей (task_dependency), отклонить те, что
--    выходят за пределы org_subtree(). Мягкое удаление (deprecated), не физическое.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_recheck_dependencies_on_org_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.org_unit_id IS DISTINCT FROM OLD.org_unit_id THEN
    UPDATE task_dependency td
    SET status = 'deprecated'
    WHERE (td.from_id = NEW.id OR td.to_id = NEW.id)
      AND td.status <> 'deprecated'
      AND (
        (SELECT t2.org_unit_id FROM task t2 WHERE t2.id = td.from_id) IS DISTINCT FROM
        (SELECT t2.org_unit_id FROM task t2 WHERE t2.id = td.to_id)
      );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_recheck_deps_trg ON task;
-- Триггер навешивается AFTER, т.к. task_dependency ещё не существует на момент 025 (026 создаёт
-- её позже) — фактическое создание триггера переносится в 026_task_dependency.sql, где таблица
-- уже гарантированно есть. Здесь только определение функции.
