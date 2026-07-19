-- 034_task_section_triggers — работа = листовая; та же org_subtree (section и task в одной зоне);
-- работа не веха; роллап plan_qty работы = Σ task_section.plan_qty; авто-создание daily_plan
-- дней для секционированной работы, аналогично 027 для несекционированной.

CREATE OR REPLACE FUNCTION task_section_check_guards() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_task task%ROWTYPE;
  v_section section%ROWTYPE;
BEGIN
  SELECT * INTO v_task FROM task WHERE id = NEW.task_id;
  SELECT * INTO v_section FROM section WHERE id = NEW.section_id;

  IF NOT task_is_leaf(NEW.task_id) THEN
    RAISE EXCEPTION 'Участки можно привязывать только к листовым работам';
  END IF;

  IF v_task.task_type = 'milestone' THEN
    RAISE EXCEPTION 'Веха не может быть секционирована';
  END IF;

  IF v_task.org_unit_id <> v_section.org_unit_id THEN
    -- Разрешаем участок вышестоящей зоны (переиспользование сверху вниз) — сверяем через org_ancestors.
    IF NOT EXISTS (SELECT 1 FROM org_ancestors(v_task.org_unit_id) a WHERE a.id = v_section.org_unit_id) THEN
      RAISE EXCEPTION 'Участок должен принадлежать той же зоне ответственности или зоне-предку работы';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_section_guards_trg ON task_section;
CREATE TRIGGER task_section_guards_trg
  BEFORE INSERT OR UPDATE ON task_section
  FOR EACH ROW EXECUTE FUNCTION task_section_check_guards();

-- Роллап plan_qty работы после изменения состава/объёма участков.
CREATE OR REPLACE FUNCTION task_section_rollup_to_task() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM task_rollup_plan_qty(COALESCE(NEW.task_id, OLD.task_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS task_section_rollup_trg ON task_section;
CREATE TRIGGER task_section_rollup_trg
  AFTER INSERT OR UPDATE OF plan_qty, status OR DELETE ON task_section
  FOR EACH ROW EXECUTE FUNCTION task_section_rollup_to_task();

-- Авто-создание дней дневного плана для нового task_section, в рамках периода работы.
CREATE OR REPLACE FUNCTION task_section_sync_daily_plan() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_task task%ROWTYPE;
  v_d date;
BEGIN
  SELECT * INTO v_task FROM task WHERE id = NEW.task_id;

  FOR v_d IN SELECT generate_series(v_task.start_date::date, v_task.end_date::date, interval '1 day')::date LOOP
    INSERT INTO task_daily_plan (task_id, task_section_id, date, plan_qty)
    VALUES (NEW.task_id, NEW.id, v_d, 0)
    ON CONFLICT (task_id, task_section_id, date) DO NOTHING;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_section_daily_plan_sync_trg ON task_section;
CREATE TRIGGER task_section_daily_plan_sync_trg
  AFTER INSERT ON task_section
  FOR EACH ROW EXECUTE FUNCTION task_section_sync_daily_plan();
