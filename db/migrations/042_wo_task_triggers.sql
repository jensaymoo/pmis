-- 042_wo_task_triggers — работа = лист, plan_qty > 0, percent_done < 100, секция обязательна
-- для секционированных работ (унаследовано от task_daily_plan.task_section_id).

CREATE OR REPLACE FUNCTION work_order_task_check_guards() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tdp task_daily_plan%ROWTYPE;
  v_task task%ROWTYPE;
  v_plan_qty numeric;
  v_percent numeric;
BEGIN
  -- NULL task_daily_plan_id = внеплановая строка наряда (fact-and-work-orders-business.md п.15.1) —
  -- разрешена без дальнейших плановых проверок здесь; task_id для внеплановой строки передаётся
  -- вместе с фактом через close_work_order(), а не через work_order_task напрямую.
  IF NEW.task_daily_plan_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_tdp FROM task_daily_plan WHERE id = NEW.task_daily_plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запись дневного плана не найдена';
  END IF;

  SELECT * INTO v_task FROM task WHERE id = v_tdp.task_id;

  IF NOT task_is_leaf(v_task.id) THEN
    RAISE EXCEPTION 'В наряд можно включать только листовые работы';
  END IF;

  -- Критерий "<100%" и plan_qty>0 проверяется по прогрессу работы (несекционированная) либо
  -- task_section.percent_done участка (секционированная), на который указывает task_daily_plan.
  IF v_tdp.task_section_id IS NOT NULL THEN
    SELECT plan_qty, percent_done INTO v_plan_qty, v_percent FROM task_section WHERE id = v_tdp.task_section_id;
  ELSE
    v_plan_qty := v_task.plan_qty;
    v_percent := v_task.percent_done;
  END IF;

  IF v_plan_qty IS NULL OR v_plan_qty <= 0 THEN
    RAISE EXCEPTION 'Работа (или участок) должна иметь плановый объём больше нуля';
  END IF;

  IF v_percent >= 100 THEN
    RAISE EXCEPTION 'Работа (или участок) уже выполнена на 100%% — нельзя включить в новый наряд';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS work_order_task_guards_trg ON work_order_task;
CREATE TRIGGER work_order_task_guards_trg
  BEFORE INSERT OR UPDATE ON work_order_task
  FOR EACH ROW EXECUTE FUNCTION work_order_task_check_guards();
