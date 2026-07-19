-- 032_section_triggers — минимум точек: linear >= 2, area >= 3.
-- Проверка выполняется AFTER INSERT/UPDATE/DELETE на section_point (constraint trigger было бы
-- избыточно сложно для деферред-проверки в этой модели; используем AFTER STATEMENT-подобную
-- проверку через обычный AFTER ROW триггер, читающий актуальное количество точек участка).
-- Практическое допущение: при формировании участка "с нуля" точки вставляются пакетно в одной
-- транзакции — проверка "минимум точек" выполняется в конце операции (после каждой вставки/
-- удаления), что технически строже необходимого, но соответствует REST-паттерну PostgREST
-- (одна точка = один INSERT-запрос; клиент обязан добавить точки ДО того как считает участок
-- завершённым — минимум проверяется на каждое изменение состава, отклоняя переход ниже минимума).

CREATE OR REPLACE FUNCTION section_check_min_points() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_section_id uuid;
  v_kind section_kind;
  v_count integer;
  v_min integer;
BEGIN
  v_section_id := COALESCE(NEW.section_id, OLD.section_id);
  SELECT kind INTO v_kind FROM section WHERE id = v_section_id;

  IF v_kind IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  v_min := CASE v_kind WHEN 'linear' THEN 2 WHEN 'area' THEN 3 END;

  SELECT count(*) INTO v_count FROM section_point WHERE section_id = v_section_id AND status <> 'deprecated';

  IF v_count < v_min THEN
    RAISE EXCEPTION 'Участок вида % должен иметь минимум % точек (сейчас %)', v_kind, v_min, v_count;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS section_point_min_check_trg ON section_point;
CREATE CONSTRAINT TRIGGER section_point_min_check_trg
  AFTER INSERT OR UPDATE OR DELETE ON section_point
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION section_check_min_points();
